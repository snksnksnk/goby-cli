import Darwin
import CryptoKit
import Foundation
import GobyApplication
import Security

public struct GADHostAuthorityMarker: Codable, Equatable, Sendable {
    public let id: String
    public let hostID: HostID
    public let hostVersion: String
    public let activatedAt: Date
    public let preHostBackup: GADPreHostBackupReceipt
    public let generation: UInt64
    public let authenticationTag: Data

    public init(
        id: String = UUID().uuidString.lowercased(),
        hostID: HostID,
        hostVersion: String,
        activatedAt: Date = .now,
        preHostBackup: GADPreHostBackupReceipt,
        generation: UInt64 = 0,
        authenticationTag: Data = Data()
    ) {
        self.id = id
        self.hostID = hostID
        self.hostVersion = hostVersion
        self.activatedAt = activatedAt
        self.preHostBackup = preHostBackup
        self.generation = generation
        self.authenticationTag = authenticationTag
    }


    fileprivate func authenticatedPayload(using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(AuthenticatedPayload(
            id: id,
            hostID: hostID,
            hostVersion: hostVersion,
            activatedAt: activatedAt,
            preHostBackup: preHostBackup
        ))
    }

    fileprivate func sealed(generation: UInt64, authenticationTag: Data) -> Self {
        Self(
            id: id,
            hostID: hostID,
            hostVersion: hostVersion,
            activatedAt: activatedAt,
            preHostBackup: preHostBackup,
            generation: generation,
            authenticationTag: authenticationTag
        )
    }

    private struct AuthenticatedPayload: Codable {
        let id: String
        let hostID: HostID
        let hostVersion: String
        let activatedAt: Date
        let preHostBackup: GADPreHostBackupReceipt
    }
}

public enum GADHostAuthorityMarkerError: LocalizedError, Equatable, Sendable {
    case missing
    case oversized
    case unsafeLocation
    case malformed
    case authenticationFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing:
            "The background host has neither a pending handoff nor retained restart authority."
        case .oversized:
            "The background-host authority record exceeded its safe size limit."
        case .unsafeLocation:
            "The background-host authority record is not an owner-only regular file in its expected directory."
        case .malformed:
            "The background-host authority record could not be decoded safely."
        case .authenticationFailed:
            "The background-host authority record is stale or failed authentication. Turn Remote Access on again from the foreground app."
        case let .keychain(status):
            "The system Keychain could not verify background-host authority (\(status))."
        }
    }
}

public struct GADHostAuthorityAuthentication: Equatable, Sendable {
    public let generation: UInt64
    public let tag: Data

    public init(generation: UInt64, tag: Data) {
        self.generation = generation
        self.tag = tag
    }
}

public protocol GADHostAuthorityAuthenticating: Sendable {
    func issue(for payload: Data) async throws -> GADHostAuthorityAuthentication
    func verify(_ authentication: GADHostAuthorityAuthentication, payload: Data) async throws
    func revokeCurrentAuthority() async throws
}

/// Shared app/helper authority state. The generation and HMAC key never enter
/// Application Support, so restoring an older marker and backup cannot undo a
/// foreground revocation performed before the one-writer lease is released.
public actor KeychainHostAuthorityAuthenticator: GADHostAuthorityAuthenticating {
    private struct State: Codable, Sendable {
        var secret: Data
        var currentGeneration: UInt64
        var revokedThrough: UInt64
    }

    private let service: String
    private let accessGroup: String?
    private let account = "background-host-authority"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "com.goby.agentic-dashboard.host-authority",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func issue(for payload: Data) async throws -> GADHostAuthorityAuthentication {
        var state = try loadState() ?? State(
            secret: Self.randomSecret(),
            currentGeneration: 0,
            revokedThrough: 0
        )
        let next = max(state.currentGeneration, state.revokedThrough).addingReportingOverflow(1)
        guard !next.overflow else { throw GADHostAuthorityMarkerError.authenticationFailed }
        state.currentGeneration = next.partialValue
        try saveState(state)
        return GADHostAuthorityAuthentication(
            generation: state.currentGeneration,
            tag: Self.tag(payload: payload, generation: state.currentGeneration, secret: state.secret)
        )
    }

    public func verify(
        _ authentication: GADHostAuthorityAuthentication,
        payload: Data
    ) async throws {
        guard let state = try loadState(),
              authentication.generation == state.currentGeneration,
              authentication.generation > state.revokedThrough else {
            throw GADHostAuthorityMarkerError.authenticationFailed
        }
        let expected = Self.tag(
            payload: payload,
            generation: authentication.generation,
            secret: state.secret
        )
        guard Self.constantTimeEqual(expected, authentication.tag) else {
            throw GADHostAuthorityMarkerError.authenticationFailed
        }
    }

    public func revokeCurrentAuthority() async throws {
        guard var state = try loadState() else { return }
        state.revokedThrough = max(state.revokedThrough, state.currentGeneration)
        try saveState(state)
    }

    private func loadState() throws -> State? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GADHostAuthorityMarkerError.keychain(status)
        }
        guard let data = result as? Data,
              let state = try? decoder.decode(State.self, from: data),
              state.secret.count == 32 else {
            throw GADHostAuthorityMarkerError.authenticationFailed
        }
        return state
    }

    private func saveState(_ state: State) throws {
        let data = try encoder.encode(state)
        let query = baseQuery()
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw GADHostAuthorityMarkerError.keychain(update)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw GADHostAuthorityMarkerError.keychain(add)
        }
    }

    private func baseQuery() -> [String: Any] {
        Self.keychainQuery(service: service, account: account, accessGroup: accessGroup)
    }

    static func keychainQuery(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            // File-based macOS Keychain ignores access groups. Its per-binary
            // ACL can block a launchd helper on an invisible password prompt.
            // Do not import legacy authority: a fresh foreground handoff must
            // issue new proofs, so an old revoked marker stays invalid.
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
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

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

/// Durable proof that a validated permanent helper may recover after its own
/// crash. The helper revokes this marker during checked update/removal
/// shutdown. It contains no pairing secret or alternate canonical state.
public actor GADHostAuthorityMarkerStore {
    public static let fileName = "host-authority.json"
    public static let maximumBytes = 8 * 1_024 * 1_024

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let authenticator: any GADHostAuthorityAuthenticating

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        authenticator: (any GADHostAuthorityAuthenticating)? = nil
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.authenticator = authenticator ?? KeychainHostAuthorityAuthenticator()
    }

    @discardableResult
    public func save(_ marker: GADHostAuthorityMarker) async throws -> GADHostAuthorityMarker {
        try prepareDirectory()
        let payload = try marker.authenticatedPayload(using: encoder)
        let authentication = try await authenticator.issue(for: payload)
        let sealed = marker.sealed(
            generation: authentication.generation,
            authenticationTag: authentication.tag
        )
        let data = try encoder.encode(sealed)
        guard data.count <= Self.maximumBytes else {
            throw GADHostAuthorityMarkerError.oversized
        }
        let destination = directoryURL.appending(path: Self.fileName)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try validateRegularOwnerOnlyFile(destination)
        }
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path(percentEncoded: false)
        )
        try validateRegularOwnerOnlyFile(destination)
        return sealed
    }

    public func load() async throws -> GADHostAuthorityMarker {
        let source = directoryURL.appending(path: Self.fileName)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw GADHostAuthorityMarkerError.missing
        }
        try validateDirectory()
        try validateRegularOwnerOnlyFile(source)
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let count = values.fileSize, count <= Self.maximumBytes else {
            throw GADHostAuthorityMarkerError.oversized
        }
        do {
            let marker = try decoder.decode(
                GADHostAuthorityMarker.self,
                from: Data(contentsOf: source)
            )
            guard marker.generation > 0, !marker.authenticationTag.isEmpty else {
                throw GADHostAuthorityMarkerError.authenticationFailed
            }
            let payload = try marker.authenticatedPayload(using: encoder)
            try await authenticator.verify(
                GADHostAuthorityAuthentication(
                    generation: marker.generation,
                    tag: marker.authenticationTag
                ),
                payload: payload
            )
            return marker
        } catch let error as GADHostAuthorityMarkerError {
            throw error
        } catch {
            throw GADHostAuthorityMarkerError.malformed
        }
    }

    public func revoke() async throws {
        try await authenticator.revokeCurrentAuthority()
        let source = directoryURL.appending(path: Self.fileName)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        try validateDirectory()
        try validateRegularOwnerOnlyFile(source)
        try fileManager.removeItem(at: source)
    }

    private func prepareDirectory() throws {
        if fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try validateDirectory()
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path(percentEncoded: false)
        )
        try validateDirectory()
    }

    private func validateDirectory() throws {
        var status = stat()
        let result = directoryURL.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o077) == 0 else {
            throw GADHostAuthorityMarkerError.unsafeLocation
        }
    }

    private func validateRegularOwnerOnlyFile(_ url: URL) throws {
        var status = stat()
        let result = url.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o077) == 0 else {
            throw GADHostAuthorityMarkerError.unsafeLocation
        }
    }
}
