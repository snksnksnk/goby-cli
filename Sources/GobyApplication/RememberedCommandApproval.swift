import Foundation
import GobyDomain

/// Adapter-authenticated executable bytes and permission context. Never derived
/// from a human-readable summary or a provider's proposed command prefix.
public struct RememberedCommandScope: Codable, Equatable, Sendable {
    public let command: String
    public let workingDirectory: String
    public let contextDigest: String

    public init(command: String, workingDirectory: String, contextDigest: String) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.contextDigest = contextDigest
    }
}

/// Folder authority for future additions and in-place edits. The policy is
/// versioned so widening the path/change policy can never reuse an older grant.
public struct RememberedFileChangeScope: Codable, Equatable, Sendable {
    public let workingDirectory: String
    public let policyVersion: Int

    public init(workingDirectory: String, policyVersion: Int = 1) {
        self.workingDirectory = workingDirectory
        self.policyVersion = policyVersion
    }
}

/// Historical wire type shared by exact-command and folder-edit rules.
/// Exactly one scope is valid; command grants never cover file grants.
public struct RememberedCommandApproval: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let providerID: AgentProviderID
    public let projectID: ProjectID
    public let projectName: String
    public let scope: RememberedCommandScope?
    public let fileChangeScope: RememberedFileChangeScope?
    /// Includes the registered project, working-copy identity and resource profile.
    public let authorizationDigest: String
    /// Display only; authenticated automation/action/revision identity is in authorizationDigest.
    public let automationName: String?
    /// A project switch may pause this rule without discarding its exact grant.
    public let isEnabled: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), providerID: AgentProviderID, projectID: ProjectID,
                projectName: String, scope: RememberedCommandScope,
                automationName: String? = nil, authorizationDigest: String, isEnabled: Bool = true,
                createdAt: Date = .now) {
        self.id = id
        self.providerID = providerID
        self.projectID = projectID
        self.projectName = projectName
        self.scope = scope
        self.fileChangeScope = nil
        self.authorizationDigest = authorizationDigest
        self.automationName = automationName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public init(id: UUID = UUID(), providerID: AgentProviderID, projectID: ProjectID,
                projectName: String, fileChangeScope: RememberedFileChangeScope,
                automationName: String? = nil, authorizationDigest: String, isEnabled: Bool = true,
                createdAt: Date = .now) {
        self.id = id
        self.providerID = providerID
        self.projectID = projectID
        self.projectName = projectName
        self.scope = nil
        self.fileChangeScope = fileChangeScope
        self.authorizationDigest = authorizationDigest
        self.automationName = automationName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, projectID, projectName, scope, fileChangeScope
        case authorizationDigest, automationName, isEnabled, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        providerID = try container.decode(AgentProviderID.self, forKey: .providerID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        projectName = try container.decode(String.self, forKey: .projectName)
        scope = try container.decodeIfPresent(RememberedCommandScope.self, forKey: .scope)
        fileChangeScope = try container.decodeIfPresent(RememberedFileChangeScope.self, forKey: .fileChangeScope)
        authorizationDigest = try container.decode(String.self, forKey: .authorizationDigest)
        automationName = try container.decodeIfPresent(String.self, forKey: .automationName)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func settingEnabled(_ enabled: Bool) -> Self {
        if let scope {
            return Self(id: id, providerID: providerID, projectID: projectID,
                        projectName: projectName, scope: scope, automationName: automationName,
                        authorizationDigest: authorizationDigest, isEnabled: enabled, createdAt: createdAt)
        }
        guard let fileChangeScope else { return self }
        return Self(id: id, providerID: providerID, projectID: projectID,
                    projectName: projectName, fileChangeScope: fileChangeScope,
                    automationName: automationName, authorizationDigest: authorizationDigest,
                    isEnabled: enabled, createdAt: createdAt)
    }

    public var hasValidScope: Bool {
        if let fileChangeScope {
            return scope == nil && fileChangeScope.policyVersion == 1
                && fileChangeScope.workingDirectory.hasPrefix("/") && fileChangeScope.workingDirectory != "/"
        }
        return scope != nil
    }

    public func covers(_ other: Self) -> Bool {
        hasValidScope && other.hasValidScope && providerID == other.providerID && projectID == other.projectID
            && scope == other.scope && fileChangeScope == other.fileChangeScope && authorizationDigest == other.authorizationDigest
    }
}

public protocol RememberedCommandApprovalStoring: Sendable {
    func all() async throws -> [RememberedCommandApproval]
    func save(_ rule: RememberedCommandApproval) async throws
    func revoke(_ id: UUID) async throws
    func setProjectEnabled(_ projectID: ProjectID, enabled: Bool) async throws
}

public enum RememberedCommandApprovalError: LocalizedError, Sendable {
    case unavailable
    case projectNotFound
    case storage

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This request cannot be remembered. Review it and use Allow Once."
        case .projectNotFound: "This project no longer has saved approvals. Refresh Settings."
        case .storage: "Goby could not read or save remembered approvals securely. No new rule was saved."
        }
    }
}
