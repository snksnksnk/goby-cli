import CryptoKit
import Foundation
import GobyDomain

public protocol LabCatalogRepository: Sendable {
    func snapshot() async throws -> LabSnapshot
    func register(projects: [LabProject], agents: [AgentProfile]) async throws
}

public protocol ProjectCatalogManaging: Sendable {
    /// Removes only Goby's catalog registration. Implementations must not
    /// delete the project directory or its Codex agent definition files.
    func removeProject(id: ProjectID) async throws
}

public struct ProjectDirectoryPlacement: Equatable, Sendable {
    public let rootURL: URL
    public let fileSystemIdentity: GADFileSystemIdentity

    public init(rootURL: URL, fileSystemIdentity: GADFileSystemIdentity) {
        self.rootURL = rootURL
        self.fileSystemIdentity = fileSystemIdentity
    }

    public func matchesCurrentObject() -> Bool {
        fileSystemIdentity.matchesCurrentObject(at: rootURL)
    }
}

public protocol ProjectDirectoryCreating: Sendable {
    func createProjectDirectory(
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) async throws -> ProjectDirectoryPlacement
    func cloneProjectRepository(
        from repository: String,
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) async throws -> ProjectDirectoryPlacement
    func removeProjectDirectoryIfEmpty(_ placement: ProjectDirectoryPlacement) async throws
}

public struct ProjectTemplateArtifact: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let relativePath: String
    public let digest: String
    public let isDirectory: Bool

    public var id: String { relativePath }

    public init(relativePath: String, digest: String, isDirectory: Bool = false) {
        self.relativePath = relativePath
        self.digest = digest
        self.isDirectory = isDirectory
    }
}

public struct ProjectTemplatePlan: Codable, Equatable, Sendable {
    public let descriptor: ProjectTemplateDescriptor
    public let selection: ProjectTemplateSelection
    public let artifacts: [ProjectTemplateArtifact]
    public let frameworks: [String]
    public let testCommands: [String]
    public let instructionRelativePaths: [String]

    public init(
        descriptor: ProjectTemplateDescriptor,
        selection: ProjectTemplateSelection,
        artifacts: [ProjectTemplateArtifact],
        frameworks: [String],
        testCommands: [String],
        instructionRelativePaths: [String]
    ) {
        self.descriptor = descriptor
        self.selection = selection
        self.artifacts = artifacts
        self.frameworks = frameworks
        self.testCommands = testCommands
        self.instructionRelativePaths = instructionRelativePaths
    }
}

public struct ProjectTemplateInstantiationReceipt: Equatable, Sendable {
    public let placement: ProjectDirectoryPlacement
    public let plan: ProjectTemplatePlan

    public init(placement: ProjectDirectoryPlacement, plan: ProjectTemplatePlan) {
        self.placement = placement
        self.plan = plan
    }
}

public enum ProjectTemplateRollbackResult: Equatable, Sendable {
    case removed
    case preservedChanges(relativePaths: [String])
}

public protocol ProjectTemplateInstantiating: Sendable {
    func preview(
        selection: ProjectTemplateSelection,
        projectName: String
    ) async throws -> ProjectTemplatePlan

    func instantiate(
        selection: ProjectTemplateSelection,
        projectName: String,
        directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) async throws -> ProjectTemplateInstantiationReceipt

    func rollback(
        _ receipt: ProjectTemplateInstantiationReceipt
    ) async throws -> ProjectTemplateRollbackResult
}

public protocol ProjectGroupCatalogManaging: Sendable {
    func saveProjectGroup(_ group: ProjectGroup) async throws
    /// Unlinks the logical product without unregistering member projects.
    func removeProjectGroup(id: ProjectGroupID) async throws
}

public protocol ProviderConfigurationCatalogManaging: Sendable {
    func saveProjectProviderConfiguration(_ configuration: ProjectProviderConfiguration) async throws
    func removeProjectProviderConfiguration(projectID: ProjectID) async throws
    func saveProviderBinding(_ binding: ProviderAgentBinding) async throws
    func removeProviderBinding(id: ProviderAgentBindingID) async throws
    func saveProviderCollaborationSet(_ collaborationSet: ProviderCollaborationSet) async throws
    func removeProviderCollaborationSet(id: ProviderCollaborationSetID) async throws
}

public protocol HandoffCatalogManaging: Sendable {
    func saveHandoffLink(_ link: AgentHandoffLink) async throws
    func removeHandoffLink(id: AgentHandoffLinkID) async throws
    func saveHandoff(_ handoff: HandoffRecord) async throws
}

/// Which of a provider's credential slots a secret occupies. Claude keeps a
/// Pro/Max subscription token beside an API key; other providers use `.apiKey`.
public enum ProviderCredentialKind: String, Codable, CaseIterable, Sendable {
    /// An API key or provider token billed to API credits.
    case apiKey
    /// A Claude Pro/Max OAuth token from `claude setup-token` (`sk-ant-oat…`).
    case subscriptionToken

    public static func isClaudeSubscriptionToken(_ credential: String) -> Bool {
        credential.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-ant-oat")
    }
}

/// Stores provider secrets outside project/catalog persistence. Implementations
/// must never include credential values in diagnostics or user-visible state.
public protocol ProviderCredentialRepository: Sendable {
    func credential(for providerID: AgentProviderID, kind: ProviderCredentialKind) async throws -> String?
    func saveCredential(
        _ credential: String,
        for providerID: AgentProviderID,
        kind: ProviderCredentialKind
    ) async throws
    func removeCredential(for providerID: AgentProviderID, kind: ProviderCredentialKind) async throws
}

public extension ProviderCredentialRepository {
    func credential(for providerID: AgentProviderID) async throws -> String? {
        try await credential(for: providerID, kind: .apiKey)
    }

    func saveCredential(_ credential: String, for providerID: AgentProviderID) async throws {
        try await saveCredential(credential, for: providerID, kind: .apiKey)
    }

    func removeCredential(for providerID: AgentProviderID) async throws {
        try await removeCredential(for: providerID, kind: .apiKey)
    }
}

public protocol ProjectDiscovering: Sendable {
    func discover(selectedRoots: [URL]) async throws -> [ProjectCandidate]
}

/// Booted iOS Simulators and running Android emulators on this Mac, for live
/// run previews. Read-only, and used only by the foreground app.
public protocol RunPreviewDeviceDiscovering: Sendable {
    func runningDevices() async -> [RunPreviewDevice]
}

public protocol AgentDiscovering: Sendable {
    func discover(projects: [LabProject]) async throws -> AgentImportPlan
}

public protocol AgentDefinitionRestructuring: Sendable {
    func preview(candidates: [AgentImportCandidate]) async throws -> [AgentDefinitionChangePreview]
    func apply(_ changes: [AgentDefinitionChangePreview]) async throws
    func undo(_ changes: [AgentDefinitionChangePreview]) async throws
}

public protocol AgentRestructureHistoryRepository: Sendable {
    func lastAgentRestructure() async throws -> [AgentDefinitionChangePreview]
    func saveLastAgentRestructure(_ changes: [AgentDefinitionChangePreview]) async throws
}

public protocol Routing: Sendable {
    func plan(for request: RouteRequest, in lab: LabSnapshot) async throws -> RoutingPlan
}

public protocol RunRepository: Sendable {
    func allRuns() async throws -> [RunRecord]
    func save(_ run: RunRecord) async throws
}

public protocol AutomationRepository: Sendable {
    func automationSnapshot() async throws -> AutomationSnapshot
    /// Atomically creates or replaces a definition only when its current value
    /// still matches the caller's reviewed predecessor. `nil` means create.
    func saveAutomation(
        _ automation: AutomationDefinition,
        replacing expected: AutomationDefinition?
    ) async throws
    func removeAutomation(
        id: AutomationID,
        replacing expected: AutomationDefinition
    ) async throws
    /// Atomically creates or replaces an occurrence. Exact predecessor
    /// matching prevents actor reentrancy from replaying an ordered action.
    func saveAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        replacing expected: AutomationOccurrence?
    ) async throws
    /// Atomically advances the reviewed definition and creates its one queued
    /// occurrence. This prevents either a lost scheduled slot or an overlapping
    /// manual run when persistence or another caller intervenes between writes.
    func claimAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        advancing automation: AutomationDefinition,
        replacing expectedAutomation: AutomationDefinition
    ) async throws
}

/// Supplies the digest already bound into authenticated automation state.
/// Callers use it to ensure planning and staging observe the same project,
/// agent, provider-binding, and instruction authority.
public protocol AutomationExecutionAuthorityProviding: Sendable {
    func automationExecutionAuthorityDigest() async throws -> Data
}

public protocol AutomationCoordinating: Sendable {
    func start() async
    func stop() async
    func tick(at date: Date) async
    func runNow(
        automationID: AutomationID,
        expectedRevision: Int,
        at date: Date
    ) async throws -> AutomationOccurrence
    func reviewAndRun(
        occurrenceID: AutomationOccurrenceID,
        reviewBinding: AutomationReviewBinding,
        receipt: ApprovalReceipt?,
        selectedResourceIDs: Set<SharedResourceID>
    ) async throws
    func cancel(occurrenceID: AutomationOccurrenceID) async throws
    func updates() async -> AsyncStream<AutomationSnapshot>
}

public protocol InstructionRepository: Sendable {
    func allInstructionPacks() async throws -> [InstructionPack]
    func save(_ pack: InstructionPack) async throws
}

public protocol AgentCatalogManaging: Sendable {
    func saveAgent(_ agent: AgentProfile) async throws
    func setAgentEnabled(id: AgentID, enabled: Bool) async throws
    func removeAgent(id: AgentID) async throws
    func replaceAgent(id: AgentID, with agent: AgentProfile) async throws
}

public protocol CodexAgentDefinitionManaging: Sendable {
    func createDefinition(
        from draft: AgentDefinitionDraft,
        projectRootURL: URL?,
        expectedProjectIdentity: GADFileSystemIdentity?
    ) async throws -> AgentProfile
    func activateDefinition(
        for agent: AgentProfile,
        projectRootURL: URL?
    ) async throws -> AgentDefinitionActivationResult
    func undoActivatedDefinition(_ agent: AgentProfile) async throws
    func undoCreatedDefinition(
        _ agent: AgentProfile,
        expectedProjectIdentity: GADFileSystemIdentity?
    ) async throws
    func archiveDefinition(
        for agent: AgentProfile,
        projectRootURL: URL?
    ) async throws -> DeletedAgentRecord
    func restoreDefinition(from record: DeletedAgentRecord) async throws
    func undoRestoredDefinition(from record: DeletedAgentRecord) async throws
}

public extension CodexAgentDefinitionManaging {
    func createDefinition(
        from draft: AgentDefinitionDraft,
        projectRootURL: URL?
    ) async throws -> AgentProfile {
        try await createDefinition(
            from: draft,
            projectRootURL: projectRootURL,
            expectedProjectIdentity: nil
        )
    }

    func undoCreatedDefinition(_ agent: AgentProfile) async throws {
        try await undoCreatedDefinition(agent, expectedProjectIdentity: nil)
    }
}

public protocol DeletedAgentHistoryRepository: Sendable {
    func lastDeletedAgent() async throws -> DeletedAgentRecord?
    func saveLastDeletedAgent(_ record: DeletedAgentRecord?) async throws
}

public protocol SharedResourceRepository: Sendable {
    func allResources() async throws -> [SharedResource]
    func saveResource(_ resource: SharedResource) async throws
    func setResourceEnabled(id: SharedResourceID, enabled: Bool) async throws
}

public protocol GraphLayoutProviding: Sendable {
    func layout(
        lab: LabSnapshot,
        assignments: [AgentAssignment],
        codexTasks: [CodexTaskActivity]
    ) async -> GraphLayoutSnapshot
}

public protocol MapLayoutRepository: Sendable {
    func loadMapLayout() async throws -> MapLayoutOverrides
    func saveMapLayout(_ layout: MapLayoutOverrides) async throws
}

public struct CodexAccountSnapshot: Codable, Equatable, Sendable {
    public let authenticated: Bool
    public let displayName: String?
    public let planName: String?
    public let selectedModel: String?
    public let availableModels: [String]
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let primaryWindowDurationMinutes: Double?
    public let secondaryUsedPercent: Double?
    public let secondaryResetsAt: Date?
    public let secondaryWindowDurationMinutes: Double?

    public init(
        authenticated: Bool,
        displayName: String?,
        planName: String?,
        selectedModel: String? = nil,
        availableModels: [String] = [],
        usedPercent: Double?,
        resetsAt: Date? = nil,
        primaryWindowDurationMinutes: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        secondaryResetsAt: Date? = nil,
        secondaryWindowDurationMinutes: Double? = nil
    ) {
        self.authenticated = authenticated
        self.displayName = displayName
        self.planName = planName
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.primaryWindowDurationMinutes = primaryWindowDurationMinutes
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetsAt = secondaryResetsAt
        self.secondaryWindowDurationMinutes = secondaryWindowDurationMinutes
    }
}

public enum CodexCommandExecutionStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case declined
    case unknown
}

public struct CodexCommandExecutionEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let command: String
    public let actionCommands: [String]
    public let workingDirectory: URL
    public let status: CodexCommandExecutionStatus
    public let exitCode: Int?
    public let durationMilliseconds: Int?
    public let source: String

    public init(
        id: String,
        command: String,
        actionCommands: [String] = [],
        workingDirectory: URL,
        status: CodexCommandExecutionStatus,
        exitCode: Int?,
        durationMilliseconds: Int? = nil,
        source: String = "agent"
    ) {
        self.id = id
        self.command = command
        self.actionCommands = actionCommands
        self.workingDirectory = workingDirectory
        self.status = status
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
        self.source = source
    }
}

public enum CodexRunEvent: Sendable, Equatable {
    case assignmentStarted(AssignmentID)
    case progress(AssignmentID, fraction: Double?, message: String)
    case approvalRequired(CodexApprovalRequest)
    case commandExecutionCompleted(AssignmentID, evidence: CodexCommandExecutionEvidence)
    case helperUpdated(AssignmentID, activity: CodexTaskActivity)
    /// A typed step for the run thread (command, file change, message…).
    case activity(AssignmentID, step: RunActivityStep)
    case assignmentCompleted(AssignmentID, outcome: String)
    case assignmentFailed(AssignmentID, message: String)
}

public enum CodexApprovalKind: String, Codable, Hashable, Sendable {
    case command
    case fileChange
    case permissions
}

public struct ApprovalSessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> ApprovalSessionID {
        ApprovalSessionID(rawValue: UUID().uuidString.lowercased())
    }
}

public struct CodexApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let assignmentID: AssignmentID
    public let kind: CodexApprovalKind
    public let summary: String
    public let details: String?
    public let canAccept: Bool
    public let approvalSessionID: ApprovalSessionID?
    /// SHA-256 of the complete canonical operation shown to the user.
    public let operationDigest: String?
    /// False when the adapter could not capture every executable field.
    public let disclosureComplete: Bool

    public init(
        id: String,
        assignmentID: AssignmentID,
        kind: CodexApprovalKind,
        summary: String,
        details: String? = nil,
        canAccept: Bool = true,
        approvalSessionID: ApprovalSessionID? = nil,
        operationDigest: String? = nil,
        disclosureComplete: Bool = false
    ) {
        self.id = id
        self.assignmentID = assignmentID
        self.kind = kind
        self.summary = summary
        self.details = details
        self.canAccept = canAccept
        self.approvalSessionID = approvalSessionID
        self.operationDigest = operationDigest
        self.disclosureComplete = disclosureComplete
    }

    private enum CodingKeys: String, CodingKey {
        case id, assignmentID, kind, summary, details, canAccept
        case approvalSessionID, operationDigest, disclosureComplete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        assignmentID = try container.decode(AssignmentID.self, forKey: .assignmentID)
        kind = try container.decode(CodexApprovalKind.self, forKey: .kind)
        summary = try container.decode(String.self, forKey: .summary)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        canAccept = try container.decodeIfPresent(Bool.self, forKey: .canAccept) ?? true
        approvalSessionID = try container.decodeIfPresent(ApprovalSessionID.self, forKey: .approvalSessionID)
        operationDigest = try container.decodeIfPresent(String.self, forKey: .operationDigest)
        disclosureComplete = try container.decodeIfPresent(Bool.self, forKey: .disclosureComplete) ?? false
    }
}

public enum CodexApprovalDecision: String, Codable, Sendable {
    case accept
    case acceptForSession
    case acceptAllForRun
    case decline
    case cancel
}

public struct CodexExecutionHandle: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String

    public init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct CodexSavedProjectReference: Equatable, Sendable {
    public let name: String
    public let rootURL: URL

    public init(name: String, rootURL: URL) {
        self.name = name
        self.rootURL = rootURL
    }
}

public struct CodexProjectRootsSnapshot: Equatable, Sendable {
    public let roots: [URL]
    public let savedProjects: [CodexSavedProjectReference]
    public let tasks: [CodexTaskActivity]
    public let warnings: [String]

    public init(
        roots: [URL],
        savedProjects: [CodexSavedProjectReference] = [],
        tasks: [CodexTaskActivity] = [],
        warnings: [String] = []
    ) {
        self.roots = roots
        self.savedProjects = savedProjects
        self.tasks = tasks
        self.warnings = warnings
    }
}

public protocol CodexServing: Sendable {
    func connectionState() async -> CodexConnectionState
    func connect() async throws -> CodexConnectionState
    func accountSnapshot() async throws -> CodexAccountSnapshot
    func recentProjectRoots() async throws -> CodexProjectRootsSnapshot
    func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery?
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) async throws -> CodexExecutionHandle
    func interrupt(assignmentID: AssignmentID) async throws
    func steer(assignmentID: AssignmentID, text: String) async throws
    func respond(to approvalID: String, decision: CodexApprovalDecision) async throws
    func respond(
        to approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) async throws
    func events() async -> AsyncStream<CodexRunEvent>
}

public extension CodexServing {
    func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery? {
        nil
    }

    func steer(assignmentID: AssignmentID, text: String) async throws {
        throw ProviderRuntimeCapabilityError.unsupported(
            providerID: .codex,
            capability: .activeSteering
        )
    }

    func respond(
        to approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) async throws {
        switch decision {
        case .accept, .acceptForSession, .acceptAllForRun:
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        case .decline, .cancel:
            try await respond(to: approvalID, decision: decision)
        }
    }
}

public struct ProviderCommandExecutionEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: AgentProviderID
    public let command: String
    public let actionCommands: [String]
    public let workingDirectory: URL
    public let status: CodexCommandExecutionStatus
    public let exitCode: Int?
    public let durationMilliseconds: Int?
    public let source: String

    public init(
        id: String,
        providerID: AgentProviderID = .codex,
        command: String,
        actionCommands: [String] = [],
        workingDirectory: URL,
        status: CodexCommandExecutionStatus,
        exitCode: Int?,
        durationMilliseconds: Int? = nil,
        source: String = "agent"
    ) {
        self.id = id
        self.providerID = providerID
        self.command = command
        self.actionCommands = actionCommands
        self.workingDirectory = workingDirectory
        self.status = status
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
        self.source = source
    }
}

public enum ProviderApprovalDecision: String, Codable, Sendable {
    case accept
    case acceptAlways
    case acceptForSession
    case acceptAllForRun
    case decline
    case cancel
}

/// Goby's provider-neutral identity for one pending runtime approval.
///
/// Provider-native request IDs are only unique inside their own runtime. The
/// provider and assignment are therefore part of every in-process lookup and
/// presentation identity so one provider can never replace another provider's
/// pending decision.
public struct ProviderApprovalIdentity: Codable, Equatable, Hashable, Sendable {
    public let providerID: AgentProviderID
    public let assignmentID: AssignmentID
    public let providerRequestID: String

    public init(
        providerID: AgentProviderID,
        assignmentID: AssignmentID,
        providerRequestID: String
    ) {
        self.providerID = providerID
        self.assignmentID = assignmentID
        self.providerRequestID = providerRequestID
    }

    /// A bounded, versioned value suitable for SwiftUI and continuity
    /// projections. The hashed material is length-prefixed so provider input
    /// cannot create delimiter ambiguity or leak a native request identifier.
    public var routingID: String {
        let provider = providerID.rawValue
        let assignment = assignmentID.rawValue
        let material = "\(provider.utf8.count):\(provider)\(assignment.utf8.count):\(assignment)\(providerRequestID.utf8.count):\(providerRequestID)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "approval-v1-\(digest)"
    }
}

public struct ProviderApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: AgentProviderID
    public let assignmentID: AssignmentID
    public let kind: CodexApprovalKind
    public let summary: String
    public let details: String?
    public let canAccept: Bool
    public let approvalSessionID: ApprovalSessionID?
    /// SHA-256 of the helper's complete canonical operation JSON.
    public let operationDigest: String?
    /// False when any executable field could not be represented in `details`.
    public let disclosureComplete: Bool
    /// True only when `summary` and `details` already contain the reversible,
    /// perceptible bytes produced by `ApprovalDisplayPolicy` on the host.
    public let displayTextIsExactVisible: Bool
    public let rememberedCommandScope: RememberedCommandScope?
    public let rememberedFileChangeScope: RememberedFileChangeScope?

    public init(
        id: String,
        providerID: AgentProviderID = .codex,
        assignmentID: AssignmentID,
        kind: CodexApprovalKind,
        summary: String,
        details: String? = nil,
        canAccept: Bool = true,
        approvalSessionID: ApprovalSessionID? = nil,
        operationDigest: String? = nil,
        disclosureComplete: Bool = true,
        displayTextIsExactVisible: Bool = false,
        rememberedCommandScope: RememberedCommandScope? = nil,
        rememberedFileChangeScope: RememberedFileChangeScope? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.assignmentID = assignmentID
        self.kind = kind
        self.summary = summary
        self.details = details
        self.canAccept = canAccept
        self.approvalSessionID = approvalSessionID
        self.operationDigest = operationDigest
        self.disclosureComplete = disclosureComplete
        self.displayTextIsExactVisible = displayTextIsExactVisible
        self.rememberedCommandScope = rememberedCommandScope
        self.rememberedFileChangeScope = rememberedFileChangeScope
    }

    /// Adds a host-derived folder offer without changing the exact patch binding.
    public func offeringFileChanges(_ scope: RememberedFileChangeScope?) -> Self {
        Self(id: id, providerID: providerID, assignmentID: assignmentID, kind: kind,
             summary: summary, details: details, canAccept: canAccept,
             approvalSessionID: approvalSessionID, operationDigest: operationDigest,
             disclosureComplete: disclosureComplete, displayTextIsExactVisible: displayTextIsExactVisible,
             rememberedCommandScope: rememberedCommandScope, rememberedFileChangeScope: scope)
    }

    public var hasRememberedScopeOffer: Bool {
        switch kind {
        case .command: rememberedCommandScope != nil && rememberedFileChangeScope == nil
        case .fileChange: rememberedCommandScope == nil && rememberedFileChangeScope?.policyVersion == 1
        case .permissions: false
        }
    }

    public var hasCompleteOperationBinding: Bool {
        guard disclosureComplete,
              let operationDigest,
              operationDigest.count == 64 else { return false }
        return operationDigest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    public var identity: ProviderApprovalIdentity {
        ProviderApprovalIdentity(
            providerID: providerID,
            assignmentID: assignmentID,
            providerRequestID: id
        )
    }

    public var routingID: String { identity.routingID }

    public var visibleSummary: String {
        displayTextIsExactVisible ? summary : ApprovalDisplayPolicy.exactVisibleText(summary)
    }

    public var visibleDetails: String? {
        details.map {
            displayTextIsExactVisible ? $0 : ApprovalDisplayPolicy.exactVisibleText($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, assignmentID, kind, summary, details, canAccept
        case approvalSessionID, operationDigest, disclosureComplete, displayTextIsExactVisible
        case rememberedCommandScope, rememberedFileChangeScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decodeIfPresent(AgentProviderID.self, forKey: .providerID) ?? .codex
        assignmentID = try container.decode(AssignmentID.self, forKey: .assignmentID)
        kind = try container.decode(CodexApprovalKind.self, forKey: .kind)
        summary = try container.decode(String.self, forKey: .summary)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        canAccept = try container.decodeIfPresent(Bool.self, forKey: .canAccept) ?? true
        approvalSessionID = try container.decodeIfPresent(
            ApprovalSessionID.self,
            forKey: .approvalSessionID
        )
        operationDigest = try container.decodeIfPresent(String.self, forKey: .operationDigest)
        disclosureComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .disclosureComplete
        ) ?? false
        rememberedCommandScope = try container.decodeIfPresent(RememberedCommandScope.self, forKey: .rememberedCommandScope)
        rememberedFileChangeScope = try container.decodeIfPresent(RememberedFileChangeScope.self, forKey: .rememberedFileChangeScope)
        displayTextIsExactVisible = try container.decodeIfPresent(
            Bool.self,
            forKey: .displayTextIsExactVisible
        ) ?? false
    }
}

public struct ProviderExecutionHandle: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let taskID: String
    public let turnID: String?

    public init(providerID: AgentProviderID, taskID: String, turnID: String? = nil) {
        self.providerID = providerID
        self.taskID = taskID
        self.turnID = turnID
    }
}

/// A provider's authoritative view of a previously started assignment.
/// Recovery never starts a replacement task: adapters either rebind the
/// existing provider task to Goby's event stream or return nil.
public struct ProviderExecutionRecovery: Equatable, Sendable {
    public let handle: ProviderExecutionHandle
    public let status: ProviderTaskStatus
    public let progress: Double?
    public let message: String?
    public let outcome: String?
    public let evidence: [ProviderCommandExecutionEvidence]

    public init(
        handle: ProviderExecutionHandle,
        status: ProviderTaskStatus,
        progress: Double? = nil,
        message: String? = nil,
        outcome: String? = nil,
        evidence: [ProviderCommandExecutionEvidence] = []
    ) {
        self.handle = handle
        self.status = status
        self.progress = progress.map { min(max($0, 0), 1) }
        self.message = message
        self.outcome = outcome
        self.evidence = evidence
    }
}

public enum ProviderRunEvent: Sendable, Equatable {
    case assignmentStarted(AgentProviderID, AssignmentID)
    case progress(AgentProviderID, AssignmentID, fraction: Double?, message: String)
    case approvalRequired(ProviderApprovalRequest)
    case commandExecutionCompleted(AssignmentID, evidence: ProviderCommandExecutionEvidence)
    case helperUpdated(AssignmentID, activity: ProviderTaskActivity)
    /// A typed step for the run thread (command, file change, message…).
    case activity(AgentProviderID, AssignmentID, step: RunActivityStep)
    case assignmentCompleted(AgentProviderID, AssignmentID, outcome: String)
    case assignmentFailed(AgentProviderID, AssignmentID, message: String)
}

/// Provider-neutral execution boundary. Adapters must report unsupported
/// capabilities honestly instead of approximating another provider's API.
public protocol AgentRuntimeServing: Sendable {
    var providerID: AgentProviderID { get }
    func capabilities() async -> ProviderCapabilities
    func connectionState() async -> ProviderConnectionState
    func connect() async throws -> ProviderConnectionState
    func accountSnapshot() async throws -> ProviderAccountSnapshot
    func recentTasks(projects: [LabProject]) async throws -> [ProviderTaskActivity]
    func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery?
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) async throws -> ProviderExecutionHandle
    func interrupt(assignmentID: AssignmentID) async throws
    func steer(assignmentID: AssignmentID, text: String) async throws
    func respond(to approvalID: String, decision: ProviderApprovalDecision) async throws
    func respond(
        to approvalID: String,
        decision: ProviderApprovalDecision,
        operationDigest: String?
    ) async throws
    func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws
    func events() async -> AsyncStream<ProviderRunEvent>
    func disconnect() async
}

public extension AgentRuntimeServing {
    /// Adapters without a durable helper process may use the default no-op.
    func disconnect() async {}

    /// Returning nil is deliberately conservative. A task-discovery result is
    /// not enough to claim that live events, interruption, and completion have
    /// been rebound to this assignment after relaunch.
    func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery? {
        nil
    }

    func steer(assignmentID: AssignmentID, text: String) async throws {
        throw ProviderRuntimeCapabilityError.unsupported(
            providerID: providerID,
            capability: .activeSteering
        )
    }

    func respond(
        to approvalID: String,
        decision: ProviderApprovalDecision,
        operationDigest: String?
    ) async throws {
        switch decision {
        case .accept, .acceptAlways, .acceptForSession, .acceptAllForRun:
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        case .decline, .cancel:
            try await respond(to: approvalID, decision: decision)
        }
    }

    func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws {
        guard approval.providerID == providerID else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        try await respond(
            to: approval.id,
            decision: decision,
            operationDigest: approval.operationDigest
        )
    }
}

public enum ProviderApprovalBindingError: LocalizedError, Equatable, Sendable {
    case missingOrChangedOperationDigest
    case duplicatePendingApproval

    public var errorDescription: String? {
        switch self {
        case .missingOrChangedOperationDigest:
            "The exact provider operation changed or is no longer available. Review the current request again."
        case .duplicatePendingApproval:
            "The provider reused an identifier for a different pending approval. Both requests were declined."
        }
    }
}

public enum ProviderRuntimeCapabilityError: LocalizedError, Equatable, Sendable {
    case unsupported(providerID: AgentProviderID, capability: ProviderCapability)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(providerID, capability):
            "\(providerID.displayName) does not support \(capability.displayName.lowercased()) for this run."
        }
    }
}

public protocol AgentRuntimeResolving: Sendable {
    func providerIDs() async -> [AgentProviderID]
    func runtime(for providerID: AgentProviderID) async -> (any AgentRuntimeServing)?
}

public protocol ApprovalChecking: Sendable {
    func validate(plan: RoutingPlan, receipt: ApprovalReceipt?) async throws
}

public protocol WorkspacePreparing: Sendable {
    func prepare(project: LabProject, for run: RunRecord) async throws -> ProjectDirectoryPlacement
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) async throws -> String?
    /// `commitMessage` is the agent's message for a commit in the project
    /// folder; other commits keep Goby's own message.
    func finalize(
        project: LabProject, workingDirectory: URL, for run: RunRecord, commitMessage: String?
    ) async throws -> String?
    func releaseRepositoryLocks(for runID: RunID) async
}

extension WorkspacePreparing {
    public func releaseRepositoryLocks(for runID: RunID) async {}
    public func finalize(
        project: LabProject, workingDirectory: URL, for run: RunRecord, commitMessage: String?
    ) async throws -> String? {
        try await finalize(project: project, workingDirectory: workingDirectory, for: run)
    }
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let summary: String

    public init(succeeded: Bool, summary: String) {
        self.succeeded = succeeded
        self.summary = summary
    }
}

public protocol VerificationRunning: Sendable {
    func verify(
        project: LabProject,
        workingDirectory: URL,
        evidence: [ProviderCommandExecutionEvidence]
    ) async -> VerificationResult
}

public protocol RunOrchestrating: Sendable {
    func recoverInterruptedRuns() async throws -> [RunRecord]
    func execute(runID: RunID) async throws
    func pause(runID: RunID) async throws
    func resume(runID: RunID) async throws
    func resume(runID: RunID, modelChange: RunModelChange) async throws
    func cancel(runID: RunID) async throws
    func startWithoutWaiting(runID: RunID) async throws
    func followUp(runID: RunID, text: String) async throws
    func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws
    func pendingApprovals() async -> [ProviderApprovalRequest]
    func canRememberCommand(_ request: ProviderApprovalRequest) async -> Bool
    func rememberedCommandApprovals() async throws -> [RememberedCommandApproval]
    func revokeRememberedCommandApproval(_ id: UUID) async throws
    func setRememberedApprovalProjectEnabled(_ projectID: ProjectID, enabled: Bool) async throws
    func updates() async -> AsyncStream<RunRecord>
}

public extension RunOrchestrating {
    /// Starts a run that is waiting for a conflicting request in the same
    /// project. Orchestrators without request scheduling have nothing to do.
    func startWithoutWaiting(runID: RunID) async throws {}
}

public extension RunOrchestrating {
    func canRememberCommand(_ request: ProviderApprovalRequest) async -> Bool { false }
    func rememberedCommandApprovals() async throws -> [RememberedCommandApproval] { [] }
    func revokeRememberedCommandApproval(_ id: UUID) async throws {
        throw RememberedCommandApprovalError.unavailable
    }
    func setRememberedApprovalProjectEnabled(_ projectID: ProjectID, enabled: Bool) async throws {
        throw RememberedCommandApprovalError.unavailable
    }

    func recoverInterruptedRuns() async throws -> [RunRecord] { [] }

    func resume(runID: RunID, modelChange: RunModelChange) async throws {
        throw GobyApplicationError.invalidRunModelChange("This host does not support changing a run's model.")
    }
}

public protocol SystemHealthChecking: Sendable {
    func check(projects: [LabProject]) async -> SystemHealthSnapshot
}

public protocol RunNotifying: Sendable {
    func notify(for run: RunRecord) async
}

/// Delivers a status-only alert after an automation action has durably stopped
/// before provider execution and now requires an explicit user decision.
public protocol AutomationNotifying: Sendable {
    func notify(for occurrence: AutomationOccurrence) async
}

public protocol DiagnosticExporting: Sendable {
    func report(lab: LabSnapshot, runs: [RunRecord], health: SystemHealthSnapshot) async throws -> String
}
