import Foundation

public struct AgentHandoffEndpoint: Codable, Hashable, Sendable {
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

public enum HandoffMode: String, Codable, CaseIterable, Hashable, Sendable {
    case suggestOnly
    case automaticWhenApproved

    public var displayName: String {
        switch self {
        case .suggestOnly: "Suggest only"
        case .automaticWhenApproved: "Automatic when included in the approved plan"
        }
    }
}

public enum HandoffTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case blockage
    case failure
    case checkpoint

    public var displayName: String {
        switch self {
        case .success: "After success"
        case .blockage: "When blocked"
        case .failure: "After failure"
        case .checkpoint: "At a requested checkpoint"
        }
    }
}

public enum HandoffArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case summary
    case patch
    case changedFileList
    case verificationEvidence
    case researchNotes
    case reviewFindings

    public var displayName: String {
        switch self {
        case .summary: "Summary"
        case .patch: "Patch"
        case .changedFileList: "Changed-file list"
        case .verificationEvidence: "Verification evidence"
        case .researchNotes: "Research notes"
        case .reviewFindings: "Review findings"
        }
    }
}

/// A reviewed directional path between two exact provider bindings. A link is
/// eligibility to propose a continuation, not authority to execute it.
public struct AgentHandoffLink: Codable, Hashable, Identifiable, Sendable {
    public let id: AgentHandoffLinkID
    public let source: AgentHandoffEndpoint
    public let destination: AgentHandoffEndpoint
    public let purpose: String
    public let conditions: String
    public let mode: HandoffMode
    public let acceptedArtifacts: Set<HandoffArtifactKind>
    public let maximumDepth: Int
    public let triggers: Set<HandoffTrigger>
    public let isEnabled: Bool
    public let createdAt: Date

    public init(
        id: AgentHandoffLinkID = .make(),
        source: AgentHandoffEndpoint,
        destination: AgentHandoffEndpoint,
        purpose: String,
        conditions: String,
        mode: HandoffMode = .suggestOnly,
        acceptedArtifacts: Set<HandoffArtifactKind> = [.summary, .changedFileList, .verificationEvidence],
        maximumDepth: Int = 1,
        triggers: Set<HandoffTrigger> = [.success, .blockage, .checkpoint],
        isEnabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.purpose = purpose
        self.conditions = conditions
        self.mode = mode
        self.acceptedArtifacts = acceptedArtifacts
        self.maximumDepth = maximumDepth
        self.triggers = triggers
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct HandoffArtifactReference: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: HandoffArtifactKind
    public let name: String
    public let url: URL?
    public let contentHash: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: HandoffArtifactKind,
        name: String,
        url: URL? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.contentHash = contentHash
    }
}

public struct HandoffVerificationEvidence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let command: String
    public let status: String
    public let exitCode: Int?
    public let source: String

    public init(
        id: String,
        command: String,
        status: String,
        exitCode: Int?,
        source: String
    ) {
        self.id = id
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.source = source
    }
}

public struct HandoffResourceDescriptor: Codable, Hashable, Sendable {
    public let name: String
    public let capability: String

    public init(name: String, capability: String) {
        self.name = name
        self.capability = capability
    }
}

/// Provider-neutral continuation data. The destination receives this bundle,
/// never a provider credential, approval receipt, hidden prompt, or transcript.
public struct HandoffBundle: Codable, Hashable, Identifiable, Sendable {
    public let id: HandoffID
    public let idempotencyKey: String
    public let runID: RunID
    public let linkID: AgentHandoffLinkID
    public let createdAt: Date
    public let source: AgentHandoffEndpoint
    public let destination: AgentHandoffEndpoint
    public let originalGoal: String
    public let purpose: String
    public let sourceOutcomeSummary: String
    public let sourceTrigger: HandoffTrigger
    public let completedSteps: [String]
    public let unresolvedWork: [String]
    public let knownRisks: [String]
    public let requestedNextAction: String
    public let artifacts: [HandoffArtifactReference]
    public let changedFiles: [String]
    public let patchOrCommitReference: String?
    public let workingCopyIdentity: String?
    public let verificationEvidence: [HandoffVerificationEvidence]
    public let resources: [HandoffResourceDescriptor]
    public let sourceAssignmentID: AssignmentID?
    public let sourceTaskIdentity: ProviderTaskIdentity?
    public let parentHandoffID: HandoffID?
    public let depth: Int
    public let integrityHash: String

    public init(
        id: HandoffID = .make(),
        idempotencyKey: String,
        runID: RunID,
        linkID: AgentHandoffLinkID,
        createdAt: Date = .now,
        source: AgentHandoffEndpoint,
        destination: AgentHandoffEndpoint,
        originalGoal: String,
        purpose: String,
        sourceOutcomeSummary: String,
        sourceTrigger: HandoffTrigger,
        completedSteps: [String] = [],
        unresolvedWork: [String] = [],
        knownRisks: [String] = [],
        requestedNextAction: String,
        artifacts: [HandoffArtifactReference] = [],
        changedFiles: [String] = [],
        patchOrCommitReference: String? = nil,
        workingCopyIdentity: String? = nil,
        verificationEvidence: [HandoffVerificationEvidence] = [],
        resources: [HandoffResourceDescriptor] = [],
        sourceAssignmentID: AssignmentID? = nil,
        sourceTaskIdentity: ProviderTaskIdentity? = nil,
        parentHandoffID: HandoffID? = nil,
        depth: Int = 1,
        integrityHash: String
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.runID = runID
        self.linkID = linkID
        self.createdAt = createdAt
        self.source = source
        self.destination = destination
        self.originalGoal = originalGoal
        self.purpose = purpose
        self.sourceOutcomeSummary = sourceOutcomeSummary
        self.sourceTrigger = sourceTrigger
        self.completedSteps = completedSteps
        self.unresolvedWork = unresolvedWork
        self.knownRisks = knownRisks
        self.requestedNextAction = requestedNextAction
        self.artifacts = artifacts
        self.changedFiles = changedFiles
        self.patchOrCommitReference = patchOrCommitReference
        self.workingCopyIdentity = workingCopyIdentity
        self.verificationEvidence = verificationEvidence
        self.resources = resources
        self.sourceAssignmentID = sourceAssignmentID
        self.sourceTaskIdentity = sourceTaskIdentity
        self.parentHandoffID = parentHandoffID
        self.depth = depth
        self.integrityHash = integrityHash
    }
}

public enum HandoffState: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case awaitingApproval
    case ready
    case queued
    case working
    case completed
    case needsAttention
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .proposed: "Proposed"
        case .awaitingApproval: "Awaiting approval"
        case .ready: "Ready"
        case .queued: "Queued"
        case .working: "Working"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

public struct HandoffRecord: Codable, Hashable, Identifiable, Sendable {
    public let bundle: HandoffBundle
    public let state: HandoffState
    /// The isolated run created for the destination continuation. Legacy
    /// records are nil because older builds appended the destination to the
    /// source run.
    public let destinationRunID: RunID?
    public let destinationAssignmentID: AssignmentID?
    public let destinationTaskIdentity: ProviderTaskIdentity?
    public let attemptCount: Int
    public let statusReason: String?
    public let updatedAt: Date

    public var id: HandoffID { bundle.id }

    public init(
        bundle: HandoffBundle,
        state: HandoffState,
        destinationRunID: RunID? = nil,
        destinationAssignmentID: AssignmentID? = nil,
        destinationTaskIdentity: ProviderTaskIdentity? = nil,
        attemptCount: Int = 0,
        statusReason: String? = nil,
        updatedAt: Date = .now
    ) {
        self.bundle = bundle
        self.state = state
        self.destinationRunID = destinationRunID
        self.destinationAssignmentID = destinationAssignmentID
        self.destinationTaskIdentity = destinationTaskIdentity
        self.attemptCount = attemptCount
        self.statusReason = statusReason
        self.updatedAt = updatedAt
    }
}
