import Foundation

public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case running
    case needsAttention
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .draft: "Draft"
        case .ready: "Ready"
        case .running: "Running"
        case .needsAttention: "Needs Attention"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .draft, .ready, .running, .needsAttention: false
        }
    }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case available
    case queued
    case working
    case waitingForApproval
    case paused
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .queued: "Queued"
        case .working: "Working"
        case .waitingForApproval: "Waiting for approval"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

public enum RunJournalEventKind: String, Codable, Sendable {
    case created
    case statusChanged
    case assignmentChanged
    case approval
    case recovery
}

public struct RunJournalEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: RunJournalEventKind
    public let message: String
    public let assignmentID: AssignmentID?
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        kind: RunJournalEventKind,
        message: String,
        assignmentID: AssignmentID? = nil,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.assignmentID = assignmentID
        self.occurredAt = occurredAt
    }
}

/// Reduces cumulative streaming snapshots into one current entry per continuous
/// assignment state while retaining meaningful state and assignment boundaries.
public enum RunJournalCompactor {
    public static func compact(_ entries: [RunJournalEntry], limit: Int = 1_000) -> [RunJournalEntry] {
        guard limit > 0 else { return [] }
        var compacted: [RunJournalEntry] = []
        compacted.reserveCapacity(min(entries.count, limit))

        for entry in entries {
            if let previous = compacted.last, shouldReplace(previous, with: entry) {
                // A cumulative stream updates one event. Keep its identity so
                // presentation and accessibility don't treat every token as a new row.
                compacted[compacted.count - 1] = RunJournalEntry(
                    id: previous.id,
                    kind: entry.kind,
                    message: entry.message,
                    assignmentID: entry.assignmentID,
                    occurredAt: entry.occurredAt
                )
            } else {
                compacted.append(entry)
            }
        }
        return Array(compacted.suffix(limit))
    }

    private static func shouldReplace(_ previous: RunJournalEntry, with entry: RunJournalEntry) -> Bool {
        guard previous.kind == .assignmentChanged,
              entry.kind == .assignmentChanged,
              previous.assignmentID != nil,
              previous.assignmentID == entry.assignmentID,
              let previousPhase = phase(of: previous.message),
              let currentPhase = phase(of: entry.message) else {
            return false
        }
        return previousPhase == currentPhase
    }

    private static func phase(of message: String) -> Substring? {
        guard let separator = message.firstIndex(of: ":") else { return nil }
        return message[..<separator]
    }
}

public struct AgentAssignment: Codable, Hashable, Identifiable, Sendable {
    public let id: AssignmentID
    public let runID: RunID
    public let projectID: ProjectID
    public let agentID: AgentID
    public let status: AgentStatus
    public let currentTask: String
    public let attachments: [PromptAttachment]
    public let progress: Double?
    public let startedAt: Date?
    public let statusReason: String?
    public let workingDirectory: URL?
    /// Kernel object identity captured when the working directory was prepared.
    /// Provider recovery must not recapture and bless a later pathname replacement.
    public let workingDirectoryIdentity: GADFileSystemIdentity?
    public let codexThreadID: String?
    public let codexTurnID: String?
    public let providerID: AgentProviderID
    /// Exact provider-native binding selected by the reviewed route.
    public let providerBindingID: ProviderAgentBindingID?
    /// The reviewed provider-native model override for this assignment. A nil
    /// value deliberately delegates to the provider's configured default.
    public let model: String?
    public let providerTaskID: String?
    public let providerTurnID: String?
    /// Identifies a destination assignment created from one immutable handoff
    /// bundle. It makes manual dispatch crash-safe and idempotent.
    public let handoffID: HandoffID?
    /// The delivery-pipeline stage this attempt performs. A later assignment
    /// with the same stage supersedes this one, which keeps rework history.
    public let deliveryStageID: DeliveryStageID?

    public init(
        id: AssignmentID = .make(),
        runID: RunID,
        projectID: ProjectID,
        agentID: AgentID,
        status: AgentStatus,
        currentTask: String,
        attachments: [PromptAttachment] = [],
        progress: Double? = nil,
        startedAt: Date? = nil,
        statusReason: String? = nil,
        workingDirectory: URL? = nil,
        workingDirectoryIdentity: GADFileSystemIdentity? = nil,
        codexThreadID: String? = nil,
        codexTurnID: String? = nil,
        providerID: AgentProviderID = .codex,
        providerBindingID: ProviderAgentBindingID? = nil,
        model: String? = nil,
        providerTaskID: String? = nil,
        providerTurnID: String? = nil,
        handoffID: HandoffID? = nil,
        deliveryStageID: DeliveryStageID? = nil
    ) {
        self.id = id
        self.runID = runID
        self.projectID = projectID
        self.agentID = agentID
        self.status = status
        self.currentTask = currentTask
        self.attachments = attachments
        self.progress = Self.normalizedProgress(progress)
        self.startedAt = startedAt
        self.statusReason = statusReason
        self.workingDirectory = workingDirectory
        self.workingDirectoryIdentity = workingDirectoryIdentity
        self.codexThreadID = codexThreadID
        self.codexTurnID = codexTurnID
        self.providerID = providerID
        self.providerBindingID = providerBindingID
        self.model = model
        self.providerTaskID = providerTaskID ?? codexThreadID
        self.providerTurnID = providerTurnID ?? codexTurnID
        self.handoffID = handoffID
        self.deliveryStageID = deliveryStageID
    }

    private enum CodingKeys: String, CodingKey {
        case id, runID, projectID, agentID, status, currentTask, attachments, progress
        case startedAt, statusReason, workingDirectory, workingDirectoryIdentity, codexThreadID, codexTurnID
        case providerID, providerBindingID, model, providerTaskID, providerTurnID, handoffID
        case deliveryStageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AssignmentID.self, forKey: .id)
        runID = try container.decode(RunID.self, forKey: .runID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        agentID = try container.decode(AgentID.self, forKey: .agentID)
        status = try container.decode(AgentStatus.self, forKey: .status)
        currentTask = try container.decode(String.self, forKey: .currentTask)
        attachments = try container.decodeIfPresent(
            [PromptAttachment].self,
            forKey: .attachments
        ) ?? []
        progress = Self.normalizedProgress(try container.decodeIfPresent(Double.self, forKey: .progress))
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason)
        workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        workingDirectoryIdentity = try container.decodeIfPresent(
            GADFileSystemIdentity.self,
            forKey: .workingDirectoryIdentity
        )
        codexThreadID = try container.decodeIfPresent(String.self, forKey: .codexThreadID)
        codexTurnID = try container.decodeIfPresent(String.self, forKey: .codexTurnID)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        providerBindingID = try container.decodeIfPresent(
            ProviderAgentBindingID.self,
            forKey: .providerBindingID
        )
        model = try container.decodeIfPresent(String.self, forKey: .model)
        providerTaskID = try container.decodeIfPresent(
            String.self,
            forKey: .providerTaskID
        ) ?? codexThreadID
        providerTurnID = try container.decodeIfPresent(
            String.self,
            forKey: .providerTurnID
        ) ?? codexTurnID
        handoffID = try container.decodeIfPresent(HandoffID.self, forKey: .handoffID)
        deliveryStageID = try container.decodeIfPresent(DeliveryStageID.self, forKey: .deliveryStageID)
    }

    private static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// A Codex thread exists, but App Server never confirmed the exact turn.
    /// Retrying this assignment could duplicate provider-side effects.
    public var hasIndeterminateProviderStart: Bool {
        providerID == .codex
            && providerTaskID != nil
            && providerTurnID == nil
            && status != .completed
            && status != .cancelled
    }
}

public struct RunRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: RunID
    public let plan: RoutingPlan
    public let status: RunStatus
    public let assignments: [AgentAssignment]
    /// Provider-owned helper tasks invoked inside this run. These are activity
    /// records, not routing targets or reusable Goby agent profiles.
    public let helperTasks: [ProviderTaskActivity]
    public let outcome: String?
    public let approvalReceipts: [ApprovalReceipt]
    public let instructionSnapshot: [InstructionPack]
    public let agentSnapshot: [AgentProfile]
    public let providerBindingSnapshot: [ProviderAgentBinding]
    /// Exact authorized projects used when the run was staged. Provider start
    /// and recovery never re-read mutable catalog roots for this run.
    public let projectSnapshot: [LabProject]
    /// Present only for automation-created runs. The provider start must still
    /// match the authenticated authority used for planning and staging.
    public let automationExecutionAuthorityDigest: Data?
    /// A one-run authorization selected during manual plan review.
    public let automaticallyApproveRuntimeRequests: Bool
    public let journal: [RunJournalEntry]
    public let resourceSnapshot: [SharedResource]
    /// Typed agent steps for the run thread (newest `RunActivityLog.limit`).
    public let activity: [RunActivityStep]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: RunID,
        plan: RoutingPlan,
        status: RunStatus,
        assignments: [AgentAssignment],
        helperTasks: [ProviderTaskActivity] = [],
        outcome: String? = nil,
        approvalReceipts: [ApprovalReceipt] = [],
        instructionSnapshot: [InstructionPack] = [],
        agentSnapshot: [AgentProfile] = [],
        providerBindingSnapshot: [ProviderAgentBinding] = [],
        projectSnapshot: [LabProject] = [],
        automationExecutionAuthorityDigest: Data? = nil,
        automaticallyApproveRuntimeRequests: Bool = false,
        journal: [RunJournalEntry] = [],
        resourceSnapshot: [SharedResource] = [],
        activity: [RunActivityStep] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.plan = plan
        self.status = status
        self.assignments = assignments
        self.helperTasks = helperTasks
        self.outcome = outcome
        self.approvalReceipts = approvalReceipts
        self.instructionSnapshot = instructionSnapshot
        self.agentSnapshot = agentSnapshot
        self.providerBindingSnapshot = providerBindingSnapshot
        self.projectSnapshot = projectSnapshot
        self.automationExecutionAuthorityDigest = automationExecutionAuthorityDigest
        self.automaticallyApproveRuntimeRequests = automaticallyApproveRuntimeRequests
        self.journal = journal
        self.resourceSnapshot = resourceSnapshot
        self.activity = Array(activity.suffix(RunActivityLog.limit))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, plan, status, assignments, helperTasks, outcome, approvalReceipts, instructionSnapshot
        case agentSnapshot, providerBindingSnapshot, projectSnapshot, automationExecutionAuthorityDigest
        case automaticallyApproveRuntimeRequests
        case journal, resourceSnapshot, activity, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RunID.self, forKey: .id)
        plan = try container.decode(RoutingPlan.self, forKey: .plan)
        status = try container.decode(RunStatus.self, forKey: .status)
        assignments = try container.decode([AgentAssignment].self, forKey: .assignments)
        helperTasks = try container.decodeIfPresent(
            [ProviderTaskActivity].self,
            forKey: .helperTasks
        ) ?? []
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        approvalReceipts = try container.decodeIfPresent([ApprovalReceipt].self, forKey: .approvalReceipts) ?? []
        instructionSnapshot = try container.decodeIfPresent([InstructionPack].self, forKey: .instructionSnapshot) ?? []
        agentSnapshot = try container.decodeIfPresent([AgentProfile].self, forKey: .agentSnapshot) ?? []
        providerBindingSnapshot = try container.decodeIfPresent(
            [ProviderAgentBinding].self,
            forKey: .providerBindingSnapshot
        ) ?? agentSnapshot.map(ProviderAgentBinding.migratedCodexBinding)
        projectSnapshot = try container.decodeIfPresent(
            [LabProject].self,
            forKey: .projectSnapshot
        ) ?? []
        automationExecutionAuthorityDigest = try container.decodeIfPresent(
            Data.self,
            forKey: .automationExecutionAuthorityDigest
        )
        automaticallyApproveRuntimeRequests = try container.decodeIfPresent(
            Bool.self, forKey: .automaticallyApproveRuntimeRequests
        ) ?? false
        journal = try container.decodeIfPresent([RunJournalEntry].self, forKey: .journal) ?? []
        resourceSnapshot = try container.decodeIfPresent([SharedResource].self, forKey: .resourceSnapshot) ?? []
        activity = try container.decodeIfPresent([RunActivityStep].self, forKey: .activity) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public enum CodexConnectionState: Codable, Equatable, Sendable {
    case notChecked
    case unavailable(String)
    case disconnected
    case connecting
    case connected(version: String)
    case needsAuthentication
    case failed(String)
}
