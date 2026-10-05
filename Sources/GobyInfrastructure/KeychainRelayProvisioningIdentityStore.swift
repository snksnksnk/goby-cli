import Foundation
import Security

public enum KeychainRelayProvisioningIdentityStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue
    case randomGeneration(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "The system Keychain could not access this Mac's relay identity: \($0)" }
                ?? "The system Keychain could not access this Mac's relay identity (\(status))."
        case .invalidStoredValue:
            return "This Mac's relay identity in Keychain is invalid."
        case let .randomGeneration(status):
            return "The system could not create this Mac's relay identity (\(status))."
        }
    }
}

/// A stable, random, installation-local pseudonym used by the provisioning
/// service to renew the same relay admission without learning a hardware ID.
/// This value is not a relay credential and cannot authorize a connection.
public actor KeychainRelayProvisioningIdentityStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.goby.agentic-dashboard.relay-provisioning-identity",
        account: String = "mac-installation-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreate() throws -> String {
        if let current = try load() { return current }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw KeychainRelayProvisioningIdentityStoreError.randomGeneration(randomStatus)
        }
        let identifier = Data(bytes).base64URLEncodedString()
        var insert = baseQuery()
        insert[kSecValueData as String] = Data(identifier.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem, let concurrent = try load() { return concurrent }
        guard status == errSecSuccess else {
            throw KeychainRelayProvisioningIdentityStoreError.keychain(status)
        }
        return identifier
    }

    private func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainRelayProvisioningIdentityStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              Self.isIdentifier(value) else {
            throw KeychainRelayProvisioningIdentityStoreError.invalidStoredValue
        }
        return value
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

    private static func isIdentifier(_ value: String) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "_"
                || scalar == "-"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
