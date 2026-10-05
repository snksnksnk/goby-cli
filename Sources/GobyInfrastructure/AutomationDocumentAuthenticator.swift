import CryptoKit
import Foundation
import Security

public struct GADAutomationDocumentAuthentication: Equatable, Sendable {
    public let generation: UInt64
    public let tag: Data

    public init(generation: UInt64, tag: Data) {
        self.generation = generation
        self.tag = tag
    }
}

public enum GADAutomationDocumentFreshness: Equatable, Sendable {
    case current
    case previous
    case prepared
}

public enum GADAutomationDocumentAuthenticationError: LocalizedError, Equatable, Sendable {
    case authenticationFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "The saved automations failed authenticity checks. Goby did not run them. Restore a verified backup or review the schedules again."
        case let .keychain(status):
            "The system Keychain could not verify saved automations (\(status)). Goby did not run them."
        }
    }
}

public protocol GADAutomationDocumentAuthenticating: Sendable {
    func issue(for payload: Data) async throws -> GADAutomationDocumentAuthentication
    func commit(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws
    func verify(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws -> GADAutomationDocumentFreshness
    func discardPrepared() async throws
}

protocol GADAutomationAuthenticationStateIO: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

private struct KeychainAutomationAuthenticationStateIO: GADAutomationAuthenticationStateIO {
    let service: String
    let account: String
    let accessGroup: String?

    func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GADAutomationDocumentAuthenticationError.keychain(status)
        }
        guard let data = result as? Data else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        return data
    }

    func save(_ data: Data) throws {
        let query = baseQuery()
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw GADAutomationDocumentAuthenticationError.keychain(update)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw GADAutomationDocumentAuthenticationError.keychain(add)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

#if DEBUG
private struct UITestFileAutomationAuthenticationStateIO: GADAutomationAuthenticationStateIO {
    let fileURL: URL

    func load() throws -> Data? {
        do {
            return try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ data: Data) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif

/// Keeps the HMAC secret and the accepted generation window outside Application
/// Support. The immediately previous generation is accepted only so an
/// interrupted atomic save can be recovered; PersistentStore quarantines it
/// before exposing any executable automation state.
public actor KeychainAutomationDocumentAuthenticator: GADAutomationDocumentAuthenticating {
    private struct State: Codable, Sendable {
        var secret: Data
        var currentGeneration: UInt64
        var currentDigest: Data?
        var previousGeneration: UInt64
        var previousDigest: Data?
        var preparedGeneration: UInt64?
        var preparedDigest: Data?
    }

    private let stateIO: any GADAutomationAuthenticationStateIO
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        scope: String,
        service: String = "com.goby.agentic-dashboard.automation-authenticity",
        accessGroup: String? = nil
    ) {
        self.stateIO = KeychainAutomationAuthenticationStateIO(
            service: service,
            account: "automations-" + Self.scopeDigest(scope),
            accessGroup: accessGroup
        )
    }

    init(stateIO: any GADAutomationAuthenticationStateIO) {
        self.stateIO = stateIO
    }

    public func issue(for payload: Data) async throws -> GADAutomationDocumentAuthentication {
        await acquireOperation()
        defer { releaseOperation() }
        let state: State
        if let stored = try await loadState() {
            state = stored
        } else {
            let created = State(
                secret: Self.randomSecret(),
                currentGeneration: 0,
                currentDigest: nil,
                previousGeneration: 0,
                previousDigest: nil,
                preparedGeneration: nil,
                preparedDigest: nil
            )
            try await saveState(created)
            state = created
        }
        let next = state.currentGeneration.addingReportingOverflow(1)
        guard !next.overflow else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        let digest = Self.digest(payload)
        if let preparedGeneration = state.preparedGeneration,
           let preparedDigest = state.preparedDigest {
            guard preparedGeneration == next.partialValue,
                  preparedDigest == digest else {
                throw GADAutomationDocumentAuthenticationError.authenticationFailed
            }
        } else {
            var reserved = state
            reserved.preparedGeneration = next.partialValue
            reserved.preparedDigest = digest
            try await saveState(reserved)
        }
        return GADAutomationDocumentAuthentication(
            generation: next.partialValue,
            tag: Self.tag(payload: payload, generation: next.partialValue, secret: state.secret)
        )
    }

    public func commit(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard var state = try await loadState() else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        let digest = Self.digest(payload)
        guard authentication.generation == state.preparedGeneration,
              digest == state.preparedDigest,
              Self.constantTimeEqual(
                Self.tag(payload: payload, generation: authentication.generation, secret: state.secret),
                authentication.tag
              ) else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        state.previousGeneration = state.currentGeneration
        state.previousDigest = state.currentDigest
        state.currentGeneration = authentication.generation
        state.currentDigest = digest
        state.preparedGeneration = nil
        state.preparedDigest = nil
        try await saveState(state)
    }

    public func verify(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws -> GADAutomationDocumentFreshness {
        await acquireOperation()
        defer { releaseOperation() }
        guard let state = try await loadState() else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        let freshness: GADAutomationDocumentFreshness
        let digest = Self.digest(payload)
        if authentication.generation == state.currentGeneration,
           digest == state.currentDigest {
            freshness = .current
        } else if authentication.generation > 0,
                  authentication.generation == state.previousGeneration,
                  digest == state.previousDigest {
            freshness = .previous
        } else if authentication.generation == state.preparedGeneration,
                  digest == state.preparedDigest {
            freshness = .prepared
        } else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        let expected = Self.tag(
            payload: payload,
            generation: authentication.generation,
            secret: state.secret
        )
        guard Self.constantTimeEqual(expected, authentication.tag) else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        return freshness
    }

    public func discardPrepared() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard var state = try await loadState(), state.preparedGeneration != nil else { return }
        state.preparedGeneration = nil
        state.preparedDigest = nil
        try await saveState(state)
    }

    private func loadState() async throws -> State? {
        let stateIO = stateIO
        guard let data = try await Task.detached(priority: .utility, operation: {
            try stateIO.load()
        }).value else {
            return nil
        }
        guard let state = try? decoder.decode(State.self, from: data),
              state.secret.count == 32,
              state.previousGeneration <= state.currentGeneration,
              (state.preparedGeneration == nil) == (state.preparedDigest == nil) else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        return state
    }

    private func saveState(_ state: State) async throws {
        let data = try encoder.encode(state)
        let stateIO = stateIO
        try await Task.detached(priority: .utility) {
            try stateIO.save(data)
        }.value
    }

    private func acquireOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private static func randomSecret() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func tag(payload: Data, generation: UInt64, secret: Data) -> Data {
        var value = generation.bigEndian
        var authenticated = Data(bytes: &value, count: MemoryLayout<UInt64>.size)
        authenticated.append(payload)
        return Data(HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: secret)
        ))
    }

    private static func digest(_ payload: Data) -> Data {
        Data(SHA256.hash(data: payload))
    }

    private static func scopeDigest(_ scope: String) -> String {
        SHA256.hash(data: Data(scope.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

#if DEBUG
/// Cross-process authenticity state for isolated UI-test stores. Production
/// composition never selects this implementation and continues to keep its
/// automation secret in the user's Keychain.
public actor UITestFileAutomationDocumentAuthenticator: GADAutomationDocumentAuthenticating {
    private let authenticator: KeychainAutomationDocumentAuthenticator

    public init(directoryURL: URL) {
        authenticator = KeychainAutomationDocumentAuthenticator(
            stateIO: UITestFileAutomationAuthenticationStateIO(
                fileURL: directoryURL
                    .standardizedFileURL
                    .appending(path: ".goby-ui-test-automation-authenticity.json")
            )
        )
    }

    public func issue(for payload: Data) async throws -> GADAutomationDocumentAuthentication {
        try await authenticator.issue(for: payload)
    }

    public func commit(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws {
        try await authenticator.commit(authentication, payload: payload)
    }

    public func verify(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws -> GADAutomationDocumentFreshness {
        try await authenticator.verify(authentication, payload: payload)
    }

    public func discardPrepared() async throws {
        try await authenticator.discardPrepared()
    }
}
#endif
