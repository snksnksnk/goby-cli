import Foundation
import GobyApplication
import Security

public enum KeychainRelayHostAdmissionStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "The system Keychain could not update relay access: \($0)" }
                ?? "The system Keychain could not update relay access (\(status))."
        case .invalidStoredValue:
            return "The relay access key in Keychain is unreadable or expired. Add a current key."
        }
    }
}

public actor KeychainRelayHostAdmissionStore: GADRelayHostAdmissionPersisting {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.goby.agentic-dashboard.relay-admission",
        account: String = "host-installation",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func credential() async throws -> GADRelayHostAdmissionCredential? {
        let service = self.service
        let account = self.account
        let accessGroup = self.accessGroup
        return try await Task.detached(priority: .userInitiated) {
            try Self.credentialSynchronously(
                service: service,
                account: account,
                accessGroup: accessGroup
            )
        }.value
    }

    public func save(_ credential: GADRelayHostAdmissionCredential) async throws {
        let service = self.service
        let account = self.account
        let accessGroup = self.accessGroup
        try await Task.detached(priority: .userInitiated) {
            try Self.saveSynchronously(
                credential,
                service: service,
                account: account,
                accessGroup: accessGroup
            )
        }.value
    }

    public func remove() async throws {
        let service = self.service
        let account = self.account
        let accessGroup = self.accessGroup
        try await Task.detached(priority: .userInitiated) {
            let status = SecItemDelete(Self.baseQuery(
                service: service,
                account: account,
                accessGroup: accessGroup
            ) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainRelayHostAdmissionStoreError.keychain(status)
            }
        }.value
    }

    nonisolated private static func credentialSynchronously(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> GADRelayHostAdmissionCredential? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainRelayHostAdmissionStoreError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainRelayHostAdmissionStoreError.invalidStoredValue
        }
        do {
            return try GADRelayHostAdmissionCredential(value)
        } catch {
            throw KeychainRelayHostAdmissionStoreError.invalidStoredValue
        }
    }

    nonisolated private static func saveSynchronously(
        _ credential: GADRelayHostAdmissionCredential,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        guard let data = credential.rawValue.data(using: .utf8) else {
            throw KeychainRelayHostAdmissionStoreError.invalidStoredValue
        }
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainRelayHostAdmissionStoreError.keychain(updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainRelayHostAdmissionStoreError.keychain(insertStatus)
        }
    }

    nonisolated private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
