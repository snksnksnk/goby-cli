import Foundation

/// Runtime state reported by Codex for a task or subagent thread.
public enum CodexTaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case waitingForApproval
    case waitingForInput
    case idle
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .active: "Working"
        case .waitingForApproval: "Needs approval"
        case .waitingForInput: "Waiting for input"
        case .idle: "Saved"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var isActive: Bool {
        switch self {
        case .active, .waitingForApproval, .waitingForInput: true
        case .idle, .completed, .failed, .cancelled: false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .failed: true
        case .active, .idle, .completed, .cancelled: false
        }
    }
}

/// A Codex chat or spawned subagent thread associated with a registered project.
/// It is intentionally distinct from ``AgentProfile``: a historical task is
/// inspectable activity, not a reusable role that Goby may route new work to.
public struct CodexTaskActivity: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let projectID: ProjectID
    public let title: String
    public let summary: String?
    public let status: CodexTaskStatus
    public let updatedAt: Date
    public let isSubagent: Bool
    public let agentRole: String?
    /// Provider-native parent task. Helper activity remains inspectable but is
    /// never promoted into a reusable Goby agent definition.
    public let parentThreadID: String?

    public init(
        id: String,
        projectID: ProjectID,
        title: String,
        summary: String? = nil,
        status: CodexTaskStatus,
        updatedAt: Date,
        isSubagent: Bool = false,
        agentRole: String? = nil,
        parentThreadID: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
        self.isSubagent = isSubagent
        self.agentRole = agentRole
        self.parentThreadID = parentThreadID
    }
}
