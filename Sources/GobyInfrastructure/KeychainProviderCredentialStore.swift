import Foundation
import Security
import GobyApplication
import GobyDomain

public enum ProviderCredentialStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "The system Keychain could not update the provider credential: \($0)" }
                ?? "The system Keychain could not update the provider credential (\(status))."
        case .invalidStoredValue:
            return "The provider credential stored in Keychain is unreadable. Remove it and add it again."
        }
    }
}

/// Device-local provider credentials. The catalog, run journal, handoff
/// bundles, and diagnostics contain only configured/not-configured state.
public actor KeychainProviderCredentialStore: ProviderCredentialRepository {
    private let service: String
    private let accessGroup: String?
    private let migratesUnscopedItems: Bool

    public init(
        service: String = "com.goby.agentic-dashboard.provider-credentials",
        accessGroup: String? = nil,
        migratesUnscopedItems: Bool = false
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.migratesUnscopedItems = migratesUnscopedItems
    }

    public func credential(
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind
    ) throws -> String? {
        var query = baseQuery(for: providerID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound,
           accessGroup != nil,
           migratesUnscopedItems,
           let legacy = try credential(for: providerID, kind: kind, useConfiguredAccessGroup: false) {
            try saveCredential(legacy, for: providerID, kind: kind)
            let legacyStatus = SecItemDelete(
                baseQuery(for: providerID, kind: kind, useConfiguredAccessGroup: false) as CFDictionary
            )
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw ProviderCredentialStoreError.keychain(legacyStatus)
            }
            return legacy
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProviderCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let credential = String(data: data, encoding: .utf8),
              !credential.isEmpty else {
            throw ProviderCredentialStoreError.invalidStoredValue
        }
        return credential
    }

    public func saveCredential(
        _ credential: String,
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind
    ) throws {
        guard let data = credential.data(using: .utf8) else {
            throw ProviderCredentialStoreError.invalidStoredValue
        }
        let query = baseQuery(for: providerID, kind: kind)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.keychain(insertStatus)
        }
    }

    public func removeCredential(
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind
    ) throws {
        let status = SecItemDelete(baseQuery(for: providerID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychain(status)
        }
        if accessGroup != nil, migratesUnscopedItems {
            let legacyStatus = SecItemDelete(
                baseQuery(for: providerID, kind: kind, useConfiguredAccessGroup: false) as CFDictionary
            )
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw ProviderCredentialStoreError.keychain(legacyStatus)
            }
        }
    }

    private func credential(
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind,
        useConfiguredAccessGroup: Bool
    ) throws -> String? {
        var query = baseQuery(
            for: providerID,
            kind: kind,
            useConfiguredAccessGroup: useConfiguredAccessGroup
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProviderCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let credential = String(data: data, encoding: .utf8),
              !credential.isEmpty else {
            throw ProviderCredentialStoreError.invalidStoredValue
        }
        return credential
    }

    private func baseQuery(
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind,
        useConfiguredAccessGroup: Bool = true
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: providerID, kind: kind),
            kSecAttrSynchronizable as String: false,
        ]
        if useConfiguredAccessGroup, let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    /// API keys keep the original account name so existing items still load.
    nonisolated static func account(for providerID: AgentProviderID, kind: ProviderCredentialKind) -> String {
        switch kind {
        case .apiKey: providerID.rawValue
        case .subscriptionToken: "\(providerID.rawValue).subscription"
        }
    }
}
