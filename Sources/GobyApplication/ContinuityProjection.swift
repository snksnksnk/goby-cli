import Foundation
import GobyDomain

public enum GADHostReachability: String, Codable, Sendable {
    case online
    case degraded
    case offline
}

public struct GADHostProjection: Codable, Equatable, Sendable {
    public let id: HostID
    public let displayName: String
    public let reachability: GADHostReachability
    public let lastUpdatedAt: Date
    /// Optional display metadata; canonical history remains on the host.
    public let omittedHistoryRunCount: Int?
    public let omittedAutomationOccurrenceCount: Int?
    /// Protocol 3.12: the chat lives only in the host's memory, so it travels
    /// with the host section. Older clients ignore it; absent means no chat.
    public let temporaryChat: GADTemporaryChatProjection?

    public init(
        id: HostID, displayName: String, reachability: GADHostReachability, lastUpdatedAt: Date,
        omittedHistoryRunCount: Int? = nil, omittedAutomationOccurrenceCount: Int? = nil,
        temporaryChat: GADTemporaryChatProjection? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.reachability = reachability
        self.lastUpdatedAt = lastUpdatedAt
        self.omittedHistoryRunCount = omittedHistoryRunCount
        self.omittedAutomationOccurrenceCount = omittedAutomationOccurrenceCount
        self.temporaryChat = temporaryChat
    }
}

/// The host's temporary chat for paired clients. Text is redacted by the
/// host; the newest messages are kept within a fixed size budget.
public struct GADTemporaryChatProjection: Codable, Equatable, Sendable, Identifiable {
    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let role: TemporaryChat.Message.Role
        public let text: String
        public let createdAt: Date

        public init(id: String, role: TemporaryChat.Message.Role, text: String, createdAt: Date) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// Each projected message keeps at most this many characters.
    public static let messageTextLimit = 12_000
    /// All projected message text together stays within this budget.
    public static let totalTextLimit = 60_000

    public let id: TemporaryChatID
    public let providerID: AgentProviderID
    public let model: String?
    public let status: TemporaryChat.Status
    public let failureMessage: String?
    public let messages: [Message]
    /// Older messages left out to stay within the size budget.
    public let omittedMessageCount: Int
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        id: TemporaryChatID,
        providerID: AgentProviderID,
        model: String?,
        status: TemporaryChat.Status,
        failureMessage: String?,
        messages: [Message],
        omittedMessageCount: Int = 0,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.model = model
        self.status = status
        self.failureMessage = failureMessage
        self.messages = messages
        self.omittedMessageCount = omittedMessageCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// Projects a chat, redacting each text with `redact(text, limit)` and
    /// keeping the newest messages that fit the budget.
    public init(_ chat: TemporaryChat, redact: (String, Int) -> String) {
        var kept: [Message] = []
        var total = 0
        for message in chat.messages.reversed() {
            let text = redact(message.text, Self.messageTextLimit)
            guard kept.isEmpty || total + text.count <= Self.totalTextLimit else { break }
            total += text.count
            kept.append(.init(id: message.id, role: message.role, text: text, createdAt: message.createdAt))
        }
        self.init(
            id: chat.id,
            providerID: chat.providerID,
            model: chat.model.map { redact($0, 120) },
            status: chat.status,
            failureMessage: chat.failureMessage.map { redact($0, 1_000) },
            messages: kept.reversed(),
            omittedMessageCount: chat.messages.count - kept.count,
            startedAt: chat.startedAt,
            updatedAt: chat.updatedAt
        )
    }

    public var canAsk: Bool { status != .answering }
}

public extension TemporaryChat {
    /// The client-side copy of a projected chat.
    init(projection: GADTemporaryChatProjection) {
        self.init(
            id: projection.id,
            providerID: projection.providerID,
            model: projection.model,
            status: projection.status,
            failureMessage: projection.failureMessage,
            messages: projection.messages.map { .init(id: $0.id, role: $0.role, text: $0.text, createdAt: $0.createdAt) },
            startedAt: projection.startedAt,
            updatedAt: projection.updatedAt
        )
    }
}

public struct GADDraftProjection: Codable, Equatable, Sendable {
    public let revision: EntityRevision
    public let text: String
    public let attachments: [GADDraftAttachmentProjection]
    public let providerID: AgentProviderID
    public let model: String?
    public let platform: ProjectPlatform?
    public let projectIDs: [ProjectID]
    public let agentTargets: [AgentRouteTarget]
    public let groupID: ProjectGroupID?

    public init(
        revision: EntityRevision = .zero,
        text: String = "",
        attachments: [GADDraftAttachmentProjection] = [],
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        platform: ProjectPlatform? = nil,
        projectIDs: [ProjectID] = [],
        agentTargets: [AgentRouteTarget] = [],
        groupID: ProjectGroupID? = nil
    ) {
        self.revision = revision
        self.text = text
        self.attachments = attachments
        self.providerID = providerID
        self.model = model
        self.platform = platform
        self.projectIDs = projectIDs
        self.agentTargets = agentTargets
        self.groupID = groupID
    }

    private enum CodingKeys: String, CodingKey {
        case revision, text, attachments, providerID, model, platform, projectIDs, agentTargets, groupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(EntityRevision.self, forKey: .revision) ?? .zero
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try container.decodeIfPresent(
            [GADDraftAttachmentProjection].self,
            forKey: .attachments
        ) ?? []
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        model = try container.decodeIfPresent(String.self, forKey: .model)
        platform = try container.decodeIfPresent(ProjectPlatform.self, forKey: .platform)
        projectIDs = try container.decodeIfPresent([ProjectID].self, forKey: .projectIDs) ?? []
        agentTargets = try container.decodeIfPresent(
            [AgentRouteTarget].self,
            forKey: .agentTargets
        ) ?? []
        groupID = try container.decodeIfPresent(ProjectGroupID.self, forKey: .groupID)
    }
}

/// Remote-safe attachment metadata. Host-local paths and snippet bodies are
/// deliberately excluded from the shared dashboard projection.
public struct GADDraftAttachmentProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: PromptAttachmentKind
    public let displayName: String
    public let byteCount: Int?
    public let typeHint: String?

    public init(
        id: UUID,
        kind: PromptAttachmentKind,
        displayName: String,
        byteCount: Int? = nil,
        typeHint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = String(displayName.prefix(240))
        self.byteCount = byteCount.map { max(0, $0) }
        self.typeHint = typeHint.map { String($0.prefix(80)) }
    }

    public init(_ attachment: PromptAttachment) {
        self.init(
            id: attachment.id,
            kind: attachment.kind,
            displayName: attachment.displayName,
            byteCount: attachment.byteCount,
            typeHint: attachment.typeHint
        )
    }

    public var attachmentReference: PromptAttachment {
        PromptAttachment(
            id: id,
            kind: kind,
            displayName: displayName,
            source: nil,
            byteCount: byteCount,
            typeHint: typeHint
        )
    }
}

public struct GADProjectProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: ProjectID
    public let name: String
    public let platforms: [ProjectPlatform]
    public let frameworks: [String]
    public let isGitRepository: Bool
    public let providerIDs: [AgentProviderID]
    public let template: ProjectTemplateReference?
    /// Stable project identity shown with exact mobile approval aliases.
    public let approvalOrdinal: Int?
    /// True when the Mac owner lets isolated worktree edits in this project
    /// start without review. Absent (nil) when not trusted.
    public let isTrusted: Bool?

    public init(
        id: ProjectID,
        name: String,
        platforms: [ProjectPlatform],
        frameworks: [String],
        isGitRepository: Bool,
        providerIDs: [AgentProviderID] = [.codex],
        template: ProjectTemplateReference? = nil,
        approvalOrdinal: Int? = nil,
        isTrusted: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.platforms = platforms
        self.frameworks = frameworks
        self.isGitRepository = isGitRepository
        self.providerIDs = providerIDs
        self.template = template
        self.approvalOrdinal = approvalOrdinal
        self.isTrusted = isTrusted == true ? true : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, platforms, frameworks, isGitRepository, providerIDs, template, approvalOrdinal, isTrusted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        platforms = try container.decode([ProjectPlatform].self, forKey: .platforms)
        frameworks = try container.decode([String].self, forKey: .frameworks)
        isGitRepository = try container.decode(Bool.self, forKey: .isGitRepository)
        providerIDs = try container.decodeIfPresent(
            [AgentProviderID].self,
            forKey: .providerIDs
        ) ?? [.codex]
        template = try container.decodeIfPresent(ProjectTemplateReference.self, forKey: .template)
        approvalOrdinal = try container.decodeIfPresent(Int.self, forKey: .approvalOrdinal)
        isTrusted = try container.decodeIfPresent(Bool.self, forKey: .isTrusted) == true ? true : nil
    }
}

public enum GADAgentScopeProjection: Codable, Equatable, Sendable {
    case global
    case union
    case project(ProjectID)
}

public struct GADAgentProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public let name: String
    public let summary: String
    public let capabilities: [AgentCapability]
    public let scope: GADAgentScopeProjection
    public let isEnabled: Bool
    public let isActiveInCodex: Bool
    public let hasDefinition: Bool

    public init(
        id: AgentID,
        name: String,
        summary: String,
        capabilities: [AgentCapability],
        scope: GADAgentScopeProjection,
        isEnabled: Bool,
        isActiveInCodex: Bool,
        hasDefinition: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.capabilities = capabilities
        self.scope = scope
        self.isEnabled = isEnabled
        self.isActiveInCodex = isActiveInCodex
        self.hasDefinition = hasDefinition
    }
}

public struct GADProjectGroupProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: ProjectGroupID
    public let name: String
    public let members: [ProjectGroupMember]

    public init(id: ProjectGroupID, name: String, members: [ProjectGroupMember]) {
        self.id = id
        self.name = name
        self.members = members
    }
}

public struct GADResourceProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: SharedResourceID
    public let name: String
    public let access: SharedResourceAccess
    public let isEnabled: Bool
    /// Stable shared-resource identity shown with exact mobile approval aliases.
    public let approvalOrdinal: Int?

    public init(
        id: SharedResourceID,
        name: String,
        access: SharedResourceAccess,
        isEnabled: Bool,
        approvalOrdinal: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.access = access
        self.isEnabled = isEnabled
        self.approvalOrdinal = approvalOrdinal
    }
}

public struct GADInstructionProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: InstructionPackID
    public let name: String
    public let scope: InstructionScope
    public let version: Int
    public let isEnabled: Bool
    public let updatedAt: Date

    public init(
        id: InstructionPackID,
        name: String,
        scope: InstructionScope,
        version: Int,
        isEnabled: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.version = version
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public struct GADPlanRouteProjection: Codable, Equatable, Identifiable, Sendable {
    public let projectID: ProjectID
    public let providerID: AgentProviderID
    public let model: String?
    public let agentIDs: [AgentID]
    public let providerBindings: [ProviderRouteBinding]
    public let reason: String
    public var id: ProjectID { projectID }

    public init(
        projectID: ProjectID,
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        agentIDs: [AgentID],
        providerBindings: [ProviderRouteBinding] = [],
        reason: String
    ) {
        self.projectID = projectID
        self.providerID = providerID
        self.model = model
        self.agentIDs = agentIDs
        self.providerBindings = providerBindings
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, providerID, model, agentIDs, providerBindings, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        model = try container.decodeIfPresent(String.self, forKey: .model)
        agentIDs = try container.decode([AgentID].self, forKey: .agentIDs)
        providerBindings = try container.decodeIfPresent(
            [ProviderRouteBinding].self,
            forKey: .providerBindings
        ) ?? []
        reason = try container.decode(String.self, forKey: .reason)
    }
}

public struct GADPlannedGitOperationProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: ProjectID
    public let kind: GitOperationKind
    public let branch: String?
    public let remote: String?

    public init(id: UUID, projectID: ProjectID, kind: GitOperationKind, branch: String?, remote: String?) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.branch = branch
        self.remote = remote
    }
}

public struct GADPlanProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: RunID
    public let goal: String
    public let attachments: [GADDraftAttachmentProjection]
    public let routes: [GADPlanRouteProjection]
    public let risk: PlanRisk
    public let confidence: Double
    public let gitOperations: [GADPlannedGitOperationProjection]
    public let warnings: [String]
    public let selectedResourceIDs: [SharedResourceID]
    public let createdAt: Date
    /// Additive optional field: absent for single-step plans.
    public let deliveryPipeline: DeliveryPipeline?
    /// Set by the host when every routed project is trusted and the plan stays
    /// within the trusted-start boundary (isolated worktrees, no push, merge,
    /// deletion or other separately approved Git work). Clients may then start
    /// it without review or local authentication; the host re-checks it.
    public let startsWithoutReview: Bool?

    public var canStartAutomatically: Bool {
        PlanAutomaticStartPolicy.allows(
            risk: risk,
            confidence: confidence,
            hasGitOperations: !gitOperations.isEmpty,
            hasWarnings: !warnings.isEmpty
        ) && selectedResourceIDs.isEmpty
            && !routes.isEmpty && routes.allSatisfy { !$0.agentIDs.isEmpty }
            && (deliveryPipeline?.stages.count ?? 0) <= 1
            && deliveryPipeline?.includesRelease != true
    }

    public init(
        id: RunID,
        goal: String,
        attachments: [GADDraftAttachmentProjection] = [],
        routes: [GADPlanRouteProjection],
        risk: PlanRisk,
        confidence: Double,
        gitOperations: [GADPlannedGitOperationProjection],
        warnings: [String],
        selectedResourceIDs: [SharedResourceID],
        createdAt: Date,
        deliveryPipeline: DeliveryPipeline? = nil,
        startsWithoutReview: Bool? = nil
    ) {
        self.startsWithoutReview = startsWithoutReview == true ? true : nil
        self.id = id
        self.goal = goal
        self.attachments = attachments
        self.routes = routes
        self.risk = risk
        self.confidence = confidence
        self.gitOperations = gitOperations
        self.warnings = warnings
        self.selectedResourceIDs = selectedResourceIDs
        self.createdAt = createdAt
        self.deliveryPipeline = deliveryPipeline
    }

    private enum CodingKeys: String, CodingKey {
        case id, goal, attachments, routes, risk, confidence, gitOperations
        case warnings, selectedResourceIDs, createdAt, deliveryPipeline, startsWithoutReview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RunID.self, forKey: .id)
        goal = try container.decode(String.self, forKey: .goal)
        attachments = try container.decodeIfPresent(
            [GADDraftAttachmentProjection].self,
            forKey: .attachments
        ) ?? []
        routes = try container.decode([GADPlanRouteProjection].self, forKey: .routes)
        risk = try container.decode(PlanRisk.self, forKey: .risk)
        confidence = try container.decode(Double.self, forKey: .confidence)
        gitOperations = try container.decode(
            [GADPlannedGitOperationProjection].self,
            forKey: .gitOperations
        )
        warnings = try container.decode([String].self, forKey: .warnings)
        selectedResourceIDs = try container.decode(
            [SharedResourceID].self,
            forKey: .selectedResourceIDs
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deliveryPipeline = try container.decodeIfPresent(DeliveryPipeline.self, forKey: .deliveryPipeline)
        startsWithoutReview = try container.decodeIfPresent(Bool.self, forKey: .startsWithoutReview) == true ? true : nil
    }
}

public struct GADAssignmentProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: AssignmentID
    public let projectID: ProjectID
    public let agentID: AgentID
    public let providerID: AgentProviderID
    public let providerBindingID: ProviderAgentBindingID?
    public let model: String?
    public let status: AgentStatus
    public let currentTask: String
    public let progress: Double?
    public let statusReason: String?
    public let startIsIndeterminate: Bool
    public let deliveryStageID: DeliveryStageID?

    public init(
        id: AssignmentID,
        projectID: ProjectID,
        agentID: AgentID,
        providerID: AgentProviderID = .codex,
        providerBindingID: ProviderAgentBindingID? = nil,
        model: String? = nil,
        status: AgentStatus,
        currentTask: String,
        progress: Double?,
        statusReason: String?,
        startIsIndeterminate: Bool = false,
        deliveryStageID: DeliveryStageID? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.providerID = providerID
        self.providerBindingID = providerBindingID
        self.model = model
        self.status = status
        self.currentTask = currentTask
        self.progress = progress
        self.statusReason = statusReason
        self.startIsIndeterminate = startIsIndeterminate
        self.deliveryStageID = deliveryStageID
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, agentID, providerID, providerBindingID, model, status, currentTask, progress, statusReason
        case startIsIndeterminate, deliveryStageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AssignmentID.self, forKey: .id)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        agentID = try container.decode(AgentID.self, forKey: .agentID)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        providerBindingID = try container.decodeIfPresent(
            ProviderAgentBindingID.self,
            forKey: .providerBindingID
        )
        model = try container.decodeIfPresent(String.self, forKey: .model)
        status = try container.decode(AgentStatus.self, forKey: .status)
        currentTask = try container.decode(String.self, forKey: .currentTask)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason)
        startIsIndeterminate = try container.decodeIfPresent(
            Bool.self,
            forKey: .startIsIndeterminate
        ) ?? false
        deliveryStageID = try container.decodeIfPresent(DeliveryStageID.self, forKey: .deliveryStageID)
    }
}

public struct GADJournalProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: RunJournalEventKind
    public let message: String
    public let assignmentID: AssignmentID?
    public let occurredAt: Date

    public init(
        id: UUID,
        kind: RunJournalEventKind,
        message: String,
        assignmentID: AssignmentID? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.assignmentID = assignmentID
        self.occurredAt = occurredAt
    }
}

/// Retained display identity only; project paths and access grants stay on the host.
public struct GADRunProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: ProjectID
    public let name: String

    public init(id: ProjectID, name: String) {
        self.id = id
        self.name = name
    }
}

/// One agent step for the mobile conversation view: what kind of thing
/// happened and its outcome, with a redacted one-line title. Command output and
/// step details never leave the Mac. `kind` and `status` travel as strings so a
/// future step kind degrades to a generic tool step instead of failing decode.
public struct GADRunActivityProjection: Codable, Equatable, Identifiable, Sendable {
    public static let limit = 120
    public static let titleLimit = 240
    /// Agent narration is the conversation, so it keeps more text.
    public static let messageTitleLimit = 1_500

    public let id: String
    public let assignmentID: AssignmentID
    public let kind: String
    public let title: String
    public let status: String
    public let exitCode: Int?
    public let startedAt: Date
    public let finishedAt: Date?

    public init(
        id: String,
        assignmentID: AssignmentID,
        kind: String,
        title: String,
        status: String,
        exitCode: Int?,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.id = id
        self.assignmentID = assignmentID
        self.kind = kind
        self.title = title
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The shared domain step, for the transcript and answer helpers.
    public var step: RunActivityStep {
        RunActivityStep(
            id: id,
            assignmentID: assignmentID,
            kind: RunActivityStep.Kind(rawValue: kind) ?? .tool,
            title: title,
            status: RunActivityStep.Status(rawValue: status) ?? .succeeded,
            exitCode: exitCode,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

public struct GADRunProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: RunID
    public let goal: String
    public let attachments: [GADDraftAttachmentProjection]
    public let risk: PlanRisk
    public let confidence: Double
    public let gitOperations: [GADPlannedGitOperationProjection]
    public let warnings: [String]
    public let status: RunStatus
    public let assignments: [GADAssignmentProjection]
    public let helperTasks: [GADProviderTaskProjection]
    public let projectSnapshot: [GADRunProjectSnapshot]
    public let outcome: String?
    public let journal: [GADJournalProjection]
    /// Protocol 3.11: newest typed steps, redacted, without output.
    public let activity: [GADRunActivityProjection]
    public let createdAt: Date
    public let updatedAt: Date
    public let deliveryPipeline: DeliveryPipeline?

    public init(
        id: RunID,
        goal: String,
        attachments: [GADDraftAttachmentProjection] = [],
        risk: PlanRisk,
        confidence: Double = 1,
        gitOperations: [GADPlannedGitOperationProjection] = [],
        warnings: [String] = [],
        status: RunStatus,
        assignments: [GADAssignmentProjection],
        helperTasks: [GADProviderTaskProjection] = [],
        projectSnapshot: [GADRunProjectSnapshot] = [],
        outcome: String?,
        journal: [GADJournalProjection],
        activity: [GADRunActivityProjection] = [],
        createdAt: Date,
        updatedAt: Date,
        deliveryPipeline: DeliveryPipeline? = nil
    ) {
        self.id = id
        self.goal = goal
        self.attachments = attachments
        self.risk = risk
        self.confidence = min(max(confidence, 0), 1)
        self.gitOperations = gitOperations
        self.warnings = warnings
        self.status = status
        self.assignments = assignments
        self.helperTasks = helperTasks
        self.projectSnapshot = projectSnapshot
        self.outcome = outcome
        self.journal = journal
        self.activity = Array(activity.suffix(GADRunActivityProjection.limit))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deliveryPipeline = deliveryPipeline
    }

    private enum CodingKeys: String, CodingKey {
        case id, goal, attachments, risk, confidence, gitOperations, warnings
        case status, assignments, helperTasks, projectSnapshot, outcome, journal, activity
        case createdAt, updatedAt, deliveryPipeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RunID.self, forKey: .id)
        goal = try container.decode(String.self, forKey: .goal)
        attachments = try container.decodeIfPresent(
            [GADDraftAttachmentProjection].self,
            forKey: .attachments
        ) ?? []
        risk = try container.decode(PlanRisk.self, forKey: .risk)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        gitOperations = try container.decodeIfPresent(
            [GADPlannedGitOperationProjection].self,
            forKey: .gitOperations
        ) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        status = try container.decode(RunStatus.self, forKey: .status)
        assignments = try container.decode([GADAssignmentProjection].self, forKey: .assignments)
        helperTasks = try container.decodeIfPresent(
            [GADProviderTaskProjection].self,
            forKey: .helperTasks
        ) ?? []
        projectSnapshot = try container.decodeIfPresent(
            [GADRunProjectSnapshot].self,
            forKey: .projectSnapshot
        ) ?? []
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        journal = try container.decode([GADJournalProjection].self, forKey: .journal)
        activity = try container.decodeIfPresent([GADRunActivityProjection].self, forKey: .activity) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deliveryPipeline = try container.decodeIfPresent(DeliveryPipeline.self, forKey: .deliveryPipeline)
    }
}

public enum GADApprovalAction: String, Codable, CaseIterable, Sendable {
    case decline
    case allowOnce
    case allowForRun
    case cancel
}

public struct GADApprovalProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let runID: RunID
    public let assignmentID: AssignmentID
    public let providerID: AgentProviderID
    public let kind: CodexApprovalKind
    public let summary: String
    public let details: String?
    public let actions: [GADApprovalAction]
    public let approvalSessionID: ApprovalSessionID?
    public let operationDigest: String?
    public let disclosureComplete: Bool
    public let expiresAt: Date

    public init(
        id: String,
        runID: RunID,
        assignmentID: AssignmentID,
        providerID: AgentProviderID = .codex,
        kind: CodexApprovalKind,
        summary: String,
        details: String?,
        actions: [GADApprovalAction],
        approvalSessionID: ApprovalSessionID?,
        operationDigest: String? = nil,
        disclosureComplete: Bool = true,
        expiresAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.assignmentID = assignmentID
        self.providerID = providerID
        self.kind = kind
        self.summary = summary
        self.details = details
        self.actions = actions
        self.approvalSessionID = approvalSessionID
        self.operationDigest = operationDigest
        self.disclosureComplete = disclosureComplete
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, runID, assignmentID, providerID, kind, summary, details, actions
        case approvalSessionID, operationDigest, disclosureComplete, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        runID = try container.decode(RunID.self, forKey: .runID)
        assignmentID = try container.decode(AssignmentID.self, forKey: .assignmentID)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        kind = try container.decode(CodexApprovalKind.self, forKey: .kind)
        summary = try container.decode(String.self, forKey: .summary)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        actions = try container.decode([GADApprovalAction].self, forKey: .actions)
        approvalSessionID = try container.decodeIfPresent(
            ApprovalSessionID.self,
            forKey: .approvalSessionID
        )
        operationDigest = try container.decodeIfPresent(String.self, forKey: .operationDigest)
        disclosureComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .disclosureComplete
        ) ?? (providerID == .codex)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public struct GADCodexTaskProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let projectID: ProjectID
    public let title: String
    public let summary: String?
    public let status: CodexTaskStatus
    public let updatedAt: Date

    public init(id: String, projectID: ProjectID, title: String, summary: String?, status: CodexTaskStatus, updatedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct GADAccountProjection: Codable, Equatable, Sendable {
    public let authenticated: Bool
    public let planName: String?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let secondaryUsedPercent: Double?
    public let secondaryResetsAt: Date?

    public init(
        authenticated: Bool,
        planName: String?,
        usedPercent: Double?,
        resetsAt: Date?,
        secondaryUsedPercent: Double?,
        secondaryResetsAt: Date?
    ) {
        self.authenticated = authenticated
        self.planName = planName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetsAt = secondaryResetsAt
    }
}

public struct GADProviderUsageProjection: Codable, Equatable, Identifiable, Sendable {
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
        resetsAt: Date?,
        isEstimate: Bool
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

public struct GADProviderAccountProjection: Codable, Equatable, Identifiable, Sendable {
    public let providerID: AgentProviderID
    public let connectionState: ProviderConnectionState
    public let planName: String?
    public let selectedModel: String?
    public let availableModels: [String]
    public let usage: [GADProviderUsageProjection]
    public let observedAt: Date
    /// Optional for older hosts and cached projections.
    public let activityFreshness: ProviderActivityFreshness?
    /// Presence only; credential values never cross the projection boundary.
    public let credentialConfigured: Bool?

    public var id: AgentProviderID { providerID }

    public init(
        providerID: AgentProviderID,
        connectionState: ProviderConnectionState,
        planName: String?,
        selectedModel: String?,
        availableModels: [String],
        usage: [GADProviderUsageProjection],
        observedAt: Date,
        activityFreshness: ProviderActivityFreshness? = nil,
        credentialConfigured: Bool? = nil
    ) {
        self.providerID = providerID
        self.connectionState = connectionState
        self.planName = planName
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.usage = usage
        self.observedAt = observedAt
        self.activityFreshness = activityFreshness
        self.credentialConfigured = credentialConfigured
    }
}

public struct GADProviderTaskProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: AgentProviderID
    public let projectID: ProjectID
    public let title: String
    public let summary: String?
    public let status: ProviderTaskStatus
    public let updatedAt: Date
    public let agentRole: String?
    public let parentTaskID: String?
    /// The exact logical agent this provider history can be attributed to.
    /// This is observational metadata and never makes the provider task routable.
    public let agentID: AgentID?

    public init(
        id: String,
        providerID: AgentProviderID,
        projectID: ProjectID,
        title: String,
        summary: String?,
        status: ProviderTaskStatus,
        updatedAt: Date,
        agentRole: String?,
        parentTaskID: String? = nil,
        agentID: AgentID? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
        self.agentRole = agentRole
        self.parentTaskID = parentTaskID
        self.agentID = agentID
    }
}

public struct GADProviderBindingProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: ProviderAgentBindingID
    public let providerID: AgentProviderID
    public let agentID: AgentID
    public let projectID: ProjectID?
    public let capabilities: [AgentCapability]
    public let state: ProviderBindingState
    public let hasInstructionsOverride: Bool

    public init(
        id: ProviderAgentBindingID,
        providerID: AgentProviderID,
        agentID: AgentID,
        projectID: ProjectID?,
        capabilities: [AgentCapability],
        state: ProviderBindingState,
        hasInstructionsOverride: Bool
    ) {
        self.id = id
        self.providerID = providerID
        self.agentID = agentID
        self.projectID = projectID
        self.capabilities = capabilities
        self.state = state
        self.hasInstructionsOverride = hasInstructionsOverride
    }
}

public struct GADHandoffEndpointProjection: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let bindingID: ProviderAgentBindingID
    public let agentID: AgentID
    public let projectID: ProjectID

    public init(
        providerID: AgentProviderID,
        bindingID: ProviderAgentBindingID,
        agentID: AgentID,
        projectID: ProjectID
    ) {
        self.providerID = providerID
        self.bindingID = bindingID
        self.agentID = agentID
        self.projectID = projectID
    }
}

public struct GADHandoffLinkProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentHandoffLinkID
    public let source: GADHandoffEndpointProjection
    public let destination: GADHandoffEndpointProjection
    public let purpose: String
    public let conditions: String
    public let triggers: [HandoffTrigger]
    public let isEnabled: Bool

    public init(
        id: AgentHandoffLinkID,
        source: GADHandoffEndpointProjection,
        destination: GADHandoffEndpointProjection,
        purpose: String,
        conditions: String,
        triggers: [HandoffTrigger],
        isEnabled: Bool
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.purpose = purpose
        self.conditions = conditions
        self.triggers = triggers
        self.isEnabled = isEnabled
    }
}

public struct GADHandoffProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: HandoffID
    public let runID: RunID
    public let destinationRunID: RunID?
    public let linkID: AgentHandoffLinkID
    public let sourceAssignmentID: AssignmentID?
    public let source: GADHandoffEndpointProjection
    public let destination: GADHandoffEndpointProjection
    public let state: HandoffState
    public let purpose: String
    public let sourceOutcomeSummary: String
    public let requestedNextAction: String
    public let attemptCount: Int
    public let statusReason: String?
    public let updatedAt: Date

    public init(
        id: HandoffID,
        runID: RunID,
        destinationRunID: RunID? = nil,
        linkID: AgentHandoffLinkID,
        sourceAssignmentID: AssignmentID? = nil,
        source: GADHandoffEndpointProjection,
        destination: GADHandoffEndpointProjection,
        state: HandoffState,
        purpose: String,
        sourceOutcomeSummary: String,
        requestedNextAction: String,
        attemptCount: Int,
        statusReason: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.destinationRunID = destinationRunID
        self.linkID = linkID
        self.sourceAssignmentID = sourceAssignmentID
        self.source = source
        self.destination = destination
        self.state = state
        self.purpose = purpose
        self.sourceOutcomeSummary = sourceOutcomeSummary
        self.requestedNextAction = requestedNextAction
        self.attemptCount = attemptCount
        self.statusReason = statusReason
        self.updatedAt = updatedAt
    }
}

public struct GADHealthProjection: Codable, Equatable, Identifiable, Sendable {
    public let kind: HealthCheckKind
    public let status: HealthCheckStatus
    public let summary: String
    public var id: HealthCheckKind { kind }

    public init(kind: HealthCheckKind, status: HealthCheckStatus, summary: String) {
        self.kind = kind
        self.status = status
        self.summary = summary
    }
}

public struct DashboardProjection: Codable, Equatable, Sendable {
    public let revision: StateRevision
    public let generatedAt: Date
    public let host: GADHostProjection
    public let draft: GADDraftProjection
    public let projects: [GADProjectProjection]
    public let agents: [GADAgentProjection]
    public let projectGroups: [GADProjectGroupProjection]
    public let resources: [GADResourceProjection]
    public let instructions: [GADInstructionProjection]
    public let plan: GADPlanProjection?
    public let runs: [GADRunProjection]
    public let automations: AutomationSnapshot
    public let approvals: [GADApprovalProjection]
    /// Legacy v1 Codex-only fields retained for cache and client compatibility.
    public let codexTasks: [GADCodexTaskProjection]
    public let account: GADAccountProjection?
    public let providerAccounts: [GADProviderAccountProjection]
    public let providerTasks: [GADProviderTaskProjection]
    public let providerBindings: [GADProviderBindingProjection]
    public let handoffLinks: [GADHandoffLinkProjection]
    public let handoffs: [GADHandoffProjection]
    public let health: [GADHealthProjection]

    public init(
        revision: StateRevision = .zero,
        generatedAt: Date,
        host: GADHostProjection,
        draft: GADDraftProjection = .init(),
        projects: [GADProjectProjection] = [],
        agents: [GADAgentProjection] = [],
        projectGroups: [GADProjectGroupProjection] = [],
        resources: [GADResourceProjection] = [],
        instructions: [GADInstructionProjection] = [],
        plan: GADPlanProjection? = nil,
        runs: [GADRunProjection] = [],
        automations: AutomationSnapshot = .empty,
        approvals: [GADApprovalProjection] = [],
        codexTasks: [GADCodexTaskProjection] = [],
        account: GADAccountProjection? = nil,
        providerAccounts: [GADProviderAccountProjection] = [],
        providerTasks: [GADProviderTaskProjection] = [],
        providerBindings: [GADProviderBindingProjection] = [],
        handoffLinks: [GADHandoffLinkProjection] = [],
        handoffs: [GADHandoffProjection] = [],
        health: [GADHealthProjection] = []
    ) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.host = host
        self.draft = draft
        self.projects = projects
        self.agents = agents
        self.projectGroups = projectGroups
        self.resources = resources
        self.instructions = instructions
        self.plan = plan
        self.runs = runs
        self.automations = automations
        self.approvals = approvals
        self.codexTasks = codexTasks
        self.account = account
        self.providerAccounts = providerAccounts.isEmpty
            ? Self.migratedAccounts(from: account, generatedAt: generatedAt)
            : providerAccounts
        self.providerTasks = providerTasks.isEmpty
            ? Self.migratedTasks(from: codexTasks)
            : providerTasks
        self.providerBindings = providerBindings
        self.handoffLinks = handoffLinks
        self.handoffs = handoffs
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case revision, generatedAt, host, draft, projects, agents, projectGroups
        case resources, instructions, plan, runs, automations, approvals, codexTasks, account
        case providerAccounts, providerTasks, providerBindings, handoffLinks, handoffs, health
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(StateRevision.self, forKey: .revision)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        host = try container.decode(GADHostProjection.self, forKey: .host)
        draft = try container.decodeIfPresent(GADDraftProjection.self, forKey: .draft) ?? .init()
        projects = try container.decodeIfPresent([GADProjectProjection].self, forKey: .projects) ?? []
        agents = try container.decodeIfPresent([GADAgentProjection].self, forKey: .agents) ?? []
        projectGroups = try container.decodeIfPresent(
            [GADProjectGroupProjection].self,
            forKey: .projectGroups
        ) ?? []
        resources = try container.decodeIfPresent([GADResourceProjection].self, forKey: .resources) ?? []
        instructions = try container.decodeIfPresent(
            [GADInstructionProjection].self,
            forKey: .instructions
        ) ?? []
        plan = try container.decodeIfPresent(GADPlanProjection.self, forKey: .plan)
        runs = try container.decodeIfPresent([GADRunProjection].self, forKey: .runs) ?? []
        automations = try container.decodeIfPresent(
            AutomationSnapshot.self,
            forKey: .automations
        ) ?? .empty
        approvals = try container.decodeIfPresent([GADApprovalProjection].self, forKey: .approvals) ?? []
        codexTasks = try container.decodeIfPresent(
            [GADCodexTaskProjection].self,
            forKey: .codexTasks
        ) ?? []
        account = try container.decodeIfPresent(GADAccountProjection.self, forKey: .account)
        let decodedAccounts = try container.decodeIfPresent(
            [GADProviderAccountProjection].self,
            forKey: .providerAccounts
        ) ?? []
        providerAccounts = decodedAccounts.isEmpty
            ? Self.migratedAccounts(from: account, generatedAt: generatedAt)
            : decodedAccounts
        let decodedTasks = try container.decodeIfPresent(
            [GADProviderTaskProjection].self,
            forKey: .providerTasks
        ) ?? []
        providerTasks = decodedTasks.isEmpty ? Self.migratedTasks(from: codexTasks) : decodedTasks
        providerBindings = try container.decodeIfPresent(
            [GADProviderBindingProjection].self,
            forKey: .providerBindings
        ) ?? []
        handoffLinks = try container.decodeIfPresent(
            [GADHandoffLinkProjection].self,
            forKey: .handoffLinks
        ) ?? []
        handoffs = try container.decodeIfPresent(
            [GADHandoffProjection].self,
            forKey: .handoffs
        ) ?? []
        health = try container.decodeIfPresent([GADHealthProjection].self, forKey: .health) ?? []
    }

    private static func migratedAccounts(
        from account: GADAccountProjection?,
        generatedAt: Date
    ) -> [GADProviderAccountProjection] {
        guard let account else { return [] }
        var usage: [GADProviderUsageProjection] = []
        if let value = account.usedPercent {
            usage.append(.init(
                id: "primary",
                kind: .consumedPercentage,
                label: "Primary usage",
                value: value,
                unit: "percent",
                resetsAt: account.resetsAt,
                isEstimate: false
            ))
        }
        if let value = account.secondaryUsedPercent {
            usage.append(.init(
                id: "secondary",
                kind: .consumedPercentage,
                label: "Secondary usage",
                value: value,
                unit: "percent",
                resetsAt: account.secondaryResetsAt,
                isEstimate: false
            ))
        }
        return [.init(
            providerID: .codex,
            connectionState: account.authenticated
                ? .connected(version: nil)
                : .needsAuthentication,
            planName: account.planName,
            selectedModel: nil,
            availableModels: [],
            usage: usage,
            observedAt: generatedAt
        )]
    }

    private static func migratedTasks(
        from tasks: [GADCodexTaskProjection]
    ) -> [GADProviderTaskProjection] {
        tasks.map { task in
            .init(
                id: task.id,
                providerID: .codex,
                projectID: task.projectID,
                title: task.title,
                summary: task.summary,
                status: task.status.providerStatus,
                updatedAt: task.updatedAt,
                agentRole: nil
            )
        }
    }
}

public enum GADProjectionSection: String, Codable, CaseIterable, Sendable {
    case host, draft, projects, agents, projectGroups, resources, instructions, plan, runs, automations, approvals
    case codexTasks, account, providerAccounts, providerTasks, providerBindings, handoffLinks, handoffs, health
}

public enum GADStateChange: Codable, Equatable, Sendable {
    case host(GADHostProjection)
    case draft(GADDraftProjection)
    case projects([GADProjectProjection])
    case agents([GADAgentProjection])
    case projectGroups([GADProjectGroupProjection])
    case resources([GADResourceProjection])
    case instructions([GADInstructionProjection])
    case plan(GADPlanProjection?)
    case runs([GADRunProjection])
    case automations(AutomationSnapshot)
    case approvals([GADApprovalProjection])
    case codexTasks([GADCodexTaskProjection])
    case account(GADAccountProjection?)
    case providerAccounts([GADProviderAccountProjection])
    case providerTasks([GADProviderTaskProjection])
    case providerBindings([GADProviderBindingProjection])
    case handoffLinks([GADHandoffLinkProjection])
    case handoffs([GADHandoffProjection])
    case health([GADHealthProjection])
}

public extension DashboardProjection {
    /// Returns the smallest section-level change set needed to replace this
    /// projection with another authoritative snapshot. Revisions and timestamps
    /// are assigned by `GADCoordinator`, not trusted from the caller.
    func changes(replacingWith replacement: DashboardProjection) -> [GADStateChange] {
        var changes: [GADStateChange] = []
        if host != replacement.host { changes.append(.host(replacement.host)) }
        if draft != replacement.draft { changes.append(.draft(replacement.draft)) }
        if projects != replacement.projects { changes.append(.projects(replacement.projects)) }
        if agents != replacement.agents { changes.append(.agents(replacement.agents)) }
        if projectGroups != replacement.projectGroups { changes.append(.projectGroups(replacement.projectGroups)) }
        if resources != replacement.resources { changes.append(.resources(replacement.resources)) }
        if instructions != replacement.instructions { changes.append(.instructions(replacement.instructions)) }
        if plan != replacement.plan { changes.append(.plan(replacement.plan)) }
        if runs != replacement.runs { changes.append(.runs(replacement.runs)) }
        if automations != replacement.automations { changes.append(.automations(replacement.automations)) }
        if approvals != replacement.approvals { changes.append(.approvals(replacement.approvals)) }
        if codexTasks != replacement.codexTasks { changes.append(.codexTasks(replacement.codexTasks)) }
        if account != replacement.account { changes.append(.account(replacement.account)) }
        if providerAccounts != replacement.providerAccounts { changes.append(.providerAccounts(replacement.providerAccounts)) }
        if providerTasks != replacement.providerTasks { changes.append(.providerTasks(replacement.providerTasks)) }
        if providerBindings != replacement.providerBindings { changes.append(.providerBindings(replacement.providerBindings)) }
        if handoffLinks != replacement.handoffLinks { changes.append(.handoffLinks(replacement.handoffLinks)) }
        if handoffs != replacement.handoffs { changes.append(.handoffs(replacement.handoffs)) }
        if health != replacement.health { changes.append(.health(replacement.health)) }
        return changes
    }

    func applying(_ changes: [GADStateChange], revision: StateRevision, generatedAt: Date) -> DashboardProjection {
        var host = host
        var draft = draft
        var projects = projects
        var agents = agents
        var projectGroups = projectGroups
        var resources = resources
        var instructions = instructions
        var plan = plan
        var runs = runs
        var automations = automations
        var approvals = approvals
        var codexTasks = codexTasks
        var account = account
        var providerAccounts = providerAccounts
        var providerTasks = providerTasks
        var providerBindings = providerBindings
        var handoffLinks = handoffLinks
        var handoffs = handoffs
        var health = health

        for change in changes {
            switch change {
            case let .host(value): host = value
            case let .draft(value): draft = value
            case let .projects(value): projects = value
            case let .agents(value): agents = value
            case let .projectGroups(value): projectGroups = value
            case let .resources(value): resources = value
            case let .instructions(value): instructions = value
            case let .plan(value): plan = value
            case let .runs(value): runs = value
            case let .automations(value): automations = value
            case let .approvals(value): approvals = value
            case let .codexTasks(value): codexTasks = value
            case let .account(value): account = value
            case let .providerAccounts(value): providerAccounts = value
            case let .providerTasks(value): providerTasks = value
            case let .providerBindings(value): providerBindings = value
            case let .handoffLinks(value): handoffLinks = value
            case let .handoffs(value): handoffs = value
            case let .health(value): health = value
            }
        }

        return DashboardProjection(
            revision: revision,
            generatedAt: generatedAt,
            host: host,
            draft: draft,
            projects: projects,
            agents: agents,
            projectGroups: projectGroups,
            resources: resources,
            instructions: instructions,
            plan: plan,
            runs: runs,
            automations: automations,
            approvals: approvals,
            codexTasks: codexTasks,
            account: account,
            providerAccounts: providerAccounts,
            providerTasks: providerTasks,
            providerBindings: providerBindings,
            handoffLinks: handoffLinks,
            handoffs: handoffs,
            health: health
        )
    }
}

public extension CodexTaskStatus {
    var providerStatus: ProviderTaskStatus {
        switch self {
        case .active: .working
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .idle: .saved
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

/// Conversation helpers for clients that see runs through the projection
/// (iPhone). Same rules as the Mac's `RunRecord` helpers.
public extension GADRunProjection {
    var activitySteps: [RunActivityStep] { activity.map(\.step) }

    private var answerFacts: [ConversationAnswer.AssignmentFacts] {
        assignments.map { .init(id: $0.id, status: $0.status, statusReason: $0.statusReason) }
    }

    var conversationAnswer: String? {
        ConversationAnswer.answer(status: status, assignments: answerFacts, outcome: outcome, activity: activitySteps)
    }

    var answerSteps: [RunActivityStep] {
        ConversationAnswer.answerSteps(status: status, assignments: answerFacts, activity: activitySteps)
    }

    var unverifiedAnswer: (issue: String, answer: String)? {
        ConversationAnswer.unverifiedAnswer(status: status, assignments: answerFacts, outcome: outcome)
    }

    var verificationNote: String? {
        ConversationAnswer.verificationNote(assignments: answerFacts, outcome: outcome)
    }
}

extension GADRunProjection: ProjectScopedRun {
    /// The mobile projection carries no plan routes; its snapshot and
    /// assignments name every project the run touched.
    public var scopedProjectIDs: Set<ProjectID> {
        Set(projectSnapshot.map(\.id)).union(assignments.map(\.projectID))
    }
}
