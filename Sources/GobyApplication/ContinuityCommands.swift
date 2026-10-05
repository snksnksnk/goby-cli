import Foundation
import GobyDomain

public enum GADCapability: String, Codable, CaseIterable, Sendable {
    case sharedDraft
    case planReview
    case runControl
    case runtimeApprovalOnce
    case runtimeApprovalRun
    case activeRunFollowUp
    case projectGroups
    case instructionPacks
    case providerBindingInstructions
    case providerActivity
    case manualHandoffs
    case projectGitBranches
    /// Legacy v1 capability retained while cached clients migrate.
    case codexRefresh
    case hostAdminProjects
    case hostAdminAgents
    case hostAdminResources
    case redactedDiagnostics
    case notifications
    case automations
    case deviceSelfRevocation

    /// Capabilities published by the production macOS continuity host. Keep
    /// feature negotiation and coordinator authorization on one reviewed set.
    public static let productionHost: Set<Self> = [
        .sharedDraft,
        .planReview,
        .runControl,
        .runtimeApprovalOnce,
        .activeRunFollowUp,
        .projectGroups,
        .instructionPacks,
        .providerBindingInstructions,
        .providerActivity,
        .manualHandoffs,
        .projectGitBranches,
        .hostAdminProjects,
        .hostAdminAgents,
        .hostAdminResources,
        .redactedDiagnostics,
        .codexRefresh,
        .notifications,
        .automations,
        .deviceSelfRevocation,
    ]
}

public struct ClientSession: Codable, Equatable, Sendable {
    public let hostID: HostID
    public let hostEpoch: HostEpoch
    public let protocolVersion: GADProtocolVersion
    public let revision: StateRevision
    public let capabilities: [GADCapability]
    public let supportsBoundAutomationReviews: Bool
    public let supportsRememberedCommandApprovals: Bool
    /// Protocol 3.11: runs carry typed, redacted activity steps. A flag rather
    /// than a capability case, so 3.10 clients still decode the session.
    public let supportsRunActivity: Bool
    /// Protocol 3.12: the host answers temporary chat commands.
    public let supportsTemporaryChat: Bool
    /// Protocol 3.13: parallel requests get temporary agent copies, and
    /// conflicting ones wait; `startNow` (Run Anyway) is accepted.
    public let supportsParallelRequests: Bool

    public init(
        hostID: HostID,
        hostEpoch: HostEpoch,
        protocolVersion: GADProtocolVersion,
        revision: StateRevision,
        capabilities: [GADCapability],
        supportsBoundAutomationReviews: Bool = true,
        supportsRememberedCommandApprovals: Bool = true,
        supportsRunActivity: Bool = true,
        supportsTemporaryChat: Bool = true,
        supportsParallelRequests: Bool = true
    ) {
        self.hostID = hostID
        self.hostEpoch = hostEpoch
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.capabilities = capabilities
        self.supportsBoundAutomationReviews = supportsBoundAutomationReviews
        self.supportsRememberedCommandApprovals = supportsRememberedCommandApprovals
        self.supportsRunActivity = supportsRunActivity
        self.supportsTemporaryChat = supportsTemporaryChat
        self.supportsParallelRequests = supportsParallelRequests
    }
    private enum CodingKeys: String, CodingKey {
        case hostID, hostEpoch, protocolVersion, revision, capabilities, supportsBoundAutomationReviews
        case supportsRememberedCommandApprovals, supportsRunActivity, supportsTemporaryChat, supportsParallelRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(HostID.self, forKey: .hostID)
        hostEpoch = try container.decode(HostEpoch.self, forKey: .hostEpoch)
        protocolVersion = try container.decode(GADProtocolVersion.self, forKey: .protocolVersion)
        revision = try container.decode(StateRevision.self, forKey: .revision)
        capabilities = try container.decode([GADCapability].self, forKey: .capabilities)
        supportsRememberedCommandApprovals = try container.decodeIfPresent(Bool.self, forKey: .supportsRememberedCommandApprovals) ?? false
        supportsBoundAutomationReviews = try container.decodeIfPresent(Bool.self, forKey: .supportsBoundAutomationReviews) ?? false
        supportsRunActivity = try container.decodeIfPresent(Bool.self, forKey: .supportsRunActivity) ?? false
        supportsTemporaryChat = try container.decodeIfPresent(Bool.self, forKey: .supportsTemporaryChat) ?? false
        supportsParallelRequests = try container.decodeIfPresent(Bool.self, forKey: .supportsParallelRequests) ?? false
    }

}

public struct GADDraftReplacement: Codable, Equatable, Sendable {
    public let expectedRevision: EntityRevision
    public let text: String
    public let attachments: [PromptAttachment]
    public let providerID: AgentProviderID
    public let model: String?
    public let platform: ProjectPlatform?
    public let projectIDs: [ProjectID]
    public let agentTargets: [AgentRouteTarget]
    public let groupID: ProjectGroupID?

    public init(
        expectedRevision: EntityRevision,
        text: String,
        attachments: [PromptAttachment] = [],
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        platform: ProjectPlatform? = nil,
        projectIDs: [ProjectID],
        agentTargets: [AgentRouteTarget],
        groupID: ProjectGroupID?
    ) {
        self.expectedRevision = expectedRevision
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
        case expectedRevision, text, attachments, providerID, model, platform, projectIDs, agentTargets, groupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedRevision = try container.decode(EntityRevision.self, forKey: .expectedRevision)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent(
            [PromptAttachment].self,
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

/// Starts one bounded, authenticated transfer from a paired mobile client.
/// Bytes are never represented as a path on the client or in a projection.
public struct GADPromptAttachmentUploadStart: Codable, Equatable, Sendable {
    public let uploadID: UUID
    public let attachmentID: UUID
    public let kind: PromptAttachmentKind
    public let displayName: String
    public let byteCount: Int
    public let typeHint: String?
    public let contentSHA256: String
    public let expectedDraftRevision: EntityRevision

    public init(
        uploadID: UUID,
        attachmentID: UUID,
        kind: PromptAttachmentKind,
        displayName: String,
        byteCount: Int,
        typeHint: String?,
        contentSHA256: String,
        expectedDraftRevision: EntityRevision
    ) {
        self.uploadID = uploadID
        self.attachmentID = attachmentID
        self.kind = kind
        self.displayName = String(displayName.prefix(240))
        self.byteCount = byteCount
        self.typeHint = typeHint.map { String($0.prefix(80)) }
        self.contentSHA256 = contentSHA256
        self.expectedDraftRevision = expectedDraftRevision
    }
}

public struct GADPromptAttachmentUploadChunk: Codable, Equatable, Sendable {
    public let uploadID: UUID
    public let offset: Int
    public let data: Data

    public init(uploadID: UUID, offset: Int, data: Data) {
        self.uploadID = uploadID
        self.offset = offset
        self.data = data
    }
}

public enum GADRunControlAction: String, Codable, Sendable {
    case pause, resume, cancel
    /// Protocol 3.13: start a request that waits for a conflicting one. Sent
    /// only when the session reports `supportsParallelRequests`.
    case startNow
}

public struct GADRunControl: Codable, Equatable, Sendable {
    public let runID: RunID
    public let action: GADRunControlAction
    public let modelChange: RunModelChange?

    public init(runID: RunID, action: GADRunControlAction, modelChange: RunModelChange? = nil) {
        self.runID = runID
        self.action = action
        self.modelChange = modelChange
    }
}

public struct GADPlanRouteSelection: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let agentIDs: [AgentID]

    public init(projectID: ProjectID, agentIDs: [AgentID]) {
        self.projectID = projectID
        self.agentIDs = agentIDs
    }
}

public struct GADPlanUpdate: Codable, Equatable, Sendable {
    public let planID: RunID
    public let routes: [GADPlanRouteSelection]
    public let selectedResourceIDs: [SharedResourceID]

    public init(planID: RunID, routes: [GADPlanRouteSelection], selectedResourceIDs: [SharedResourceID]) {
        self.planID = planID
        self.routes = routes
        self.selectedResourceIDs = selectedResourceIDs
    }
}

public struct GADPlanApproval: Codable, Equatable, Sendable {
    public let planID: RunID
    public let authorizationAssertion: String?
    public let automaticallyApproveRuntimeRequests: Bool
    /// The plan's separate push approval. Absent or false starts the plan
    /// without its push steps; omitted from the wire when nil.
    public let allowsPush: Bool?

    public init(
        planID: RunID,
        authorizationAssertion: String? = nil,
        automaticallyApproveRuntimeRequests: Bool = false,
        allowsPush: Bool? = nil
    ) {
        self.planID = planID
        self.authorizationAssertion = authorizationAssertion
        self.automaticallyApproveRuntimeRequests = automaticallyApproveRuntimeRequests
        self.allowsPush = allowsPush
    }

    private enum CodingKeys: String, CodingKey {
        case planID, authorizationAssertion, automaticallyApproveRuntimeRequests, allowsPush
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planID = try container.decode(RunID.self, forKey: .planID)
        authorizationAssertion = try container.decodeIfPresent(String.self, forKey: .authorizationAssertion)
        automaticallyApproveRuntimeRequests = try container.decodeIfPresent(Bool.self, forKey: .automaticallyApproveRuntimeRequests) ?? false
        allowsPush = try container.decodeIfPresent(Bool.self, forKey: .allowsPush)
    }
}

public struct GADApprovalResponse: Codable, Equatable, Sendable {
    public let approvalID: String
    public let runID: RunID
    public let assignmentID: AssignmentID
    public let action: GADApprovalAction
    public let approvalSessionID: ApprovalSessionID?
    public let authorizationAssertion: String?
    /// Opaque digest binding the canonical request to the exact disclosure
    /// bytes reviewed on this client.
    public let disclosureDigest: String?
    /// Legacy wire name: opt into the current host-offered command or folder-edit rule.
    public let rememberCommand: Bool?

    public init(
        approvalID: String,
        runID: RunID,
        assignmentID: AssignmentID,
        action: GADApprovalAction,
        approvalSessionID: ApprovalSessionID? = nil,
        authorizationAssertion: String? = nil,
        disclosureDigest: String? = nil,
        rememberCommand: Bool? = nil
    ) {
        self.approvalID = approvalID
        self.runID = runID
        self.assignmentID = assignmentID
        self.action = action
        self.approvalSessionID = approvalSessionID
        self.authorizationAssertion = authorizationAssertion
        self.disclosureDigest = disclosureDigest
        self.rememberCommand = rememberCommand
    }
}

public struct GADFollowUp: Codable, Equatable, Sendable {
    public let runID: RunID
    public let text: String

    public init(runID: RunID, text: String) {
        self.runID = runID
        self.text = text
    }
}

/// Protocol 3.12: a question for the host's temporary chat.
public struct GADTemporaryChatQuestion: Codable, Equatable, Sendable {
    /// The chat being continued; nil starts a new chat.
    public let chatID: TemporaryChatID?
    public let text: String
    /// An explicit Codex model; nil uses Codex's default.
    public let model: String?
    /// The provider to chat with; nil (older clients) means Codex.
    public let providerID: AgentProviderID?

    public init(chatID: TemporaryChatID?, text: String, model: String? = nil, providerID: AgentProviderID? = nil) {
        self.chatID = chatID
        self.text = text
        self.model = model
        self.providerID = providerID
    }
}

public struct GADManualHandoffRequest: Codable, Equatable, Sendable {
    public let runID: RunID
    public let sourceAssignmentID: AssignmentID
    public let linkID: AgentHandoffLinkID

    public init(
        runID: RunID,
        sourceAssignmentID: AssignmentID,
        linkID: AgentHandoffLinkID
    ) {
        self.runID = runID
        self.sourceAssignmentID = sourceAssignmentID
        self.linkID = linkID
    }
}

public struct GADInstructionMutation: Codable, Equatable, Sendable {
    public let id: InstructionPackID?
    public let expectedRevision: EntityRevision?
    public let name: String
    public let body: String
    public let scope: InstructionScope
    public let isEnabled: Bool

    public init(
        id: InstructionPackID?,
        expectedRevision: EntityRevision?,
        name: String,
        body: String,
        scope: InstructionScope,
        isEnabled: Bool
    ) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.name = name
        self.body = body
        self.scope = scope
        self.isEnabled = isEnabled
    }
}

public struct GADInstructionEditor: Codable, Equatable, Sendable {
    public let id: InstructionPackID
    public let name: String
    public let body: String
    public let scope: InstructionScope
    public let version: Int
    public let isEnabled: Bool
    public let expiresAt: Date

    public init(
        id: InstructionPackID,
        name: String,
        body: String,
        scope: InstructionScope,
        version: Int,
        isEnabled: Bool,
        expiresAt: Date
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.scope = scope
        self.version = version
        self.isEnabled = isEnabled
        self.expiresAt = expiresAt
    }
}

public struct GADProviderBindingInstructionEditor: Codable, Equatable, Sendable {
    public let bindingID: ProviderAgentBindingID
    public let instructions: String
    public let expiresAt: Date

    public init(bindingID: ProviderAgentBindingID, instructions: String, expiresAt: Date) {
        self.bindingID = bindingID
        self.instructions = instructions
        self.expiresAt = expiresAt
    }
}

public struct GADProviderBindingInstructionMutation: Codable, Equatable, Sendable {
    public let bindingID: ProviderAgentBindingID
    public let instructions: String?

    public init(bindingID: ProviderAgentBindingID, instructions: String?) {
        self.bindingID = bindingID
        self.instructions = instructions
    }
}

public struct GADProjectGroupMutation: Codable, Equatable, Sendable {
    public let id: ProjectGroupID?
    public let expectedRevision: EntityRevision?
    public let name: String
    public let members: [ProjectGroupMember]

    public init(id: ProjectGroupID?, expectedRevision: EntityRevision?, name: String, members: [ProjectGroupMember]) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.name = name
        self.members = members
    }
}

public struct GADAuthorizedLocationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct GADCodexProjectCandidateProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: ProjectID
    public let name: String
    public let platforms: [ProjectPlatform]
    public let isGitRepository: Bool
    public let evidence: [String]

    public init(
        id: ProjectID,
        name: String,
        platforms: [ProjectPlatform],
        isGitRepository: Bool,
        evidence: [String]
    ) {
        self.id = id
        self.name = name
        self.platforms = platforms
        self.isGitRepository = isGitRepository
        self.evidence = evidence
    }
}

public struct GADCodexAgentCandidateProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public let name: String
    public let summary: String
    public let capabilities: [AgentCapability]
    public let scope: GADAgentScopeProjection
    public let evidence: [String]
    public let requiresMacReview: Bool

    public init(
        id: AgentID,
        name: String,
        summary: String,
        capabilities: [AgentCapability],
        scope: GADAgentScopeProjection,
        evidence: [String],
        requiresMacReview: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.capabilities = capabilities
        self.scope = scope
        self.evidence = evidence
        self.requiresMacReview = requiresMacReview
    }
}

public struct GADCodexCatalogDiscovery: Codable, Equatable, Identifiable, Sendable {
    public let projects: [GADCodexProjectCandidateProjection]
    public let agents: [GADCodexAgentCandidateProjection]
    public let scannedProjectCount: Int
    public let scannedAgentCount: Int
    public let limitedProjectAccessCount: Int
    public let warnings: [String]
    public let expiresAt: Date
    public var id: Date { expiresAt }

    public init(
        projects: [GADCodexProjectCandidateProjection],
        agents: [GADCodexAgentCandidateProjection],
        scannedProjectCount: Int,
        scannedAgentCount: Int,
        limitedProjectAccessCount: Int,
        warnings: [String],
        expiresAt: Date
    ) {
        self.projects = projects
        self.agents = agents
        self.scannedProjectCount = scannedProjectCount
        self.scannedAgentCount = scannedAgentCount
        self.limitedProjectAccessCount = limitedProjectAccessCount
        self.warnings = warnings
        self.expiresAt = expiresAt
    }
}

public struct GADAgentImportCandidateProjection: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public let name: String
    public let summary: String
    public let instructions: String?
    public let capabilities: [AgentCapability]
    public let scope: GADAgentScopeProjection
    public let evidence: [String]
    public let canRestructure: Bool
    public let requiresMacReview: Bool
    public let reviewHash: String

    public init(
        id: AgentID,
        name: String,
        summary: String,
        instructions: String?,
        capabilities: [AgentCapability],
        scope: GADAgentScopeProjection,
        evidence: [String],
        canRestructure: Bool,
        requiresMacReview: Bool = false,
        reviewHash: String = ""
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.scope = scope
        self.evidence = evidence
        self.canRestructure = canRestructure
        self.requiresMacReview = requiresMacReview
        self.reviewHash = reviewHash
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, instructions, capabilities, scope, evidence, canRestructure, requiresMacReview, reviewHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AgentID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        capabilities = try container.decode([AgentCapability].self, forKey: .capabilities)
        scope = try container.decode(GADAgentScopeProjection.self, forKey: .scope)
        evidence = try container.decode([String].self, forKey: .evidence)
        canRestructure = try container.decode(Bool.self, forKey: .canRestructure)
        requiresMacReview = try container.decodeIfPresent(Bool.self, forKey: .requiresMacReview) ?? false
        reviewHash = try container.decodeIfPresent(String.self, forKey: .reviewHash) ?? ""
    }
}

public struct GADAgentImportSelection: Codable, Equatable, Sendable {
    public let agentID: AgentID
    public let reviewHash: String

    public init(agentID: AgentID, reviewHash: String) {
        self.agentID = agentID
        self.reviewHash = reviewHash
    }
}

public struct GADAgentCatalogDiscovery: Codable, Equatable, Identifiable, Sendable {
    public let candidates: [GADAgentImportCandidateProjection]
    public let totalCandidateCount: Int
    public let nextOffset: Int?
    public let expiresAt: Date
    public var id: Date { expiresAt }

    public init(
        candidates: [GADAgentImportCandidateProjection],
        totalCandidateCount: Int? = nil,
        nextOffset: Int? = nil,
        expiresAt: Date
    ) {
        self.candidates = candidates
        self.totalCandidateCount = totalCandidateCount ?? candidates.count
        self.nextOffset = nextOffset
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case candidates, totalCandidateCount, nextOffset, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decode([GADAgentImportCandidateProjection].self, forKey: .candidates)
        totalCandidateCount = try container.decodeIfPresent(Int.self, forKey: .totalCandidateCount)
            ?? candidates.count
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public struct GADNewProjectAgentIntent: Codable, Equatable, Sendable {
    public let name: String
    public let summary: String
    public let instructions: String?
    public let capabilities: [AgentCapability]
    public let providerIDs: [AgentProviderID]
    public let providerInstructions: [AgentProviderID: String]

    public init(
        name: String,
        summary: String,
        instructions: String? = nil,
        capabilities: [AgentCapability],
        providerIDs: [AgentProviderID] = [.codex],
        providerInstructions: [AgentProviderID: String] = [:]
    ) {
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.providerIDs = providerIDs
        self.providerInstructions = providerInstructions
    }
}

public struct GADNewProjectLinkIntent: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let groupName: String?
    public let projectRole: ProjectGroupRole
    public let linkedProjectRole: ProjectGroupRole

    public init(
        projectID: ProjectID,
        groupName: String? = nil,
        projectRole: ProjectGroupRole,
        linkedProjectRole: ProjectGroupRole = .service
    ) {
        self.projectID = projectID
        self.groupName = groupName
        self.projectRole = projectRole
        self.linkedProjectRole = linkedProjectRole
    }
}

public struct GADNewProjectHandoffIntent: Codable, Equatable, Sendable {
    public let sourceAgentIndex: Int
    public let sourceProviderID: AgentProviderID
    public let destinationAgentIndex: Int
    public let destinationProviderID: AgentProviderID
    public let purpose: String
    public let conditions: String
    public let acceptedArtifacts: [HandoffArtifactKind]
    public let maximumDepth: Int
    public let triggers: [HandoffTrigger]

    public init(
        sourceAgentIndex: Int,
        sourceProviderID: AgentProviderID,
        destinationAgentIndex: Int,
        destinationProviderID: AgentProviderID,
        purpose: String,
        conditions: String,
        acceptedArtifacts: [HandoffArtifactKind] = [.summary, .changedFileList, .verificationEvidence],
        maximumDepth: Int = 1,
        triggers: [HandoffTrigger] = [.success, .blockage, .checkpoint]
    ) {
        self.sourceAgentIndex = sourceAgentIndex
        self.sourceProviderID = sourceProviderID
        self.destinationAgentIndex = destinationAgentIndex
        self.destinationProviderID = destinationProviderID
        self.purpose = purpose
        self.conditions = conditions
        self.acceptedArtifacts = acceptedArtifacts
        self.maximumDepth = maximumDepth
        self.triggers = triggers
    }
}

public enum GADNewProjectSourceIntent: Codable, Equatable, Sendable {
    case blank
    case gitClone(repository: String)

    private enum Kind: String, Codable {
        case blank
        case gitClone
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case repository
    }

    public init(source: NewProjectSource) {
        switch source {
        case .blank:
            self = .blank
        case let .gitClone(repository):
            self = .gitClone(repository: repository)
        }
    }

    public var newProjectSource: NewProjectSource {
        switch self {
        case .blank:
            .blank
        case let .gitClone(repository):
            .gitClone(repository: repository)
        }
    }

    /// Remote project creation deliberately accepts a narrower source set than
    /// the trusted Mac picker. This prevents a paired client from turning the
    /// host into a local-file, SSH or private-network clone primitive.
    public func validatedRemoteSource() throws -> NewProjectSource {
        switch self {
        case .blank:
            return .blank
        case let .gitClone(repository):
            let candidate = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.utf8.count <= 2_048,
                  !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !candidate.contains("\\"),
                  let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  let host = components.host,
                  Self.approvedRemoteGitHosts.contains(host.lowercased()),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.url != nil else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "iPhone Git clone accepts only a credential-free HTTPS repository on a supported public Git host, without a query or fragment. Use the paired Mac for other hosts, local, file, SSH, or private-network sources."
                )
            }
            return .gitClone(repository: candidate)
        }
    }

    private static let approvedRemoteGitHosts: Set<String> = [
        "bitbucket.org",
        "codeberg.org",
        "dev.azure.com",
        "github.com",
        "gitlab.com",
        "git.sr.ht",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .blank {
        case .blank:
            self = .blank
        case .gitClone:
            self = .gitClone(repository: try container.decode(String.self, forKey: .repository))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blank:
            try container.encode(Kind.blank, forKey: .kind)
        case let .gitClone(repository):
            try container.encode(Kind.gitClone, forKey: .kind)
            try container.encode(repository, forKey: .repository)
        }
    }
}

public struct GADCreateProjectIntent: Codable, Equatable, Sendable {
    public let name: String
    public let directoryName: String
    public let parentLocationID: GADAuthorizedLocationID
    public let source: GADNewProjectSourceIntent
    public let platforms: [ProjectPlatform]
    public let providerIDs: [AgentProviderID]
    public let agents: [GADNewProjectAgentIntent]
    public let link: GADNewProjectLinkIntent?
    public let collaborateAcrossProviders: Bool
    public let handoffLinks: [GADNewProjectHandoffIntent]
    public let template: ProjectTemplateSelection?

    public init(
        name: String,
        directoryName: String,
        parentLocationID: GADAuthorizedLocationID,
        source: GADNewProjectSourceIntent = .blank,
        platforms: [ProjectPlatform],
        providerIDs: [AgentProviderID] = [.codex],
        agents: [GADNewProjectAgentIntent] = [],
        link: GADNewProjectLinkIntent? = nil,
        collaborateAcrossProviders: Bool = false,
        handoffLinks: [GADNewProjectHandoffIntent] = [],
        template: ProjectTemplateSelection? = nil
    ) {
        self.name = name
        self.directoryName = directoryName
        self.parentLocationID = parentLocationID
        self.source = source
        self.platforms = platforms
        self.providerIDs = providerIDs
        self.agents = agents
        self.link = link
        self.collaborateAcrossProviders = collaborateAcrossProviders
        self.handoffLinks = handoffLinks
        self.template = template
    }

    private enum CodingKeys: String, CodingKey {
        case name, directoryName, parentLocationID, source, platforms, providerIDs, agents, link
        case collaborateAcrossProviders, handoffLinks, template
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        directoryName = try container.decode(String.self, forKey: .directoryName)
        parentLocationID = try container.decode(GADAuthorizedLocationID.self, forKey: .parentLocationID)
        source = try container.decodeIfPresent(GADNewProjectSourceIntent.self, forKey: .source) ?? .blank
        platforms = try container.decode([ProjectPlatform].self, forKey: .platforms)
        providerIDs = try container.decodeIfPresent([AgentProviderID].self, forKey: .providerIDs) ?? [.codex]
        agents = try container.decodeIfPresent([GADNewProjectAgentIntent].self, forKey: .agents) ?? []
        link = try container.decodeIfPresent(GADNewProjectLinkIntent.self, forKey: .link)
        collaborateAcrossProviders = try container.decodeIfPresent(
            Bool.self,
            forKey: .collaborateAcrossProviders
        ) ?? false
        handoffLinks = try container.decodeIfPresent(
            [GADNewProjectHandoffIntent].self,
            forKey: .handoffLinks
        ) ?? []
        template = try container.decodeIfPresent(ProjectTemplateSelection.self, forKey: .template)
    }
}

public struct GADAgentMutationIntent: Codable, Equatable, Sendable {
    public let agentID: AgentID?
    public let projectID: ProjectID?
    public let scope: GADAgentScopeProjection
    public let name: String
    public let summary: String
    public let instructions: String?
    public let capabilities: [AgentCapability]
    public let toolPreset: AgentToolPreset?

    public init(
        agentID: AgentID?,
        projectID: ProjectID?,
        scope: GADAgentScopeProjection? = nil,
        name: String,
        summary: String,
        instructions: String?,
        capabilities: [AgentCapability],
        toolPreset: AgentToolPreset? = nil
    ) {
        self.agentID = agentID
        self.projectID = projectID
        self.scope = scope ?? projectID.map(GADAgentScopeProjection.project) ?? .global
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.toolPreset = toolPreset
    }

    private enum CodingKeys: String, CodingKey {
        case agentID, projectID, scope, name, summary, instructions, capabilities, toolPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decodeIfPresent(AgentID.self, forKey: .agentID)
        projectID = try container.decodeIfPresent(ProjectID.self, forKey: .projectID)
        scope = try container.decodeIfPresent(GADAgentScopeProjection.self, forKey: .scope)
            ?? projectID.map(GADAgentScopeProjection.project)
            ?? .global
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        capabilities = try container.decode([AgentCapability].self, forKey: .capabilities)
        toolPreset = try container.decodeIfPresent(AgentToolPreset.self, forKey: .toolPreset)
    }
}

public struct GADTemporaryAgentIntent: Codable, Equatable, Sendable {
    public let agentID: AgentID
    public let projectID: ProjectID
    public let providerID: AgentProviderID
    public let task: String

    public init(agentID: AgentID, projectID: ProjectID, providerID: AgentProviderID, task: String) {
        self.agentID = agentID
        self.projectID = projectID
        self.providerID = providerID
        self.task = task
    }
}

public struct GADAutomationMutation: Codable, Equatable, Sendable {
    public let automation: AutomationDefinition
    public let expectedRevision: Int?
    public let authorizationAssertion: String?

    public init(
        automation: AutomationDefinition,
        expectedRevision: Int?,
        authorizationAssertion: String? = nil
    ) {
        self.automation = automation
        self.expectedRevision = expectedRevision
        self.authorizationAssertion = authorizationAssertion
    }
}

public struct GADAutomationStateMutation: Codable, Equatable, Sendable {
    public let id: AutomationID
    public let expectedRevision: Int
    public let state: AutomationState

    public init(id: AutomationID, expectedRevision: Int, state: AutomationState) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.state = state
    }
}

public struct GADAutomationRunNowRequest: Codable, Equatable, Sendable {
    public let id: AutomationID
    public let expectedRevision: Int

    public init(id: AutomationID, expectedRevision: Int) {
        self.id = id
        self.expectedRevision = expectedRevision
    }
}

public struct GADAutomationOccurrenceReview: Codable, Equatable, Sendable {
    public let id: AutomationOccurrenceID
    public let reviewBinding: AutomationReviewBinding?
    public let authorizationAssertion: String?
    public let selectedResourceIDs: [SharedResourceID]

    public init(
        id: AutomationOccurrenceID,
        reviewBinding: AutomationReviewBinding?,
        authorizationAssertion: String?,
        selectedResourceIDs: [SharedResourceID] = []
    ) {
        self.id = id
        self.reviewBinding = reviewBinding
        self.authorizationAssertion = authorizationAssertion
        self.selectedResourceIDs = selectedResourceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, reviewBinding, authorizationAssertion, selectedResourceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AutomationOccurrenceID.self, forKey: .id)
        reviewBinding = try container.decodeIfPresent(AutomationReviewBinding.self, forKey: .reviewBinding)
        authorizationAssertion = try container.decodeIfPresent(
            String.self,
            forKey: .authorizationAssertion
        )
        selectedResourceIDs = try container.decodeIfPresent(
            [SharedResourceID].self,
            forKey: .selectedResourceIDs
        ) ?? []
    }
}

/// A short-lived, path-free view of one registered project's local branches.
/// Branch names are display/selection values only; execution remains behind a
/// reviewed Host-admin request and the host revalidates the repository.
public struct GADProjectBranchDiscovery: Codable, Equatable, Identifiable, Sendable {
    public let projectID: ProjectID
    public let currentBranch: String?
    public let localBranches: [String]
    public let hasUncommittedChanges: Bool
    public let expiresAt: Date

    public var id: ProjectID { projectID }

    public init(
        projectID: ProjectID,
        currentBranch: String?,
        localBranches: [String],
        hasUncommittedChanges: Bool,
        expiresAt: Date
    ) {
        self.projectID = projectID
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.hasUncommittedChanges = hasUncommittedChanges
        self.expiresAt = expiresAt
    }
}

public enum GADHostAdminRequest: Codable, Equatable, Sendable {
    case createProject(GADCreateProjectIntent)
    case removeProject(ProjectID)
    case syncCodexCatalog(projectIDs: [ProjectID], agentIDs: [AgentID])
    case importAgents([GADAgentImportSelection])
    case saveAgent(GADAgentMutationIntent)
    case createTemporaryAgent(GADTemporaryAgentIntent)
    case retireTemporaryAgent(AgentID)
    case addMissingAutomationAgents(AutomationAgentRecoveryPlan)
    case setAgentEnabled(agentID: AgentID, enabled: Bool)
    case publishAgent(AgentID)
    case deleteAgent(AgentID)
    case restoreLastDeletedAgent
    case restructureAgents([GADAgentImportSelection])
    case undoLastAgentRestructure
    case setResourceAccess(resourceID: SharedResourceID, access: SharedResourceAccess, enabled: Bool)
    case switchProjectBranch(ProjectGitBranchSwitchApproval)
    case exportRedactedDiagnostics
}

public struct GADHostAdminCommit: Codable, Equatable, Sendable {
    public let previewID: String
    public let previewHash: String
    public let authorizationAssertion: String?

    public init(previewID: String, previewHash: String, authorizationAssertion: String?) {
        self.previewID = previewID
        self.previewHash = previewHash
        self.authorizationAssertion = authorizationAssertion
    }
}

public enum GADRememberedApprovalOperation: Codable, Equatable, Sendable {
    case list
    case revoke(UUID)
    case setProjectEnabled(ProjectID, Bool)
}

public enum GADCommandPayload: Codable, Equatable, Sendable {
    case replaceDraft(GADDraftReplacement)
    case beginPromptAttachmentUpload(GADPromptAttachmentUploadStart)
    case appendPromptAttachmentUpload(GADPromptAttachmentUploadChunk)
    case commitPromptAttachmentUpload(UUID)
    case cancelPromptAttachmentUpload(UUID)
    case preparePlan
    case updatePlan(GADPlanUpdate)
    case cancelPlan(RunID)
    case startRun(GADPlanApproval)
    case controlRun(GADRunControl)
    case rememberedApprovals(GADRememberedApprovalOperation)
    case requestApprovalDisclosure(String)
    case respondToApproval(GADApprovalResponse)
    case reuseRequest(RunID)
    case followUp(GADFollowUp)
    /// Protocol 3.12. Sent only to hosts whose session supports temporary chat.
    case askTemporaryChat(GADTemporaryChatQuestion)
    case endTemporaryChat(TemporaryChatID)
    case refreshProviders([AgentProviderID])
    /// Protocol 3.9: task polling without account or system-health inspection.
    case refreshProviderActivity([AgentProviderID])
    case dispatchManualHandoff(GADManualHandoffRequest)
    /// Legacy v1 command retained while cached clients migrate.
    case refreshCodex
    case saveProjectGroup(GADProjectGroupMutation)
    /// Lets a project start isolated worktree edits without review, or not.
    /// Accepted only from the Mac's own dashboard.
    case setProjectTrust(GADProjectTrustMutation)
    case deleteProjectGroup(ProjectGroupID)
    case requestInstructionEditor(InstructionPackID)
    case saveInstruction(GADInstructionMutation)
    case requestProviderBindingInstructionEditor(ProviderAgentBindingID)
    case saveProviderBindingInstructions(GADProviderBindingInstructionMutation)
    case requestCodexCatalogDiscovery
    case requestAgentCatalogDiscovery(offset: Int)
    case requestProjectGitBranches(ProjectID)
    case requestHostAdminPreview(GADHostAdminRequest)
    case commitHostAdmin(GADHostAdminCommit)
    case updateNotificationRegistration(GADNotificationRegistration?)
    case saveAutomation(GADAutomationMutation)
    case setAutomationState(GADAutomationStateMutation)
    case deleteAutomation(AutomationID, expectedRevision: Int)
    /// Legacy ID-only command. Hosts reject it so an old cached row cannot
    /// authorize the current, unseen definition.
    case runAutomationNow(AutomationID)
    case runAutomationNowChecked(GADAutomationRunNowRequest)
    case reviewAndRunAutomationOccurrence(GADAutomationOccurrenceReview)
    case cancelAutomationOccurrence(AutomationOccurrenceID)
    /// Permanently revokes the sending device after its signed command is
    /// durably accepted by the authoritative Mac host.
    case revokeCurrentDevice

    var requiresExactBaseRevision: Bool {
        switch self {
        case .replaceDraft, .beginPromptAttachmentUpload, .appendPromptAttachmentUpload,
             .commitPromptAttachmentUpload, .cancelPromptAttachmentUpload,
             .controlRun, .rememberedApprovals, .requestApprovalDisclosure, .requestInstructionEditor,
             .requestProviderBindingInstructionEditor,
             .requestCodexCatalogDiscovery,
             .requestAgentCatalogDiscovery,
             .requestProjectGitBranches,
             .requestHostAdminPreview, .commitHostAdmin,
             .respondToApproval, .refreshProviders, .refreshProviderActivity, .refreshCodex,
             .askTemporaryChat, .endTemporaryChat,
             .updateNotificationRegistration, .revokeCurrentDevice, .setProjectTrust:
            false
        case .preparePlan, .updatePlan, .cancelPlan, .startRun, .reuseRequest, .followUp, .saveProjectGroup,
             .dispatchManualHandoff, .deleteProjectGroup,
             .saveInstruction, .saveProviderBindingInstructions,
             .saveAutomation, .setAutomationState, .deleteAutomation, .runAutomationNow,
             .runAutomationNowChecked,
             .reviewAndRunAutomationOccurrence, .cancelAutomationOccurrence:
            true
        }
    }
}

public struct GADProjectTrustMutation: Codable, Equatable, Sendable {
    /// Nil applies `trusted` to every project (used to revoke all trust).
    public let projectID: ProjectID?
    public let trusted: Bool

    public init(projectID: ProjectID?, trusted: Bool) {
        self.projectID = projectID
        self.trusted = trusted
    }
}

public struct GADCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: CommandID
    public let idempotencyKey: String
    public let hostEpoch: HostEpoch
    public let deviceID: DeviceID
    public let baseRevision: StateRevision
    public let issuedAt: Date
    public let expiresAt: Date
    public let payload: GADCommandPayload

    public init(
        id: CommandID = .make(),
        idempotencyKey: String,
        hostEpoch: HostEpoch,
        deviceID: DeviceID,
        baseRevision: StateRevision,
        issuedAt: Date,
        expiresAt: Date,
        payload: GADCommandPayload
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.hostEpoch = hostEpoch
        self.deviceID = deviceID
        self.baseRevision = baseRevision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.payload = payload
    }
}

public struct GADHostAdminEffect: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let isDestructive: Bool

    public init(id: String, title: String, detail: String, isDestructive: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isDestructive = isDestructive
    }
}

public struct GADHostAdminPreview: Codable, Equatable, Sendable {
    public let id: String
    public let hash: String
    public let expiresAt: Date
    public let requiresLocalAuthentication: Bool
    public let effects: [GADHostAdminEffect]

    public init(id: String, hash: String, expiresAt: Date, requiresLocalAuthentication: Bool, effects: [GADHostAdminEffect]) {
        self.id = id
        self.hash = hash
        self.expiresAt = expiresAt
        self.requiresLocalAuthentication = requiresLocalAuthentication
        self.effects = effects
    }
}

public struct GADOperationReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let summary: String
    public let isUndoAvailable: Bool

    public init(id: String, summary: String, isUndoAvailable: Bool) {
        self.id = id
        self.summary = summary
        self.isUndoAvailable = isUndoAvailable
    }
}

public struct GADApprovalDisclosure: Codable, Equatable, Sendable {
    public let approvalID: String
    /// Opaque digest binding the canonical request to `summary` and `details`.
    /// A paired client echoes it only after presenting those exact bytes.
    public let requestDigest: String?
    public let summary: String
    public let details: String?
    public let expiresAt: Date
    public let rememberedCommandScope: RememberedCommandScope?
    public let rememberedFileChangeScope: RememberedFileChangeScope?

    public init(
        approvalID: String,
        requestDigest: String? = nil,
        summary: String,
        details: String?,
        expiresAt: Date,
        rememberedCommandScope: RememberedCommandScope? = nil,
        rememberedFileChangeScope: RememberedFileChangeScope? = nil
    ) {
        self.approvalID = approvalID
        self.requestDigest = requestDigest
        self.summary = summary
        self.details = details
        self.expiresAt = expiresAt
        self.rememberedCommandScope = rememberedCommandScope
        self.rememberedFileChangeScope = rememberedFileChangeScope
    }
}

public enum GADCommandArtifact: Codable, Equatable, Sendable {
    case rememberedApprovals([RememberedCommandApproval])
    case approvalDisclosure(GADApprovalDisclosure)
    case instructionEditor(GADInstructionEditor)
    case providerBindingInstructionEditor(GADProviderBindingInstructionEditor)
    case codexCatalogDiscovery(GADCodexCatalogDiscovery)
    case agentCatalogDiscovery(GADAgentCatalogDiscovery)
    case projectGitBranches(GADProjectBranchDiscovery)
    case hostAdminPreview(GADHostAdminPreview)
    case operationReceipt(GADOperationReceipt)
    case redactedDiagnostics(Data)
}

public enum GADCommandDisposition: String, Codable, Sendable {
    case accepted
    case rejectedStale
    case rejectedPolicy
    case rejectedCapability
    case rejectedExpired
    case rejectedRevoked
    case failedRecoverable
    case failedIndeterminate
}

public struct GADCommandAcknowledgement: Codable, Equatable, Sendable {
    public let commandID: CommandID
    public let disposition: GADCommandDisposition
    public let revision: StateRevision
    public let message: String?
    public let artifact: GADCommandArtifact?
    /// Set only before admission/reservation. Missing on older hosts; never
    /// infer retry safety from human-readable messages or failedRecoverable.
    public let wasDeferredBeforeAdmission: Bool?

    public init(
        commandID: CommandID,
        disposition: GADCommandDisposition,
        revision: StateRevision,
        message: String? = nil,
        artifact: GADCommandArtifact? = nil,
        wasDeferredBeforeAdmission: Bool? = nil
    ) {
        self.commandID = commandID
        self.disposition = disposition
        self.revision = revision
        self.message = message
        self.artifact = artifact
        self.wasDeferredBeforeAdmission = wasDeferredBeforeAdmission
    }
}

public struct GADStateDelta: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let hostEpoch: HostEpoch
    public let revision: StateRevision
    public let occurredAt: Date
    public let originatingCommandID: CommandID?
    public let changes: [GADStateChange]
    public let isResyncSnapshot: Bool

    public init(
        id: UUID = UUID(),
        hostEpoch: HostEpoch,
        revision: StateRevision,
        occurredAt: Date,
        originatingCommandID: CommandID?,
        changes: [GADStateChange],
        isResyncSnapshot: Bool = false
    ) {
        self.id = id
        self.hostEpoch = hostEpoch
        self.revision = revision
        self.occurredAt = occurredAt
        self.originatingCommandID = originatingCommandID
        self.changes = changes
        self.isResyncSnapshot = isResyncSnapshot
    }
}

public protocol GobyClient: Sendable {
    func connect() async throws -> ClientSession
    func snapshot() async throws -> DashboardProjection
    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement
    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta>
    func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent>
    func disconnect() async
}

public enum GobyClientLifecycleEvent: Equatable, Sendable {
    case revoked
    case incompatible
    case transportLost
}

public extension GobyClient {
    func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

public enum GobyClientLocalError: LocalizedError, Equatable, Sendable {
    case localAuthenticationCancelled
    case localAuthenticationUnavailable

    public var errorDescription: String? {
        switch self {
        case .localAuthenticationCancelled:
            "Authentication was cancelled. No change was made."
        case .localAuthenticationUnavailable:
            "Goby could not produce a device-bound authorization proof. Re-pair this device and try again."
        }
    }
}

public protocol GADProjectionCaching: Sendable {
    func load() async throws -> DashboardProjection?
    func save(_ projection: DashboardProjection) async throws
    func clear() async throws
}

/// Stores only an unsent device-local draft. Implementations must protect it
/// at least as strongly as the offline projection and erase it after sync,
/// revocation, unpairing, or reset.
public protocol GADLocalDraftCaching: Sendable {
    func loadLocalDraft() async throws -> String?
    func saveLocalDraft(_ text: String?) async throws
}
