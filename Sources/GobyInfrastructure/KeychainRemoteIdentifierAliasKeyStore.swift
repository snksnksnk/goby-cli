import Foundation
import Security

public enum KeychainRemoteIdentifierAliasKeyStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue
    case randomGeneration(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "The system Keychain could not access the remote identifier key: \($0)" }
                ?? "The system Keychain could not access the remote identifier key (\(status))."
        case .invalidStoredValue:
            return "The remote identifier key in Keychain is invalid."
        case let .randomGeneration(status):
            return "The system could not create a remote identifier key (\(status))."
        }
    }
}

/// Installation-local secret used only to turn path-derived domain IDs into
/// opaque remote aliases. It is shared by the signed app and helper, never
/// synchronized, and never leaves the Mac Keychain.
public actor KeychainRemoteIdentifierAliasKeyStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.goby.agentic-dashboard.remote-identifier-alias",
        account: String = "host-installation-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreate() throws -> Data {
        if let current = try load() { return current }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw KeychainRemoteIdentifierAliasKeyStoreError.randomGeneration(randomStatus)
        }
        let key = Data(bytes)
        var insert = baseQuery()
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem, let concurrent = try load() { return concurrent }
        guard status == errSecSuccess else {
            throw KeychainRemoteIdentifierAliasKeyStoreError.keychain(status)
        }
        return key
    }

    private func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainRemoteIdentifierAliasKeyStoreError.keychain(status)
        }
        guard let data = result as? Data, data.count == 32 else {
            throw KeychainRemoteIdentifierAliasKeyStoreError.invalidStoredValue
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
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
