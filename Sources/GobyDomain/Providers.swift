import Foundation

/// A capability reported by a provider adapter. Absence means unsupported or
/// not yet verified; Goby must not silently emulate the missing capability.
public enum ProviderCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case accountInspection
    case taskDiscovery
    case agentDiscovery
    case agentPublication
    case execution
    case interruption
    case activeSteering
    case resume
    case approvals
    case usageReporting
    case quotaReporting
    case skills
    case plugins
    case hooks
    case mcp

    public var displayName: String {
        switch self {
        case .accountInspection: "Account inspection"
        case .taskDiscovery: "Task discovery"
        case .agentDiscovery: "Agent discovery"
        case .agentPublication: "Agent publication"
        case .execution: "Execution"
        case .interruption: "Interruption"
        case .activeSteering: "Active steering"
        case .resume: "Resume"
        case .approvals: "Approvals"
        case .usageReporting: "Usage reporting"
        case .quotaReporting: "Quota reporting"
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .hooks: "Hooks"
        case .mcp: "MCP"
        }
    }
}

public struct ProviderCapabilities: Codable, Hashable, Sendable {
    public let supported: Set<ProviderCapability>

    public init(_ supported: Set<ProviderCapability> = []) {
        self.supported = supported
    }

    public func supports(_ capability: ProviderCapability) -> Bool {
        supported.contains(capability)
    }

    public static let unavailable = ProviderCapabilities()
}

public enum ProviderConnectionState: Codable, Equatable, Sendable {
    case notChecked
    case unavailable(reason: String)
    case disconnected
    case connecting
    case connected(version: String?)
    case needsAuthentication
    case failed(message: String)
}

public enum ProviderUsageKind: String, Codable, Hashable, Sendable {
    case consumedPercentage
    case remainingPercentage
    case interactions
    case requests
    case inputTokens
    case outputTokens
    case estimatedCost
}

/// A provider-native usage value. `isEstimate` is explicit so an SDK cost
/// estimate can never be presented as an authoritative subscription balance.
public struct ProviderUsageSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: ProviderUsageKind
    public let label: String
    public let value: Double
    public let unit: String
    public let resetsAt: Date?
    public let isEstimate: Bool

    public init(
        id: String,
        kind: ProviderUsageKind,
        label: String,
        value: Double,
        unit: String,
        resetsAt: Date? = nil,
        isEstimate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.unit = unit
        self.resetsAt = resetsAt
        self.isEstimate = isEstimate
    }
}

public struct ProviderAccountSnapshot: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let connectionState: ProviderConnectionState
    public let displayName: String?
    public let organizationName: String?
    public let planName: String?
    public let selectedModel: String?
    public let availableModels: [String]
    public let usage: [ProviderUsageSnapshot]
    public let observedAt: Date

    public init(
        providerID: AgentProviderID,
        connectionState: ProviderConnectionState,
        displayName: String? = nil,
        organizationName: String? = nil,
        planName: String? = nil,
        selectedModel: String? = nil,
        availableModels: [String] = [],
        usage: [ProviderUsageSnapshot] = [],
        observedAt: Date = .now
    ) {
        self.providerID = providerID
        self.connectionState = connectionState
        self.displayName = displayName
        self.organizationName = organizationName
        self.planName = planName
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.usage = usage
        self.observedAt = observedAt
    }
}

public struct ProviderTaskIdentity: Codable, Hashable, Sendable {
    public let providerID: AgentProviderID
    public let nativeID: String

    public init(providerID: AgentProviderID, nativeID: String) {
        self.providerID = providerID
        self.nativeID = nativeID
    }
}

public enum ProviderTaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case working
    case waitingForApproval
    case waitingForInput
    case saved
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .working: "Working"
        case .waitingForApproval: "Needs approval"
        case .waitingForInput: "Waiting for input"
        case .saved: "Saved"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .failed: true
        case .working, .saved, .completed, .cancelled: false
        }
    }

    public var isActive: Bool {
        switch self {
        case .working, .waitingForApproval, .waitingForInput: true
        case .saved, .completed, .failed, .cancelled: false
        }
    }
}

/// Provider-owned activity is deliberately separate from a reusable agent
/// binding. An external task is inspectable history, never a routing target.
public struct ProviderTaskActivity: Codable, Hashable, Identifiable, Sendable {
    public let identity: ProviderTaskIdentity
    public let projectID: ProjectID
    public let title: String
    public let summary: String?
    public let status: ProviderTaskStatus
    public let updatedAt: Date
    public let parentTaskIdentity: ProviderTaskIdentity?
    public let agentRole: String?

    public var id: ProviderTaskIdentity { identity }
    public var providerID: AgentProviderID { identity.providerID }

    public init(
        identity: ProviderTaskIdentity,
        projectID: ProjectID,
        title: String,
        summary: String? = nil,
        status: ProviderTaskStatus,
        updatedAt: Date,
        parentTaskIdentity: ProviderTaskIdentity? = nil,
        agentRole: String? = nil
    ) {
        self.identity = identity
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
        self.parentTaskIdentity = parentTaskIdentity
        self.agentRole = agentRole
    }
}

public enum ProviderBindingState: String, Codable, Hashable, Sendable {
    case configured
    case unavailable
    case disabled
    case needsAuthentication

    public var displayName: String {
        switch self {
        case .configured: "Configured"
        case .unavailable: "Unavailable"
        case .disabled: "Disabled"
        case .needsAuthentication: "Needs authentication"
        }
    }
}

/// The provider planes a user has attached to one Goby project. This remains
/// meaningful even before the project has an agent binding on every plane.
public struct ProjectProviderConfiguration: Codable, Hashable, Identifiable, Sendable {
    public let projectID: ProjectID
    public let providerIDs: Set<AgentProviderID>
    public let configuredAt: Date

    public var id: ProjectID { projectID }

    public init(
        projectID: ProjectID,
        providerIDs: Set<AgentProviderID>,
        configuredAt: Date = .now
    ) {
        self.projectID = projectID
        self.providerIDs = providerIDs
        self.configuredAt = configuredAt
    }

    public static func migratedCodexConfiguration(for project: LabProject) -> Self {
        ProjectProviderConfiguration(
            projectID: project.id,
            providerIDs: [.codex],
            configuredAt: project.registeredAt
        )
    }
}

/// One provider-native realization of a Goby logical agent role.
public struct ProviderAgentBinding: Codable, Hashable, Identifiable, Sendable {
    public let id: ProviderAgentBindingID
    public let providerID: AgentProviderID
    public let agentID: AgentID
    public let projectID: ProjectID?
    public let nativeID: String
    public let nativeDefinitionURL: URL?
    public let capabilities: Set<AgentCapability>
    public let state: ProviderBindingState
    /// Optional instructions for this provider plane. When absent, the
    /// logical agent's shared instructions apply unchanged.
    public let instructionsOverride: String?

    public init(
        id: ProviderAgentBindingID? = nil,
        providerID: AgentProviderID,
        agentID: AgentID,
        projectID: ProjectID?,
        nativeID: String,
        nativeDefinitionURL: URL? = nil,
        capabilities: Set<AgentCapability>,
        state: ProviderBindingState = .configured,
        instructionsOverride: String? = nil
    ) {
        self.id = id ?? .derived(
            providerID: providerID,
            agentID: agentID,
            projectID: projectID,
            nativeID: nativeID
        )
        self.providerID = providerID
        self.agentID = agentID
        self.projectID = projectID
        self.nativeID = nativeID
        self.nativeDefinitionURL = nativeDefinitionURL
        self.capabilities = capabilities
        self.state = state
        self.instructionsOverride = instructionsOverride
    }

    public static func migratedCodexBinding(for agent: AgentProfile) -> ProviderAgentBinding {
        let projectID: ProjectID? = switch agent.scope {
        case let .project(id): id
        case .global, .union: nil
        }
        let nativeID = agent.codexRegistrationKey
            ?? agent.sourceURL?.standardizedFileURL.path(percentEncoded: false)
            ?? agent.id.rawValue
        return ProviderAgentBinding(
            providerID: .codex,
            agentID: agent.id,
            projectID: projectID,
            nativeID: nativeID,
            nativeDefinitionURL: agent.sourceURL,
            capabilities: agent.capabilities,
            state: agent.isEnabled ? .configured : .disabled
        )
    }
}

public struct ProviderCollaborationMember: Codable, Hashable, Sendable {
    public let providerID: AgentProviderID
    public let bindingID: ProviderAgentBindingID

    public init(providerID: AgentProviderID, bindingID: ProviderAgentBindingID) {
        self.providerID = providerID
        self.bindingID = bindingID
    }
}

/// Symmetric eligibility for provider bindings to participate in one project
/// plan. It is not an execution edge and never implies a handoff direction.
public struct ProviderCollaborationSet: Codable, Hashable, Identifiable, Sendable {
    public let id: ProviderCollaborationSetID
    public let projectID: ProjectID
    public let members: Set<ProviderCollaborationMember>
    public let createdAt: Date

    public init(
        id: ProviderCollaborationSetID = .make(),
        projectID: ProjectID,
        members: Set<ProviderCollaborationMember>,
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.members = members
        self.createdAt = createdAt
    }

    public var providerIDs: Set<AgentProviderID> {
        Set(members.map(\.providerID))
    }

    public var isCollaborative: Bool {
        providerIDs.count >= 2 && members.count >= 2
    }
}
