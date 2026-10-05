import CryptoKit
import Foundation
import GobyApplication
import GobyDomain
import Security

protocol RememberedApprovalStateIO: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

private struct KeychainRememberedApprovalStateIO: RememberedApprovalStateIO {
    let account: String
    let accessGroup: String?
    let service: String

    private var query: [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RememberedCommandApprovalError.storage
        }
        return data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw RememberedCommandApprovalError.storage }
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
            throw RememberedCommandApprovalError.storage
        }
    }
}

/// Authority lives in the host's device-only Keychain, outside agent-writable
/// project files and ordinary Application Support snapshots. No fallback grants.
public actor KeychainRememberedCommandApprovals: RememberedCommandApprovalStoring {
    private struct Document: Codable {
        let version: Int
        let rules: [RememberedCommandApproval]
    }
    private let stateIO: any RememberedApprovalStateIO

    public init(
        scope: String,
        service: String = "com.goby.agentic-dashboard.remembered-commands",
        accessGroup: String? = nil
    ) {
        stateIO = KeychainRememberedApprovalStateIO(
            account: SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined(),
            accessGroup: accessGroup,
            service: service
        )
    }

    init(stateIO: any RememberedApprovalStateIO) { self.stateIO = stateIO }

    public func all() throws -> [RememberedCommandApproval] {
        guard let data = try stateIO.load() else { return [] }
        guard data.count <= 1_048_576,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              [1, 2, 3].contains(document.version), document.rules.count <= 128,
              document.rules.allSatisfy(\.hasValidScope),
              Set(document.rules.map(\.id)).count == document.rules.count else {
            throw RememberedCommandApprovalError.storage
        }
        return document.rules.sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ rule: RememberedCommandApproval) throws {
        guard rule.hasValidScope else { throw RememberedCommandApprovalError.unavailable }
        var rules = try all()
        let alreadyEnabled = rules.filter { $0.projectID == rule.projectID }.allSatisfy(\.isEnabled)
        if rules.contains(where: { $0.covers(rule) }), alreadyEnabled { return }
        // A fresh Always Allow confirmation resumes this project's previously
        // saved exact grants as well as the newly confirmed operation.
        rules = rules.map { $0.projectID == rule.projectID ? $0.settingEnabled(true) : $0 }
        if !rules.contains(where: { $0.covers(rule) }) { rules.append(rule.settingEnabled(true)) }
        try write(rules)
    }

    public func revoke(_ id: UUID) throws {
        try write(all().filter { $0.id != id })
    }

    public func setProjectEnabled(_ projectID: ProjectID, enabled: Bool) throws {
        let rules = try all()
        guard rules.contains(where: { $0.projectID == projectID }) else {
            throw RememberedCommandApprovalError.projectNotFound
        }
        try write(rules.map { $0.projectID == projectID ? $0.settingEnabled(enabled) : $0 })
    }

    private func write(_ rules: [RememberedCommandApproval]) throws {
        let version = rules.contains(where: { !$0.isEnabled }) ? 3
            : (rules.contains { $0.fileChangeScope != nil } ? 2 : 1)
        let data = try JSONEncoder().encode(Document(version: version, rules: rules))
        guard rules.count <= 128, data.count <= 1_048_576 else {
            throw RememberedCommandApprovalError.storage
        }
        try stateIO.save(data)
    }
}
