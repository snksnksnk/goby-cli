import Darwin
import Foundation
import GobyApplication
import GobyDomain
import GobyExperience
import Observation

public enum AppDestination: String, CaseIterable, Hashable, Sendable {
    case home
    case runs
    case automations
    case projects
    case agents
    case instructions
    case settings

    public var title: String {
        switch self {
        case .home: "Home"
        case .runs: "Runs"
        case .automations: "Automations"
        case .projects: "Projects"
        case .agents: "Agents"
        case .instructions: "Instructions"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "sparkles"
        case .runs: "list.bullet.rectangle"
        case .automations: "calendar"
        case .projects: "square.stack.3d.up"
        case .agents: "person.2.badge.gearshape"
        case .instructions: "text.book.closed"
        case .settings: "gearshape"
        }
    }
}

public struct PendingRunControl: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pause
        case resume
        case cancel
    }

    public let action: Action
    public let statusBeforeRequest: RunStatus
    public let requestedAt: Date

    public init(action: Action, statusBeforeRequest: RunStatus, requestedAt: Date = .now) {
        self.action = action
        self.statusBeforeRequest = statusBeforeRequest
        self.requestedAt = requestedAt
    }
}

public enum DashboardViewMode: String, CaseIterable, Sendable {
    case overview = "Overview"
    case map = "Map"
    case list = "List"
}

public enum PromptScope: String, CaseIterable, Sendable {
    case all = "Automatic"
    case web = "Web"
    case macOS = "macOS"
    case iOS = "iOS"
    case android = "Android"
    case research = "Research"

    var routeScope: RouteScope {
        switch self {
        case .all: .all
        case .web: .platform(.web)
        case .macOS: .platform(.macOS)
        case .iOS: .platform(.iOS)
        case .android: .platform(.android)
        case .research: .platform(.research)
        }
    }
}

public struct AgentCreationSuggestion: Identifiable, Equatable, Sendable {
    public let projectID: ProjectID
    public let projectName: String
    public let providerID: AgentProviderID
    public let requiredCapabilities: Set<AgentCapability>

    public var id: ProjectID { projectID }

    public var message: String {
        GobyApplicationError.noAppropriateAgent(
            projectID: projectID,
            projectName: projectName,
            providerID: providerID,
            capabilities: requiredCapabilities
        ).localizedDescription
    }
}

@MainActor
public protocol GADDesktopHostAdministrating: AnyObject {
    func localCatalogSnapshot() async throws -> GADHostLocalCatalogSnapshot
    func localRunSnapshot(runID: RunID) async throws -> RunRecord
    func discoverProjects(at urls: [URL]) async throws -> [ProjectCandidate]
    func registerProjects(at urls: [URL], selectedProjectIDs: Set<ProjectID>) async throws
    func registerResources(at urls: [URL]) async throws
    func createProject(_ draft: NewProjectDraft) async throws
    func inspectProjectGitBranches(projectID: ProjectID) async throws -> ProjectGitBranchSnapshot
    func switchProjectGitBranch(
        approval: ProjectGitBranchSwitchApproval
    ) async throws -> ProjectGitBranchSnapshot
    func saveProviderCredential(
        _ credential: String,
        providerID: AgentProviderID,
        kind: ProviderCredentialKind
    ) async throws
    func removeProviderCredential(providerID: AgentProviderID, kind: ProviderCredentialKind) async throws
    /// Reads the shared Keychain this signed UI writes; never the value itself.
    func providerCredentialConfigured(providerID: AgentProviderID, kind: ProviderCredentialKind) async -> Bool
}

@MainActor
@Observable
public final class AppStore {
    public var destination: AppDestination = .home
    /// Live previews beside the run thread (Mac only).
    public let runPreview = RunPreviewStore()
    /// The project Runs is limited to; nil shows every project.
    public var runsProjectFilter: ProjectID?
    public var prompt = "" {
        didSet {
            if prompt != oldValue { agentCreationSuggestion = nil }
            notifyStateDidChange()
        }
    }
    public private(set) var promptAttachments: [PromptAttachment] = [] {
        didSet { notifyStateDidChange() }
    }
    public var promptScope: PromptScope = .all {
        didSet { notifyStateDidChange() }
    }
    public private(set) var promptProjectGroupID: ProjectGroupID?
    public private(set) var promptProjectIDs: Set<ProjectID> = []
    public private(set) var promptAgentTargets: Set<AgentRouteTarget> = []
    public private(set) var quickTaskProjectID: ProjectID?
    private var quickTaskAgentID: AgentID?
    private var quickTaskAgentTask: String?
    /// Temporary agents created so a multi-project request can cover every
    /// project without asking. They retire when the plan is cancelled or the
    /// run ends.
    private var scopeTemporaryAgentIDs: [AgentID] = []
    private var isCreatingQuickTaskAgent = false
    public var dashboardViewMode: DashboardViewMode = .map
    public private(set) var selectedProviderID = AgentProviderID.codex
    /// Explicit model override for the current provider plane. `nil` means the
    /// provider's configured default remains authoritative.
    public private(set) var promptModelID: String?
    public private(set) var availableProviderIDs: Set<AgentProviderID> = [.codex]
    public private(set) var lab: LabSnapshot = .empty {
        didSet { operationsSnapshotCache = nil }
    }
    public private(set) var runs: [RunRecord] = [] {
        didSet { operationsSnapshotCache = nil }
    }
    public private(set) var omittedRunHistoryCount = 0
    public private(set) var omittedAutomationHistoryCount = 0
    public private(set) var pendingRunControls: [RunID: PendingRunControl] = [:]
    public private(set) var automationSnapshot: AutomationSnapshot = .empty
    public private(set) var graph: GraphLayoutSnapshot = .empty
    public private(set) var mapLayoutOverrides: MapLayoutOverrides = .empty
    public private(set) var codexState: CodexConnectionState = .notChecked
    public private(set) var codexAccount: CodexAccountSnapshot?
    /// The Claude API key slot, which takes over when the subscription runs out.
    public private(set) var claudeCredentialConfigured = false
    /// The Claude Pro/Max subscription token slot, used by default.
    public private(set) var claudeSubscriptionConfigured = false
    public private(set) var copilotCredentialConfigured = false
    public private(set) var codexTasks: [CodexTaskActivity] = [] {
        didSet { operationsSnapshotCache = nil }
    }
    public private(set) var providerAccounts: [ProviderAccountSnapshot] = []
    public private(set) var providerTasks: [ProviderTaskActivity] = []
    public private(set) var codexActivityRefresh = CodexActivityRefresh.unavailable(since: .now) {
        didSet { operationsSnapshotCache = nil }
    }
    /// Projects the user lets start isolated-worktree edits without a review
    /// click. Local to this Mac, off by default, and revocable at any time.
    public private(set) var trustedProjectIDs: Set<ProjectID> = []
    private let localDefaults: UserDefaults
    private static let trustedProjectsKey = "GobyTrustedProjectIDs"

    /// The host owns trust, so every paired device follows it. A connected
    /// dashboard asks the host; the host itself stores it.
    public func setProjectTrusted(_ projectID: ProjectID, trusted: Bool) {
        if let continuityStore {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.acceptClientAcknowledgement(
                    await continuityStore.setProjectTrust(projectID, trusted: trusted),
                    successNotice: nil
                )
            }
            return
        }
        if trusted { trustedProjectIDs.insert(projectID) } else { trustedProjectIDs.remove(projectID) }
        persistTrustedProjects()
        notifyStateDidChange()
    }

    /// One switch that returns every project to asking first.
    public func revokeAllProjectTrust() {
        if let continuityStore {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.acceptClientAcknowledgement(
                    await continuityStore.setProjectTrust(nil, trusted: false),
                    successNotice: "Every project asks for review again."
                )
            }
            return
        }
        trustedProjectIDs = []
        persistTrustedProjects()
        notifyStateDidChange()
    }

    /// Host side: whether the prepared plan may start without review on any
    /// device. Clients read the result from the projection.
    public var proposedPlanStartsWithoutReview: Bool {
        guard let plan = proposedPlan else { return false }
        return TrustedStartPolicy.allows(
            plan: plan,
            trustedProjectIDs: trustedProjectIDs,
            lab: lab,
            hasSelectedResources: !selectedRunResourceIDs.isEmpty,
            hasBlockingReadinessIssue: readinessIssues(for: plan).contains(where: \.blocksAutomaticStart)
        ) && scopeTemporaryAgentIDs.isEmpty && quickTaskProjectID == nil
    }

    private func persistTrustedProjects() {
        localDefaults.set(trustedProjectIDs.map(\.rawValue).sorted(), forKey: Self.trustedProjectsKey)
    }

    // MARK: Activity read state

    /// When this device last showed each run's activity to the user. Local to
    /// this device like Notification Center; the host keeps no read state.
    public private(set) var activityReadState = ActivityReadState(baseline: .now)
    /// Failed and finished runs last changed before this time are cleared
    /// from the Activity panel. They stay in Runs.
    public private(set) var activityClearedAt: Date? {
        didSet { operationsSnapshotCache = nil }
    }
    private static let activityReadMarksKey = "GobyActivityReadMarks"
    private static let activityClearedAtKey = "GobyActivityClearedAt"
    private static let activityReadBaselineKey = "GobyActivityReadBaseline"

    /// Whether a run changed since the user last saw it. An open
    /// conversation is being read, so its run is not unread.
    public func isActivityUnread(_ run: RunRecord) -> Bool {
        activeThread != .run(run.id) && activityReadState.isUnread(run)
    }

    /// Unread notifications in the Activity panel: changed results plus
    /// approvals, which stay until answered.
    public var unreadActivityCount: Int {
        let snapshot = operationsSnapshot
        return snapshot.pendingApprovalCount
            + (snapshot.attentionRuns + snapshot.recentRuns).filter(isActivityUnread).count
    }

    public func markActivityRead(_ runID: RunID) {
        guard let run = runs.first(where: { $0.id == runID }),
              activityReadState.markRead(run) else { return }
        persistActivityReadState()
    }

    public func markAllActivityRead() {
        let snapshot = operationsSnapshot
        var changed = false
        for run in snapshot.attentionRuns + snapshot.recentRuns + snapshot.approvalRuns {
            changed = activityReadState.markRead(run) || changed
        }
        if changed { persistActivityReadState() }
    }

    /// Clears failed and finished runs from the Activity panel. Runs waiting
    /// on a decision and pending approvals stay until resolved.
    public func clearActivity() {
        markAllActivityRead()
        let now = Date()
        activityClearedAt = now
        localDefaults.set(now.timeIntervalSinceReferenceDate, forKey: Self.activityClearedAtKey)
    }

    private func persistActivityReadState() {
        activityReadState.retain(Set(runs.map(\.id)))
        let encoded = Dictionary(uniqueKeysWithValues: activityReadState.marks.map {
            ($0.key.rawValue, $0.value.timeIntervalSinceReferenceDate)
        })
        localDefaults.set(encoded, forKey: Self.activityReadMarksKey)
    }

    private static func loadActivityReadState(defaults: UserDefaults) -> ActivityReadState {
        var baseline = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: activityReadBaselineKey))
        if baseline.timeIntervalSinceReferenceDate <= 0 {
            baseline = Date()
            defaults.set(baseline.timeIntervalSinceReferenceDate, forKey: activityReadBaselineKey)
        }
        let stored = defaults.dictionary(forKey: activityReadMarksKey) as? [String: Double] ?? [:]
        return ActivityReadState(
            marks: Dictionary(uniqueKeysWithValues: stored.map {
                (RunID(rawValue: $0.key), Date(timeIntervalSinceReferenceDate: $0.value))
            }),
            baseline: baseline
        )
    }

    public private(set) var pendingApprovals: [ProviderApprovalRequest] = [] {
        didSet { operationsSnapshotCache = nil }
    }
    /// Sorting every run is the cost of an activity summary, so it is built once
    /// per change to its inputs instead of on every read.
    @ObservationIgnored private var operationsSnapshotCache: OperationsCenterSnapshot?
    private var remoteApprovalDisclosures: [String: RemoteApprovalDisclosure] = [:]
    @ObservationIgnored private var approvalDisclosureTasks: [String: (id: UUID, task: Task<ProviderApprovalRequest, Never>)] = [:]
    public private(set) var systemHealth = SystemHealthSnapshot(checks: [])
    public private(set) var limitedProjectAccessCount = 0
    public private(set) var instructionPacks: [InstructionPack] = []
    public private(set) var projectGitBranches: [ProjectID: ProjectGitBranchSnapshot] = [:]
    public private(set) var projectGitBranchUnavailableIDs: Set<ProjectID> = []
    /// Why the last branch check failed, for the map's Retry action.
    public private(set) var projectGitBranchFailureReasons: [ProjectID: String] = [:]
    public private(set) var projectGitBranchBusyIDs: Set<ProjectID> = []
    public var selectedRunID: RunID?
    private var selectedRunHistorySnapshot: RunRecord?
    public private(set) var selectedRunGraph: GraphLayoutSnapshot = .empty
    public private(set) var diagnosticReport: String?
    public private(set) var sharedResources: [SharedResource] = []
    public private(set) var selectedRunResourceIDs = Set<SharedResourceID>()
    public var showsResourceImporter = false
    public var showsProjectImporter = false
    public var showsCommandPalette = false
    public var showsOnboarding = false
    public var opensAutomationEditorFromPrompt = false
    public private(set) var proposedPlan: RoutingPlan? {
        didSet { if oldValue?.id != proposedPlan?.id { allowsPlanPush = false } }
    }
    /// The plan's separate push approval. Off for every new plan; a start
    /// without it removes the plan's push steps.
    public var allowsPlanPush = false
    /// A follow-up plan whose conversation last ran uninterrupted, so its
    /// review starts with Run uninterrupted already chosen.
    public private(set) var uninterruptedDefaultPlanID: RunID?
    /// Runs this device started uninterrupted, so a follow-up keeps that
    /// choice. Local, like the switch itself.
    private var uninterruptedRunIDs: [RunID] = []
    private static let uninterruptedRunIDsKey = "GobyUninterruptedRunIDs"

    private func rememberUninterruptedRun(_ runID: RunID) {
        guard !uninterruptedRunIDs.contains(runID) else { return }
        uninterruptedRunIDs = Array((uninterruptedRunIDs + [runID]).suffix(200))
        localDefaults.set(uninterruptedRunIDs.map(\.rawValue), forKey: Self.uninterruptedRunIDsKey)
    }
    public private(set) var agentCreationSuggestion: AgentCreationSuggestion?
    /// The request shown as a conversation on Home: its message while it is
    /// being planned, then the run it became. Nil shows the map or list.
    public private(set) var activeThread: ConversationThread? {
        didSet {
            // Whatever changed while the conversation was open has been seen.
            if case .run(let runID) = oldValue, oldValue != activeThread { markActivityRead(runID) }
        }
    }
    /// The host's temporary chat: quick questions outside any project. It is
    /// never persisted; see `TemporaryChatServing`.
    public private(set) var temporaryChat: TemporaryChat?
    public private(set) var isAskingTemporaryChat = false
    @ObservationIgnored private let temporaryChatService: (any TemporaryChatServing)?
    @ObservationIgnored private var temporaryChatObservation: Task<Void, Never>?
    /// Opens the full plan review sheet over an active thread ("Edit scope").
    public var showsFullPlanReview = false
    public private(set) var importCandidates: [ProjectCandidate] = []
    public var selectedImportIDs = Set<ProjectID>()
    public private(set) var isRegisteringProjects = false
    public private(set) var projectImportError: String?
    public var selectedProjectImportIsRefresh: Bool {
        !selectedImportIDs.isEmpty
            && selectedImportIDs.isSubset(of: Set(lab.projects.map(\.id)))
    }
    public private(set) var codexSyncPlan: CodexCatalogSyncPlan?
    public private(set) var selectedCodexProjectIDs = Set<ProjectID>()
    public private(set) var selectedCodexAgentIDs = Set<AgentID>()
    public private(set) var agentImportPlan: AgentImportPlan?
    public private(set) var agentRestructurePreviews: [AgentDefinitionChangePreview] = []
    public private(set) var lastAppliedAgentRestructure: [AgentDefinitionChangePreview] = []
    public private(set) var lastDeletedAgent: DeletedAgentRecord?
    public var restorableAgentName: String? {
        continuityStore == nil ? lastDeletedAgent?.agent.name : localCatalogSnapshot?.lastDeletedAgentName
    }
    public var selectedAgentImportIDs = Set<AgentID>()
    public private(set) var isBusy = false
    public private(set) var isCancellingPlan = false
    public var isRefreshingProviderStatus: Bool { providerRefreshCount > 0 }
    private var providerRefreshCount = 0
    public private(set) var errorMessage: String?
    public private(set) var notice: String? {
        didSet { noticeRevision &+= 1 }
    }
    public private(set) var noticeRevision = 0

    private let promptAttachmentDirectoryURL: URL?
    private let loadDashboard: LoadDashboardUseCase!
    private let discoverProjects: DiscoverProjectsUseCase!
    private let discoverCodexCatalogSync: DiscoverCodexCatalogSyncUseCase!
    private let discoverCodexActivity: DiscoverCodexActivityUseCase!
    private let syncCodexCatalog: SyncCodexCatalogUseCase!
    private let registerProjects: RegisterProjectsUseCase!
    private let createProjectUseCase: CreateProjectUseCase!
    private let removeProjectUseCase: RemoveProjectUseCase!
    private let saveProjectGroupUseCase: SaveProjectGroupUseCase!
    private let removeProjectGroupUseCase: RemoveProjectGroupUseCase!
    private let inspectProjectGitBranchesUseCase: InspectProjectGitBranchesUseCase?
    private let switchProjectGitBranchUseCase: SwitchProjectGitBranchUseCase?
    private let preparePlan: PrepareRoutingPlanUseCase!
    private let stageRun: StageRunUseCase!
    private let buildGraph: BuildGraphUseCase!
    private let loadMapLayoutUseCase: LoadMapLayoutUseCase!
    private let saveMapLayoutUseCase: SaveMapLayoutUseCase!
    private let inspectCodex: InspectCodexUseCase!
    private let discoverAgents: DiscoverAgentsUseCase!
    private let registerAgents: RegisterAgentsUseCase!
    private let previewAgentRestructure: PreviewAgentRestructureUseCase!
    private let applyAgentRestructure: ApplyAgentRestructureUseCase!
    private let undoAgentRestructure: UndoAgentRestructureUseCase!
    private let loadAgentRestructureHistory: LoadAgentRestructureHistoryUseCase!
    private let saveAgentRestructureHistory: SaveAgentRestructureHistoryUseCase!
    private let executeRun: ExecuteRunUseCase!
    private let controlRun: ControlRunUseCase!
    private let followUpRun: FollowUpRunUseCase!
    private let observeRuns: ObserveRunsUseCase!
    private let manageApproval: ManageProviderApprovalUseCase!
    private let recoverInterruptedRuns: RecoverInterruptedRunsUseCase!
    private let checkSystemHealth: CheckSystemHealthUseCase!
    private let loadInstructions: LoadInstructionsUseCase!
    private let saveInstruction: SaveInstructionUseCase!
    private let createAgent: CreateAgentUseCase!
    private let createTemporaryAgentUseCase: CreateTemporaryAgentUseCase?
    private let retireTemporaryAgentUseCase: RetireTemporaryAgentUseCase?
    private let recordTemporaryAgentNotesUseCase: RecordTemporaryAgentNotesUseCase?
    private let setAgentEnabled: SetAgentEnabledUseCase!
    private let updateProviderBindingInstructions: UpdateProviderBindingInstructionsUseCase?
    private let inspectProviderCredential: InspectProviderCredentialUseCase?
    private let saveProviderCredential: SaveProviderCredentialUseCase?
    private let removeProviderCredential: RemoveProviderCredentialUseCase?
    private let publishAgentToCodex: PublishAgentToCodexUseCase!
    private let deleteAgentUseCase: DeleteAgentUseCase!
    private let loadDeletedAgentHistory: LoadDeletedAgentHistoryUseCase!
    private let restoreDeletedAgent: RestoreDeletedAgentUseCase!
    private let generateDiagnostics: GenerateDiagnosticsUseCase!
    private let loadSharedResources: LoadSharedResourcesUseCase!
    private let registerSharedResources: RegisterSharedResourcesUseCase!
    private let setSharedResourceEnabled: SetSharedResourceEnabledUseCase!
    private let setSharedResourceAccess: SetSharedResourceAccessUseCase!
    private let setSharedResourceSettings: SetSharedResourceSettingsUseCase!
    private let prepareManualHandoff: PrepareManualHandoffUseCase?
    private let dispatchManualHandoff: DispatchManualHandoffUseCase?
    private let runtimeRegistry: (any AgentRuntimeResolving)?
    private let operationalContinuityRepository: (any GADOperationalContinuityRepository)?
    private let coordinatorCheckpointRepository: (any GADCoordinatorCheckpointRepository)?
    private let loadAutomationsUseCase: LoadAutomationsUseCase?
    private let saveAutomationUseCase: SaveAutomationUseCase?
    private let setAutomationStateUseCase: SetAutomationStateUseCase?
    private let deleteAutomationUseCase: DeleteAutomationUseCase?
    private let persistenceOwnership: (any GADPersistenceOwnershipControlling)?
    public private(set) var isTransferringOwnership = false
    /// False until the first load (or a reported startup failure) finishes,
    /// so Home can tell an empty lab from one that is still being restored.
    public private(set) var hasRestoredLab = false
    private var activeProviderRefreshes = 0
    private var providerRefreshDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingAttachmentOperations = 0
    public var hasPendingAttachmentOperations: Bool { pendingAttachmentOperations > 0 }
    private let automationCoordinator: (any AutomationCoordinating)?
    private let addMissingAutomationAgentsUseCase: AddMissingAutomationAgentsUseCase?
    @ObservationIgnored private let continuityStore: ContinuityStore?
    @ObservationIgnored private let desktopHostAdministration: (any GADDesktopHostAdministrating)?
    @ObservationIgnored private var localCatalogSnapshot: GADHostLocalCatalogSnapshot?
    @ObservationIgnored private var localRunSnapshots: [RunID: RunRecord] = [:]
    @ObservationIgnored private var localPresentationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var runControlTimeoutTasks: [RunID: Task<Void, Never>] = [:]
    @ObservationIgnored private var codexCatalogHostRecoveryAction:
        (@MainActor @Sendable () async -> Bool)?
    @ObservationIgnored private var lastRoutingPlanRequestedReview = true
    /// A plan was dismissed to re-authorize a project folder; once the folder
    /// import is confirmed, the same request is planned again.
    @ObservationIgnored private var replansAfterFolderAuthorization = false
    @ObservationIgnored private var applicationRelaunchAction:
        (@MainActor @Sendable () async -> Void)?
    private var runObservationTask: Task<Void, Never>?
    private var automationObservationTask: Task<Void, Never>?
    private var mapLayoutSaveTask: Task<Void, Never>?
    private var hasLoadedClientMapLayout = false
    private var operationalContinuitySaveTask: Task<Void, Never>?
    private var clientDraftSaveTask: Task<Void, Never>?
    private var clientDraftSaveGeneration: UInt64 = 0
    private var clientPlanSaveTask: Task<Void, Never>?
    private var pendingClientPlanUpdate: GADPlanUpdate?
    private var clientPlanUpdateRevision: UInt64 = 0
    private var clientAgentReviewHashes: [AgentID: String] = [:]
    private var clientImportURLsByID: [ProjectID: URL] = [:]
    @ObservationIgnored private var scheduledResumeRunIDs = Set<RunID>()
    private var isRestoringOperationalContinuity = false
    private var isHydratingClientProjection = false
    private var observedClientSelection: ClientDraftSelection?
    private var pendingClientSelection: ClientDraftSelection?

    private struct ClientDraftSelection: Equatable {
        let providerID: AgentProviderID
        let model: String?
        let scope: PromptScope
        let projectIDs: Set<ProjectID>
        let agentTargets: Set<AgentRouteTarget>
        let groupID: ProjectGroupID?
    }
    @ObservationIgnored public var stateDidChange: (@MainActor @Sendable () -> Void)?

    public init(
        loadDashboard: LoadDashboardUseCase,
        discoverProjects: DiscoverProjectsUseCase,
        discoverCodexCatalogSync: DiscoverCodexCatalogSyncUseCase,
        discoverCodexActivity: DiscoverCodexActivityUseCase,
        syncCodexCatalog: SyncCodexCatalogUseCase,
        registerProjects: RegisterProjectsUseCase,
        createProject: CreateProjectUseCase,
        removeProject: RemoveProjectUseCase,
        saveProjectGroup: SaveProjectGroupUseCase,
        removeProjectGroup: RemoveProjectGroupUseCase,
        preparePlan: PrepareRoutingPlanUseCase,
        stageRun: StageRunUseCase,
        buildGraph: BuildGraphUseCase,
        loadMapLayout: LoadMapLayoutUseCase,
        saveMapLayout: SaveMapLayoutUseCase,
        inspectCodex: InspectCodexUseCase,
        discoverAgents: DiscoverAgentsUseCase,
        registerAgents: RegisterAgentsUseCase,
        previewAgentRestructure: PreviewAgentRestructureUseCase,
        applyAgentRestructure: ApplyAgentRestructureUseCase,
        undoAgentRestructure: UndoAgentRestructureUseCase,
        loadAgentRestructureHistory: LoadAgentRestructureHistoryUseCase,
        saveAgentRestructureHistory: SaveAgentRestructureHistoryUseCase,
        executeRun: ExecuteRunUseCase,
        controlRun: ControlRunUseCase,
        followUpRun: FollowUpRunUseCase,
        observeRuns: ObserveRunsUseCase,
        manageApproval: ManageProviderApprovalUseCase,
        recoverInterruptedRuns: RecoverInterruptedRunsUseCase,
        checkSystemHealth: CheckSystemHealthUseCase,
        loadInstructions: LoadInstructionsUseCase,
        saveInstruction: SaveInstructionUseCase,
        createAgent: CreateAgentUseCase,
        createTemporaryAgent: CreateTemporaryAgentUseCase? = nil,
        retireTemporaryAgent: RetireTemporaryAgentUseCase? = nil,
        recordTemporaryAgentNotes: RecordTemporaryAgentNotesUseCase? = nil,
        setAgentEnabled: SetAgentEnabledUseCase,
        updateProviderBindingInstructions: UpdateProviderBindingInstructionsUseCase? = nil,
        inspectProviderCredential: InspectProviderCredentialUseCase? = nil,
        saveProviderCredential: SaveProviderCredentialUseCase? = nil,
        removeProviderCredential: RemoveProviderCredentialUseCase? = nil,
        publishAgentToCodex: PublishAgentToCodexUseCase,
        deleteAgent: DeleteAgentUseCase,
        loadDeletedAgentHistory: LoadDeletedAgentHistoryUseCase,
        restoreDeletedAgent: RestoreDeletedAgentUseCase,
        generateDiagnostics: GenerateDiagnosticsUseCase,
        loadSharedResources: LoadSharedResourcesUseCase,
        registerSharedResources: RegisterSharedResourcesUseCase,
        setSharedResourceEnabled: SetSharedResourceEnabledUseCase,
        setSharedResourceAccess: SetSharedResourceAccessUseCase,
        setSharedResourceSettings: SetSharedResourceSettingsUseCase,
        prepareManualHandoff: PrepareManualHandoffUseCase? = nil,
        dispatchManualHandoff: DispatchManualHandoffUseCase? = nil,
        runtimeRegistry: (any AgentRuntimeResolving)? = nil,
        operationalContinuityRepository: (any GADOperationalContinuityRepository)? = nil,
        coordinatorCheckpointRepository: (any GADCoordinatorCheckpointRepository)? = nil,
        persistenceOwnership: (any GADPersistenceOwnershipControlling)? = nil,
        inspectProjectGitBranches: InspectProjectGitBranchesUseCase? = nil,
        switchProjectGitBranch: SwitchProjectGitBranchUseCase? = nil,
        loadAutomations: LoadAutomationsUseCase? = nil,
        saveAutomation: SaveAutomationUseCase? = nil,
        setAutomationState: SetAutomationStateUseCase? = nil,
        deleteAutomation: DeleteAutomationUseCase? = nil,
        automationCoordinator: (any AutomationCoordinating)? = nil,
        addMissingAutomationAgents: AddMissingAutomationAgentsUseCase? = nil,
        temporaryChatService: (any TemporaryChatServing)? = nil,
        promptAttachmentDirectoryURL: URL? = nil,
        localDefaults: UserDefaults = .standard
    ) {
        self.localDefaults = localDefaults
        trustedProjectIDs = Set((localDefaults.stringArray(forKey: Self.trustedProjectsKey) ?? [])
            .map(ProjectID.init(rawValue:)))
        activityReadState = Self.loadActivityReadState(defaults: localDefaults)
        let activityClearedValue = localDefaults.double(forKey: Self.activityClearedAtKey)
        activityClearedAt = activityClearedValue > 0
            ? Date(timeIntervalSinceReferenceDate: activityClearedValue) : nil
        uninterruptedRunIDs = (localDefaults.stringArray(forKey: Self.uninterruptedRunIDsKey) ?? [])
            .map(RunID.init(rawValue:))
        self.promptAttachmentDirectoryURL = promptAttachmentDirectoryURL?.standardizedFileURL
        self.temporaryChatService = temporaryChatService
        self.loadDashboard = loadDashboard
        self.discoverProjects = discoverProjects
        self.discoverCodexCatalogSync = discoverCodexCatalogSync
        self.discoverCodexActivity = discoverCodexActivity
        self.syncCodexCatalog = syncCodexCatalog
        self.registerProjects = registerProjects
        self.createProjectUseCase = createProject
        self.removeProjectUseCase = removeProject
        self.saveProjectGroupUseCase = saveProjectGroup
        self.removeProjectGroupUseCase = removeProjectGroup
        self.inspectProjectGitBranchesUseCase = inspectProjectGitBranches
        self.switchProjectGitBranchUseCase = switchProjectGitBranch
        self.preparePlan = preparePlan
        self.stageRun = stageRun
        self.buildGraph = buildGraph
        self.loadMapLayoutUseCase = loadMapLayout
        self.saveMapLayoutUseCase = saveMapLayout
        self.inspectCodex = inspectCodex
        self.discoverAgents = discoverAgents
        self.registerAgents = registerAgents
        self.previewAgentRestructure = previewAgentRestructure
        self.applyAgentRestructure = applyAgentRestructure
        self.undoAgentRestructure = undoAgentRestructure
        self.loadAgentRestructureHistory = loadAgentRestructureHistory
        self.saveAgentRestructureHistory = saveAgentRestructureHistory
        self.executeRun = executeRun
        self.controlRun = controlRun
        self.followUpRun = followUpRun
        self.observeRuns = observeRuns
        self.manageApproval = manageApproval
        self.recoverInterruptedRuns = recoverInterruptedRuns
        self.checkSystemHealth = checkSystemHealth
        self.loadInstructions = loadInstructions
        self.saveInstruction = saveInstruction
        self.createAgent = createAgent
        self.createTemporaryAgentUseCase = createTemporaryAgent
        self.retireTemporaryAgentUseCase = retireTemporaryAgent
        self.recordTemporaryAgentNotesUseCase = recordTemporaryAgentNotes
        self.setAgentEnabled = setAgentEnabled
        self.updateProviderBindingInstructions = updateProviderBindingInstructions
        self.inspectProviderCredential = inspectProviderCredential
        self.saveProviderCredential = saveProviderCredential
        self.removeProviderCredential = removeProviderCredential
        self.publishAgentToCodex = publishAgentToCodex
        self.deleteAgentUseCase = deleteAgent
        self.loadDeletedAgentHistory = loadDeletedAgentHistory
        self.restoreDeletedAgent = restoreDeletedAgent
        self.generateDiagnostics = generateDiagnostics
        self.loadSharedResources = loadSharedResources
        self.registerSharedResources = registerSharedResources
        self.setSharedResourceEnabled = setSharedResourceEnabled
        self.setSharedResourceAccess = setSharedResourceAccess
        self.setSharedResourceSettings = setSharedResourceSettings
        self.prepareManualHandoff = prepareManualHandoff
        self.dispatchManualHandoff = dispatchManualHandoff
        self.runtimeRegistry = runtimeRegistry
        self.operationalContinuityRepository = operationalContinuityRepository
        self.coordinatorCheckpointRepository = coordinatorCheckpointRepository
        self.persistenceOwnership = persistenceOwnership
        self.loadAutomationsUseCase = loadAutomations
        self.saveAutomationUseCase = saveAutomation
        self.setAutomationStateUseCase = setAutomationState
        self.deleteAutomationUseCase = deleteAutomation
        self.automationCoordinator = automationCoordinator
        self.addMissingAutomationAgentsUseCase = addMissingAutomationAgents
        self.continuityStore = nil
        self.desktopHostAdministration = nil
        observeTemporaryChat()
    }

    /// Creates the desktop presentation facade used after ownership has moved
    /// to the background host. An optional repository stores only local map
    /// preferences, independently of the host-owned operational catalog.
    /// This initializer constructs no operational repository,
    /// provider runtime, process transport, workspace manager, or credential
    /// store in the UI process.
    public init(
        client: any GobyClient,
        deviceID: DeviceID,
        desktopHostAdministration: (any GADDesktopHostAdministrating)? = nil,
        promptAttachmentDirectoryURL: URL? = nil,
        mapLayoutRepository: (any MapLayoutRepository)? = nil,
        localDraftCache: (any GADLocalDraftCaching)? = nil
    ) {
        localDefaults = .standard
        trustedProjectIDs = Set((localDefaults.stringArray(forKey: Self.trustedProjectsKey) ?? [])
            .map(ProjectID.init(rawValue:)))
        activityReadState = Self.loadActivityReadState(defaults: localDefaults)
        let activityClearedValue = localDefaults.double(forKey: Self.activityClearedAtKey)
        activityClearedAt = activityClearedValue > 0
            ? Date(timeIntervalSinceReferenceDate: activityClearedValue) : nil
        uninterruptedRunIDs = (localDefaults.stringArray(forKey: Self.uninterruptedRunIDsKey) ?? [])
            .map(RunID.init(rawValue:))
        self.promptAttachmentDirectoryURL = promptAttachmentDirectoryURL?.standardizedFileURL
        let continuityStore = ContinuityStore(
            client: client,
            deviceID: deviceID,
            draftCache: localDraftCache,
            reconnectDelays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
            reconnectRepeatDelay: .seconds(30)
        )
        self.loadDashboard = nil
        self.discoverProjects = nil
        self.discoverCodexCatalogSync = nil
        self.discoverCodexActivity = nil
        self.syncCodexCatalog = nil
        self.registerProjects = nil
        self.createProjectUseCase = nil
        self.removeProjectUseCase = nil
        self.saveProjectGroupUseCase = nil
        self.removeProjectGroupUseCase = nil
        self.inspectProjectGitBranchesUseCase = nil
        self.switchProjectGitBranchUseCase = nil
        self.preparePlan = nil
        self.stageRun = nil
        self.buildGraph = nil
        self.loadMapLayoutUseCase = mapLayoutRepository.map { LoadMapLayoutUseCase(repository: $0) }
        self.saveMapLayoutUseCase = mapLayoutRepository.map { SaveMapLayoutUseCase(repository: $0) }
        self.inspectCodex = nil
        self.discoverAgents = nil
        self.registerAgents = nil
        self.previewAgentRestructure = nil
        self.applyAgentRestructure = nil
        self.undoAgentRestructure = nil
        self.loadAgentRestructureHistory = nil
        self.saveAgentRestructureHistory = nil
        self.executeRun = nil
        self.controlRun = nil
        self.followUpRun = nil
        self.observeRuns = nil
        self.manageApproval = nil
        self.recoverInterruptedRuns = nil
        self.checkSystemHealth = nil
        self.loadInstructions = nil
        self.saveInstruction = nil
        self.createAgent = nil
        self.createTemporaryAgentUseCase = nil
        self.retireTemporaryAgentUseCase = nil
        self.recordTemporaryAgentNotesUseCase = nil
        self.setAgentEnabled = nil
        self.updateProviderBindingInstructions = nil
        self.inspectProviderCredential = nil
        self.saveProviderCredential = nil
        self.removeProviderCredential = nil
        self.publishAgentToCodex = nil
        self.deleteAgentUseCase = nil
        self.loadDeletedAgentHistory = nil
        self.restoreDeletedAgent = nil
        self.generateDiagnostics = nil
        self.loadSharedResources = nil
        self.registerSharedResources = nil
        self.setSharedResourceEnabled = nil
        self.setSharedResourceAccess = nil
        self.setSharedResourceSettings = nil
        self.prepareManualHandoff = nil
        self.dispatchManualHandoff = nil
        self.runtimeRegistry = nil
        self.operationalContinuityRepository = nil
        self.coordinatorCheckpointRepository = nil
        self.persistenceOwnership = nil
        self.loadAutomationsUseCase = nil
        self.saveAutomationUseCase = nil
        self.setAutomationStateUseCase = nil
        self.deleteAutomationUseCase = nil
        self.automationCoordinator = nil
        self.addMissingAutomationAgentsUseCase = nil
        self.temporaryChatService = nil
        self.continuityStore = continuityStore
        self.desktopHostAdministration = desktopHostAdministration
        continuityStore.projectionDidChange = { [weak self] projection in
            guard let projection else {
                self?.discardRevokedClientState()
                return
            }
            self?.hydrateClientProjection(projection)
            self?.scheduleLocalPresentationRefresh()
        }
        continuityStore.applicationRelaunchDidBecomeRequired = { [weak self] in
            guard let self, let action = self.applicationRelaunchAction else { return }
            Task { @MainActor in await action() }
        }
    }

    public var isHostClientBacked: Bool { continuityStore != nil }
    public var isReconnectingToHost: Bool {
        continuityStore?.isRecoveringConnection ?? false
    }

    public var hostConnectionStatus: String? {
        guard let continuityStore else { return nil }
        if continuityStore.requiresApplicationRelaunch {
            return applicationRelaunchAction == nil
                ? "Goby was rebuilt or updated while it was open. Relaunch Goby to reconnect; your draft is kept on this Mac."
                : "Goby was rebuilt or updated while it was open. Relaunching into the new build… Your draft is kept on this Mac."
        }
        if isReconnectingToHost {
            return "Reconnecting to background host… Your draft is preserved. Live updates will resume automatically."
        }
        switch continuityStore.connectionPhase {
        case let .failed(message):
            return message
        case .incompatible:
            return "The app and background host are incompatible. Reopen the updated Goby app to reconnect."
        default:
            return nil
        }
    }

    public var hostConnectionDetail: String? { continuityStore?.lastClientErrorMessage }
    public var requiresApplicationRelaunch: Bool {
        continuityStore?.requiresApplicationRelaunch ?? false
    }
    public var canRelaunchApplication: Bool {
        requiresApplicationRelaunch && applicationRelaunchAction != nil
    }

    public func relaunchApplication() async {
        guard requiresApplicationRelaunch, let applicationRelaunchAction else { return }
        await applicationRelaunchAction()
    }

    /// Installs the native shell's relaunch transaction. It runs automatically
    /// once the host transport reports that this app's bundle was replaced.
    public func setApplicationRelaunchAction(
        _ action: @escaping @MainActor @Sendable () async -> Void
    ) {
        applicationRelaunchAction = action
        if requiresApplicationRelaunch {
            Task { @MainActor in await action() }
        }
    }

    public var canReconnectHostNow: Bool {
        isReconnectingToHost && continuityStore?.connectionPhase != .connecting
    }

    public func reconnectHostClient() async {
        guard let continuityStore, canReconnectHostNow else { return }
        await continuityStore.reconnect()
    }
    public var hasUnsyncedPlanChanges: Bool { pendingClientPlanUpdate != nil }

    /// Gives the macOS shell one bounded opportunity to restore its local
    /// permanent-host connection and replay a failed Codex catalog request.
    /// Other clients deliberately remain read-only when their transport is
    /// stale and do not install this device-local recovery action.
    public func setCodexCatalogHostRecoveryAction(
        _ action: @escaping @MainActor @Sendable () async -> Bool
    ) {
        codexCatalogHostRecoveryAction = action
    }

    public func flushHostClientChanges() async {
        if let clientPlanSaveTask { await clientPlanSaveTask.value }
        guard pendingClientPlanUpdate == nil else { return }
        await flushClientDraftNow()
    }

    public func disconnectHostClient() async {
        remoteApprovalDisclosures.removeAll()
        approvalDisclosureTasks.values.forEach { $0.task.cancel() }
        approvalDisclosureTasks.removeAll()
        await mapLayoutSaveTask?.value
        clientDraftSaveTask?.cancel()
        clientPlanSaveTask?.cancel()
        await continuityStore?.disconnect()
    }

    /// Quiesces the local automation owner before the durable store moves to
    /// another process. The observation task must be cancelled too because it
    /// otherwise retains the coordinator's update stream after this store is
    /// no longer presented.
    public func suspendAutomationCoordination() async {
        automationObservationTask?.cancel()
        automationObservationTask = nil
        await automationCoordinator?.stop()
    }

    /// Close local admission before awaiting anything. Background observations
    /// may continue briefly while the scheduler drains, but cannot enqueue new
    /// draft/layout saves. The final explicit checkpoint happens after draining.
    public func prepareForOwnershipTransfer() async throws {
        guard continuityStore == nil, !isBusy, !isTransferringOwnership, pendingRunControls.isEmpty, !hasPendingAttachmentOperations else {
            throw GADPersistenceOwnershipError.transferInProgress
        }
        isTransferringOwnership = true
        await suspendAutomationCoordination()
        if activeProviderRefreshes > 0 {
            await withCheckedContinuation { providerRefreshDrainWaiters.append($0) }
        }
        runObservationTask?.cancel()
        await runObservationTask?.value
        runObservationTask = nil
        await mapLayoutSaveTask?.value
        mapLayoutSaveTask = nil
        operationalContinuitySaveTask?.cancel()
        await operationalContinuitySaveTask?.value
        operationalContinuitySaveTask = nil
        // A final timer tick can have admitted work before stop completed.
        // Refresh durable runs so the caller's second readiness check sees it.
        let (_, currentRuns) = try await loadDashboard()
        runs = currentRuns
    }

    public func disconnectIdleProvidersForOwnershipTransfer() async {
        guard isTransferringOwnership, let runtimeRegistry else { return }
        for providerID in await runtimeRegistry.providerIDs() {
            await runtimeRegistry.runtime(for: providerID)?.disconnect()
        }
    }

    /// Must complete before the composition root releases its lease. A retained
    /// old AppStore can no longer write, even via a late callback or direct save.
    public func sealPersistenceForOwnershipTransfer() async {
        isTransferringOwnership = true
        await persistenceOwnership?.suspendWrites()
    }

    /// Called only after the composition root reacquires the foreground lease.
    public func resumeAfterOwnershipTransfer() async {
        await persistenceOwnership?.resumeWrites()
        isTransferringOwnership = false
        startObservingRunsIfNeeded()
        await resumeAutomationCoordination()
    }

    /// Restarts a foreground automation owner when a process handoff rolls
    /// back. Reloading first closes the small update window around quiescing.
    public func resumeAutomationCoordination() async {
        guard let loadAutomationsUseCase, let automationCoordinator else { return }
        if let snapshot = try? await loadAutomationsUseCase() {
            automationSnapshot = snapshot
            notifyStateDidChange()
        }
        startObservingAutomationsIfNeeded()
        await automationCoordinator.start()
    }

    public var activeRuns: [RunRecord] {
        runs.filter { $0.status == .running }
    }

    public var isSelectedProviderAvailable: Bool {
        availableProviderIDs.contains(selectedProviderID)
    }

    public var currentRuns: [RunRecord] {
        runs.filter { $0.status == .running || $0.status == .ready }
    }

    /// The plane a new request starts on: Codex when it is available, otherwise
    /// the first available provider, so a Claude-only setup never lands on an
    /// unavailable Codex plane after each run.
    public var defaultProviderID: AgentProviderID {
        if availableProviderIDs.contains(.codex) || availableProviderIDs.isEmpty { return .codex }
        let preferredOrder: [AgentProviderID] = [.claude, .githubCopilot]
        return preferredOrder.first(where: availableProviderIDs.contains)
            ?? availableProviderIDs.sorted().first
            ?? .codex
    }

    public var attentionRuns: [RunRecord] {
        runs.filter { $0.status == .needsAttention || $0.status == .failed }
    }

    public var automations: [AutomationDefinition] {
        automationSnapshot.definitions
    }

    public var automationOccurrences: [AutomationOccurrence] {
        automationSnapshot.occurrences
    }

    public func latestOccurrence(for automationID: AutomationID) -> AutomationOccurrence? {
        automationSnapshot.occurrences
            .filter { $0.automationID == automationID }
            .max { $0.scheduledAt < $1.scheduledAt }
    }

    public var operationsSnapshot: OperationsCenterSnapshot {
        if let operationsSnapshotCache { return operationsSnapshotCache }
        let registeredProjectIDs = Set(lab.projects.map(\.id))
        let snapshot = OperationsCenterSnapshot(
            runs: runs,
            codexTasks: codexTasks.filter { registeredProjectIDs.contains($0.projectID) },
            pendingApprovalAssignmentIDs: pendingApprovals.map(\.assignmentID),
            codexActivityRefresh: codexActivityRefresh,
            clearedAt: activityClearedAt
        )
        operationsSnapshotCache = snapshot
        return snapshot
    }

    public var dockStatusSnapshot: DockStatusSnapshot {
        let registeredProjectIDs = Set(lab.projects.map(\.id))
        var freshProviderIDs = Set(providerAccounts.compactMap { account -> AgentProviderID? in
            guard case .connected = account.connectionState else { return nil }
            return account.providerID
        })
        if codexActivityRefresh.isStale {
            freshProviderIDs.remove(.codex)
        } else {
            freshProviderIDs.insert(.codex)
        }
        // The host carries task freshness separately from authentication.
        for account in continuityStore?.projection?.providerAccounts ?? [] {
            if account.activityFreshness?.isStale == true {
                freshProviderIDs.remove(account.providerID)
            }
        }
        return DockStatusSnapshot(
            runs: runs,
            providerTasks: (providerTasks + codexTasks.map(Self.providerActivity))
                .filter { registeredProjectIDs.contains($0.projectID) },
            pendingApprovalAssignmentIDs: pendingApprovals.map(\.assignmentID),
            freshProviderIDs: freshProviderIDs,
            isLive: continuityStore.map { $0.connectionPhase == .live } ?? true
        )
    }

    public var reviewQueueCount: Int {
        operationsSnapshot.actionCount
    }

    public var selectedRun: RunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first(where: { $0.id == selectedRunID })
            ?? (selectedRunHistorySnapshot?.id == selectedRunID ? selectedRunHistorySnapshot : nil)
    }

    public var promptTargetAgent: AgentProfile? {
        guard let promptAgentTarget else { return nil }
        return lab.agents.first { $0.id == promptAgentTarget.agentID }
    }

    public var promptTargetProject: LabProject? {
        guard let promptAgentTarget else { return nil }
        return lab.projects.first { $0.id == promptAgentTarget.projectID }
    }

    public var promptAgentTarget: AgentRouteTarget? {
        promptAgentTargets.count == 1 ? promptAgentTargets.first : nil
    }

    public var promptProjectGroup: ProjectGroup? {
        guard let promptProjectGroupID else { return nil }
        return lab.projectGroups.first { $0.id == promptProjectGroupID }
    }

    public var promptScopeTitle: String {
        if promptProjectIDs.count == 1,
           let projectID = promptProjectIDs.first,
           let project = lab.projects.first(where: { $0.id == projectID }) {
            return project.name
        }
        if promptProjectIDs.count > 1 {
            return "\(promptProjectIDs.count) projects"
        }
        return promptProjectGroup?.name ?? promptScope.rawValue
    }

    public var enabledSharedResources: [SharedResource] {
        sharedResources.filter(\.isEnabled).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public var accessHealthChecks: [HealthCheck] {
        systemHealth.checks.filter { check in
            guard check.status != .passed else { return false }
            return check.kind == .authentication
                || check.kind == .storage
                || check.kind == .projectRoots
        }
    }

    public var requiresAccessAttention: Bool {
        limitedProjectAccessCount > 0 || !accessHealthChecks.isEmpty
    }

    public func restoreLimitedProjectAccessCount(_ count: Int) {
        guard limitedProjectAccessCount == 0, count > 0 else { return }
        limitedProjectAccessCount = count
    }

    /// Host ownership depends on persisted state, not live provider reachability.
    /// The local migration path defers provider inspection until its client connects.
    public func load(includingLiveProviderChecks: Bool = true) async {
        defer { hasRestoredLab = true }
        if let continuityStore {
            isBusy = true
            errorMessage = nil
            if !hasLoadedClientMapLayout, let loadMapLayoutUseCase {
                do {
                    mapLayoutOverrides = try await loadMapLayoutUseCase()
                    hasLoadedClientMapLayout = true
                } catch {
                    notice = "Could not restore map preferences: \(error.localizedDescription)"
                }
            }
            await continuityStore.connect()
            // Local presentation details are optional enrichment. Never keep
            // the composer busy while the host prepares them.
            isBusy = false
            if let projection = continuityStore.projection {
                hydrateClientProjection(projection)
                await refreshLocalPresentationState()
            } else if case let .failed(message) = continuityStore.connectionPhase, !isReconnectingToHost {
                errorMessage = message
            }
            return
        }
        await perform {
            if let runtimeRegistry {
                availableProviderIDs = Set(await runtimeRegistry.providerIDs())
            }
            if let inspectProviderCredential {
                claudeCredentialConfigured = (try? await inspectProviderCredential(
                    providerID: .claude
                )) ?? false
                claudeSubscriptionConfigured = (try? await inspectProviderCredential(
                    providerID: .claude,
                    kind: .subscriptionToken
                )) ?? false
                copilotCredentialConfigured = (try? await inspectProviderCredential(
                    providerID: .githubCopilot
                )) ?? false
            }
            // Verify and, when necessary, quarantine authenticated automation
            // authority before any provider recovery can resume execution.
            if let loadAutomationsUseCase {
                self.automationSnapshot = try await loadAutomationsUseCase()
            }
            let recovered = try await recoverInterruptedRuns()

            // Restore the durable local catalog before waiting for Codex or
            // system-health probes. Those checks can be comparatively slow,
            // and must never make a successful previous import look empty.
            var (updatedLab, updatedRuns) = try await loadDashboard()
            if let retireTemporaryAgentUseCase {
                for agent in updatedLab.agents where agent.isTemporary {
                    let matchingRuns = updatedRuns.filter { run in
                        run.agentSnapshot.contains(where: { $0.id == agent.id })
                    }
                    guard !matchingRuns.isEmpty,
                          matchingRuns.allSatisfy(\.status.isFinished) else { continue }
                    // Runs that finished while Goby was closed still leave
                    // continuation notes; recording is idempotent per run.
                    for finished in matchingRuns { await recordTemporaryAgentNotes(for: finished) }
                    do {
                        try await retireTemporaryAgentUseCase(id: agent.id)
                    } catch {
                        notice = "A finished quick-task agent still needs cleanup: \(error.localizedDescription)"
                    }
                }
                (updatedLab, updatedRuns) = try await loadDashboard()
            }
            self.lab = updatedLab
            self.runs = updatedRuns
            if loadAutomationsUseCase != nil {
                startObservingAutomationsIfNeeded()
                await automationCoordinator?.start()
            }
            self.mapLayoutOverrides = try await loadMapLayoutUseCase()
            try await refreshGraph()
            startObservingRunsIfNeeded()
            await Task.yield()

            let previousCodex = (self.codexState, self.codexAccount)
            let previousHealth = self.systemHealth
            async let codex = includingLiveProviderChecks ? inspectCodex() : previousCodex
            async let health = includingLiveProviderChecks ? checkSystemHealth() : previousHealth
            async let instructions = loadInstructions()
            async let resources = loadSharedResources()
            async let historyTask = loadAgentRestructureHistory()
            async let deletedAgentTask = loadDeletedAgentHistory()
            let (codexState, codexAccount) = await codex
            let healthSnapshot = await health
            let instructionPacks = try await instructions
            let sharedResources = try await resources
            let restructureHistory = try await historyTask
            let deletedAgent = try await deletedAgentTask
            self.codexState = codexState
            self.codexAccount = codexAccount
            self.systemHealth = mergedHealth(healthSnapshot, account: codexAccount)
            self.instructionPacks = instructionPacks
            self.sharedResources = sharedResources
            self.lastAppliedAgentRestructure = restructureHistory
            self.lastDeletedAgent = deletedAgent
            if let operationalContinuityRepository {
                let continuity = try await operationalContinuityRepository.loadOperationalContinuity()
                restoreOperationalContinuity(continuity)
            }
            // Persisted unsent drafts and reviewed plans own attachment copies
            // too. Restore every owner before collecting unreferenced files.
            await sweepOwnedPromptAttachmentStorage()
            if includingLiveProviderChecks, case .connected = codexState {
                do {
                    codexTasks = try await discoverCodexActivity()
                    codexActivityRefresh = .fresh(at: .now)
                } catch {
                    codexActivityRefresh = codexActivityRefresh.markingStale(at: .now)
                }
            } else {
                codexActivityRefresh = codexActivityRefresh.markingStale(at: .now)
            }
            if includingLiveProviderChecks {
                await refreshProviderSnapshots(providerIDs: availableProviderIDs)
            }
            if !recovered.isEmpty {
                let reconnected = recovered.filter { run in
                    run.assignments.contains { $0.status == .working || $0.status == .waitingForApproval }
                }.count
                let needsReview = recovered.filter { $0.status == .needsAttention }.count
                if reconnected > 0, needsReview > 0 {
                    notice = "Reconnected \(reconnected) run\(reconnected == 1 ? "" : "s"); \(needsReview) need\(needsReview == 1 ? "s" : "") review."
                } else if reconnected > 0 {
                    notice = "Reconnected \(reconnected) running provider task\(reconnected == 1 ? "" : "s") without replaying work."
                } else {
                    notice = recovered.count == 1
                        ? "Recovered 1 interrupted run. Its last progress was preserved for review."
                        : "Recovered \(recovered.count) interrupted runs. Their last progress was preserved for review."
                }
            }
            try await refreshGraph()
        }
    }

#if DEBUG
    /// Restores the complete device-local model for native UI tests without
    /// waiting on live Codex, system-health, or provider-network probes.
    public func loadForUITesting() async {
        await perform {
            if let runtimeRegistry {
                availableProviderIDs = Set(await runtimeRegistry.providerIDs())
            }
            if let loadAutomationsUseCase {
                self.automationSnapshot = try await loadAutomationsUseCase()
            }
            _ = try await recoverInterruptedRuns()
            let (updatedLab, updatedRuns) = try await loadDashboard()
            self.lab = updatedLab
            self.runs = updatedRuns
            if loadAutomationsUseCase != nil {
                startObservingAutomationsIfNeeded()
                await automationCoordinator?.start()
            }
            self.mapLayoutOverrides = try await loadMapLayoutUseCase()
            self.instructionPacks = try await loadInstructions()
            self.sharedResources = try await loadSharedResources()
            self.lastAppliedAgentRestructure = try await loadAgentRestructureHistory()
            self.lastDeletedAgent = try await loadDeletedAgentHistory()
            if let operationalContinuityRepository {
                let continuity = try await operationalContinuityRepository.loadOperationalContinuity()
                restoreOperationalContinuity(continuity)
            }
            // Persisted unsent drafts and reviewed plans own attachment copies
            // too. Restore every owner before collecting unreferenced files.
            await sweepOwnedPromptAttachmentStorage()
            try await refreshGraph()
            startObservingRunsIfNeeded()
        }
    }
#endif

    public func refreshCodexStatus() async {
        guard !isTransferringOwnership else { return }
        activeProviderRefreshes += 1
        defer { finishProviderRefresh() }
        if let continuityStore {
            await performClientRefresh { await continuityStore.refreshCodex() }
            return
        }
        async let codex = inspectCodex()
        async let health = checkSystemHealth()
        let (state, account) = await codex
        codexState = state
        codexAccount = account
        systemHealth = mergedHealth(await health, account: account)
        if case .connected = state {
            do {
                codexTasks = try await discoverCodexActivity()
                codexActivityRefresh = .fresh(at: .now)
                try? await refreshGraph()
            } catch {
                codexActivityRefresh = codexActivityRefresh.markingStale(at: .now)
            }
        } else {
            codexActivityRefresh = codexActivityRefresh.markingStale(at: .now)
        }
    }

    public func refreshProviderStatus(
        providerIDs: Set<AgentProviderID> = Set(AgentProviderID.builtIn)
    ) async {
        guard !isTransferringOwnership else { return }
        activeProviderRefreshes += 1
        defer { finishProviderRefresh() }
        if let continuityStore {
            await performClientRefresh {
                await continuityStore.refreshProviders(
                    providerIDs.sorted()
                )
            }
            return
        }
        let requested = providerIDs.intersection(availableProviderIDs)
        guard !requested.isEmpty else { return }
        if requested.contains(.codex) {
            await refreshCodexStatus()
        }
        await refreshProviderSnapshots(providerIDs: requested)
        notifyStateDidChange()
    }

    /// Refreshes provider-owned task activity for the visible map without
    /// rerunning account and system-health inspection on every short poll.
    public func refreshMapActivity(providerID: AgentProviderID) async {
        guard !isTransferringOwnership else { return }
        activeProviderRefreshes += 1
        defer { finishProviderRefresh() }
        if let continuityStore {
            await performClientRefresh {
                await continuityStore.refreshProviders([providerID], activityOnly: true)
            }
            return
        }
        guard availableProviderIDs.contains(providerID) else { return }

        if providerID == .codex {
            do {
                codexTasks = try await discoverCodexActivity()
                codexActivityRefresh = .fresh(at: .now)
                providerTasks.removeAll { $0.providerID == .codex }
                providerTasks.append(contentsOf: codexTasks.map(Self.providerActivity))
                mergeHelperActivitiesFromRuns()
                try? await refreshGraph()
            } catch {
                codexActivityRefresh = codexActivityRefresh.markingStale(at: .now)
            }
            notifyStateDidChange()
            return
        }

        guard let runtimeRegistry,
              let runtime = await runtimeRegistry.runtime(for: providerID) else { return }
        do {
            let tasks = try await runtime.recentTasks(projects: lab.projects)
            providerTasks.removeAll { $0.providerID == providerID }
            providerTasks.append(contentsOf: tasks)
            mergeHelperActivitiesFromRuns()
            notifyStateDidChange()
        } catch {
            // Keep the last observed task state. Connection recovery and its
            // actionable error remain owned by the explicit provider refresh.
        }
    }

    /// Keeps the app-wide Dock status current even when Home is not mounted.
    /// Shares ordinary read-only provider admission; never starts provider work.
    public func refreshDockActivity() async {
        guard !isTransferringOwnership, activeProviderRefreshes == 0, !lab.projects.isEmpty else { return }
        var providers = Set(providerAccounts.compactMap { account -> AgentProviderID? in
            guard case .connected = account.connectionState else { return nil }
            return account.providerID
        })
        if case .connected = codexState { providers.insert(.codex) }
        providers.formIntersection(availableProviderIDs)
        guard !providers.isEmpty else { return }
        if let continuityStore {
            guard continuityStore.connectionPhase == .live else { return }
            activeProviderRefreshes += 1
            defer { finishProviderRefresh() }
            await performClientRefresh {
                await continuityStore.refreshProviders(providers.sorted(), activityOnly: true)
            }
        } else {
            for providerID in providers.sorted() {
                guard !Task.isCancelled else { return }
                await refreshMapActivity(providerID: providerID)
            }
        }
    }

    public func discover(urls: [URL]) async {
        projectImportError = nil
        if continuityStore != nil {
            guard let desktopHostAdministration else {
                errorMessage = "The local host authorization channel is unavailable."
                return
            }
            do {
                let candidates = try await desktopHostAdministration.discoverProjects(at: urls)
                importCandidates = candidates
                selectedImportIDs = Set(candidates.map(\.id))
                clientImportURLsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.project.rootURL) })
                if candidates.isEmpty {
                    notice = "No recognizable projects were found in the selected folders."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        await perform {
            let candidates = try await discoverProjects(selectedRoots: urls)
            importCandidates = candidates
            selectedImportIDs = Set(candidates.map(\.id))
            if candidates.isEmpty {
                notice = "No recognizable projects were found in the selected folders."
            }
        }
    }

    public func discoverCurrentProjects() async {
        if let continuityStore {
            guard let discovery = await continuityStore.codexCatalogDiscovery() else {
                let hostMessage = continuityStore.lastClientErrorMessage
                if await codexCatalogHostRecoveryAction?() == true { return }
                errorMessage = hostMessage
                    ?? "The host could not inspect the current Codex catalog."
                return
            }
            codexSyncPlan = clientCodexPlan(discovery)
            limitedProjectAccessCount = discovery.limitedProjectAccessCount
            selectedCodexProjectIDs = Set(discovery.projects.map(\.id))
            selectedCodexAgentIDs = Set(
                discovery.agents.filter { !$0.requiresMacReview }.map(\.id)
            )
            if discovery.projects.isEmpty && discovery.agents.isEmpty {
                notice = discovery.warnings.first ?? "Codex projects are up to date."
            }
            return
        }
        await perform {
            let plan = try await discoverCodexCatalogSync()
            codexTasks = plan.tasks
            codexActivityRefresh = .fresh(at: .now)
            limitedProjectAccessCount = plan.limitedProjectAccessCount
            try await refreshGraph()
            if plan.hasChanges {
                codexSyncPlan = plan
                selectedCodexProjectIDs = Set(plan.projects.map(\.id))
                selectedCodexAgentIDs = Set(plan.agents.candidates.compactMap { candidate in
                    candidate.profile.sourceURL == nil ? candidate.id : nil
                })
            } else if let warning = plan.warnings.first {
                errorMessage = "\(warning) Checked \(countLabel(plan.scannedProjectCount, singular: "project")) and \(countLabel(plan.scannedAgentCount, singular: "agent"))."
            } else {
                notice = "Codex projects are up to date. Checked \(countLabel(plan.scannedProjectCount, singular: "project")), \(countLabel(plan.scannedAgentCount, singular: "agent")), and \(countLabel(plan.tasks.count, singular: "task"))."
            }
        }
    }

    /// Runs the same Codex catalog discovery used by the macOS review sheet
    /// without replacing the sheet's device-local selection state. Remote
    /// callers retain the returned plan inside their purpose-bound review.
    public func prepareRemoteCodexCatalogDiscovery() async -> CodexCatalogSyncPlan? {
        var result: CodexCatalogSyncPlan?
        await perform {
            let plan = try await discoverCodexCatalogSync()
            codexTasks = plan.tasks
            codexActivityRefresh = .fresh(at: .now)
            limitedProjectAccessCount = plan.limitedProjectAccessCount
            try await refreshGraph()
            result = plan
        }
        return result
    }

    public func applyRemoteCodexCatalogSync(
        projectIDs: Set<ProjectID>,
        agentIDs: Set<AgentID>,
        plan: CodexCatalogSyncPlan
    ) async -> Bool {
        guard !isBusy else { return false }
        let availableProjectIDs = Set(plan.projects.map(\.id))
        let availableAgentIDs = Set(plan.agents.candidates.compactMap { candidate in
            candidate.profile.sourceURL == nil ? candidate.id : nil
        })
        guard projectIDs.isSubset(of: availableProjectIDs),
              agentIDs.isSubset(of: availableAgentIDs) else { return false }
        let selectedProjects = plan.projects.filter { projectIDs.contains($0.id) }
        let allowedProjectIDs = Set(lab.projects.map(\.id)).union(selectedProjects.map(\.id))
        let selectedAgents = plan.agents.candidates.filter { candidate in
            guard agentIDs.contains(candidate.id) else { return false }
            switch candidate.profile.scope {
            case .global, .union:
                return true
            case let .project(projectID):
                return allowedProjectIDs.contains(projectID)
            }
        }
        guard selectedAgents.count == agentIDs.count else { return false }
        let wasEmpty = lab.projects.isEmpty

        await perform {
            try await syncCodexCatalog(projects: selectedProjects, agents: selectedAgents)
            let verb = wasEmpty ? "Imported" : "Refreshed"
            notice = "\(verb) \(countLabel(selectedProjects.count, singular: "project")) and \(countLabel(selectedAgents.count, singular: "agent")) from Codex."
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            systemHealth = mergedHealth(await checkSystemHealth(), account: codexAccount)
            try await refreshGraph()
        }
        return errorMessage == nil
    }

    public func setCodexProject(_ id: ProjectID, selected: Bool) {
        if selected {
            selectedCodexProjectIDs.insert(id)
            guard let plan = codexSyncPlan else { return }
            selectedCodexAgentIDs.formUnion(plan.agents.candidates.compactMap { candidate in
                guard case let .project(projectID) = candidate.profile.scope,
                      projectID == id,
                      candidate.profile.sourceURL == nil else { return nil }
                return candidate.id
            })
        } else {
            selectedCodexProjectIDs.remove(id)
            guard !lab.projects.contains(where: { $0.id == id }),
                  let plan = codexSyncPlan else { return }
            selectedCodexAgentIDs.subtract(plan.agents.candidates.compactMap { candidate in
                guard case let .project(projectID) = candidate.profile.scope,
                      projectID == id else { return nil }
                return candidate.id
            })
        }
    }

    public func setCodexAgent(_ id: AgentID, selected: Bool) {
        if selected {
            selectedCodexAgentIDs.insert(id)
        } else {
            selectedCodexAgentIDs.remove(id)
        }
    }

    public func clearCodexSyncSelection() {
        selectedCodexProjectIDs.removeAll()
        selectedCodexAgentIDs.removeAll()
    }

    public func selectAllCodexProjectChanges() {
        guard let plan = codexSyncPlan else { return }
        for candidate in plan.projects {
            setCodexProject(candidate.id, selected: true)
        }
    }

    public func cancelCodexSync() {
        codexSyncPlan = nil
        selectedCodexProjectIDs = []
        selectedCodexAgentIDs = []
    }

    public func applyCodexSync() async {
        guard let plan = codexSyncPlan else { return }
        if continuityStore != nil {
            await commitClientAdmin(
                .syncCodexCatalog(
                    projectIDs: selectedCodexProjectIDs.sorted { $0.rawValue < $1.rawValue },
                    agentIDs: selectedCodexAgentIDs.sorted { $0.rawValue < $1.rawValue }
                ),
                successNotice: "Applied the reviewed Codex catalog changes."
            )
            if errorMessage == nil {
                codexSyncPlan = nil
                selectedCodexProjectIDs = []
                selectedCodexAgentIDs = []
            }
            return
        }
        let selectedProjects = plan.projects.filter { selectedCodexProjectIDs.contains($0.id) }
        let allowedProjectIDs = Set(lab.projects.map(\.id)).union(selectedProjects.map(\.id))
        let selectedAgents = plan.agents.candidates.filter { candidate in
            guard selectedCodexAgentIDs.contains(candidate.id) else { return false }
            switch candidate.profile.scope {
            case .global, .union:
                return true
            case let .project(projectID):
                return allowedProjectIDs.contains(projectID)
            }
        }
        let wasEmpty = lab.projects.isEmpty

        await perform {
            try await syncCodexCatalog(projects: selectedProjects, agents: selectedAgents)
            codexSyncPlan = nil
            selectedCodexProjectIDs = []
            selectedCodexAgentIDs = []
            let verb = wasEmpty ? "Imported" : "Refreshed"
            notice = "\(verb) \(countLabel(selectedProjects.count, singular: "project")) and \(countLabel(selectedAgents.count, singular: "agent")) from Codex."
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            systemHealth = mergedHealth(await checkSystemHealth(), account: codexAccount)
            try await refreshGraph()
        }
    }

    public func cancelImport() {
        guard !isRegisteringProjects else { return }
        replansAfterFolderAuthorization = false
        importCandidates = []
        selectedImportIDs = []
        clientImportURLsByID = [:]
        projectImportError = nil
    }

    public func registerSelectedProjects() async {
        guard !isRegisteringProjects, !selectedImportIDs.isEmpty else { return }
        isRegisteringProjects = true
        projectImportError = nil
        defer { isRegisteringProjects = false }
        if continuityStore != nil {
            guard let desktopHostAdministration else {
                projectImportError = "The local host authorization channel is unavailable."
                return
            }
            let urls = selectedImportIDs.compactMap { clientImportURLsByID[$0] }
            guard urls.count == selectedImportIDs.count, !urls.isEmpty else {
                projectImportError = "Choose the project folders again before importing."
                return
            }
            do {
                let importedCount = selectedImportIDs.count
                let isRefresh = selectedProjectImportIsRefresh
                try await desktopHostAdministration.registerProjects(
                    at: urls,
                    selectedProjectIDs: selectedImportIDs
                )
                importCandidates = []
                selectedImportIDs = []
                clientImportURLsByID = [:]
                notice = "\(isRefresh ? "Refreshed" : "Registered") \(countLabel(importedCount, singular: "project folder")) from the review."
                if let continuityStore {
                    if replansAfterFolderAuthorization {
                        await continuityStore.refreshProjection()
                    } else {
                        Task { await continuityStore.refreshProjection() }
                    }
                }
                await replanAfterFolderAuthorizationIfNeeded()
            } catch {
                projectImportError = error.localizedDescription
            }
            return
        }
        await perform {
            let selected = importCandidates.filter { selectedImportIDs.contains($0.id) }
            let isRefresh = selectedProjectImportIsRefresh
            try await registerProjects(candidates: selected)
            importCandidates = []
            selectedImportIDs = []
            let detectedAgentCount = selected.reduce(0) { $0 + $1.detectedAgents.count }
            let verb = isRefresh ? "Refreshed" : "Imported"
            let projectMessage = "\(verb) \(countLabel(selected.count, singular: "project"))."
            notice = detectedAgentCount == 0
                ? projectMessage
                : "\(projectMessage) Review \(detectedAgentCount) detected agent \(detectedAgentCount == 1 ? "definition" : "definitions") separately before trusting them."
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
        }
        projectImportError = errorMessage
        if errorMessage == nil { await replanAfterFolderAuthorizationIfNeeded() }
    }

    private func replanAfterFolderAuthorizationIfNeeded() async {
        guard replansAfterFolderAuthorization else { return }
        replansAfterFolderAuthorization = false
        guard hasPromptContent else { return }
        // Still reviewed (never auto-started), but in the conversation's plan
        // card rather than a second copy in the full review sheet.
        await prepareRoutingPlan(alwaysReview: true, presentsFullReview: false)
    }

    public func createProject(_ draft: NewProjectDraft) async -> Bool {
        if continuityStore != nil {
            guard let desktopHostAdministration else {
                errorMessage = "The local host authorization channel is unavailable."
                return false
            }
            do {
                try await desktopHostAdministration.createProject(draft)
                notice = "Created \(draft.name) with its reviewed provider and agent configuration."
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        var succeeded = false
        await perform {
            let created = try await createProjectUseCase(draft)
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            systemHealth = mergedHealth(await checkSystemHealth(), account: codexAccount)
            try await refreshGraph()

            let agentDetail = created.agents.isEmpty
                ? ""
                : " with \(countLabel(created.agents.count, singular: "project agent"))"
            let providerNames = created.providerConfiguration.providerIDs
                .sorted()
                .map(\.displayName)
                .joined(separator: ", ")
            let providerDetail = providerNames.isEmpty
                ? " with providers left for later"
                : " linked to \(providerNames)"
            let collaborationDetail = created.providerCollaborationSet == nil
                ? ""
                : " as one collaboration set"
            let handoffDetail = created.handoffLinks.isEmpty
                ? ""
                : " with \(countLabel(created.handoffLinks.count, singular: "reviewed handoff path"))"
            let linkDetail = created.projectGroup.map { " and linked it in \($0.name)" } ?? ""
            notice = "Created \(created.project.name)\(agentDetail)\(providerDetail)\(collaborationDetail)\(handoffDetail)\(linkDetail)."
            succeeded = true
        }
        return succeeded
    }

    public func refreshProjectGitBranches(
        _ projectID: ProjectID,
        reportsFailure: Bool = true
    ) async {
        guard projectGitBranchBusyIDs.insert(projectID).inserted else { return }
        defer { projectGitBranchBusyIDs.remove(projectID) }
        projectGitBranchUnavailableIDs.remove(projectID)
        do {
            projectGitBranches[projectID] = try await inspectProjectGitBranches(
                projectID: projectID
            )
            projectGitBranchFailureReasons.removeValue(forKey: projectID)
        } catch {
            projectGitBranches.removeValue(forKey: projectID)
            projectGitBranchUnavailableIDs.insert(projectID)
            projectGitBranchFailureReasons[projectID] = error.localizedDescription
            if reportsFailure {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Keeps the project Map/List branch labels current without turning a
    /// background read-only inspection failure into a blocking alert. The
    /// Projects library retains its explicit, actionable failure reporting.
    public func refreshProjectGitBranchesForDisplay() async {
        let projectIDs = lab.projects
            .filter(\.isGitRepository)
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
        for projectID in projectIDs {
            guard !Task.isCancelled else { return }
            await refreshProjectGitBranches(projectID, reportsFailure: false)
        }
    }

    public func inspectProjectGitBranches(
        projectID: ProjectID
    ) async throws -> ProjectGitBranchSnapshot {
        if let continuityStore {
            guard let discovery = await continuityStore.projectGitBranches(for: projectID) else {
                throw GADHostIPCClientError.hostUnavailable(
                    continuityStore.lastClientErrorMessage
                        ?? "The background host could not inspect this project's Git branches."
                )
            }
            return ProjectGitBranchSnapshot(
                projectID: discovery.projectID,
                currentBranch: discovery.currentBranch,
                localBranches: discovery.localBranches,
                hasUncommittedChanges: discovery.hasUncommittedChanges
            )
        }
        guard let inspectProjectGitBranchesUseCase else {
            throw GADHostIPCClientError.hostUnavailable(
                "Git branch inspection is unavailable."
            )
        }
        return try await inspectProjectGitBranchesUseCase(projectID: projectID)
    }

    public func switchProjectGitBranch(
        _ approval: ProjectGitBranchSwitchApproval
    ) async -> Bool {
        guard projectGitBranchBusyIDs.insert(approval.projectID).inserted else { return false }
        defer { projectGitBranchBusyIDs.remove(approval.projectID) }
        do {
            let snapshot = try await applyProjectGitBranchSwitch(approval)
            projectGitBranches[approval.projectID] = snapshot
            notice = "Switched to \(approval.destinationBranch). Goby did not stash, reset, merge, or delete any work."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func applyProjectGitBranchSwitch(
        _ approval: ProjectGitBranchSwitchApproval
    ) async throws -> ProjectGitBranchSnapshot {
        if continuityStore != nil {
            guard let desktopHostAdministration else {
                throw GADHostIPCClientError.hostUnavailable(
                    "The local host authorization channel is unavailable."
                )
            }
            return try await desktopHostAdministration.switchProjectGitBranch(
                approval: approval
            )
        }
        guard let switchProjectGitBranchUseCase else {
            throw GADHostIPCClientError.hostUnavailable(
                "Git branch switching is unavailable."
            )
        }
        return try await switchProjectGitBranchUseCase(approval: approval)
    }

    public func eligibleHandoffLinks(
        from assignment: AgentAssignment,
        in run: RunRecord
    ) -> [AgentHandoffLink] {
        lab.agentHandoffLinks.filter { link in
            guard link.isEnabled,
                  link.mode == .suggestOnly,
                  link.source.providerID == assignment.providerID,
                  link.source.agentID == assignment.agentID,
                  link.source.projectID == assignment.projectID,
                  run.providerBindingSnapshot.contains(where: { $0.id == link.source.bindingID }),
                  handoffTrigger(for: assignment.status, allowed: link.triggers) != nil else { return false }
            return true
        }
        .sorted {
            if $0.destination.providerID != $1.destination.providerID {
                return $0.destination.providerID < $1.destination.providerID
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func isHandoffDestinationAvailable(_ link: AgentHandoffLink) -> Bool {
        availableProviderIDs.contains(link.destination.providerID)
            && lab.providerBindings.contains(where: {
                $0.id == link.destination.bindingID && $0.state == .configured
            })
            && lab.agents.contains(where: {
                $0.id == link.destination.agentID && $0.isEnabled
            })
    }

    public func existingHandoff(
        for link: AgentHandoffLink,
        sourceAssignmentID: AssignmentID,
        runID: RunID
    ) -> HandoffRecord? {
        lab.handoffs.first {
            $0.bundle.linkID == link.id
                && $0.bundle.runID == runID
                && $0.bundle.sourceAssignmentID == sourceAssignmentID
        }
    }

    public func prepareAndQueueHandoff(
        _ link: AgentHandoffLink,
        from assignment: AgentAssignment,
        in run: RunRecord
    ) async -> Bool {
        if let continuityStore {
            let acknowledgement = await continuityStore.dispatchManualHandoff(
                runID: run.id,
                sourceAssignmentID: assignment.id,
                linkID: link.id
            )
            return acceptClientAcknowledgement(
                acknowledgement,
                successNotice: "Queued a fresh read-only destination run. It does not inherit source permissions, attachments, Git actions, or unfinished work."
            )
        }
        guard let prepareManualHandoff, let dispatchManualHandoff,
              let trigger = handoffTrigger(for: assignment.status, allowed: link.triggers),
              isHandoffDestinationAvailable(link) else {
            errorMessage = GobyApplicationError.providerUnavailable(
                link.destination.providerID
            ).localizedDescription
            return false
        }
        var succeeded = false
        await perform {
            let prepared = try await prepareManualHandoff(PrepareManualHandoffRequest(
                runID: run.id,
                linkID: link.id,
                sourceAssignmentID: assignment.id,
                trigger: trigger,
                sourceOutcomeSummary: handoffOutcomeSummary(for: assignment.status),
                completedSteps: assignment.status == .completed
                    ? ["The source provider reported that its assigned work completed."]
                    : [],
                unresolvedWork: assignment.status == .completed
                    ? []
                    : ["Review the source result and continue the requested handoff purpose."],
                knownRisks: assignment.status == .failed
                    ? ["The source provider reported that its assignment did not complete."]
                    : [],
                requestedNextAction: link.purpose,
                workingCopyIdentity: assignment.workingDirectory?.lastPathComponent,
                parentHandoffID: assignment.handoffID
            ))
            let dispatched = try await dispatchManualHandoff(handoffID: prepared.id)
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            replaceGraphPreservingManualLayout(try await buildGraph(
                assignments: dispatched.run.assignments,
                codexTasks: codexTasks,
                providerID: selectedProviderID
            ))
            if selectedRunID == dispatched.run.id {
                selectedRunGraph = (try? await buildGraph(
                    assignments: dispatched.run.assignments,
                    providerID: selectedProviderID
                )) ?? selectedRunGraph
            }
            let destinationName = lab.agents.first(where: {
                $0.id == link.destination.agentID
            })?.name ?? link.destination.agentID.rawValue
            notice = "Queued a fresh read-only run for \(destinationName) on \(link.destination.providerID.displayName). It does not inherit source permissions, attachments, Git actions, or unfinished work. Start it when ready."
            succeeded = true
        }
        return succeeded
    }

    private func handoffOutcomeSummary(for status: AgentStatus) -> String {
        switch status {
        case .completed: "The source assignment completed."
        case .failed: "The source assignment failed."
        case .paused: "The source assignment paused before completion."
        case .waitingForApproval: "The source assignment stopped for a separate approval."
        default: "The source assignment reached a reviewed handoff checkpoint."
        }
    }

    private func handoffTrigger(
        for status: AgentStatus,
        allowed: Set<HandoffTrigger>
    ) -> HandoffTrigger? {
        let candidates: [HandoffTrigger] = switch status {
        case .completed: [.success, .checkpoint]
        case .failed: [.failure, .blockage, .checkpoint]
        case .paused, .waitingForApproval: [.blockage, .checkpoint]
        case .available, .queued, .working, .cancelled: []
        }
        return candidates.first(where: allowed.contains)
    }

    public func removeProject(_ id: ProjectID) async {
        guard let project = lab.projects.first(where: { $0.id == id }) else {
            errorMessage = GobyApplicationError.unknownProject(id).localizedDescription
            return
        }
        let scopedAgentCount = lab.agents.filter { agent in
            if case let .project(projectID) = agent.scope { return projectID == id }
            return false
        }.count

        if continuityStore != nil {
            await commitClientAdmin(
                .removeProject(id),
                successNotice: "Removed \(project.name) from Goby. Its folder and provider definitions were not changed."
            )
            return
        }

        await perform {
            try await removeProjectUseCase(project: project)
            promptProjectIDs.remove(id)
            promptAgentTargets = Set(promptAgentTargets.filter { $0.projectID != id })
            if proposedPlan?.routes.contains(where: { $0.projectID == id }) == true {
                proposedPlan = nil
            }
            selectedImportIDs.remove(id)
            selectedCodexProjectIDs.remove(id)

            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            systemHealth = mergedHealth(await checkSystemHealth(), account: codexAccount)
            try await refreshGraph()
            if let selectedRunID,
               let selectedRun = runs.first(where: { $0.id == selectedRunID }) {
                selectedRunGraph = (try? await buildGraph(
                    assignments: selectedRun.assignments,
                    providerID: selectedProviderID
                )) ?? .empty
            }

            let agentDetail = scopedAgentCount == 0
                ? ""
                : " and \(countLabel(scopedAgentCount, singular: "project agent"))"
            notice = "Removed \(project.name)\(agentDetail) from Goby. Its folder and Codex definitions were not changed; import it again at any time."
        }
    }

    public func saveProjectGroup(
        id: ProjectGroupID?,
        name: String,
        members: [ProjectGroupMember]
    ) async -> Bool {
        if let continuityStore {
            let acknowledgement = await continuityStore.saveProjectGroup(
                id: id,
                name: name,
                members: members
            )
            return acceptClientAcknowledgement(
                acknowledgement,
                successNotice: id == nil ? "Linked the selected projects." : "Updated the project group."
            )
        }
        var succeeded = false
        await perform {
            let existing = id.flatMap { id in lab.projectGroups.first { $0.id == id } }
            let group = ProjectGroup(
                id: id ?? .make(),
                name: name,
                members: members,
                createdAt: existing?.createdAt ?? .now
            )
            let saved = try await saveProjectGroupUseCase(group)
            let (updatedLab, updatedRuns) = try await loadDashboard()
            self.lab = updatedLab
            self.runs = updatedRuns
            try await refreshGraph()
            notice = existing == nil
                ? "Linked \(saved.members.count) projects as \(saved.name)."
                : "Updated \(saved.name)."
            succeeded = true
        }
        return succeeded
    }

    public func removeProjectGroup(_ id: ProjectGroupID) async {
        guard let group = lab.projectGroups.first(where: { $0.id == id }) else {
            errorMessage = GobyApplicationError.unknownProjectGroup(id).localizedDescription
            return
        }
        if let continuityStore {
            _ = acceptClientAcknowledgement(
                await continuityStore.deleteProjectGroup(id),
                successNotice: "Unlinked \(group.name). Its project folders remain registered and unchanged."
            )
            return
        }
        await perform {
            try await removeProjectGroupUseCase(id: id)
            if promptProjectGroupID == id { promptProjectGroupID = nil }
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            notice = "Unlinked \(group.name). Its \(group.members.count) project folders remain registered and unchanged."
        }
    }

    public func discoverExistingAgents() async {
        if let continuityStore {
            var candidates: [GADAgentImportCandidateProjection] = []
            var offset = 0
            repeat {
                guard let page = await continuityStore.agentCatalogDiscovery(offset: offset) else {
                    errorMessage = "The host could not inspect the current agent definitions."
                    return
                }
                candidates.append(contentsOf: page.candidates)
                guard let next = page.nextOffset else { break }
                offset = next
            } while true

            clientAgentReviewHashes = Dictionary(
                uniqueKeysWithValues: candidates.map { ($0.id, $0.reviewHash) }
            )
            agentImportPlan = AgentImportPlan(
                candidates: candidates.map(clientAgentCandidate),
                suggestions: []
            )
            agentRestructurePreviews = []
            selectedAgentImportIDs = []
            if candidates.isEmpty {
                notice = "No agent definitions were found in the host-authorized locations."
            }
            return
        }
        await perform {
            let plan = try await discoverAgents()
            agentImportPlan = plan
            agentRestructurePreviews = try await previewAgentRestructure(candidates: plan.candidates)
            selectedAgentImportIDs = []
            if plan.candidates.isEmpty {
                notice = "No Codex agent definitions were found in the global or registered-project agent folders."
            }
        }
    }

    /// Runs the same definition discovery and restructure preview used by the
    /// macOS review sheet. The remote layer projects only bounded, redacted
    /// semantic fields; file URLs and raw configuration never leave the Mac.
    public func prepareRemoteAgentCatalogDiscovery() async -> (
        plan: AgentImportPlan,
        restructurePreviews: [AgentDefinitionChangePreview]
    )? {
        var result: (
            plan: AgentImportPlan,
            restructurePreviews: [AgentDefinitionChangePreview]
        )?
        await perform {
            let plan = try await discoverAgents()
            let previews = try await previewAgentRestructure(candidates: plan.candidates)
            result = (plan: plan, restructurePreviews: previews)
        }
        return result
    }

    public func applyRemoteAgentImport(
        agentIDs: Set<AgentID>,
        plan: AgentImportPlan,
        restructurePreviews: [AgentDefinitionChangePreview],
        applyFileChanges: Bool
    ) async -> Bool {
        guard !isBusy, !agentIDs.isEmpty else { return false }
        let availableIDs = Set(plan.candidates.map(\.id))
        guard agentIDs.isSubset(of: availableIDs) else { return false }
        if applyFileChanges {
            errorMessage = "Restructuring executable agent files requires a complete local review on the Mac."
            return false
        }
        var succeeded = false
        await perform {
            let selected = plan.candidates
                .filter { agentIDs.contains($0.id) }
                .map(instructionOnlyImportCandidate)
            try await registerAgents(candidates: selected)
            notice = selected.count == 1
                ? "Imported 1 instruction-only agent copy."
                : "Imported \(selected.count) instruction-only agent copies."
            let (updatedLab, updatedRuns) = try await loadDashboard()
            lab = updatedLab
            runs = updatedRuns
            try await refreshGraph()
            succeeded = true
        }
        return succeeded
    }

    public func cancelAgentImport() {
        agentImportPlan = nil
        agentRestructurePreviews = []
        selectedAgentImportIDs = []
    }

    public func registerSelectedAgents(applyFileChanges: Bool = false) async {
        guard let plan = agentImportPlan else { return }
        if continuityStore != nil {
            guard !applyFileChanges else {
                errorMessage = "Restructuring executable agent files requires a complete local review on the Mac."
                return
            }
            let selections = selectedAgentImportIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                clientAgentReviewHashes[id].map { GADAgentImportSelection(agentID: id, reviewHash: $0) }
            }
            guard selections.count == selectedAgentImportIDs.count, !selections.isEmpty else {
                errorMessage = "Refresh the agent review before applying this selection."
                return
            }
            await commitClientAdmin(
                .importAgents(selections),
                successNotice: "Imported instruction-only agent copies. Executable source configuration stayed on the host."
            )
            if errorMessage == nil {
                agentImportPlan = nil
                agentRestructurePreviews = []
                selectedAgentImportIDs = []
                clientAgentReviewHashes = [:]
            }
            return
        }
        await perform {
            var selected = plan.candidates.filter { selectedAgentImportIDs.contains($0.id) }
            if applyFileChanges {
                let changes = agentRestructurePreviews.filter { selectedAgentImportIDs.contains($0.agentID) }
                try await applyAgentRestructure(changes)
                do {
                    try await saveAgentRestructureHistory(changes)
                    lastAppliedAgentRestructure = changes
                } catch {
                    try? await undoAgentRestructure(changes)
                    throw error
                }
                let changeByAgent = Dictionary(uniqueKeysWithValues: changes.map { ($0.agentID, $0) })
                selected = selected.map { candidate in
                    guard let change = changeByAgent[candidate.id] else { return candidate }
                    let profile = AgentProfile(
                        id: candidate.profile.id,
                        name: candidate.profile.name,
                        summary: candidate.profile.summary,
                        instructions: candidate.profile.instructions,
                        capabilities: candidate.profile.capabilities,
                        scope: candidate.profile.scope,
                        sourceURL: change.targetURL,
                        toolPreset: candidate.profile.toolPreset,
                        reviewedDefinitionDigest: DefinitionReviewDigest.sha256(change.proposedContents),
                        codexRegistrationKey: candidate.profile.codexRegistrationKey,
                        isEnabled: candidate.profile.isEnabled
                    )
                    return AgentImportCandidate(
                        profile: profile,
                        configurationPreview: change.proposedContents,
                        evidence: candidate.evidence
                    )
                }
            }
            try await registerAgents(candidates: selected)
            agentImportPlan = nil
            agentRestructurePreviews = []
            selectedAgentImportIDs = []
            if applyFileChanges {
                let agentCount = selected.count == 1 ? "1 agent" : "\(selected.count) agents"
                notice = "Imported \(agentCount) and archived the original definitions. Undo remains available in Agents."
            } else {
                notice = selected.count == 1 ? "Imported 1 agent." : "Imported \(selected.count) agents."
            }
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
        }
    }

    public func undoLastAgentRestructure() async {
        let changes = lastAppliedAgentRestructure
        guard !changes.isEmpty else { return }
        if continuityStore != nil {
            await commitClientAdmin(
                .undoLastAgentRestructure,
                successNotice: "Restored the original agent definition files. Catalog history remains intact."
            )
            return
        }
        await perform {
            try await undoAgentRestructure(changes)
            lastAppliedAgentRestructure = []
            try await saveAgentRestructureHistory([])
            notice = "Restored the original agent definition files. Catalog history remains intact."
        }
    }

    public func addAgent(
        name: String,
        summary: String,
        instructions: String? = nil,
        capabilities: Set<AgentCapability>,
        scope: AgentScope,
        toolPreset: AgentToolPreset? = nil
    ) async -> Bool {
        if continuityStore != nil {
            let projectedScope: GADAgentScopeProjection = switch scope {
            case .global: .global
            case .union: .union
            case let .project(id): .project(id)
            }
            let projectID: ProjectID? = switch scope {
            case .global, .union: nil
            case let .project(id): id
            }
            await commitClientAdmin(
                .saveAgent(.init(
                    agentID: nil,
                    projectID: projectID,
                    scope: projectedScope,
                    name: name,
                    summary: summary,
                    instructions: instructions,
                    capabilities: capabilities.sorted { $0.rawValue < $1.rawValue },
                    toolPreset: toolPreset
                )),
                successNotice: "Created \(name) for future routing and provider sessions."
            )
            return errorMessage == nil
        }
        var succeeded = false
        await perform {
            let agent = try await createAgent(
                name: name,
                summary: summary,
                instructions: instructions,
                capabilities: capabilities,
                scope: scope,
                toolPreset: toolPreset
            )
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            notice = "Created \(agent.name) in Codex. It is ready for routing and future subagent sessions."
            succeeded = true
        }
        return succeeded
    }

    /// The run shown in the active thread, preferring the full local snapshot
    /// (with typed activity) over the path-free projection.
    public var activeThreadRun: RunRecord? {
        guard case let .run(id) = activeThread else { return nil }
        return localRunSnapshots[id] ?? runs.first(where: { $0.id == id })
    }

    /// Opens Runs limited to the conversations that touched one project.
    public func showConversations(in projectID: ProjectID) {
        runsProjectFilter = projectID
        destination = .runs
    }

    /// Shows a run as a conversation on Home instead of a modal or the Runs page.
    public func openThread(_ runID: RunID) {
        markActivityRead(runID)
        activeThread = .run(runID)
        selectedRunID = nil
        destination = .home
        if continuityStore != nil {
            Task { @MainActor [weak self] in await self?.refreshLocalRunSnapshot(runID) }
        }
    }

    /// What Send does from the composer while a conversation is open.
    public var composerIntent: ComposerIntent {
        if activeThread == .temporaryChat { return .temporaryChat }
        guard let run = activeThreadRun else { return .newRequest }
        let working = run.assignments.filter { $0.status == .working }
        if run.status == .running, !working.isEmpty {
            // Mid-run steering is supported by the Codex runtime only.
            return working.allSatisfy { $0.providerID == .codex } ? .steer(run.id) : .newRequest
        }
        return run.status.isFinished ? .continueThread(run.id) : .newRequest
    }

    static let previousAnswerAttachmentName = "Previous answer"

    /// Sends the composer text according to `composerIntent`.
    public func submitComposer(alwaysReview: Bool) async {
        switch composerIntent {
        case let .steer(runID):
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if await followUp(runID: runID, text: text) {
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == text { prompt = "" }
                notice = "Sent to the running agent."
            }
        case let .continueThread(runID):
            // A follow-up keeps the same projects and carries the answer it
            // continues from, bounded, as an ordinary reviewed attachment.
            if let run = activeThreadRun, run.id == runID {
                if promptProjectIDs.isEmpty, promptProjectGroupID == nil {
                    promptProjectIDs = Set(run.plan.routes.map(\.projectID))
                }
                if let answer = run.conversationAnswer,
                   !promptAttachments.contains(where: { $0.displayName == Self.previousAnswerAttachmentName }) {
                    addPromptSnippet(answer, displayName: Self.previousAnswerAttachmentName)
                }
            }
            await prepareRoutingPlan(alwaysReview: alwaysReview)
            // Keep the conversation's Run uninterrupted choice.
            if uninterruptedRunIDs.contains(runID) {
                if let plan = proposedPlan {
                    uninterruptedDefaultPlanID = plan.id
                } else if case let .run(startedID)? = activeThread, startedID != runID {
                    rememberUninterruptedRun(startedID)
                }
            }
        case .newRequest:
            await prepareRoutingPlan(alwaysReview: alwaysReview)
        case .temporaryChat:
            let text = prompt
            if await askTemporaryChat(text), prompt == text { prompt = "" }
        }
    }

    // MARK: - Temporary chat

    /// Whether the paired host answers temporary chat. The local host always
    /// does when it was composed with a chat service.
    public var supportsTemporaryChat: Bool {
        if let continuityStore { return continuityStore.session?.supportsTemporaryChat == true }
        return temporaryChatService != nil
    }

    /// Opens the temporary chat on Home. The composer then asks it questions
    /// instead of preparing a project request.
    public func openTemporaryChat() {
        guard supportsTemporaryChat else {
            errorMessage = "Update Goby's background host to use temporary chat."
            return
        }
        proposedPlan = nil
        showsFullPlanReview = false
        activeThread = .temporaryChat
    }

    /// Asks the current chat, or starts one. Returns whether the host accepted it.
    @discardableResult
    public func askTemporaryChat(_ text: String) async -> Bool {
        guard TemporaryChat.normalizedQuestion(text) != nil else { return false }
        guard temporaryChat?.canAsk ?? true else {
            errorMessage = TemporaryChatError.answering.errorDescription
            return false
        }
        isAskingTemporaryChat = true
        defer { isAskingTemporaryChat = false }
        // A chat continues on its own provider; a new one uses the current plane.
        let providerID = temporaryChat?.providerID ?? selectedProviderID
        let chatID = temporaryChat?.providerID == providerID ? temporaryChat?.id : nil
        // The picked model belongs to the current plane's catalog.
        let model = providerID == selectedProviderID ? promptModelID : nil
        if let continuityStore {
            return acceptClientAcknowledgement(
                await continuityStore.askTemporaryChat(text, chatID: chatID, model: model, providerID: providerID),
                successNotice: nil
            )
        }
        do {
            try await hostAskTemporaryChat(text, chatID: chatID, model: model, providerID: providerID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Ends and forgets the chat, then leaves it.
    public func endTemporaryChat() async {
        if let chatID = temporaryChat?.id {
            if let continuityStore {
                _ = acceptClientAcknowledgement(
                    await continuityStore.endTemporaryChat(chatID),
                    successNotice: "Temporary chat ended and cleared."
                )
            } else {
                await hostEndTemporaryChat(chatID)
                notice = "Temporary chat ended and cleared."
            }
        }
        if activeThread == .temporaryChat { activeThread = nil }
    }

    /// Host side of a paired client's question.
    public func hostAskTemporaryChat(
        _ text: String,
        chatID: TemporaryChatID?,
        model: String?,
        providerID: AgentProviderID = .codex
    ) async throws {
        guard let temporaryChatService else {
            throw TemporaryChatError.unavailable("Temporary chat is not available on this Mac.")
        }
        temporaryChat = try await temporaryChatService.ask(text, in: chatID, model: model, providerID: providerID)
        notifyStateDidChange()
    }

    /// Host side of ending a chat. Unknown chats are ignored.
    public func hostEndTemporaryChat(_ chatID: TemporaryChatID) async {
        await temporaryChatService?.end(chatID)
        if temporaryChat?.id == chatID {
            temporaryChat = nil
            notifyStateDidChange()
        }
    }

    private func observeTemporaryChat() {
        guard let temporaryChatService else { return }
        temporaryChatObservation = Task { [weak self] in
            for await chat in await temporaryChatService.updates() {
                guard let self, !Task.isCancelled else { return }
                self.temporaryChat = chat
                self.notifyStateDidChange()
            }
        }
    }

    /// Returns Home to the map or list. The run keeps going.
    public func closeThread() {
        activeThread = nil
        showsFullPlanReview = false
        runPreview.dismiss()
    }

    private func beginPendingThread() {
        activeThread = .pending(PendingConversation(
            prompt: promptTextForRouting,
            providerID: selectedProviderID,
            projectIDs: promptProjectIDs.sorted { $0.rawValue < $1.rawValue },
            startedAt: .now
        ))
    }

    /// Clears a thread whose request never became a plan or run.
    private func abandonPendingThreadIfNeeded() {
        if case .pending = activeThread, proposedPlan == nil { activeThread = nil }
    }

    /// Starts the one-off path from a project's context menu. The current
    /// draft text remains in the composer until the user submits it.
    public func beginQuickTask(in projectID: ProjectID) {
        guard lab.projects.contains(where: { $0.id == projectID }), proposedPlan == nil else { return }
        if quickTaskAgentID != nil { cancelQuickTask() }
        quickTaskProjectID = projectID
        promptProjectGroupID = nil
        promptProjectIDs = [projectID]
        promptAgentTargets = []
        destination = .home
        notice = "Quick task selected. Enter the task and review its scope to create a temporary agent."
        notifyStateDidChange()
    }

    /// Problems Goby can already see that would make this plan fail or stall.
    public func readinessIssues(for plan: RoutingPlan) -> [RunReadinessIssue] {
        RunReadiness.issues(
            for: plan,
            lab: lab,
            providerAccounts: providerAccounts,
            runs: runs,
            // The path-free host projection carries no folder identities; only
            // judge them once the local catalog details have loaded.
            projectIdentitiesKnown: continuityStore == nil || localCatalogSnapshot != nil
        )
    }

    public func resolveReadinessIssue(_ action: RunReadinessIssue.Action) {
        dismissPlan()
        switch action {
        case .openProviderSettings:
            destination = .settings
        case .switchToCodex:
            selectProviderPlane(.codex)
            notice = "Switched to Codex. Your request is unchanged; send it again when ready."
        case .reauthorizeProjects:
            replansAfterFolderAuthorization = hasPromptContent
            // Present the folder panel only once the plan's cancellation has
            // finished: a presentation change during it tore the panel down.
            Task { @MainActor [weak self] in
                await Task.yield()
                for _ in 0..<50 {
                    guard let self, self.isCancellingPlan || self.proposedPlan != nil else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(150))
                self?.showsProjectImporter = true
            }
        }
    }

    /// A temporary agent replaces the missing specialist only when the request
    /// is scoped to that one project, so the scope never silently narrows.
    public func canUseTemporaryAgent(for suggestion: AgentCreationSuggestion) -> Bool {
        let scopedProjectIDs = promptProjectIDs.isEmpty
            ? (promptProjectGroup?.projectIDs ?? [])
            : promptProjectIDs
        return scopedProjectIDs == [suggestion.projectID]
            && lab.projects.contains(where: { $0.id == suggestion.projectID })
            && proposedPlan == nil
    }

    /// The pending plan's request sounds recurring, so the plan offers to make
    /// it an automation instead of running it once.
    public var proposedPlanSuggestsAutomation: Bool {
        proposedPlan != nil && RecurringRequestIntent.requestsSchedule(prompt)
    }

    /// The pending plan uses a temporary agent because no saved agent in the
    /// project covered the request.
    public var proposedPlanUsesTemporaryAgent: Bool {
        guard let proposedPlan else { return false }
        let temporaryIDs = Set(scopeTemporaryAgentIDs + [quickTaskAgentID].compactMap { $0 })
        return proposedPlan.routes.contains { !temporaryIDs.isDisjoint(with: $0.agentIDs) }
    }

    /// Creates one temporary agent for each selected project that has no
    /// suitable agent, and targets it, when the request spans several
    /// projects. Returns false, leaving nothing behind, if any step fails.
    private func coverMissingAgentsWithTemporaryAgents() async -> Bool {
        let suggestions = missingAgentSuggestionsForCurrentScope()
        let scopedProjectIDs = promptProjectIDs.isEmpty
            ? (promptProjectGroup?.projectIDs ?? [])
            : promptProjectIDs
        guard !suggestions.isEmpty, scopedProjectIDs.count > 1, proposedPlan == nil else { return false }
        let task = promptTextForRouting
        let providerID = selectedProviderID
        var created: [AgentID] = []
        var targets: [AgentRouteTarget] = []
        for suggestion in suggestions {
            let agentID = AgentID(rawValue: "temporary-agent-\(UUID().uuidString.lowercased())")
            guard await createTemporaryAgent(
                id: agentID,
                projectID: suggestion.projectID,
                providerID: providerID,
                task: task
            ) else {
                for id in created { _ = await retireTemporaryAgent(id) }
                return false
            }
            created.append(agentID)
            targets.append(AgentRouteTarget(providerID: providerID, agentID: agentID, projectID: suggestion.projectID))
        }
        // Keep every selected project in scope; only the uncovered ones get
        // a direct target.
        guard setPromptRecipients(
            projectIDs: scopedProjectIDs,
            agentTargets: promptAgentTargets.union(targets)
        ), missingAgentSuggestionForCurrentScope() == nil else {
            _ = setPromptRecipients(
                projectIDs: scopedProjectIDs,
                agentTargets: promptAgentTargets.subtracting(targets)
            )
            for id in created { _ = await retireTemporaryAgent(id) }
            return false
        }
        scopeTemporaryAgentIDs = created
        return true
    }

    /// Retires the multi-project temporary agents and drops their targets.
    private func retireScopeTemporaryAgents() async {
        let ids = scopeTemporaryAgentIDs
        scopeTemporaryAgentIDs = []
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        _ = setPromptRecipients(
            projectIDs: promptProjectIDs,
            agentTargets: promptAgentTargets.filter { !idSet.contains($0.agentID) }
        )
        for id in ids { _ = await retireTemporaryAgent(id) }
    }

    /// Answers "no suitable agent" by creating a task-specific temporary agent
    /// for the same project and provider, then continuing the same submission.
    public func useTemporaryAgent(for suggestion: AgentCreationSuggestion) async {
        guard canUseTemporaryAgent(for: suggestion) else { return }
        agentCreationSuggestion = nil
        if quickTaskAgentID != nil, quickTaskProjectID != suggestion.projectID { cancelQuickTask() }
        quickTaskProjectID = suggestion.projectID
        promptProjectGroupID = nil
        promptProjectIDs = [suggestion.projectID]
        promptAgentTargets = []
        await prepareRoutingPlan(alwaysReview: lastRoutingPlanRequestedReview)
    }

    public func cancelQuickTask() {
        if proposedPlan != nil {
            dismissPlan()
            return
        }
        let temporaryID = quickTaskAgentID
        quickTaskAgentID = nil
        quickTaskAgentTask = nil
        quickTaskProjectID = nil
        promptAgentTargets = []
        notifyStateDidChange()
        if let temporaryID {
            Task { _ = await retireTemporaryAgent(temporaryID) }
        }
    }

    @discardableResult
    public func createTemporaryAgent(
        id: AgentID,
        projectID: ProjectID,
        providerID: AgentProviderID,
        task: String
    ) async -> Bool {
        if let continuityStore {
            await commitClientAdmin(
                .createTemporaryAgent(.init(
                    agentID: id,
                    projectID: projectID,
                    providerID: providerID,
                    task: task
                )),
                successNotice: nil
            )
            guard errorMessage == nil else { return false }
            await continuityStore.refreshProjection()
            guard lab.agents.contains(where: { $0.id == id }) else {
                errorMessage = "The host created the quick-task agent, but its catalog update has not reached this window. Refresh before trying again."
                return false
            }
            return true
        }
        guard let createTemporaryAgentUseCase else {
            errorMessage = "Temporary agents are unavailable in this host."
            return false
        }
        var created = false
        await perform {
            _ = try await createTemporaryAgentUseCase(
                id: id, projectID: projectID, providerID: providerID, task: task
            )
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            created = true
        }
        return created
    }

    @discardableResult
    public func retireTemporaryAgent(_ id: AgentID) async -> Bool {
        guard !runs.contains(where: {
            !$0.status.isFinished && $0.agentSnapshot.contains(where: { $0.id == id })
        }) else {
            errorMessage = "This quick-task agent still has an unfinished run. Cancel or finish the run before removing it."
            return false
        }
        if continuityStore != nil {
            await commitClientAdmin(.retireTemporaryAgent(id), successNotice: nil)
            return errorMessage == nil
        }
        guard let retireTemporaryAgentUseCase else { return false }
        do {
            try await retireTemporaryAgentUseCase(id: id)
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Reclaims quick-task roles that no draft, reviewed plan, or unfinished
    /// run can use. Run snapshots retain their result after catalog retirement.
    public func retireUnusedTemporaryAgents(
        protecting additionalAgentIDs: Set<AgentID> = [],
        among candidateIDs: Set<AgentID>? = nil
    ) async {
        let draftAgentIDs = Set(promptAgentTargets.map(\.agentID))
        let plannedAgentIDs = Set(proposedPlan?.routes.flatMap(\.agentIDs) ?? [])
        let activeRunAgentIDs = Set(runs.filter { !$0.status.isFinished }
            .flatMap { $0.agentSnapshot.map(\.id) })
        let protectedAgentIDs = additionalAgentIDs
            .union(draftAgentIDs)
            .union(plannedAgentIDs)
            .union(activeRunAgentIDs)
        let unusedIDs = lab.agents.filter {
            $0.isTemporary
                && (candidateIDs == nil || candidateIDs?.contains($0.id) == true)
                && !protectedAgentIDs.contains($0.id)
        }.map(\.id)
        for id in unusedIDs {
            _ = await retireTemporaryAgent(id)
        }
    }

    public func publishAgent(_ id: AgentID) async {
        guard !lab.agents.contains(where: { $0.id == id && $0.isTemporary }) else {
            errorMessage = "Quick-task agents retire automatically and cannot be published as reusable definitions."
            return
        }
        if continuityStore != nil {
            await commitClientAdmin(
                .publishAgent(id),
                successNotice: "Activated the selected agent in Codex for future sessions."
            )
            return
        }
        await perform {
            let published = try await publishAgentToCodex(id: id)
            if case let .project(projectID) = published.scope {
                promptAgentTargets = Set(promptAgentTargets.map { target in
                    target.agentID == id
                        ? AgentRouteTarget(agentID: published.id, projectID: projectID)
                        : target
                })
            }
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            notice = "Activated \(published.name) in Codex. New sessions can use it."
        }
    }

    public func updateProviderInstructions(
        _ instructionsByBindingID: [ProviderAgentBindingID: String]
    ) async -> Bool {
        if let continuityStore {
            for (bindingID, instructions) in instructionsByBindingID.sorted(by: {
                $0.key.rawValue < $1.key.rawValue
            }) {
                guard acceptClientAcknowledgement(
                    await continuityStore.saveProviderBindingInstructions(
                        bindingID: bindingID,
                        instructions: instructions
                    ),
                    successNotice: nil
                ) else { return false }
            }
            notice = "Updated provider-specific instructions for future assignments. Existing run snapshots are unchanged."
            return true
        }
        guard let updateProviderBindingInstructions else {
            errorMessage = "Provider instruction editing is unavailable in this build."
            return false
        }
        var succeeded = false
        await perform {
            for (bindingID, instructions) in instructionsByBindingID.sorted(by: {
                $0.key.rawValue < $1.key.rawValue
            }) {
                _ = try await updateProviderBindingInstructions(
                    bindingID: bindingID,
                    instructions: instructions
                )
            }
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            notice = "Updated provider-specific instructions for future assignments. Existing run snapshots are unchanged."
            succeeded = true
        }
        return succeeded
    }

    public func saveClaudeAPIKey(_ apiKey: String) async -> Bool {
        await saveClaudeCredential(apiKey, kind: .apiKey)
    }

    public func removeClaudeAPIKey() async -> Bool {
        await removeClaudeCredential(kind: .apiKey)
    }

    /// Saves a `claude setup-token` token. Claude work bills the Pro/Max plan
    /// first and moves to the API key only while the plan's limit is reached.
    public func saveClaudeSubscriptionToken(_ token: String) async -> Bool {
        await saveClaudeCredential(token, kind: .subscriptionToken)
    }

    public func removeClaudeSubscriptionToken() async -> Bool {
        await removeClaudeCredential(kind: .subscriptionToken)
    }

    private func saveClaudeCredential(_ credential: String, kind: ProviderCredentialKind) async -> Bool {
        let label = kind == .subscriptionToken ? "Claude subscription token" : "Claude API key"
        if continuityStore != nil {
            guard await saveClientProviderCredential(credential, providerID: .claude, kind: kind) else {
                return false
            }
            setClaudeCredential(kind, configured: true)
            return true
        }
        guard let saveProviderCredential else {
            errorMessage = "Claude credential setup is unavailable in this build."
            return false
        }
        var succeeded = false
        await perform {
            try await saveProviderCredential(providerID: .claude, credential: credential, kind: kind)
            setClaudeCredential(kind, configured: true)
            let reconnected = await reconnectProvider(.claude)
            await refreshProviderSnapshots(providerIDs: [.claude])
            notice = reconnected
                ? "Saved the \(label) in this Mac's Keychain and reconnected the Claude bridge."
                : "Saved the \(label) in this Mac's Keychain. The Claude bridge still needs attention before it can run work."
            succeeded = true
        }
        return succeeded
    }

    private func removeClaudeCredential(kind: ProviderCredentialKind) async -> Bool {
        let label = kind == .subscriptionToken ? "Claude subscription token" : "Claude API key"
        if continuityStore != nil {
            guard await removeClientProviderCredential(providerID: .claude, kind: kind) else { return false }
            setClaudeCredential(kind, configured: false)
            return true
        }
        guard let removeProviderCredential else {
            errorMessage = "Claude credential setup is unavailable in this build."
            return false
        }
        var succeeded = false
        await perform {
            try await removeProviderCredential(providerID: .claude, kind: kind)
            setClaudeCredential(kind, configured: false)
            _ = await reconnectProvider(.claude)
            await refreshProviderSnapshots(providerIDs: [.claude])
            notice = "Removed Goby's \(label) from this Mac's Keychain. Project records and run history were not changed."
            succeeded = true
        }
        return succeeded
    }

    private func setClaudeCredential(_ kind: ProviderCredentialKind, configured: Bool) {
        switch kind {
        case .apiKey: claudeCredentialConfigured = configured
        case .subscriptionToken: claudeSubscriptionConfigured = configured
        }
    }

    public func saveCopilotToken(_ token: String) async -> Bool {
        if continuityStore != nil {
            return await saveClientProviderCredential(token, providerID: .githubCopilot)
        }
        guard let saveProviderCredential else {
            errorMessage = "GitHub Copilot credential setup is unavailable in this build."
            return false
        }
        var succeeded = false
        await perform {
            try await saveProviderCredential(providerID: .githubCopilot, credential: token)
            copilotCredentialConfigured = true
            let reconnected = await reconnectProvider(.githubCopilot)
            notice = reconnected
                ? "Saved the GitHub Copilot token in this Mac's Keychain and connected the Copilot bridge."
                : "Saved the GitHub Copilot token in this Mac's Keychain. The Copilot bridge still needs attention before it can run work."
            succeeded = true
        }
        return succeeded
    }

    public func removeCopilotToken() async -> Bool {
        if continuityStore != nil {
            return await removeClientProviderCredential(providerID: .githubCopilot)
        }
        guard let removeProviderCredential else {
            errorMessage = "GitHub Copilot credential setup is unavailable in this build."
            return false
        }
        var succeeded = false
        await perform {
            try await removeProviderCredential(providerID: .githubCopilot)
            copilotCredentialConfigured = false
            _ = await reconnectProvider(.githubCopilot)
            notice = "Removed Goby's GitHub Copilot token from this Mac's Keychain. Project records and run history were not changed."
            succeeded = true
        }
        return succeeded
    }

    /// Re-reads provider credential state after the signed macOS UI changes
    /// the shared Keychain item. Credential bytes never cross local IPC.
    public func providerCredentialDidChange(_ providerID: AgentProviderID) async -> Bool {
        guard continuityStore == nil else {
            errorMessage = "Provider credential refresh is available only in the authoritative host."
            return false
        }
        guard providerID == .claude || providerID == .githubCopilot else {
            errorMessage = "This provider does not use a Goby-managed credential."
            return false
        }
        guard let inspectProviderCredential else {
            errorMessage = "Provider credential inspection is unavailable in this build."
            return false
        }

        var succeeded = false
        await perform {
            var configured = try await inspectProviderCredential(providerID: providerID)
            if providerID == .claude {
                claudeCredentialConfigured = configured
                claudeSubscriptionConfigured = try await inspectProviderCredential(
                    providerID: providerID,
                    kind: .subscriptionToken
                )
                configured = configured || claudeSubscriptionConfigured
            } else {
                copilotCredentialConfigured = configured
            }
            _ = await reconnectProvider(providerID)
            await refreshProviderSnapshots(providerIDs: [providerID])
            try? await refreshGraph()
            notice = configured
                ? "Reloaded the \(providerID.displayName) credential from the host-owned Keychain."
                : "Removed the \(providerID.displayName) credential from the host-owned Keychain. Project records and run history were not changed."
            succeeded = true
        }
        return succeeded
    }

    public func deleteAgent(_ id: AgentID) async {
        guard !lab.agents.contains(where: { $0.id == id && $0.isTemporary }) else {
            errorMessage = "Cancel or finish the quick task; its temporary agent will be removed automatically."
            return
        }
        if continuityStore != nil {
            await commitClientAdmin(
                .deleteAgent(id),
                successNotice: "Deleted the selected agent and preserved its recovery archive and run history."
            )
            return
        }
        await perform {
            let record = try await deleteAgentUseCase(id: id)
            promptAgentTargets = Set(promptAgentTargets.filter { $0.agentID != id })
            lastDeletedAgent = record
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            if record.agent.codexRegistrationKey != nil {
                notice = "Deleted \(record.agent.name) from Codex and Goby. Its definition is archived and Undo is available."
            } else if record.sourceURL != nil {
                notice = "Archived \(record.agent.name)'s inactive definition and removed it from Goby. Undo is available."
            } else {
                notice = "Deleted \(record.agent.name) from Goby. Run history is preserved and Undo is available."
            }
        }
    }

    public func undoLastAgentDelete() async {
        if continuityStore != nil {
            await commitClientAdmin(
                .restoreLastDeletedAgent,
                successNotice: "Restored the most recently deleted agent."
            )
            return
        }
        await perform {
            guard let restored = try await restoreDeletedAgent() else { return }
            lastDeletedAgent = nil
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            if restored.codexRegistrationKey != nil {
                notice = "Restored \(restored.name) to Codex and Goby."
            } else if restored.sourceURL != nil {
                notice = "Restored \(restored.name)'s definition and Goby catalog entry."
            } else {
                notice = "Restored \(restored.name) to Goby."
            }
        }
    }

    public func setAgent(_ id: AgentID, enabled: Bool) async {
        guard !lab.agents.contains(where: { $0.id == id && $0.isTemporary }) else {
            errorMessage = "Quick-task agents are managed for one run and cannot be changed in the reusable agent catalog."
            return
        }
        if continuityStore != nil {
            await commitClientAdmin(
                .setAgentEnabled(agentID: id, enabled: enabled),
                successNotice: enabled
                    ? "Agent enabled for future routing."
                    : "Agent disabled for future routing; existing run snapshots are unchanged."
            )
            return
        }
        await perform {
            try await setAgentEnabled(id: id, enabled: enabled)
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            try await refreshGraph()
            notice = enabled
                ? "Agent enabled for future routing. Its Codex definition is unchanged."
                : "Agent disabled for future routing. Its Codex definition and existing run snapshots are unchanged."
        }
    }

    public func addInstructionPack(name: String, body: String, scope: InstructionScope) async -> Bool {
        await saveInstructionPack(existing: nil, name: name, body: body, scope: scope)
    }

    public func saveInstructionPack(
        existing: InstructionPack?,
        name: String,
        body: String,
        scope: InstructionScope
    ) async -> Bool {
        if let continuityStore {
            let acknowledgement = await continuityStore.saveInstruction(
                id: existing?.id,
                version: existing?.version,
                name: name,
                body: body,
                scope: scope,
                isEnabled: existing?.isEnabled ?? true
            )
            return acceptClientAcknowledgement(
                acknowledgement,
                successNotice: "Shared instruction pack saved for future matching runs."
            )
        }
        var succeeded = false
        await perform {
            let pack = InstructionPack(
                id: existing?.id ?? .make(),
                name: name,
                body: body,
                scope: scope,
                version: (existing?.version ?? 0) + 1,
                isEnabled: existing?.isEnabled ?? true
            )
            try await saveInstruction(pack)
            instructionPacks = try await loadInstructions()
            notice = "Shared instruction pack saved. Future matching runs will snapshot version \(pack.version)."
            succeeded = true
        }
        return succeeded
    }

    public func applyRemoteInstructionMutation(
        id: InstructionPackID?,
        expectedVersion: Int?,
        name: String,
        body: String,
        scope: InstructionScope,
        isEnabled: Bool
    ) async -> Bool {
        var succeeded = false
        await perform {
            let existing = id.flatMap { requestedID in
                instructionPacks.first { $0.id == requestedID }
            }
            if id != nil, existing == nil {
                throw RemoteInstructionMutationError.stale
            }
            if let existing, expectedVersion != existing.version {
                throw RemoteInstructionMutationError.changed
            }
            let pack = InstructionPack(
                id: existing?.id ?? .make(),
                name: name,
                body: body,
                scope: scope,
                version: (existing?.version ?? 0) + 1,
                isEnabled: isEnabled
            )
            try await saveInstruction(pack)
            instructionPacks = try await loadInstructions()
            notice = "Shared instruction pack saved. Future matching runs will snapshot version \(pack.version)."
            succeeded = true
        }
        return succeeded
    }

    public func setInstruction(_ pack: InstructionPack, enabled: Bool) async {
        if let continuityStore {
            let editor = await continuityStore.instructionEditor(for: pack.id)
            guard let editor else {
                errorMessage = "The host could not open this instruction pack. Refresh and try again."
                return
            }
            _ = acceptClientAcknowledgement(
                await continuityStore.saveInstruction(
                    id: editor.id,
                    version: editor.version,
                    name: editor.name,
                    body: editor.body,
                    scope: editor.scope,
                    isEnabled: enabled
                ),
                successNotice: enabled ? "Instruction pack enabled." : "Instruction pack disabled for future runs."
            )
            return
        }
        await perform {
            try await saveInstruction(InstructionPack(
                id: pack.id,
                name: pack.name,
                body: pack.body,
                scope: pack.scope,
                version: pack.version,
                isEnabled: enabled
            ))
            instructionPacks = try await loadInstructions()
            notice = enabled ? "Instruction pack enabled." : "Instruction pack disabled for future runs."
        }
    }

    public func prepareRoutingPlan(
        alwaysReview: Bool = true,
        allowOneTimeRecurringRequest: Bool = false,
        presentsFullReview: Bool? = nil
    ) async {
        guard !isBusy else {
            notice = "Still finishing the previous step. Send again in a moment; your request is kept."
            return
        }
        lastRoutingPlanRequestedReview = alwaysReview
        guard hasPromptContent else {
            errorMessage = "Enter a request before reviewing its scope."
            return
        }
        guard isSelectedProviderAvailable else {
            errorMessage = GobyApplicationError.providerUnavailable(selectedProviderID).localizedDescription
            return
        }
        // A request that sounds recurring is never blocked by a question:
        // it is prepared as one reviewed run, and the plan offers to turn it
        // into an automation instead.
        let requestsSchedule = !allowOneTimeRecurringRequest
            && RecurringRequestIntent.requestsSchedule(prompt)
        if let existingID = quickTaskAgentID,
           quickTaskAgentTask != promptTextForRouting {
            guard await retireTemporaryAgent(existingID) else { return }
            quickTaskAgentID = nil
            quickTaskAgentTask = nil
            promptAgentTargets.removeAll()
        }
        if let quickTaskProjectID, quickTaskAgentID == nil {
            guard !isCreatingQuickTaskAgent else { return }
            isCreatingQuickTaskAgent = true
            if continuityStore != nil { isBusy = true }
            defer {
                isCreatingQuickTaskAgent = false
                if continuityStore != nil { isBusy = false }
            }
            let agentID = AgentID(rawValue: "temporary-agent-\(UUID().uuidString.lowercased())")
            let task = promptTextForRouting
            let providerID = selectedProviderID
            guard await createTemporaryAgent(
                id: agentID,
                projectID: quickTaskProjectID,
                providerID: providerID,
                task: task
            ) else { return }
            guard self.quickTaskProjectID == quickTaskProjectID,
                  selectedProviderID == providerID,
                  promptTextForRouting == task else {
                _ = await retireTemporaryAgent(agentID)
                return
            }
            let target = AgentRouteTarget(
                providerID: providerID,
                agentID: agentID,
                projectID: quickTaskProjectID
            )
            quickTaskAgentID = agentID
            quickTaskAgentTask = task
            setPromptAgentTargets([target])
            guard promptAgentTargets.contains(target) else {
                quickTaskAgentID = nil
                quickTaskAgentTask = nil
                _ = await retireTemporaryAgent(agentID)
                return
            }
        }
        if !scopeTemporaryAgentIDs.isEmpty {
            // Agents made for an earlier send belong to that request.
            await retireScopeTemporaryAgents()
        }
        if let suggestion = missingAgentSuggestionForCurrentScope() {
            proposedPlan = nil
            // Default silently to a temporary agent for this one project; the
            // plan explains it and still requires review. Ask only when that
            // is not possible or fails.
            if canUseTemporaryAgent(for: suggestion) {
                await useTemporaryAgent(for: suggestion)
                if quickTaskAgentID != nil { return }
                cancelQuickTask()
            }
            // Several projects: give each uncovered one a temporary agent and
            // keep planning the whole request, so its scope never narrows.
            if !(await coverMissingAgentsWithTemporaryAgents()) {
                agentCreationSuggestion = suggestion
                errorMessage = nil
                return
            }
        }
        agentCreationSuggestion = nil
        // The request becomes a conversation on Home right away; it turns into
        // the run once staged, or is cleared if it never becomes a plan.
        beginPendingThread()
        // A plan shows once, in the conversation's plan card; the full sheet
        // opens only from Edit Scope.
        showsFullPlanReview = presentsFullReview ?? false
        defer { abandonPendingThreadIfNeeded() }
        if let continuityStore {
            guard !isBusy else { return }
            isBusy = true
            errorMessage = nil
            defer { isBusy = false }
            let submittedText = prompt
            let submittedAttachments = promptAttachments
            let submittedSelection = currentClientSelection
            if continuityStore.requiresApplicationRelaunch {
                errorMessage = "Goby was rebuilt or updated while it was open and must relaunch before planning. Your draft is kept on this Mac."
                return
            }
            if continuityStore.connectionPhase != .live {
                // Send is an explicit user request: reconnect now instead of
                // waiting for the next background retry, then save the draft.
                await continuityStore.reconnect()
                if continuityStore.requiresApplicationRelaunch {
                    errorMessage = "Goby was rebuilt or updated while it was open and must relaunch before planning. Your draft is kept on this Mac."
                    return
                }
            }
            // Another agent's admitted host mutation can hold the command
            // boundary longer than one draft retry cycle. Only an explicit
            // pre-admission deferral is safe to retry with a fresh command.
            await flushClientDraftNow(retriesAfterDeferredAdmission: 4)
            guard continuityStore.draftSyncPhase == .synced, pendingClientSelection == nil,
                  prompt == submittedText, promptAttachments == submittedAttachments,
                  currentClientSelection == submittedSelection else {
                if case .conflict = continuityStore.draftSyncPhase {
                    errorMessage = "The host has a different saved request. Choose which draft to keep before planning."
                } else if case .locallyModified = continuityStore.draftSyncPhase,
                   continuityStore.lastAcknowledgement?.wasDeferredBeforeAdmission == true {
                    errorMessage = "The host is still finishing another change. Your draft is kept here; try Send again when it is ready."
                } else if continuityStore.connectionPhase != .live {
                    errorMessage = "Goby can't reach its background host right now. Your draft is kept here; Send again after the connection banner clears."
                } else {
                    errorMessage = "Your latest draft has not reached the host. Try again to save it before planning."
                }
                return
            }
            let prepared = acceptClientAcknowledgement(
                await continuityStore.preparePlan(),
                successNotice: nil
            )
            if prepared, !alwaysReview, !requestsSchedule, quickTaskProjectID == nil,
               scopeTemporaryAgentIDs.isEmpty,
               prompt == submittedText, promptAttachments == submittedAttachments,
               currentClientSelection == submittedSelection,
               let plan = proposedPlan, plan.canStartAutomatically,
               !readinessIssues(for: plan).contains(where: \.blocksAutomaticStart),
               selectedRunResourceIDs.isEmpty,
               !plan.routes.isEmpty, plan.routes.allSatisfy({ !$0.agentIDs.isEmpty }) {
                isBusy = false
                await stageProposedPlan(approved: false)
            } else if prepared, !alwaysReview, !requestsSchedule, quickTaskProjectID == nil,
                      scopeTemporaryAgentIDs.isEmpty,
                      prompt == submittedText, promptAttachments == submittedAttachments,
                      currentClientSelection == submittedSelection,
                      proposedPlan != nil,
                      continuityStore.projection?.plan?.startsWithoutReview == true {
                isBusy = false
                await stageProposedPlan(approved: true)
                if errorMessage == nil {
                    notice = "Started without review: the project is trusted and the work is isolated in a worktree."
                }
            }
            return
        }
        var automaticallyStagedRunID: RunID?
        let replacedPlanAgentIDs = temporaryAgentIDs(in: proposedPlan)
        defer {
            if !replacedPlanAgentIDs.isEmpty {
                Task { await retireUnusedTemporaryAgents(among: replacedPlanAgentIDs) }
            }
        }
        await perform {
            let routeScope: RouteScope
            if !promptProjectIDs.isEmpty {
                routeScope = .projects(promptProjectIDs)
            } else if let promptProjectGroup {
                routeScope = .projects(promptProjectGroup.projectIDs)
            } else {
                routeScope = promptScope.routeScope
            }
            let request = RouteRequest(
                prompt: promptTextForRouting,
                attachments: promptAttachments,
                scope: routeScope,
                providerID: selectedProviderID,
                model: resolvedPromptModelID,
                agentTargets: promptAgentTargets
            )
            let routedPlan = try await planWithParallelCopies(try await preparePlan(request)) { targets in
                try await self.preparePlan(RouteRequest(
                    prompt: request.prompt,
                    attachments: request.attachments,
                    scope: request.scope,
                    providerID: request.providerID,
                    model: request.model,
                    agentTargets: Set(targets)
                ))
            }
            let plan = await resolvingWorkingCopyGit(routedPlan)
            selectedRunResourceIDs = suggestedResourceIDs(for: plan.interpretedGoal)
            let shouldReview = alwaysReview || requestsSchedule || quickTaskProjectID != nil
                || !scopeTemporaryAgentIDs.isEmpty
                || readinessIssues(for: plan).contains(where: \.blocksAutomaticStart)
                || !plan.canStartAutomatically || !selectedRunResourceIDs.isEmpty
                || plan.routes.isEmpty || plan.routes.contains(where: { $0.agentIDs.isEmpty })
            if shouldReview {
                proposedPlan = plan
            } else {
                let run = try await stageRun(
                    plan: plan,
                    receipt: nil,
                    selectedResourceIDs: selectedRunResourceIDs
                )
                selectedRunResourceIDs = []
                promptProjectIDs.removeAll()
                promptAgentTargets.removeAll()
                prompt = ""
                clearPromptAttachments()
                selectedProviderID = defaultProviderID
                promptModelID = nil
                notice = "Safe read-only run started in the background."
                runs.removeAll { $0.id == run.id }
                runs.insert(run, at: 0)
                activeThread = .run(run.id)
                automaticallyStagedRunID = run.id
                if let graph = try? await buildGraph(assignments: run.assignments) {
                    replaceGraphPreservingManualLayout(graph)
                }
            }
        }
        if let automaticallyStagedRunID {
            Task { await executeInBackground(automaticallyStagedRunID) }
        }
    }

    private func temporaryAgentIDs(in plan: RoutingPlan?) -> Set<AgentID> {
        Set((plan?.routes.flatMap(\.agentIDs) ?? []).filter { id in
            lab.agents.contains { $0.id == id && $0.isTemporary } && id != quickTaskAgentID
        })
    }

    /// When a planned agent is already working on another request in the same
    /// project and the two requests don't interfere (`ParallelRequestPolicy`),
    /// this request gets a temporary copy of that agent: same role and
    /// instructions, its own status and notes, retired when its run ends.
    /// Conflicting requests keep the agent; they wait at run time instead.
    private func planWithParallelCopies(
        _ plan: RoutingPlan,
        reprepare: ([AgentRouteTarget]) async throws -> RoutingPlan
    ) async throws -> RoutingPlan {
        guard let createTemporaryAgentUseCase else { return plan }
        let activeRuns = runs.filter { $0.id != plan.id && $0.status == .running }
        var targets: [AgentRouteTarget] = []
        var copies: [AgentID] = []
        for route in plan.routes {
            for agentID in route.agentIDs {
                let busyRun = activeRuns.first { run in
                    run.assignments.contains {
                        $0.projectID == route.projectID && $0.agentID == agentID
                            && ![.completed, .failed, .cancelled].contains($0.status)
                    }
                }
                if let busyRun,
                   !lab.agents.contains(where: { $0.id == agentID && $0.isTemporary }),
                   ParallelRequestPolicy.conflict(later: plan, earlier: busyRun.plan, in: route.projectID) == nil {
                    let copyID = AgentID(rawValue: "temporary-agent-\(UUID().uuidString.lowercased())")
                    _ = try await createTemporaryAgentUseCase(
                        id: copyID,
                        projectID: route.projectID,
                        providerID: route.providerID,
                        task: plan.interpretedGoal,
                        basedOn: agentID
                    )
                    copies.append(copyID)
                    targets.append(AgentRouteTarget(providerID: route.providerID, agentID: copyID, projectID: route.projectID))
                } else {
                    targets.append(AgentRouteTarget(providerID: route.providerID, agentID: agentID, projectID: route.projectID))
                }
            }
        }
        guard !copies.isEmpty else { return plan }
        do {
            let (lab, runs) = try await loadDashboard()
            self.lab = lab
            self.runs = runs
            return try await reprepare(targets)
        } catch {
            for id in copies { try? await retireTemporaryAgentUseCase?(id: id) }
            throw error
        }
    }

    public var conflictingHostDraftPreview: String? {
        guard let continuityStore,
              case let .conflict(canonicalText) = continuityStore.draftSyncPhase else { return nil }
        let preview = String(canonicalText.prefix(240))
        return preview.isEmpty ? "(empty request)" : preview + (canonicalText.count > 240 ? "…" : "")
    }

    public func keepLocalDraftAfterConflict() async {
        guard !isBusy, let continuityStore,
              case .conflict = continuityStore.draftSyncPhase else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let platform: ProjectPlatform? = switch promptScope {
        case .all: nil
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        }
        await continuityStore.deliberatelyReplaceConflictingDraft(
            providerID: selectedProviderID,
            model: promptModelID,
            platform: platform,
            projectIDs: promptProjectIDs.sorted { $0.rawValue < $1.rawValue },
            agentTargets: promptAgentTargets.sorted {
                if $0.projectID != $1.projectID { return $0.projectID.rawValue < $1.projectID.rawValue }
                if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
                return $0.agentID.rawValue < $1.agentID.rawValue
            },
            groupID: promptProjectGroupID
        )
        completeClientSelectionSave()
        if continuityStore.draftSyncPhase == .synced {
            notice = "Your request is saved. Review the plan when ready."
        } else {
            errorMessage = "The host request changed while resolving this draft. Review both versions again."
        }
    }

    public func useHostDraftAfterConflict() {
        guard let continuityStore,
              case .conflict = continuityStore.draftSyncPhase,
              let projection = continuityStore.projection else { return }
        continuityStore.reloadCanonicalDraft()
        pendingClientSelection = nil
        hydrateClientProjection(projection)
        errorMessage = nil
        notice = "The host request is now in the composer."
    }

    public func dismissPlan() {
        if case .pending = activeThread { activeThread = nil }
        showsFullPlanReview = false
        if let continuityStore, let planID = proposedPlan?.id {
            guard !isBusy else { return }
            isBusy = true
            isCancellingPlan = true
            errorMessage = nil
            clientPlanUpdateRevision &+= 1
            let precedingSave = clientPlanSaveTask
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isBusy = false
                    self.isCancellingPlan = false
                }
                await precedingSave?.value
                let acknowledgement = await continuityStore.cancelPlan(planID)
                if self.acceptClientAcknowledgement(acknowledgement, successNotice: nil) {
                    let temporaryID = self.quickTaskAgentID
                    self.quickTaskAgentID = nil
                    self.quickTaskAgentTask = nil
                    self.quickTaskProjectID = nil
                    if let temporaryID { _ = await self.retireTemporaryAgent(temporaryID) }
                    await self.retireScopeTemporaryAgents()
                }
            }
            return
        }
        let abandonedQuickTaskAgentID = quickTaskAgentID
        quickTaskAgentID = nil
        quickTaskAgentTask = nil
        quickTaskProjectID = nil
        if let abandonedQuickTaskAgentID {
            Task { _ = await retireTemporaryAgent(abandonedQuickTaskAgentID) }
        }
        if !scopeTemporaryAgentIDs.isEmpty {
            Task { await retireScopeTemporaryAgents() }
        }
        let abandonedPlanAgentIDs = temporaryAgentIDs(in: proposedPlan)
        proposedPlan = nil
        if !abandonedPlanAgentIDs.isEmpty {
            // Parallel copies made for this plan are not needed any more.
            Task { await retireUnusedTemporaryAgents(among: abandonedPlanAgentIDs) }
        }
        selectedRunResourceIDs = []
        notifyStateDidChange()
    }

    public var hasPromptContent: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !promptAttachments.isEmpty
    }

    public var remainingPromptAttachmentCapacity: Int {
        max(0, 12 - promptAttachments.count)
    }

    public func addPromptFileAttachments(_ urls: [URL]) async {
        guard !isTransferringOwnership else { return }
        pendingAttachmentOperations += 1
        defer { pendingAttachmentOperations -= 1 }
        let admittedURLs = Array(urls.prefix(remainingPromptAttachmentCapacity))
        guard !admittedURLs.isEmpty else {
            if !urls.isEmpty { errorMessage = "A request can include up to 12 attachments." }
            return
        }
        let attachmentRoot = promptAttachmentDirectoryURL
        let snapshots = await Task.detached(priority: .userInitiated) {
            admittedURLs.map { Self.stagePromptAttachment($0, root: attachmentRoot) }
        }.value
        var additions: [PromptAttachment] = []
        var rejectedDirectory = false

        for snapshot in snapshots {
            let url = snapshot.sourceURL
            guard let staged = snapshot.stagedURL else {
                rejectedDirectory = rejectedDirectory || snapshot.rejectedDirectory
                continue
            }
            let fileExtension = url.pathExtension.lowercased()
            let kind: PromptAttachmentKind = Self.imageFileExtensions.contains(fileExtension)
                ? .image
                : .file
            additions.append(PromptAttachment(
                kind: kind,
                displayName: url.lastPathComponent,
                source: .localFile(staged),
                byteCount: snapshot.byteCount,
                typeHint: fileExtension.isEmpty ? "File" : fileExtension.uppercased()
            ))
        }

        let acceptedIDs = appendPromptAttachments(additions)
        let rejectedOwnedURLs = additions.compactMap { attachment -> URL? in
            guard !acceptedIDs.contains(attachment.id),
                  case let .localFile(url) = attachment.source else { return nil }
            return url
        }
        if !rejectedOwnedURLs.isEmpty {
            await Task.detached(priority: .utility) {
                for url in rejectedOwnedURLs { Self.removeOwnedPromptAttachment(at: url, root: attachmentRoot) }
            }.value
        }
        if rejectedDirectory {
            errorMessage = "Drop individual files rather than a folder. Project folders remain controlled by routing."
        } else if additions.isEmpty, !urls.isEmpty {
            errorMessage = "Goby could not access the dropped file."
        } else if admittedURLs.count < urls.count {
            errorMessage = "A request can include up to 12 attachments."
        }
    }

    public func addPromptImageAttachment(
        data: Data,
        suggestedName: String?,
        fileExtension: String
    ) async {
        guard !isTransferringOwnership else { return }
        pendingAttachmentOperations += 1
        defer { pendingAttachmentOperations -= 1 }
        guard remainingPromptAttachmentCapacity > 0 else {
            errorMessage = "A request can include up to 12 attachments."
            return
        }
        let attachmentRoot = promptAttachmentDirectoryURL
        guard let staged = await Task.detached(priority: .userInitiated, operation: { () -> URL? in
            Self.stagePromptImage(data: data, fileExtension: fileExtension, root: attachmentRoot)
        }).value else {
            errorMessage = "The dropped image is empty, too large, or could not be stored safely."
            return
        }
        let attachment = PromptAttachment(
            kind: .image,
            displayName: Self.droppedImageDisplayName(suggestedName, fileExtension: staged.pathExtension),
            source: .localFile(staged),
            byteCount: data.count,
            typeHint: staged.pathExtension.uppercased()
        )
        let acceptedIDs = appendPromptAttachments([attachment])
        if !acceptedIDs.contains(attachment.id) {
            await Task.detached(priority: .utility) {
                Self.removeOwnedPromptAttachment(at: staged, root: attachmentRoot)
            }.value
        }
    }

    /// Stages bytes received through the authenticated mobile attachment
    /// transfer. The mobile URI is never accepted as a Mac pathname; only the
    /// completed, digest-verified bytes reach this owner-only storage boundary.
    public func addRemotePromptAttachment(
        id: UUID,
        kind: PromptAttachmentKind,
        displayName: String,
        data: Data,
        typeHint: String?
    ) async -> Bool {
        guard !isTransferringOwnership else { return false }
        pendingAttachmentOperations += 1
        defer { pendingAttachmentOperations -= 1 }
        guard remainingPromptAttachmentCapacity > 0,
              kind == .file || kind == .image,
              !data.isEmpty,
              data.count <= 25 * 1_024 * 1_024 else { return false }
        let suffix = URL(fileURLWithPath: displayName).pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let safeSuffix = String(suffix.prefix(32))
        let attachmentRoot = promptAttachmentDirectoryURL
        guard let staged = await Task.detached(priority: .userInitiated, operation: { () -> URL? in
            guard let storage = PromptAttachmentStorage.openOrCreateRoot(attachmentRoot) else { return nil }
            defer { close(storage.descriptor) }
            guard let destination = PromptAttachmentStorage.write(
                data,
                fileExtension: safeSuffix,
                root: storage.url,
                descriptor: storage.descriptor
            ) else { return nil }
            guard let identity = GADFileSystemIdentity.capture(destination),
                  identity.kind == .regularFile else {
                PromptAttachmentStorage.removeDirectChild(
                    root: storage.url,
                    descriptor: storage.descriptor,
                    url: destination
                )
                return nil
            }
            return destination
        }).value else { return false }

        let attachment = PromptAttachment(
            id: id,
            kind: kind,
            displayName: displayName,
            source: .localFile(staged),
            byteCount: data.count,
            typeHint: typeHint
        )
        let accepted = appendPromptAttachments([attachment]).contains(id)
        if !accepted {
            await Task.detached(priority: .utility) {
                Self.removeOwnedPromptAttachment(at: staged, root: attachmentRoot)
            }.value
        }
        return accepted
    }

    public func addPromptSnippet(_ value: String, displayName: String? = nil) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let limited = String(text.prefix(32_000))
        let language = Self.inferredSnippetLanguage(limited)
        appendPromptAttachments([PromptAttachment(
            kind: .snippet,
            displayName: displayName ?? language.map { "\($0) snippet" } ?? "Text snippet",
            source: .text(limited),
            byteCount: limited.utf8.count,
            typeHint: language
        )])
    }

    public func removePromptAttachment(_ id: UUID) {
        let removed = promptAttachments.filter { $0.id == id }
        promptAttachments.removeAll { $0.id == id }
        scheduleOwnedPromptAttachmentCleanup(removed)
    }

    /// Empties the composer after the host accepted a run, without deleting
    /// the files. The queued run still needs them, and this window only sees
    /// redacted run references, so it cannot tell they are in use; the host,
    /// which sees the full references, removes them once nothing needs them.
    private func forgetSubmittedPromptAttachments() {
        promptAttachments = []
    }

    public func clearPromptAttachments() {
        guard !promptAttachments.isEmpty else { return }
        let removed = promptAttachments
        promptAttachments = []
        scheduleOwnedPromptAttachmentCleanup(removed)
    }

    /// Replaces the shared draft attachment list while retaining authoritative
    /// host-only sources for matching redacted references.
    public func replacePromptAttachments(
        _ attachments: [PromptAttachment],
        allowingNewSources: Bool = true
    ) {
        let previous = promptAttachments
        let existing = Dictionary(uniqueKeysWithValues: promptAttachments.map { ($0.id, $0) })
        var seen = Set<UUID>()
        promptAttachments = attachments.prefix(12).compactMap { attachment in
            guard seen.insert(attachment.id).inserted else { return nil }
            if allowingNewSources { return attachment }
            // A paired client may only retain or remove host-selected
            // references. It can never introduce a local path or snippet body,
            // nor create a new attachment identity that the Mac did not issue.
            guard attachment.source == nil,
                  let preserved = existing[attachment.id],
                  preserved.source != nil else { return nil }
            return preserved
        }
        let retainedIDs = Set(promptAttachments.map(\.id))
        scheduleOwnedPromptAttachmentCleanup(previous.filter { !retainedIDs.contains($0.id) })
    }

    private func scheduleOwnedPromptAttachmentCleanup(_ attachments: [PromptAttachment]) {
        guard !isTransferringOwnership else { return }
        let candidateURLs = attachments.compactMap { attachment -> URL? in
            guard case let .localFile(url) = attachment.source else { return nil }
            return url.standardizedFileURL
        }
        guard !candidateURLs.isEmpty else { return }
        pendingAttachmentOperations += 1

        Task { @MainActor [weak self] in
            defer { self?.pendingAttachmentOperations -= 1 }
            // Submission inserts the immutable run immediately after clearing
            // the draft. Yield once so that reference becomes visible before
            // deciding whether the owned copy is an orphan.
            await Task.yield()
            guard let self else { return }
            let referencedURLs = self.referencedPromptAttachmentURLs()
            let attachmentRoot = self.promptAttachmentDirectoryURL
            let orphaned = candidateURLs.filter { !referencedURLs.contains($0) }
            guard !orphaned.isEmpty else { return }
            await Task.detached(priority: .utility) {
                for url in orphaned {
                    Self.removeOwnedPromptAttachment(at: url, root: attachmentRoot)
                }
            }.value
        }
    }

    private func referencedPromptAttachmentURLs() -> Set<URL> {
        var attachments = promptAttachments
        attachments.append(contentsOf: proposedPlan?.attachments ?? [])
        for run in runs {
            attachments.append(contentsOf: run.plan.attachments)
            attachments.append(contentsOf: run.assignments.flatMap(\.attachments))
        }
        return Set(attachments.compactMap { attachment -> URL? in
            guard case let .localFile(url) = attachment.source else { return nil }
            return url.standardizedFileURL
        })
    }

    private func sweepOwnedPromptAttachmentStorage() async {
        guard let root = promptAttachmentDirectoryURL else { return }
        let referencedURLs = referencedPromptAttachmentURLs()
        await Task.detached(priority: .utility) {
            Self.sweepPromptAttachmentStorage(at: root, retaining: referencedURLs)
        }.value
    }

    @discardableResult
    private func appendPromptAttachments(_ additions: [PromptAttachment]) -> Set<UUID> {
        guard !additions.isEmpty else { return [] }
        var result = promptAttachments
        var acceptedIDs = Set<UUID>()
        var knownFiles = Set(result.compactMap { attachment -> URL? in
            guard case let .localFile(url) = attachment.source else { return nil }
            return url.standardizedFileURL
        })
        var knownSnippets = Set(result.compactMap { attachment -> String? in
            guard case let .text(text) = attachment.source else { return nil }
            return text
        })

        for attachment in additions {
            guard result.count < 12 else {
                errorMessage = "A request can include up to 12 attachments."
                break
            }
            switch attachment.source {
            case let .localFile(url):
                guard knownFiles.insert(url.standardizedFileURL).inserted else { continue }
            case let .text(text):
                guard knownSnippets.insert(text).inserted else { continue }
            case nil:
                break
            }
            result.append(attachment)
            acceptedIDs.insert(attachment.id)
        }
        promptAttachments = result
        return acceptedIDs
    }

    public func setPromptAgentTarget(_ target: AgentRouteTarget?) {
        setPromptAgentTargets(target.map { Set([$0]) } ?? [])
    }

    public func setPromptAgentTargets(_ targets: Set<AgentRouteTarget>) {
        guard targets.allSatisfy(canDirectlyAssignAgent) else {
            errorMessage = "One or more selected agents are not available for direct assignment."
            return
        }
        if !targets.isEmpty {
            promptProjectGroupID = nil
            promptProjectIDs = Set(targets.map(\.projectID))
        }
        promptAgentTargets = targets
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    /// Applies the complete recipient set from a shared draft. A direct agent
    /// can coexist with projects that remain in automatic routing scope.
    @discardableResult
    public func setPromptRecipients(
        projectIDs: Set<ProjectID>,
        agentTargets: Set<AgentRouteTarget>
    ) -> Bool {
        // The authoritative host has no local quickTaskAgentID for an agent
        // created by a connected window. Validate its registered binding here;
        // the UI-only direct-selection guard still hides unrelated temporaries.
        let registeredProjectIDs = Set(lab.projects.map(\.id))
        guard projectIDs.isSubset(of: registeredProjectIDs),
              Set(agentTargets.map(\.projectID)).isSubset(of: projectIDs),
              agentTargets.allSatisfy({ target in
                  target.providerID == selectedProviderID
                      && availableProviderIDs.contains(target.providerID)
                      && AgentRoutingMatcher.isEligible(target, in: lab)
              }) else {
            errorMessage = "The selected projects or agents changed. Review the recipients and try again."
            return false
        }
        promptProjectGroupID = nil
        promptProjectIDs = projectIDs
        promptAgentTargets = agentTargets
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
        return true
    }

    public func removePromptAgentTarget(_ target: AgentRouteTarget) {
        guard promptAgentTargets.contains(target) else { return }
        promptProjectGroupID = nil
        promptProjectIDs.formUnion(promptAgentTargets.map(\.projectID))
        promptAgentTargets.remove(target)
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func removePromptAgentTargets(in projectID: ProjectID) {
        guard promptAgentTargets.contains(where: { $0.projectID == projectID }) else { return }
        promptProjectGroupID = nil
        promptProjectIDs.formUnion(promptAgentTargets.map(\.projectID))
        promptAgentTargets = Set(promptAgentTargets.filter { $0.projectID != projectID })
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func clearPromptAgentTargetsKeepingProjects() {
        guard !promptAgentTargets.isEmpty else { return }
        promptProjectGroupID = nil
        promptProjectIDs.formUnion(promptAgentTargets.map(\.projectID))
        promptAgentTargets.removeAll()
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func dismissAgentCreationSuggestion() {
        agentCreationSuggestion = nil
    }

    public func selectProviderPlane(_ providerID: AgentProviderID) {
        guard AgentProviderID.builtIn.contains(providerID), providerID != selectedProviderID else { return }
        if quickTaskAgentID != nil { cancelQuickTask() }
        selectedProviderID = providerID
        promptModelID = nil
        agentCreationSuggestion = nil
        let invalidTargets = promptAgentTargets.filter { $0.providerID != providerID }
        if !invalidTargets.isEmpty {
            promptAgentTargets.subtract(invalidTargets)
            notice = "Switched to \(providerID.displayName). Cleared \(countLabel(invalidTargets.count, singular: "direct agent target")); your request draft is unchanged."
        } else if !availableProviderIDs.contains(providerID) {
            notice = "\(providerID.displayName) setup is not available in this build. Your request draft is unchanged."
        }
        proposedPlan = nil
        if continuityStore != nil {
            graph = ClientProjectionAdapter().graph(
                lab: lab, runs: runs, tasks: codexTasks, providerID: selectedProviderID
            )
            if let selectedRun { selectedRunGraph = clientGraph(for: selectedRun) }
            notifyStateDidChange()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await refreshGraph()
            if let selectedRun {
                selectedRunGraph = (try? await buildGraph(
                    assignments: selectedRun.assignments,
                    providerID: selectedProviderID
                )) ?? .empty
            }
        }
        notifyStateDidChange()
    }

    public var promptAvailableModels: [String] {
        guard let account = providerAccounts.first(where: { $0.providerID == selectedProviderID }) else {
            return []
        }
        var models = account.availableModels
        if let selected = account.selectedModel, !models.contains(selected) {
            models.insert(selected, at: 0)
        }
        var seen = Set<String>()
        return models.filter { model in
            let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    public var resolvedPromptModelID: String? {
        promptModelID ?? promptProviderDefaultModelID
    }

    public var promptProviderDefaultModelID: String? {
        providerAccounts.first(where: { $0.providerID == selectedProviderID })?.selectedModel
    }

    public func selectPromptModel(_ modelID: String?) {
        let normalized = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        guard next != promptModelID else { return }
        promptModelID = next
        proposedPlan = nil
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func setPromptProjectIDs(_ projectIDs: Set<ProjectID>) {
        let registeredProjectIDs = Set(lab.projects.map(\.id))
        guard projectIDs.isSubset(of: registeredProjectIDs) else {
            errorMessage = "One or more selected projects are no longer registered."
            return
        }
        if !projectIDs.isEmpty {
            promptProjectGroupID = nil
            promptAgentTargets.removeAll()
        }
        promptProjectIDs = projectIDs
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func togglePromptAgentTarget(_ target: AgentRouteTarget, extendingSelection: Bool) {
        guard canDirectlyAssignAgent(target) else {
            errorMessage = "That agent is not available for direct assignment in this project."
            return
        }
        var targets = extendingSelection ? promptAgentTargets : []
        if extendingSelection, targets.contains(target) {
            targets.remove(target)
        } else if !extendingSelection,
                  promptAgentTargets == [target] {
            targets.removeAll()
        } else {
            targets.insert(target)
        }
        setPromptAgentTargets(targets)
    }

    public func setPromptScope(_ scope: PromptScope) {
        promptProjectGroupID = nil
        promptProjectIDs.removeAll()
        promptAgentTargets.removeAll()
        promptScope = scope
        agentCreationSuggestion = nil
        notifyStateDidChange()
    }

    public func setPromptProjectGroup(_ id: ProjectGroupID) {
        guard lab.projectGroups.contains(where: { $0.id == id }) else {
            errorMessage = GobyApplicationError.unknownProjectGroup(id).localizedDescription
            return
        }
        promptProjectIDs.removeAll()
        promptAgentTargets.removeAll()
        promptProjectGroupID = id
        agentCreationSuggestion = nil
        errorMessage = nil
        notifyStateDidChange()
    }

    public func setRunResource(_ id: SharedResourceID, selected: Bool) {
        guard !isBusy, proposedPlan != nil,
              enabledSharedResources.contains(where: { $0.id == id }) else { return }
        if selected {
            selectedRunResourceIDs.insert(id)
        } else {
            selectedRunResourceIDs.remove(id)
        }
        scheduleClientPlanUpdate()
        notifyStateDidChange()
    }

    /// The host command adapter validates the complete catalog, provider-binding,
    /// and resource scope first. Commit it once without resolving obsolete
    /// intermediate assignments or publishing a partially edited plan.
    @discardableResult
    public func applyValidatedPlanScope(
        planID: RunID,
        routes: [ProjectRoute],
        resourceIDs: Set<SharedResourceID>
    ) -> Bool {
        guard continuityStore == nil, !isBusy,
              let plan = proposedPlan, plan.id == planID else { return false }
        let projectIDs = Set(routes.map(\.projectID))
        let previousProjectIDs = Set(plan.routes.map(\.projectID))
        func targets(in routes: [ProjectRoute]) -> Set<AgentRouteTarget> {
            Set(routes.flatMap { route in
                route.agentIDs.map {
                    AgentRouteTarget(providerID: route.providerID, agentID: $0, projectID: route.projectID)
                }
            })
        }
        let revisedTargets = targets(in: routes)
        var operations = plan.gitOperations.filter { projectIDs.contains($0.projectID) }
        if plan.risk != .readOnly {
            for project in lab.projects where projectIDs.contains(project.id)
                && !previousProjectIDs.contains(project.id) && project.isGitRepository {
                operations.append(contentsOf: [
                    PlannedGitOperation(projectID: project.id, kind: .createWorktree),
                    PlannedGitOperation(
                        projectID: project.id, kind: .createBranch,
                        branch: "codex/goby-manual-\(String(project.id.rawValue.suffix(12)))"
                    ),
                    PlannedGitOperation(projectID: project.id, kind: .commit)
                ])
            }
        }
        proposedPlan = copy(plan, routes: routes, gitOperations: operations)
        selectedRunResourceIDs = resourceIDs
        if revisedTargets != targets(in: plan.routes) {
            promptProjectGroupID = nil
            promptProjectIDs = projectIDs
            promptAgentTargets = revisedTargets
        }
        errorMessage = nil
        notifyStateDidChange()
        return true
    }

    public func setProject(_ projectID: ProjectID, selected: Bool) {
        guard !isBusy, let plan = proposedPlan,
              let project = lab.projects.first(where: { $0.id == projectID }) else { return }
        var routes = plan.routes
        var operations = plan.gitOperations

        if selected, !routes.contains(where: { $0.projectID == projectID }) {
            let matchingAgents = lab.agents.filter { agent in
                guard agent.isEnabled else { return false }
                let scopeMatches = switch agent.scope {
                case .global, .union:
                    true
                case let .project(scopedProjectID):
                    scopedProjectID == projectID
                }
                return scopeMatches && lab.providerBindings.contains { binding in
                    binding.providerID == selectedProviderID
                        && binding.agentID == agent.id
                        && (binding.projectID == nil || binding.projectID == projectID)
                        && binding.state == .configured
                }
            }
            let preferred = matchingAgents.filter { agent in
                agent.capabilities.contains { capability in
                    switch capability {
                    case .web: project.platforms.contains(.web)
                    case .macOS: project.platforms.contains(.macOS)
                    case .iOS: project.platforms.contains(.iOS)
                    case .android: project.platforms.contains(.android)
                    case .backend: project.platforms.contains(.backend)
                    case .research: project.platforms.contains(.research)
                    case .design: true
                    default: false
                    }
                }
            }
            let agents = preferred.isEmpty ? Array(matchingAgents.prefix(1)) : Array(preferred.prefix(2))
            let agentIDs = agents.map(\.id)
            let routeBindings: [ProviderRouteBinding]
            do {
                routeBindings = try ProviderBindingResolver.routeBindings(
                    agentIDs: agentIDs,
                    providerID: selectedProviderID,
                    projectID: projectID,
                    in: lab.providerBindings
                )
            } catch {
                errorMessage = error.localizedDescription
                notifyStateDidChange()
                return
            }
            routes.append(ProjectRoute(
                projectID: projectID,
                providerID: selectedProviderID,
                model: plan.routes.first?.model,
                agentIDs: agentIDs,
                providerBindings: routeBindings,
                reason: "Added manually to this run."
            ))
            if plan.risk != .readOnly, project.isGitRepository {
                operations.append(contentsOf: [
                    PlannedGitOperation(projectID: projectID, kind: .createWorktree),
                    PlannedGitOperation(
                        projectID: projectID,
                        kind: .createBranch,
                        branch: "codex/goby-manual-\(String(projectID.rawValue.suffix(12)))"
                    ),
                    PlannedGitOperation(projectID: projectID, kind: .commit)
                ])
            }
        } else if !selected {
            routes.removeAll { $0.projectID == projectID }
            operations.removeAll { $0.projectID == projectID }
        }
        proposedPlan = copy(plan, routes: routes, gitOperations: operations)
        promptProjectGroupID = nil
        promptAgentTargets.removeAll()
        promptProjectIDs = Set(routes.map(\.projectID))
        scheduleClientPlanUpdate()
        notifyStateDidChange()
    }

    public func setAgent(_ agentID: AgentID, in projectID: ProjectID, selected: Bool) {
        guard !isBusy, let plan = proposedPlan,
              let index = plan.routes.firstIndex(where: { $0.projectID == projectID }) else { return }
        var routes = plan.routes
        var ids = routes[index].agentIDs
        if selected, !ids.contains(agentID) {
            ids.append(agentID)
        } else if !selected {
            ids.removeAll { $0 == agentID }
        }
        let routeBindings: [ProviderRouteBinding]
        do {
            routeBindings = try ProviderBindingResolver.routeBindings(
                agentIDs: ids,
                providerID: routes[index].providerID,
                projectID: projectID,
                in: lab.providerBindings
            )
        } catch {
            errorMessage = error.localizedDescription
            notifyStateDidChange()
            return
        }
        routes[index] = ProjectRoute(
            projectID: projectID,
            providerID: routes[index].providerID,
            model: routes[index].model,
            agentIDs: ids,
            providerBindings: routeBindings,
            reason: "Adjusted manually; \(ids.count) agent\(ids.count == 1 ? "" : "s") selected."
        )
        proposedPlan = copy(plan, routes: routes, gitOperations: plan.gitOperations)
        promptProjectGroupID = nil
        promptProjectIDs = Set(routes.map(\.projectID))
        promptAgentTargets = Set(routes.flatMap { route in
            route.agentIDs.map {
                AgentRouteTarget(
                    providerID: route.providerID,
                    agentID: $0,
                    projectID: route.projectID
                )
            }
        })
        scheduleClientPlanUpdate()
        notifyStateDidChange()
    }

    /// Fills in the branch and remote a commit in the project folder will use,
    /// so the plan shows exactly what is committed and where it is pushed.
    /// A commit without a branch stays unresolved and fails before committing.
    /// The branch the conversation's previous run committed on, for a
    /// follow-up (it carries the previous answer). The answer seen by a
    /// client is redacted, so an exact match is preferred and the project's
    /// latest completed branch run is the fallback; the plan shows the branch.
    private func followUpCommittedBranch(for projectID: ProjectID) -> String? {
        guard let previous = promptAttachments.first(where: { $0.displayName == Self.previousAnswerAttachmentName }),
              case let .text(answer)? = previous.source else { return nil }
        let candidates = runs
            .filter { $0.status == .completed }
            .compactMap { run -> (RunRecord, String)? in
                guard let branch = run.plan.gitOperations.first(where: {
                    $0.projectID == projectID && $0.kind == .createBranch
                })?.branch else { return nil }
                return (run, branch)
            }
            .sorted { $0.0.updatedAt > $1.0.updatedAt }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = candidates.first { candidate in
            guard let earlier = candidate.0.conversationAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return earlier == trimmed || earlier.hasPrefix(trimmed) || trimmed.hasPrefix(earlier)
        }
        return (exact ?? candidates.first)?.1
    }

    private func resolvingWorkingCopyGit(_ plan: RoutingPlan) async -> RoutingPlan {
        guard plan.commitsWorkingCopy, let inspectProjectGitBranchesUseCase else { return plan }
        var operations: [PlannedGitOperation] = []
        var warnings = plan.warnings
        var snapshots: [ProjectID: ProjectGitBranchSnapshot?] = [:]
        let pushedProjectIDs = Set(plan.pushOperations.map(\.projectID))
        for operation in plan.gitOperations {
            // A push follow-up to a run that committed on its own branch
            // pushes that branch; the user's folder is left alone.
            if pushedProjectIDs.contains(operation.projectID),
               let earlier = followUpCommittedBranch(for: operation.projectID) {
                if operation.kind == .push {
                    let snapshot = try? await inspectProjectGitBranchesUseCase(projectID: operation.projectID)
                    if let snapshot { projectGitBranches[operation.projectID] = snapshot }
                    let name = lab.projects.first { $0.id == operation.projectID }?.name ?? operation.projectID.rawValue
                    if let remote = snapshot?.pushRemote, snapshot?.localBranches.contains(earlier) == true {
                        operations.append(PlannedGitOperation(
                            id: operation.id, projectID: operation.projectID, kind: .push, branch: earlier, remote: remote
                        ))
                    } else {
                        warnings.append("\(name) no longer has the previous run's branch \(earlier) or a remote, so there is nothing to push.")
                    }
                }
                continue
            }
            guard plan.commitsWorkingCopy(of: operation.projectID),
                  operation.kind == .commit || operation.kind == .push else {
                operations.append(operation)
                continue
            }
            let projectID = operation.projectID
            if snapshots[projectID] == nil {
                snapshots[projectID] = .some(try? await inspectProjectGitBranchesUseCase(projectID: projectID))
            }
            let snapshot = snapshots[projectID] ?? nil
            if let snapshot { projectGitBranches[projectID] = snapshot }
            let name = lab.projects.first { $0.id == projectID }?.name ?? projectID.rawValue
            guard let branch = snapshot?.currentBranch else {
                if operation.kind == .commit {
                    warnings.append("\(name) is not on a branch, so Goby cannot commit there. Switch to a branch first.")
                    operations.append(operation)
                }
                continue
            }
            switch operation.kind {
            case .commit:
                operations.append(PlannedGitOperation(id: operation.id, projectID: projectID, kind: .commit, branch: branch))
                if snapshot?.hasUncommittedChanges == false {
                    warnings.append("\(name) has no uncommitted changes on \(branch).")
                }
            default:
                if let remote = snapshot?.pushRemote {
                    operations.append(PlannedGitOperation(
                        id: operation.id, projectID: projectID, kind: .push, branch: branch, remote: remote
                    ))
                } else {
                    warnings.append("\(name) has no remote to push \(branch) to.")
                }
            }
        }
        return plan.replacingGitOperations(operations, warnings: warnings)
    }

    public func stageProposedPlan(
        approved: Bool,
        automaticallyApproveRuntimeRequests: Bool = false,
        allowsPush: Bool? = nil
    ) async {
        guard !isBusy, let reviewedPlan = proposedPlan else { return }
        let allowsPush = approved && (allowsPush ?? allowsPlanPush)
        if automaticallyApproveRuntimeRequests { rememberUninterruptedRun(reviewedPlan.id) }
        // Pushing is approved separately: without it the push steps go.
        let plan = allowsPush ? reviewedPlan : reviewedPlan.removingPushOperations()
        if let continuityStore {
            let submittedPrompt = prompt
            let submittedAttachments = promptAttachments
            isBusy = true
            errorMessage = nil
            defer { isBusy = false }
            // A plan is an authorization boundary. Wait for the exact edits
            // shown in this review before sending its start command.
            if pendingClientPlanUpdate != nil {
                scheduleClientPlanUpdate()
            }
            await clientPlanSaveTask?.value
            guard !Task.isCancelled, pendingClientPlanUpdate == nil,
                  proposedPlan?.id == plan.id else {
                if errorMessage == nil {
                    errorMessage = "Your reviewed scope has not reached the host. Review the plan and try again."
                }
                return
            }
            let acknowledgement = await continuityStore.startRun(
                plan.id,
                authorizationAssertion: approved || automaticallyApproveRuntimeRequests ? "macos-local-confirmed" : nil,
                automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests,
                allowsPush: allowsPush && !reviewedPlan.pushOperations.isEmpty ? true : nil
            )
            if acceptClientAcknowledgement(
                acknowledgement,
                successNotice: "Run queued. Execution starts after the host verifies the approved policy."
            ) {
                quickTaskAgentID = nil
                quickTaskAgentTask = nil
                quickTaskProjectID = nil
                // The run now owns these agents; they retire when it ends.
                scopeTemporaryAgentIDs = []
                if prompt == submittedPrompt {
                    prompt = ""
                    selectedProviderID = defaultProviderID
                    promptModelID = nil
                }
                if promptAttachments == submittedAttachments { forgetSubmittedPromptAttachments() }
                activeThread = .run(plan.id)
                showsFullPlanReview = false
            }
            return
        }
        var stagedRunID: RunID?
        await perform {
            let receipt: ApprovalReceipt? = approved
                ? ApprovalReceipt(
                    runID: plan.id,
                    decision: .approved,
                    operationIDs: Set(plan.gitOperations.map(\.id))
                )
                : nil
            let run = try await stageRun(
                plan: plan,
                receipt: receipt,
                selectedResourceIDs: selectedRunResourceIDs,
                automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests
            )
            proposedPlan = nil
            quickTaskAgentID = nil
            quickTaskAgentTask = nil
            quickTaskProjectID = nil
            // The run now owns these agents; they retire when it ends.
            scopeTemporaryAgentIDs = []
            selectedRunResourceIDs = []
            promptProjectIDs.removeAll()
            promptAgentTargets.removeAll()
            prompt = ""
            clearPromptAttachments()
            // Each new request starts on the default provider. A provider
            // chosen for this request applied only to it.
            selectedProviderID = defaultProviderID
            promptModelID = nil
            notice = "Run queued. Execution starts only after its approved policy is verified."
            runs.removeAll { $0.id == run.id }
            runs.insert(run, at: 0)
            activeThread = .run(run.id)
            showsFullPlanReview = false
            stagedRunID = run.id
            if let graph = try? await buildGraph(assignments: run.assignments) {
                replaceGraphPreservingManualLayout(graph)
            }
        }
        if let stagedRunID {
            Task { await executeInBackground(stagedRunID) }
        }
    }

    public func availableRunModels(for providerID: AgentProviderID) -> [String] {
        guard let account = providerAccounts.first(where: { $0.providerID == providerID }) else { return [] }
        let candidates = account.availableModels + [account.selectedModel].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func canChangeModel(in run: RunRecord) -> Bool {
        if let continuityStore,
           (continuityStore.session?.protocolVersion ?? .version1) < .init(major: 3, minor: 10) { return false }
        return [.needsAttention, .failed].contains(run.status)
            && !run.assignments.contains(where: { $0.hasIndeterminateProviderStart })
            && run.assignments.contains(where: { $0.status != .completed })
    }

    @discardableResult
    public func control(_ action: ControlRunUseCase.Action, runID: RunID, modelChange: RunModelChange? = nil) async -> Bool {
        guard !isTransferringOwnership else { return false }
        if case .startNow = action { return await startWithoutWaiting(runID: runID) }
        let isResume = switch action {
        case .resume: true
        case .pause, .cancel, .startNow: false
        }
        if modelChange != nil && !isResume {
            errorMessage = "A model change requires a fresh run attempt."
            return false
        }
        if let continuityStore {
            if modelChange != nil && (continuityStore.session?.protocolVersion ?? .version1) < .init(major: 3, minor: 10) {
                errorMessage = "Update the Goby host to change this run's model."
                return false
            }
            guard pendingRunControls[runID] == nil else {
                notice = "That run action is already being processed."
                return false
            }
            let remoteAction: GADRunControlAction = switch action {
            case .pause: .pause
            case .resume: .resume
            case .cancel: .cancel
            case .startNow: .startNow
            }
            let pendingAction: PendingRunControl.Action = switch action {
            case .pause: .pause
            case .resume, .startNow: .resume
            case .cancel: .cancel
            }
            guard let status = runs.first(where: { $0.id == runID })?.status else {
                errorMessage = "This run is no longer available."
                return false
            }
            beginPendingRunControl(pendingAction, runID: runID, status: status)
            let resumeNotice = runs.first(where: { $0.id == runID })?.status == .ready
                ? "Run started."
                : "Retry started in a fresh provider task."
            let accepted = acceptClientAcknowledgement(
                await continuityStore.control(runID: runID, action: remoteAction, modelChange: modelChange),
                successNotice: isResume ? resumeNotice : nil
            )
            if !accepted {
                clearPendingRunControl(runID)
            }
            return accepted
        }

        if isResume {
            return scheduleResume(runID: runID, modelChange: modelChange)
        }

        guard pendingRunControls[runID] == nil else {
            notice = "That run action is already being processed."
            return false
        }
        guard let status = runs.first(where: { $0.id == runID })?.status else {
            errorMessage = "This run is no longer available."
            return false
        }
        let pendingAction: PendingRunControl.Action = action == .pause ? .pause : .cancel
        beginPendingRunControl(pendingAction, runID: runID, status: status)
        do {
            try await controlRun(runID: runID, action: action)
            errorMessage = nil
            reconcilePendingRunControls()
            return true
        } catch {
            clearPendingRunControl(runID)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Whether the host can start a request that waits for a conflicting one.
    public var supportsRunAnyway: Bool {
        guard let continuityStore else { return controlRun != nil }
        return continuityStore.session?.supportsParallelRequests == true
    }

    /// Run Anyway: starts a request that waits for a conflicting request in
    /// the same project, accepting that they may interfere.
    public func startWithoutWaiting(runID: RunID) async -> Bool {
        if let continuityStore {
            guard supportsRunAnyway else {
                errorMessage = "Update Goby's background host to start a waiting request."
                return false
            }
            return acceptClientAcknowledgement(
                await continuityStore.control(runID: runID, action: .startNow),
                successNotice: "Started without waiting."
            )
        }
        do {
            try await controlRun(runID: runID, action: .startNow)
            notice = "Started without waiting."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func scheduleResume(runID: RunID, modelChange: RunModelChange?) -> Bool {
        guard let run = runs.first(where: { $0.id == runID }) else {
            errorMessage = "This run is no longer available."
            return false
        }
        guard [.ready, .needsAttention, .failed].contains(run.status) else {
            errorMessage = "A \(run.status.displayName.lowercased()) run cannot start."
            return false
        }
        if let modelChange {
            guard canChangeModel(in: run), modelChange.matchesRunVersion(run.updatedAt) else {
                errorMessage = "This run changed. Close the model picker and review its latest state."
                return false
            }
            guard availableRunModels(for: modelChange.providerID).contains(modelChange.model),
                  run.assignments.contains(where: {
                      $0.status != .completed && $0.providerID == modelChange.providerID && $0.model != modelChange.model
                  }) else {
                errorMessage = "Choose a different available model for an unfinished assignment."
                return false
            }
        }
        let assignmentIDs = Set(run.assignments.map(\.id))
        guard modelChange != nil || !pendingApprovals.contains(where: { assignmentIDs.contains($0.assignmentID) }) else {
            errorMessage = "Respond to the pending approval or cancel the run before retrying."
            return false
        }
        guard !run.assignments.contains(where: { $0.hasIndeterminateProviderStart }) else {
            errorMessage = "The earlier provider start is unconfirmed. Cancel the run and inspect its working copy before starting again."
            return false
        }
        guard run.assignments.lazy.filter({ $0.status != .completed }).allSatisfy({
            availableProviderIDs.contains($0.providerID)
        }) else {
            errorMessage = "A required provider is unavailable. Restore it in Settings before retrying."
            return false
        }
        guard scheduledResumeRunIDs.insert(runID).inserted || modelChange != nil else {
            notice = "Retry is already starting."
            return true
        }
        guard pendingRunControls[runID] == nil else {
            scheduledResumeRunIDs.remove(runID)
            notice = "That run action is already being processed."
            return false
        }
        beginPendingRunControl(.resume, runID: runID, status: run.status)

        errorMessage = nil
        notice = run.status == .ready
            ? "Run started."
            : "Retry started in a fresh provider task."
        Task { @MainActor [weak self] in
            await self?.resumeInBackground(runID, modelChange: modelChange)
        }
        return true
    }

    private func resumeInBackground(_ runID: RunID, modelChange: RunModelChange?) async {
        defer { scheduledResumeRunIDs.remove(runID) }
        do {
            try await controlRun(runID: runID, action: .resume, modelChange: modelChange)
            reconcilePendingRunControls()
        } catch {
            clearPendingRunControl(runID)
            errorMessage = error.localizedDescription
            notifyStateDidChange()
        }
    }

    private func beginPendingRunControl(
        _ action: PendingRunControl.Action,
        runID: RunID,
        status: RunStatus
    ) {
        let pending = PendingRunControl(action: action, statusBeforeRequest: status)
        pendingRunControls[runID] = pending
        notifyStateDidChange()
        runControlTimeoutTasks.removeValue(forKey: runID)?.cancel()
        runControlTimeoutTasks[runID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self, self.pendingRunControls[runID] == pending else { return }
            self.clearPendingRunControl(runID)
            self.errorMessage = "The host accepted this run control, but its state did not update. Refresh and try again."
            self.notifyStateDidChange()
        }
    }

    private func clearPendingRunControl(_ runID: RunID) {
        pendingRunControls.removeValue(forKey: runID)
        runControlTimeoutTasks.removeValue(forKey: runID)?.cancel()
        notifyStateDidChange()
    }

    private func reconcilePendingRunControls() {
        for (runID, pending) in pendingRunControls {
            guard let run = runs.first(where: { $0.id == runID }) else {
                clearPendingRunControl(runID)
                continue
            }
            if run.status != pending.statusBeforeRequest || run.updatedAt > pending.requestedAt {
                clearPendingRunControl(runID)
            }
        }
    }

    @discardableResult
    public func followUp(runID: RunID, text: String) async -> Bool {
        if let continuityStore {
            return acceptClientAcknowledgement(
                await continuityStore.followUp(runID: runID, text: text),
                successNotice: "Follow-up delivered to the active run."
            )
        }
        do {
            try await followUpRun(runID: runID, text: text)
            notice = "Follow-up delivered to the active run."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func showRun(_ id: RunID) async {
        guard let run = runs.first(where: { $0.id == id }) else {
            errorMessage = "This run is no longer in the loaded history. Open Runs to choose an available result."
            return
        }
        selectedRunHistorySnapshot = nil
        selectedRunID = id
        errorMessage = nil
        if continuityStore != nil {
            selectedRunGraph = clientGraph(for: run)
            await refreshLocalRunSnapshot(id)
            return
        }
        pendingApprovals = await manageApproval.pending()
        selectedRunGraph = (try? await buildGraph(
            assignments: run.assignments,
            codexTasks: codexHelperActivities(in: run),
            providerID: selectedProviderID
        )) ?? .empty
    }

    public func dismissRun() {
        selectedRunID = nil
        selectedRunHistorySnapshot = nil
        selectedRunGraph = .empty
    }

    public func reuseRequest(from run: RunRecord) {
        if let continuityStore {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = acceptClientAcknowledgement(
                    await continuityStore.reuseRequest(from: run.id),
                    successNotice: "Request restored from the authoritative run snapshot."
                )
                guard accepted else { return }
                destination = .home
                selectedRunID = nil
                selectedRunGraph = .empty
            }
            return
        }
        prompt = run.plan.interpretedGoal
        replacePromptAttachments(run.plan.attachments)
        promptScope = .all
        promptProjectIDs.removeAll()
        promptAgentTargets.removeAll()
        proposedPlan = nil
        selectedRunResourceIDs = []
        selectedRunID = nil
        selectedRunGraph = .empty
        destination = .home
        notice = "Request restored. Goby will route it against the current projects, agents, resources, and approval policy."
        notifyStateDidChange()
    }

    /// Flushes the exact local draft and reviewed-plan state before the
    /// single-writer lease can move to another process.
    public func checkpointOperationalContinuity() async throws {
        guard let operationalContinuityRepository else { return }
        operationalContinuitySaveTask?.cancel()
        await operationalContinuitySaveTask?.value
        try await operationalContinuityRepository.saveOperationalContinuity(
            operationalContinuitySnapshot()
        )
    }

    public func loadCoordinatorCheckpoint(hostID: HostID) async throws -> GADCoordinatorCheckpoint? {
        try await coordinatorCheckpointRepository?.loadCoordinatorCheckpoint(hostID: hostID)
    }

    public func saveCoordinatorCheckpoint(_ checkpoint: GADCoordinatorCheckpoint) async throws {
        try await coordinatorCheckpointRepository?.saveCoordinatorCheckpoint(checkpoint)
    }

    public func prepareDiagnosticExport() async -> Bool {
        if let continuityStore {
            guard let preview = await continuityStore.hostAdminPreview(for: .exportRedactedDiagnostics),
                  let data = await continuityStore.redactedDiagnostics(using: preview),
                  let report = String(data: data, encoding: .utf8) else {
                errorMessage = "The host could not prepare the redacted diagnostic report."
                return false
            }
            diagnosticReport = report
            errorMessage = nil
            return true
        }
        var succeeded = false
        await perform {
            diagnosticReport = try await generateDiagnostics(lab: lab, runs: runs, health: systemHealth)
            succeeded = true
        }
        return succeeded
    }

    public func registerResources(_ urls: [URL]) async {
        if continuityStore != nil {
            guard let desktopHostAdministration else {
                errorMessage = "The local host authorization channel is unavailable."
                return
            }
            do {
                try await desktopHostAdministration.registerResources(at: urls)
                notice = urls.count == 1
                    ? "Added 1 shared resource folder."
                    : "Added \(urls.count) shared resource folders."
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        await perform {
            try await registerSharedResources(urls: urls)
            sharedResources = try await loadSharedResources()
            notice = urls.count == 1 ? "Added 1 shared resource folder." : "Added \(urls.count) shared resource folders."
        }
    }

    public func setResource(_ id: SharedResourceID, enabled: Bool) async {
        if continuityStore != nil,
           let resource = sharedResources.first(where: { $0.id == id }) {
            await commitClientAdmin(
                .setResourceAccess(resourceID: id, access: resource.access, enabled: enabled),
                successNotice: enabled ? "Shared resource restored." : "Shared resource removed from future runs."
            )
            return
        }
        await perform {
            try await setSharedResourceEnabled(id: id, enabled: enabled)
            sharedResources = try await loadSharedResources()
            notice = enabled ? "Shared resource restored." : "Shared resource access removed from future runs."
        }
    }

    public func setResourceAccess(_ resource: SharedResource, access: SharedResourceAccess) async {
        if continuityStore != nil {
            await commitClientAdmin(
                .setResourceAccess(resourceID: resource.id, access: access, enabled: resource.isEnabled),
                successNotice: access == .readWrite
                    ? "Read and write intent saved; runtime approvals still apply."
                    : "Shared resource returned to read-only access."
            )
            return
        }
        await perform {
            try await setSharedResourceAccess(resource, access: access)
            sharedResources = try await loadSharedResources()
            notice = access == .readWrite
                ? "Read and write intent saved for future runs; runtime approvals still apply."
                : "Shared resource returned to read-only access."
        }
    }

    public func applyRemoteResourceSettings(
        id: SharedResourceID,
        access: SharedResourceAccess,
        enabled: Bool
    ) async -> Bool {
        var succeeded = false
        await perform {
            try await setSharedResourceSettings(id: id, access: access, enabled: enabled)
            sharedResources = try await loadSharedResources()
            notice = enabled
                ? "Shared resource settings updated for future runs; runtime approvals still apply."
                : "Shared resource access removed from future runs."
            succeeded = true
        }
        return succeeded
    }

    public var rememberedCommandApprovals: [RememberedCommandApproval] = []
    public var rememberedApprovalsError: String?
    public private(set) var hasLoadedRememberedCommandApprovals = false

    public var supportsRememberedCommandApprovals: Bool {
        continuityStore.map { $0.session?.supportsRememberedCommandApprovals == true } ?? true
    }

    public func canRememberCommand(_ approval: ProviderApprovalRequest) async -> Bool {
        guard approval.canAccept, approval.hasRememberedScopeOffer else { return false }
        if continuityStore != nil { return canAllow(approval) && supportsRememberedCommandApprovals }
        return await manageApproval.canRemember(approval)
    }

    public func refreshRememberedCommandApprovals() async {
        rememberedApprovalsError = nil
        defer { hasLoadedRememberedCommandApprovals = true }
        if let continuityStore {
            guard let acknowledgement = await continuityStore.rememberedApprovals(.list),
                  acknowledgement.disposition == .accepted,
                  case let .rememberedApprovals(rules) = acknowledgement.artifact else {
                rememberedCommandApprovals = []
                rememberedApprovalsError = "Remembered approvals are unavailable. Reconnect to this Mac and retry."
                return
            }
            rememberedCommandApprovals = rules
        } else {
            do { rememberedCommandApprovals = try await manageApproval.remembered() }
            catch { rememberedApprovalsError = error.localizedDescription }
        }
    }

    public func revokeRememberedCommandApproval(_ id: UUID) async {
        rememberedApprovalsError = nil
        if let continuityStore {
            guard let acknowledgement = await continuityStore.rememberedApprovals(.revoke(id)),
                  acknowledgement.disposition == .accepted else {
                rememberedApprovalsError = "Goby could not revoke this rule. Reconnect and retry."
                return
            }
        } else {
            do { try await manageApproval.revoke(id) }
            catch { rememberedApprovalsError = error.localizedDescription; return }
        }
        await refreshRememberedCommandApprovals()
    }

    public func setRememberedApprovalProjectEnabled(_ projectID: ProjectID, enabled: Bool) async {
        rememberedApprovalsError = nil
        if let continuityStore {
            guard let acknowledgement = await continuityStore.rememberedApprovals(
                .setProjectEnabled(projectID, enabled)
            ), acknowledgement.disposition == .accepted else {
                rememberedApprovalsError = "Goby could not update this project's saved approvals. Reconnect and retry."
                return
            }
        } else {
            do { try await manageApproval.setProjectEnabled(projectID, enabled: enabled) }
            catch { rememberedApprovalsError = error.localizedDescription; return }
        }
        await refreshRememberedCommandApprovals()
    }

    @discardableResult
    public func respond(to approval: ProviderApprovalRequest, decision: ProviderApprovalDecision) async -> Bool {
        if let continuityStore {
            guard let projected = continuityStore.projection?.approvals.first(where: { $0.id == approval.id }) else {
                errorMessage = "This approval is no longer pending. Refresh the run before trying again."
                return false
            }
            if decision == .accept || decision == .acceptAlways || decision == .acceptForSession || decision == .acceptAllForRun,
               !canAllow(approval) {
                errorMessage = "Review the current exact request before allowing it."
                return false
            }
            if decision == .acceptAlways, !(await canRememberCommand(approval)) {
                errorMessage = RememberedCommandApprovalError.unavailable.localizedDescription
                return false
            }
            let action: GADApprovalAction = switch decision {
            case .accept, .acceptAlways, .acceptForSession, .acceptAllForRun: .allowOnce
            case .decline: .decline
            case .cancel: .cancel
            }
            let assertion = action == .allowOnce
                ? "macos-local-confirmed"
                : nil
            let accepted = acceptClientAcknowledgement(
                await continuityStore.respond(
                    to: projected,
                    action: action,
                    authorizationAssertion: assertion,
                    rememberCommand: decision == .acceptAlways
                ),
                successNotice: decision == .acceptAlways ? "Always Allow saved. Matching requests will continue automatically. Pause the project's saved approvals in Settings → Saved Approvals." : nil
            )
            remoteApprovalDisclosures.removeValue(forKey: approval.id)
            return accepted
        }
        errorMessage = nil
        do {
            try await manageApproval.respond(to: approval, decision: decision)
            pendingApprovals = await manageApproval.pending()
            if decision == .acceptAlways {
                notice = "Always Allow saved. Matching requests will continue automatically. Pause the project's saved approvals in Settings → Saved Approvals."
            } else if decision == .acceptAllForRun || decision == .acceptForSession {
                notice = "This approval was allowed once. Wider provider-session and text-matched run grants stay disabled until exact structured scope is available."
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Fetches the short-lived exact approval disclosure only when a client
    /// projection intentionally omitted it. Callers should keep the returned
    /// value scoped to the active inspector rather than persist it.
    public func disclosedApproval(
        _ approval: ProviderApprovalRequest
    ) async -> ProviderApprovalRequest {
        guard let continuityStore else { return approval }
        if let cached = remoteApprovalDisclosures[approval.id], canAllow(cached.request) {
            return cached.request
        }
        if let pending = approvalDisclosureTasks[approval.id] { return await pending.task.value }
        let taskID = UUID()
        let task = Task { await self.fetchApprovalDisclosure(approval, from: continuityStore) }
        approvalDisclosureTasks[approval.id] = (taskID, task)
        let result = await task.value
        if approvalDisclosureTasks[approval.id]?.id == taskID {
            approvalDisclosureTasks.removeValue(forKey: approval.id)
        }
        return result
    }

    private func fetchApprovalDisclosure(
        _ approval: ProviderApprovalRequest, from continuityStore: ContinuityStore
    ) async -> ProviderApprovalRequest {
        let source = continuityStore.projection?.approvals.first { $0.id == approval.id }
        guard let source, source.providerID == approval.providerID, source.assignmentID == approval.assignmentID,
              let disclosure = await continuityStore.approvalDisclosure(for: approval.id),
              let current = continuityStore.projection?.approvals.first(where: { $0.id == approval.id }),
              RemoteApprovalDisclosure(source: source, request: approval).matches(current),
              !Task.isCancelled else {
            let unavailableSummary = approval.disclosureComplete
                ? "Exact request details are temporarily unavailable. Try showing them again."
                : "Exact request details were not captured. Decline this request and retry the action."
            return ProviderApprovalRequest(
                id: approval.id,
                providerID: approval.providerID,
                assignmentID: approval.assignmentID,
                kind: approval.kind,
                summary: unavailableSummary,
                details: nil,
                canAccept: false,
                approvalSessionID: approval.approvalSessionID,
                operationDigest: approval.operationDigest,
                disclosureComplete: approval.disclosureComplete
            )
        }
        let disclosed = ProviderApprovalRequest(
            id: approval.id,
            providerID: approval.providerID,
            assignmentID: approval.assignmentID,
            kind: source.kind,
            summary: disclosure.summary,
            details: disclosure.details,
            canAccept: source.actions.contains(.allowOnce),
            approvalSessionID: source.approvalSessionID,
            operationDigest: source.operationDigest,
            disclosureComplete: source.disclosureComplete,
            displayTextIsExactVisible: true,
            rememberedCommandScope: disclosure.rememberedCommandScope,
            rememberedFileChangeScope: disclosure.rememberedFileChangeScope
        )
        remoteApprovalDisclosures[approval.id] = RemoteApprovalDisclosure(source: source, request: disclosed)
        if let index = pendingApprovals.firstIndex(where: { $0.identity == approval.identity }) {
            pendingApprovals[index] = disclosed
        }
        return disclosed
    }

    public func canAllow(_ approval: ProviderApprovalRequest) -> Bool {
        guard approval.canAccept else { return false }
        if let continuityStore {
            guard let cached = remoteApprovalDisclosures[approval.id], cached.request.canAccept,
                  cached.accepts(approval),
                  let current = continuityStore.projection?.approvals.first(where: { $0.id == approval.id }),
                  cached.matches(current) else { return false }
            return continuityStore.hasCurrentApprovalDisclosure(for: approval.id)
        }
        return approval.hasCompleteOperationBinding
    }

    public func clearMessages() {
        errorMessage = nil
        notice = nil
    }

    public func reportStartupFailure(_ message: String) {
        errorMessage = message
        hasRestoredLab = true
    }

    public func dismissNotice() {
        notice = nil
    }

    public func moveMapNode(
        _ nodeID: GraphNodeID,
        to preferredPosition: GraphPoint,
        relativeTo projectPosition: GraphPoint?
    ) {
        commitMapLayout(mapLayoutOverrides.preferring(
            nodeID,
            at: preferredPosition,
            relativeTo: projectPosition
        ))
    }

    public func setAgentMapVisibility(_ target: AgentRouteTarget, isVisible: Bool) {
        commitMapLayout(mapLayoutOverrides.settingAgentVisibility(target, isVisible: isVisible))
    }

    public func resetMapNodePosition(_ nodeID: GraphNodeID) {
        commitMapLayout(mapLayoutOverrides.resetting(nodeID))
    }

    public func resetMapLayout() {
        guard !mapLayoutOverrides.isEmpty else { return }
        commitMapLayout(mapLayoutOverrides.resettingPositions())
        notice = "Restored the automatic map layout."
    }

    public func presentError(_ message: String) {
        errorMessage = message
    }

    public func saveAutomation(_ draft: AutomationDefinition) async {
        let expectedRevision = automationSnapshot.definitions
            .first(where: { $0.id == draft.id })?.revision
        await saveAutomation(draft, expectedRevision: expectedRevision)
    }

    public func saveAutomation(
        _ draft: AutomationDefinition,
        expectedRevision: Int?
    ) async {
        if let continuityStore {
            await performClientCommand {
                await continuityStore.saveAutomation(
                    draft,
                    expectedRevision: expectedRevision
                )
            }
            return
        }
        guard let saveAutomationUseCase, let loadAutomationsUseCase else {
            errorMessage = "Automations are unavailable in this host."
            return
        }
        await perform {
            _ = try await saveAutomationUseCase(
                draft,
                expectedRevision: expectedRevision
            )
            automationSnapshot = try await loadAutomationsUseCase()
            notice = draft.id.rawValue.isEmpty ? "Automation saved." : "Saved \(draft.name)."
        }
    }

    public func setAutomationState(
        id: AutomationID,
        state: AutomationState
    ) async {
        guard let expectedRevision = automationSnapshot.definitions
            .first(where: { $0.id == id })?.revision else {
            errorMessage = GobyApplicationError.unknownAutomation(id).localizedDescription
            return
        }
        await setAutomationState(
            id: id,
            state: state,
            expectedRevision: expectedRevision
        )
    }

    public func setAutomationState(
        id: AutomationID,
        state: AutomationState,
        expectedRevision: Int
    ) async {
        if let continuityStore {
            await performClientCommand {
                await continuityStore.setAutomationState(
                    id: id,
                    state: state,
                    expectedRevision: expectedRevision
                )
            }
            return
        }
        guard let setAutomationStateUseCase, let loadAutomationsUseCase else {
            errorMessage = "Automations are unavailable in this host."
            return
        }
        await perform {
            _ = try await setAutomationStateUseCase(
                id: id,
                state: state,
                expectedRevision: expectedRevision
            )
            automationSnapshot = try await loadAutomationsUseCase()
            notice = state == .active ? "Automation resumed." : "Automation paused."
        }
    }

    public func deleteAutomation(id: AutomationID) async {
        guard let expectedRevision = automationSnapshot.definitions
            .first(where: { $0.id == id })?.revision else {
            errorMessage = GobyApplicationError.unknownAutomation(id).localizedDescription
            return
        }
        await deleteAutomation(id: id, expectedRevision: expectedRevision)
    }

    public func deleteAutomation(
        id: AutomationID,
        expectedRevision: Int
    ) async {
        if let continuityStore {
            await performClientCommand {
                await continuityStore.deleteAutomation(
                    id: id,
                    expectedRevision: expectedRevision
                )
            }
            return
        }
        guard let deleteAutomationUseCase, let loadAutomationsUseCase else {
            errorMessage = "Automations are unavailable in this host."
            return
        }
        await perform {
            try await deleteAutomationUseCase(
                id: id,
                expectedRevision: expectedRevision
            )
            automationSnapshot = try await loadAutomationsUseCase()
            notice = "Automation deleted. Its completed run history was retained."
        }
    }

    public func runAutomationNow(id: AutomationID) async {
        guard let revision = automationSnapshot.definitions
            .first(where: { $0.id == id })?.revision else {
            errorMessage = "This automation is no longer available."
            return
        }
        await runAutomationNow(id: id, expectedRevision: revision)
    }

    public func runAutomationNow(
        id: AutomationID,
        expectedRevision: Int
    ) async {
        if let continuityStore {
            await performClientCommand {
                await continuityStore.runAutomationNow(
                    id: id,
                    expectedRevision: expectedRevision
                )
            }
            return
        }
        guard let automationCoordinator else {
            errorMessage = "The automation scheduler is unavailable in this host."
            return
        }
        await perform {
            _ = try await automationCoordinator.runNow(
                automationID: id,
                expectedRevision: expectedRevision,
                at: .now
            )
            if let loadAutomationsUseCase {
                automationSnapshot = try await loadAutomationsUseCase()
            }
            notice = "Automation started."
        }
    }

    public func reviewAndRunAutomationOccurrence(
        id: AutomationOccurrenceID,
        reviewBinding: AutomationReviewBinding,
        approved: Bool,
        selectedResourceIDs: Set<SharedResourceID> = []
    ) async {
        guard let occurrence = automationSnapshot.occurrences.first(where: { $0.id == id }),
              let plan = occurrence.currentReviewAttempt?.plan else {
            errorMessage = GobyApplicationError.automationOccurrenceNotReviewable(id).localizedDescription
            return
        }
        guard occurrence.currentReviewBinding == reviewBinding else {
            errorMessage = "This automation action changed. Reopen its current review before running."
            return
        }
        if let continuityStore {
            await performClientCommand(successNotice: "Automation action started after review.") {
                await continuityStore.reviewAndRunAutomationOccurrence(
                    id: id,
                    reviewBinding: reviewBinding,
                    authorizationAssertion: approved && plan.requiresApproval
                        ? "macos-local-confirmed"
                        : nil,
                    selectedResourceIDs: selectedResourceIDs.sorted { $0.rawValue < $1.rawValue }
                )
            }
            return
        }
        guard let automationCoordinator else {
            errorMessage = "The automation scheduler is unavailable in this host."
            return
        }
        await perform {
            let receipt = approved && plan.requiresApproval
                ? ApprovalReceipt(
                    runID: plan.id,
                    decision: .approved,
                    operationIDs: Set(plan.gitOperations.map(\.id))
                )
                : nil
            try await automationCoordinator.reviewAndRun(
                occurrenceID: id,
                reviewBinding: reviewBinding,
                receipt: receipt,
                selectedResourceIDs: selectedResourceIDs
            )
            if let loadAutomationsUseCase {
                automationSnapshot = try await loadAutomationsUseCase()
            }
            notice = "Automation action started after review."
        }
    }

    public func missingAutomationAgents(
        for occurrenceID: AutomationOccurrenceID
    ) -> AutomationAgentRecoveryPlan? {
        guard let plan = AutomationAgentRecoveryPolicy.plan(
            for: occurrenceID, in: automationSnapshot, lab: lab
        ), plan.providerID == .codex else { return nil }
        return plan
    }

    public func addMissingAutomationAgents(_ plan: AutomationAgentRecoveryPlan) async -> Bool {
        if continuityStore != nil {
            guard !isBusy else { return false }
            isBusy = true
            defer { isBusy = false }
            await commitClientAdmin(
                .addMissingAutomationAgents(plan),
                successNotice: "Added missing agents. Review the paused automation before resuming it."
            )
            return errorMessage == nil
        }
        guard let addMissingAutomationAgentsUseCase else {
            errorMessage = "Automatic agent creation is unavailable in this host."
            return false
        }
        await perform {
            do {
                let created = try await addMissingAutomationAgentsUseCase(plan)
                notice = "Added \(created.count) missing agents. Review the paused automation before resuming it."
            } catch {
                // Keep partial success visible so recovery only adds remaining roles.
                if let (updatedLab, updatedRuns) = try? await loadDashboard() {
                    lab = updatedLab
                    runs = updatedRuns
                    try? await refreshGraph()
                }
                throw error
            }
            let (updatedLab, updatedRuns) = try await loadDashboard()
            lab = updatedLab
            runs = updatedRuns
            try await refreshGraph()
        }
        return errorMessage == nil
    }

    public func cancelAutomationOccurrence(id: AutomationOccurrenceID) async {
        if let continuityStore {
            await performClientCommand {
                await continuityStore.cancelAutomationOccurrence(id: id)
            }
            return
        }
        guard let automationCoordinator else {
            errorMessage = "The automation scheduler is unavailable in this host."
            return
        }
        await perform {
            try await automationCoordinator.cancel(occurrenceID: id)
            if let loadAutomationsUseCase {
                automationSnapshot = try await loadAutomationsUseCase()
            }
            notice = "Automation occurrence cancelled."
        }
    }

    private func discardRevokedClientState() {
        // A revoked core must also erase the desktop facade, not just its
        // underlying continuity store. Suppress autosaves during this reset.
        isHydratingClientProjection = true
        defer { isHydratingClientProjection = false }
        clientDraftSaveTask?.cancel()
        clientPlanSaveTask?.cancel()
        pendingClientPlanUpdate = nil
        clientPlanUpdateRevision &+= 1
        pendingClientSelection = nil
        observedClientSelection = nil
        prompt = ""
        replacePromptAttachments([])
        promptModelID = nil
        promptScope = .all
        promptProjectIDs = []
        promptAgentTargets = []
        promptProjectGroupID = nil
        lab = .empty
        runs = []
        pendingRunControls = [:]
        runControlTimeoutTasks.values.forEach { $0.cancel() }
        runControlTimeoutTasks = [:]
        localPresentationRefreshTask?.cancel()
        localPresentationRefreshTask = nil
        localCatalogSnapshot = nil
        localRunSnapshots = [:]
        selectedRunHistorySnapshot = nil
        omittedRunHistoryCount = 0
        omittedAutomationHistoryCount = 0
        automationSnapshot = .empty
        graph = .empty
        selectedRunID = nil
        selectedRunGraph = .empty
        proposedPlan = nil
        selectedRunResourceIDs = []
        instructionPacks = []
        sharedResources = []
        pendingApprovals = []
        remoteApprovalDisclosures.removeAll()
        approvalDisclosureTasks.values.forEach { $0.task.cancel() }
        approvalDisclosureTasks.removeAll()
        rememberedCommandApprovals = []
        rememberedApprovalsError = nil
        hasLoadedRememberedCommandApprovals = false
        codexTasks = []
        codexAccount = nil
        providerAccounts = []
        providerTasks = []
        codexState = .failed("Background-host access was revoked.")
        systemHealth = .init(checks: [])
        projectGitBranches = [:]
        importCandidates = []
        codexSyncPlan = nil
        agentImportPlan = nil
        clientAgentReviewHashes = [:]
        clientImportURLsByID = [:]
        diagnosticReport = nil
        errorMessage = "Background-host access was revoked. Reopen Goby to establish a new authorized session."
    }

    private func hydrateClientProjection(_ projection: DashboardProjection) {
        guard let continuityStore else { return }
        let previouslySelectedRun = selectedRun
        isHydratingClientProjection = true
        defer { isHydratingClientProjection = false }

        let graphProviderID = pendingClientSelection == nil && pendingClientPlanUpdate == nil
            ? projection.draft.providerID : selectedProviderID
        let adapted = ClientProjectionAdapter().adapt(projection, providerID: graphProviderID)
        lab = mergedClientLab(adapted.lab)
        runs = adapted.runs.map { projected in
            guard let local = localRunSnapshots[projected.id],
                  local.updatedAt == projected.updatedAt else { return projected }
            return local
        }
        automationSnapshot = projection.automations
        // The host owns trust; a connected dashboard only mirrors it.
        trustedProjectIDs = Set(projection.projects.filter { $0.isTrusted == true }.map(\.id))
        graph = graph(adapted.graph, using: lab)
        instructionPacks = adapted.instructions
        sharedResources = mergedClientResources(adapted.resources)
        remoteApprovalDisclosures = remoteApprovalDisclosures.filter { id, cached in
            projection.approvals.contains { $0.id == id && cached.matches($0) }
                && continuityStore.hasCurrentApprovalDisclosure(for: id)
        }
        pendingApprovals = adapted.approvals.map { remoteApprovalDisclosures[$0.id]?.request ?? $0 }
        codexTasks = adapted.codexTasks
        codexAccount = adapted.codexAccount
        providerAccounts = adapted.providerAccounts
        providerTasks = adapted.providerTasks
        omittedRunHistoryCount = max(0, projection.host.omittedHistoryRunCount ?? 0)
        omittedAutomationHistoryCount = max(0, projection.host.omittedAutomationOccurrenceCount ?? 0)
        temporaryChat = projection.host.temporaryChat.map(TemporaryChat.init(projection:))
        systemHealth = adapted.health
        if let pendingClientPlanUpdate, adapted.plan?.id == pendingClientPlanUpdate.planID {
            // Provider events and older acknowledgements must not replace
            // scope the user is still editing or waiting to save.
        } else {
            pendingClientPlanUpdate = nil
            proposedPlan = pendingClientSelection == nil ? adapted.plan : nil
            selectedRunResourceIDs = adapted.selectedResourceIDs
        }
        availableProviderIDs = adapted.availableProviderIDs
        codexState = adapted.codexState
        reconcilePendingRunControls()
        let projectedCodexAccount = projection.providerAccounts.first { $0.providerID == .codex }
        if let freshness = projectedCodexAccount?.activityFreshness {
            codexActivityRefresh = freshness
        } else if case .connected = adapted.codexState {
            codexActivityRefresh = .fresh(at: projectedCodexAccount?.observedAt ?? projection.generatedAt)
        } else {
            codexActivityRefresh = codexActivityRefresh.markingStale(at: projection.generatedAt)
        }
        func hasConfiguredCredential(for providerID: AgentProviderID) -> Bool {
            guard let account = projection.providerAccounts.first(where: { $0.providerID == providerID }) else {
                return false
            }
            return account.credentialConfigured ?? account.connectionState.isConfigured
        }
        // The Mac UI reads Claude's two slots from the shared Keychain instead;
        // the projection only says whether any Claude credential is saved.
        if desktopHostAdministration == nil {
            claudeCredentialConfigured = hasConfiguredCredential(for: .claude)
        }
        copilotCredentialConfigured = hasConfiguredCredential(for: .githubCopilot)

        let draft = projection.draft
        if pendingClientSelection == nil, pendingClientPlanUpdate == nil {
            let selection = clientSelection(for: draft)
            selectedProviderID = adapted.availableProviderIDs.contains(selection.providerID) ? selection.providerID : .codex
            promptModelID = selection.model
            promptScope = selection.scope
            promptProjectIDs = selection.projectIDs
            promptAgentTargets = Set(selection.agentTargets.filter(canDirectlyAssignAgent))
            promptProjectGroupID = selection.groupID
        }
        prompt = continuityStore.draftText
        replacePromptAttachments(continuityStore.draftAttachments)
        if !promptAgentTargets.isEmpty {
            promptProjectIDs.formUnion(promptAgentTargets.map(\.projectID))
        }
        observedClientSelection = currentClientSelection

        if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) {
            if omittedRunHistoryCount > 0, let previouslySelectedRun,
               previouslySelectedRun.status.isFinished {
                // A display-window change must not dismiss a completed result
                // the user is still reviewing. Keep only this visible snapshot.
                selectedRunHistorySnapshot = previouslySelectedRun
            } else {
                dismissRun()
            }
        } else if let selectedRunID,
                  let run = runs.first(where: { $0.id == selectedRunID }) {
            selectedRunHistorySnapshot = nil
            selectedRunGraph = clientGraph(for: run)
        }
    }

    private func scheduleLocalPresentationRefresh() {
        guard desktopHostAdministration != nil else { return }
        localPresentationRefreshTask?.cancel()
        localPresentationRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshLocalPresentationState()
        }
    }

    private func refreshLocalPresentationState() async {
        guard let desktopHostAdministration else { return }
        claudeCredentialConfigured = await desktopHostAdministration.providerCredentialConfigured(
            providerID: .claude,
            kind: .apiKey
        )
        claudeSubscriptionConfigured = await desktopHostAdministration.providerCredentialConfigured(
            providerID: .claude,
            kind: .subscriptionToken
        )
        do {
            let snapshot = try await desktopHostAdministration.localCatalogSnapshot()
            guard !Task.isCancelled else { return }
            localCatalogSnapshot = snapshot
            lab = mergedClientLab(lab)
            sharedResources = mergedClientResources(sharedResources)
            graph = graph(graph, using: lab)
            if let selectedRunID {
                await refreshLocalRunSnapshot(selectedRunID)
            }
            // The conversation on Home needs the full run, including its typed
            // steps, which the path-free projection does not carry.
            if case let .run(threadRunID) = activeThread, threadRunID != selectedRunID {
                await refreshLocalRunSnapshot(threadRunID)
            }
        } catch {
            // The path-free projection remains safe and usable while the signed
            // local administration channel reconnects on a later host update.
        }
    }

    private func refreshLocalRunSnapshot(_ runID: RunID) async {
        guard let desktopHostAdministration else { return }
        do {
            let run = try await desktopHostAdministration.localRunSnapshot(runID: runID)
            guard !Task.isCancelled else { return }
            localRunSnapshots[runID] = run
            if let index = runs.firstIndex(where: { $0.id == runID }) {
                runs[index] = run
            }
            if selectedRunID == runID {
                selectedRunGraph = clientGraph(for: run)
            }
            reconcilePendingRunControls()
        } catch {
            // A projection update can race run retention. The projected record
            // remains the canonical fallback and the next update retries.
        }
    }

    private func clientGraph(for run: RunRecord) -> GraphLayoutSnapshot {
        ClientProjectionAdapter().graph(
            lab: lab,
            runs: [run],
            tasks: selectedProviderID == .codex ? codexHelperActivities(in: run) : [],
            providerID: selectedProviderID
        )
    }

    private func mergedClientLab(_ projected: LabSnapshot) -> LabSnapshot {
        guard let localCatalogSnapshot else { return projected }
        let projects = Dictionary(uniqueKeysWithValues: localCatalogSnapshot.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: localCatalogSnapshot.agents.map { ($0.id, $0) })
        return LabSnapshot(
            projects: projected.projects.map { projects[$0.id] ?? $0 },
            agents: projected.agents.map { agents[$0.id] ?? $0 },
            projectGroups: projected.projectGroups,
            projectProviderConfigurations: projected.projectProviderConfigurations,
            providerBindings: projected.providerBindings,
            providerCollaborationSets: projected.providerCollaborationSets,
            agentHandoffLinks: projected.agentHandoffLinks,
            handoffs: projected.handoffs
        )
    }

    private func mergedClientResources(_ projected: [SharedResource]) -> [SharedResource] {
        guard let localCatalogSnapshot else { return projected }
        let resources = Dictionary(
            uniqueKeysWithValues: localCatalogSnapshot.resources.map { ($0.id, $0) }
        )
        return projected.map { resources[$0.id] ?? $0 }
    }

    private func graph(
        _ projected: GraphLayoutSnapshot,
        using lab: LabSnapshot
    ) -> GraphLayoutSnapshot {
        let projects = Dictionary(uniqueKeysWithValues: lab.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: lab.agents.map { ($0.id, $0) })
        return GraphLayoutSnapshot(
            nodes: projected.nodes.map { node in
                let kind: GraphNodeKind = switch node.kind {
                case let .project(project, status):
                    .project(projects[project.id] ?? project, statusSummary: status)
                case let .agent(agent, assignment):
                    .agent(agents[agent.id] ?? agent, assignment: assignment)
                case .cluster, .codexTask:
                    node.kind
                }
                return GraphNode(id: node.id, kind: kind, position: node.position)
            },
            edges: projected.edges
        )
    }

    private func clientCodexPlan(_ discovery: GADCodexCatalogDiscovery) -> CodexCatalogSyncPlan {
        let projects = discovery.projects.map { candidate in
            ProjectCandidate(
                project: LabProject(
                    id: candidate.id,
                    name: candidate.name,
                    rootURL: clientIdentityURL(kind: "project-review", id: candidate.id.rawValue),
                    platforms: Set(candidate.platforms),
                    isGitRepository: candidate.isGitRepository
                ),
                evidence: candidate.evidence,
                inspectionLevel: .metadataOnly
            )
        }
        let agents = discovery.agents.map { candidate in
            AgentImportCandidate(
                profile: AgentProfile(
                    id: candidate.id,
                    name: candidate.name,
                    summary: candidate.summary,
                    capabilities: Set(candidate.capabilities),
                    scope: clientAgentScope(candidate.scope),
                    sourceURL: candidate.requiresMacReview
                        ? clientIdentityURL(kind: "agent-review", id: candidate.id.rawValue)
                        : nil
                ),
                configurationPreview: candidate.summary,
                evidence: candidate.evidence
            )
        }
        return CodexCatalogSyncPlan(
            projects: projects,
            agents: AgentImportPlan(candidates: agents, suggestions: []),
            scannedProjectCount: discovery.scannedProjectCount,
            scannedAgentCount: discovery.scannedAgentCount,
            limitedProjectAccessCount: discovery.limitedProjectAccessCount,
            warnings: discovery.warnings
        )
    }

    private func clientAgentCandidate(
        _ candidate: GADAgentImportCandidateProjection
    ) -> AgentImportCandidate {
        AgentImportCandidate(
            profile: AgentProfile(
                id: candidate.id,
                name: candidate.name,
                summary: candidate.summary,
                instructions: candidate.instructions,
                capabilities: Set(candidate.capabilities),
                scope: clientAgentScope(candidate.scope),
                definitionReviewProvenance: .semanticOnly
            ),
            configurationPreview: candidate.instructions ?? candidate.summary,
            evidence: candidate.evidence + ["Executable source configuration stays on the Mac; this review imports an instruction-only copy."]
        )
    }

    private func instructionOnlyImportCandidate(
        _ candidate: AgentImportCandidate
    ) -> AgentImportCandidate {
        let profile = candidate.profile
        return AgentImportCandidate(
            profile: AgentProfile(
                id: profile.id,
                name: profile.name,
                summary: profile.summary,
                instructions: profile.instructions,
                capabilities: profile.capabilities,
                scope: profile.scope,
                definitionReviewProvenance: .semanticOnly,
                isEnabled: profile.isEnabled
            ),
            configurationPreview: profile.instructions ?? profile.summary,
            evidence: candidate.evidence + ["Imported as an instruction-only copy after semantic review; no source file or executable tool configuration was authorized."]
        )
    }

    private func clientAgentScope(_ scope: GADAgentScopeProjection) -> AgentScope {
        switch scope {
        case .global: .global
        case .union: .union
        case let .project(id): .project(id)
        }
    }

    private func clientIdentityURL(kind: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = "goby"
        components.host = kind
        components.path = "/\(id)"
        return components.url ?? URL(string: "goby://\(kind)")!
    }

    private var currentClientSelection: ClientDraftSelection {
        .init(providerID: selectedProviderID, model: promptModelID, scope: promptScope,
              projectIDs: promptProjectIDs, agentTargets: promptAgentTargets, groupID: promptProjectGroupID)
    }

    private func clientSelection(for draft: GADDraftProjection) -> ClientDraftSelection {
        let scope: PromptScope = switch draft.platform {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        case .backend, .general, .none: .all
        }
        return .init(providerID: draft.providerID, model: draft.model, scope: scope,
                     projectIDs: Set(draft.projectIDs).union(draft.agentTargets.map(\.projectID)),
                     agentTargets: Set(draft.agentTargets), groupID: draft.groupID)
    }

    private func completeClientSelectionSave() {
        guard !Task.isCancelled, continuityStore?.draftSyncPhase == .synced,
              let draft = continuityStore?.projection?.draft,
              pendingClientSelection == currentClientSelection,
              currentClientSelection == clientSelection(for: draft) else { return }
        pendingClientSelection = nil
    }

    private func scheduleClientDraftFlush() {
        guard let continuityStore, !isHydratingClientProjection,
              pendingClientPlanUpdate == nil else { return }
        let selection = currentClientSelection
        if let observedClientSelection, observedClientSelection != selection {
            pendingClientSelection = selection
        }
        observedClientSelection = selection
        continuityStore.updateDraft(prompt, attachments: promptAttachments)
        let platform: ProjectPlatform? = switch promptScope {
        case .all: nil
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        }
        clientDraftSaveGeneration &+= 1
        let generation = clientDraftSaveGeneration
        let precedingSave = clientDraftSaveTask
        clientDraftSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self, self.clientDraftSaveGeneration == generation else { return }
                // Once a draft mutation is admitted, its acknowledgement must
                // settle. A later edit or Send waits instead of cancelling it.
                await precedingSave?.value
                guard self.clientDraftSaveGeneration == generation,
                      !Task.isCancelled, let continuityStore = self.continuityStore else { return }
                await continuityStore.flushDraft(
                    providerID: self.selectedProviderID,
                    model: self.promptModelID,
                    platform: platform,
                    projectIDs: self.promptProjectIDs.sorted { $0.rawValue < $1.rawValue },
                    agentTargets: self.promptAgentTargets.sorted {
                        if $0.projectID != $1.projectID { return $0.projectID.rawValue < $1.projectID.rawValue }
                        if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
                        return $0.agentID.rawValue < $1.agentID.rawValue
                    },
                    groupID: self.promptProjectGroupID
                )
                self.completeClientSelectionSave()
                if case let .failed(message) = continuityStore.draftSyncPhase {
                    self.errorMessage = message
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func flushClientDraftNow(retriesAfterDeferredAdmission: Int = 0) async {
        guard let continuityStore else { return }
        clientDraftSaveGeneration &+= 1
        let generation = clientDraftSaveGeneration
        let precedingSave = clientDraftSaveTask
        await precedingSave?.value
        if clientDraftSaveGeneration == generation { clientDraftSaveTask = nil }
        guard !Task.isCancelled else { return }
        var remainingDeferredRetries = max(0, retriesAfterDeferredAdmission)
        while true {
            continuityStore.updateDraft(prompt, attachments: promptAttachments)
            let platform: ProjectPlatform? = switch promptScope {
            case .all: nil
            case .web: .web
            case .macOS: .macOS
            case .iOS: .iOS
            case .android: .android
            case .research: .research
            }
            await continuityStore.flushDraft(
                providerID: selectedProviderID,
                model: promptModelID,
                platform: platform,
                projectIDs: promptProjectIDs.sorted { $0.rawValue < $1.rawValue },
                agentTargets: promptAgentTargets.sorted {
                    if $0.projectID != $1.projectID { return $0.projectID.rawValue < $1.projectID.rawValue }
                    if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
                    return $0.agentID.rawValue < $1.agentID.rawValue
                },
                groupID: promptProjectGroupID
            )
            completeClientSelectionSave()
            guard remainingDeferredRetries > 0,
                  case .locallyModified = continuityStore.draftSyncPhase,
                  continuityStore.lastAcknowledgement?.wasDeferredBeforeAdmission == true else {
                return
            }
            remainingDeferredRetries -= 1
            await Task.yield()
        }
    }

    private func scheduleClientPlanUpdate() {
        guard let continuityStore, let plan = proposedPlan, !isHydratingClientProjection else { return }
        let update = GADPlanUpdate(
            planID: plan.id,
            routes: plan.routes.map {
                GADPlanRouteSelection(projectID: $0.projectID, agentIDs: $0.agentIDs)
            },
            selectedResourceIDs: selectedRunResourceIDs.sorted { $0.rawValue < $1.rawValue }
        )
        pendingClientPlanUpdate = update
        clientPlanUpdateRevision &+= 1
        let revision = clientPlanUpdateRevision
        // The host updates the draft's selection as part of a plan revision.
        // Sending a second draft replacement can race that authoritative write.
        clientDraftSaveTask?.cancel()
        pendingClientSelection = nil
        let precedingSave = clientPlanSaveTask
        clientPlanSaveTask = Task { @MainActor [weak self] in
            await precedingSave?.value
            do {
                guard self?.clientPlanUpdateRevision == revision else { return }
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard let self, self.clientPlanUpdateRevision == revision,
                      self.pendingClientPlanUpdate == update else { return }
                let acknowledgement = await continuityStore.updatePlan(
                    update.planID,
                    routes: update.routes,
                    selectedResourceIDs: update.selectedResourceIDs
                )
                guard !Task.isCancelled, self.clientPlanUpdateRevision == revision else { return }
                if self.acceptClientAcknowledgement(acknowledgement, successNotice: nil) {
                    guard let savedPlan = continuityStore.projection?.plan,
                          savedPlan.id == update.planID,
                          savedPlan.routes.count == update.routes.count,
                          update.routes.allSatisfy({ selection in
                              savedPlan.routes.contains {
                                  $0.projectID == selection.projectID
                                      && Set($0.agentIDs) == Set(selection.agentIDs)
                              }
                          }),
                          Set(savedPlan.selectedResourceIDs) == Set(update.selectedResourceIDs) else {
                        self.errorMessage = "The host has not confirmed the reviewed scope. Review the plan and try again."
                        return
                    }
                    self.pendingClientPlanUpdate = nil
                    if let projection = continuityStore.projection {
                        self.hydrateClientProjection(projection)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func performClientCommand(
        successNotice: String? = nil,
        _ operation: () async -> GADCommandAcknowledgement?
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        _ = acceptClientAcknowledgement(await operation(), successNotice: successNotice)
    }

    private func performClientRefresh(
        _ operation: () async -> GADCommandAcknowledgement?
    ) async {
        providerRefreshCount += 1
        defer { providerRefreshCount -= 1 }
        let acknowledgement = await operation()
        guard !Task.isCancelled else { return }
        // Background reads neither block the composer nor dismiss an unrelated
        // user-action error. A still-busy host is retried on the next poll.
        if acknowledgement?.disposition == .accepted { return }
        if acknowledgement?.disposition == .failedRecoverable,
           acknowledgement?.wasDeferredBeforeAdmission == true { return }
        // Read-only polling resumes through the connection recovery loop. Its
        // failures belong in the persistent status banner, not a modal alert.
        // A superseded read can also finish after recovery already succeeded.
        if acknowledgement == nil { return }
        _ = acceptClientAcknowledgement(acknowledgement, successNotice: nil)
    }

    private func commitClientAdmin(
        _ request: GADHostAdminRequest,
        successNotice: String?
    ) async {
        guard let continuityStore else { return }
        guard let preview = await continuityStore.hostAdminPreview(for: request) else {
            errorMessage = "The background host could not prepare this reviewed change. Refresh and try again."
            return
        }
        let assertion = preview.requiresLocalAuthentication ? "macos-local-confirmed" : nil
        _ = acceptClientAcknowledgement(
            await continuityStore.commitHostAdmin(
                preview,
                authorizationAssertion: assertion
            ),
            successNotice: successNotice
        )
    }

    private func saveClientProviderCredential(
        _ credential: String,
        providerID: AgentProviderID,
        kind: ProviderCredentialKind = .apiKey
    ) async -> Bool {
        guard let desktopHostAdministration else {
            errorMessage = "The local host authorization channel is unavailable."
            return false
        }
        do {
            try await desktopHostAdministration.saveProviderCredential(
                credential,
                providerID: providerID,
                kind: kind
            )
            notice = "Saved the \(providerID.displayName) credential in the host-owned Keychain."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func removeClientProviderCredential(
        providerID: AgentProviderID,
        kind: ProviderCredentialKind = .apiKey
    ) async -> Bool {
        guard let desktopHostAdministration else {
            errorMessage = "The local host authorization channel is unavailable."
            return false
        }
        do {
            try await desktopHostAdministration.removeProviderCredential(providerID: providerID, kind: kind)
            notice = "Removed the \(providerID.displayName) credential from the host-owned Keychain."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func acceptClientAcknowledgement(
        _ acknowledgement: GADCommandAcknowledgement?,
        successNotice: String?
    ) -> Bool {
        guard let acknowledgement else {
            let reason = continuityStore?.lastClientErrorMessage
                ?? "The background-host connection was interrupted."
            let recovery = isReconnectingToHost
                ? "Goby is reconnecting automatically and kept your local UI state."
                : "Goby kept your local UI state. Reconnect after resolving the host connection issue."
            errorMessage = "\(reason) \(recovery) The interrupted action was not retried; it may already have been accepted. Check its refreshed status before trying again."
            return false
        }
        guard acknowledgement.disposition == .accepted else {
            errorMessage = acknowledgement.message ?? "The background host did not accept this change."
            return false
        }
        errorMessage = nil
        if let successNotice { notice = successNotice }
        return true
    }

    public func suggestedResourceIDs(for goal: String) -> Set<SharedResourceID> {
        let normalizedGoal = goal.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return Set(enabledSharedResources.compactMap { resource in
            let name = resource.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 3,
                  normalizedGoal.localizedCaseInsensitiveContains(name) else { return nil }
            return resource.id
        })
    }

    private func refreshGraph() async throws {
        if continuityStore != nil { return }
        mergeHelperActivitiesFromRuns()
        let registeredProjectIDs = Set(lab.projects.map(\.id))
        promptProjectIDs.formIntersection(registeredProjectIDs)
        promptAgentTargets = Set(promptAgentTargets.filter(canRetainPromptAgentTarget))
        if let promptProjectGroupID,
           !lab.projectGroups.contains(where: { $0.id == promptProjectGroupID }) {
            self.promptProjectGroupID = nil
        }
        let assignments = currentRuns.first?.assignments ?? []
        replaceGraphPreservingManualLayout(
            try await buildGraph(
                assignments: assignments,
                codexTasks: codexTasks,
                providerID: selectedProviderID
            )
        )
    }

    private func finishProviderRefresh() {
        activeProviderRefreshes -= 1
        guard activeProviderRefreshes == 0 else { return }
        let waiters = providerRefreshDrainWaiters
        providerRefreshDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func refreshProviderSnapshots(providerIDs: Set<AgentProviderID>) async {
        guard let runtimeRegistry else { return }
        let projects = lab.projects
        let slices = await withTaskGroup(
            of: ProviderRefreshSlice?.self,
            returning: [ProviderRefreshSlice].self
        ) { group in
            for providerID in providerIDs {
                group.addTask {
                    guard let runtime = await runtimeRegistry.runtime(for: providerID) else {
                        return nil
                    }
                    do {
                        let account = try await runtime.accountSnapshot()
                        let tasks = try await runtime.recentTasks(projects: projects)
                        return ProviderRefreshSlice(account: account, tasks: tasks)
                    } catch {
                        let currentState = await runtime.connectionState()
                        let state: ProviderConnectionState = switch currentState {
                        case .notChecked, .disconnected, .connecting, .connected:
                            .failed(message: error.localizedDescription)
                        case .unavailable, .needsAuthentication, .failed:
                            currentState
                        }
                        return ProviderRefreshSlice(
                            account: ProviderAccountSnapshot(
                                providerID: providerID,
                                connectionState: state,
                                observedAt: .now
                            ),
                            tasks: []
                        )
                    }
                }
            }
            var results: [ProviderRefreshSlice] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        var accountsByProvider = Dictionary(
            uniqueKeysWithValues: providerAccounts.map { ($0.providerID, $0) }
        )
        var tasksByProvider = Dictionary(grouping: providerTasks, by: \.providerID)
        for slice in slices {
            accountsByProvider[slice.account.providerID] = slice.account
            tasksByProvider[slice.account.providerID] = slice.tasks
        }
        providerAccounts = accountsByProvider.values.sorted { $0.providerID < $1.providerID }
        providerTasks = tasksByProvider.values.flatMap { $0 }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
            return $0.identity.nativeID < $1.identity.nativeID
        }
    }

    private func reconnectProvider(_ providerID: AgentProviderID) async -> Bool {
        guard let runtimeRegistry,
              let runtime = await runtimeRegistry.runtime(for: providerID) else { return false }
        await runtime.disconnect()
        do {
            _ = try await runtime.connect()
            _ = try await runtime.accountSnapshot()
            return true
        } catch {
            return false
        }
    }

    private func replaceGraphPreservingManualLayout(_ refreshedGraph: GraphLayoutSnapshot) {
        let rebasedLayout = mapLayoutOverrides.rebased(
            preservingPositionsFrom: graph,
            to: refreshedGraph
        )
        graph = refreshedGraph
        commitMapLayout(rebasedLayout)
    }

    private func commitMapLayout(_ next: MapLayoutOverrides) {
        guard !isTransferringOwnership, next != mapLayoutOverrides else { return }
        mapLayoutOverrides = next
        guard let saveMapLayoutUseCase else { return }
        let precedingSave = mapLayoutSaveTask
        mapLayoutSaveTask = Task { [weak self] in
            await precedingSave?.value
            guard let self else { return }
            do {
                try await saveMapLayoutUseCase(next)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func canDirectlyAssignAgent(_ target: AgentRouteTarget) -> Bool {
        guard target.providerID == selectedProviderID,
              availableProviderIDs.contains(target.providerID) else { return false }
        if let agent = lab.agents.first(where: { $0.id == target.agentID }),
           agent.isTemporary, quickTaskAgentID != target.agentID { return false }
        return AgentRoutingMatcher.isEligible(target, in: lab)
    }

    private func canRetainPromptAgentTarget(_ target: AgentRouteTarget) -> Bool {
        canDirectlyAssignAgent(target)
            || (continuityStore == nil
                && target.providerID == selectedProviderID
                && availableProviderIDs.contains(target.providerID)
                && AgentRoutingMatcher.isEligible(target, in: lab))
    }

    private var promptTextForRouting: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return promptAttachments.count == 1
            ? "Handle the attached context."
            : "Handle the attached context items."
    }

    private func missingAgentSuggestionForCurrentScope() -> AgentCreationSuggestion? {
        missingAgentSuggestionsForCurrentScope().first
    }

    /// Every selected project that has no suitable agent for this request.
    private func missingAgentSuggestionsForCurrentScope() -> [AgentCreationSuggestion] {
        var suggestions: [AgentCreationSuggestion] = []
        let selectedProjectIDs: Set<ProjectID>
        if !promptProjectIDs.isEmpty {
            selectedProjectIDs = promptProjectIDs
        } else if let promptProjectGroup {
            selectedProjectIDs = promptProjectGroup.projectIDs
        } else {
            return []
        }

        let requiredCapabilities = AgentRoutingMatcher.inferredCapabilities(from: promptTextForRouting)
        let selectedProjects = lab.projects
            .filter { selectedProjectIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for project in selectedProjects {
            let hasExplicitAgent = promptAgentTargets.contains {
                $0.providerID == selectedProviderID && $0.projectID == project.id
            }
            if hasExplicitAgent { continue }

            let eligibleAgents = AgentRoutingMatcher.suitableAgents(
                AgentRoutingMatcher.eligibleAgents(
                    for: project.id,
                    providerID: selectedProviderID,
                    in: lab
                ),
                for: project,
                required: requiredCapabilities
            )
            let missing = AgentRoutingMatcher.missingCapabilities(
                required: requiredCapabilities,
                among: eligibleAgents
            )
            if !missing.isEmpty {
                suggestions.append(AgentCreationSuggestion(
                    projectID: project.id,
                    projectName: project.name,
                    providerID: selectedProviderID,
                    requiredCapabilities: missing
                ))
            }
        }
        return suggestions
    }

    private func operationalContinuitySnapshot() -> GADOperationalContinuityState {
        let platform: ProjectPlatform? = switch promptScope {
        case .all: nil
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        }
        return GADOperationalContinuityState(
            draftText: prompt,
            draftAttachments: promptAttachments,
            providerID: selectedProviderID,
            model: promptModelID,
            platform: platform,
            projectIDs: promptProjectIDs,
            agentTargets: promptAgentTargets,
            groupID: promptProjectGroupID,
            proposedPlan: proposedPlan,
            selectedResourceIDs: selectedRunResourceIDs
        )
    }

    private func restoreOperationalContinuity(_ state: GADOperationalContinuityState) {
        isRestoringOperationalContinuity = true
        defer { isRestoringOperationalContinuity = false }

        let projectIDs = Set(lab.projects.map(\.id))
        let agentIDs = Set(lab.agents.map(\.id))
        // Codex is the default provider. Only an unsent draft keeps the
        // provider it was written for.
        let hasUnsentDraft = !state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.draftAttachments.isEmpty
        let providerID = hasUnsentDraft && availableProviderIDs.contains(state.providerID)
            ? state.providerID
            : .codex
        selectedProviderID = providerID
        promptModelID = state.model
        prompt = String(state.draftText.prefix(32_000))
        replacePromptAttachments(state.draftAttachments)
        promptScope = switch state.platform {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        case .backend, .general, .none: .all
        }

        promptProjectIDs = state.projectIDs.intersection(projectIDs)
        promptProjectGroupID = state.groupID.flatMap { id in
            lab.projectGroups.contains(where: { $0.id == id }) ? id : nil
        }
        promptAgentTargets = Set(state.agentTargets.filter { target in
            target.providerID == providerID
                && projectIDs.contains(target.projectID)
                && agentIDs.contains(target.agentID)
                && canRetainPromptAgentTarget(target)
        })

        if promptProjectGroupID != nil {
            promptProjectIDs.removeAll()
            promptAgentTargets.removeAll()
        } else if !promptAgentTargets.isEmpty {
            promptProjectIDs.formUnion(promptAgentTargets.map(\.projectID))
        }

        proposedPlan = state.proposedPlan.flatMap { plan in
            let isValid = !plan.routes.isEmpty && plan.routes.allSatisfy { route in
                projectIDs.contains(route.projectID)
                    && availableProviderIDs.contains(route.providerID)
                    && route.agentIDs.allSatisfy(agentIDs.contains)
            }
            return isValid ? plan : nil
        }
        if proposedPlan == nil {
            selectedRunResourceIDs = []
        } else {
            let enabledResourceIDs = Set(enabledSharedResources.map(\.id))
            selectedRunResourceIDs = state.selectedResourceIDs.intersection(enabledResourceIDs)
        }
    }

    private func notifyStateDidChange() {
        guard !isRestoringOperationalContinuity, !isTransferringOwnership else { return }
        stateDidChange?()
        scheduleClientDraftFlush()
        scheduleOperationalContinuitySave()
    }

    private func scheduleOperationalContinuitySave() {
        guard !isTransferringOwnership, let operationalContinuityRepository else { return }
        let state = operationalContinuitySnapshot()
        let precedingSave = operationalContinuitySaveTask
        precedingSave?.cancel()
        operationalContinuitySaveTask = Task { @MainActor [weak self] in
            await precedingSave?.value
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                try await operationalContinuityRepository.saveOperationalContinuity(state)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.errorMessage == nil else { return }
                self.errorMessage = "Goby could not checkpoint the shared draft: \(error.localizedDescription)"
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isTransferringOwnership else { return }
        guard !isBusy else {
            errorMessage = "Another dashboard change is finishing. Try this action again."
            notifyStateDidChange()
            return
        }
        isBusy = true
        errorMessage = nil
        notice = nil
        defer {
            isBusy = false
            notifyStateDidChange()
        }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        // Catalog and enabled-instruction writes deliberately quarantine any
        // active automation before changing its execution authority. Reload
        // that authenticated document before publishing the operation result;
        // otherwise the dashboard and coordinator can retain a review action
        // that persistence has already invalidated.
        if let loadAutomationsUseCase {
            do {
                automationSnapshot = try await loadAutomationsUseCase()
            } catch {
                if errorMessage == nil {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startObservingRunsIfNeeded() {
        guard runObservationTask == nil else { return }
        runObservationTask = Task { [weak self] in
            guard let self else { return }
            let updates = await observeRuns()
            for await run in updates {
                await apply(run)
            }
        }
    }

    private func startObservingAutomationsIfNeeded() {
        guard automationObservationTask == nil, let automationCoordinator else { return }
        automationObservationTask = Task { [weak self] in
            let updates = await automationCoordinator.updates()
            for await snapshot in updates {
                guard let self else { return }
                automationSnapshot = snapshot
                notifyStateDidChange()
            }
        }
    }

    private func executeInBackground(_ runID: RunID) async {
        do {
            try await executeRun(runID: runID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a finished temporary agent's handoff before the agent is retired.
    /// A failed write never blocks retirement; the run result stays in history.
    private func recordTemporaryAgentNotes(for run: RunRecord) async {
        guard let recordTemporaryAgentNotesUseCase,
              run.agentSnapshot.contains(where: \.isTemporary) else { return }
        do {
            try await recordTemporaryAgentNotesUseCase(run)
        } catch {
            notice = "Temporary agent notes could not be saved: \(error.localizedDescription)"
        }
    }

    private func apply(_ run: RunRecord) async {
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        runs.sort { $0.updatedAt > $1.updatedAt }
        if run.status.isFinished, let retireTemporaryAgentUseCase {
            await recordTemporaryAgentNotes(for: run)
            for agent in run.agentSnapshot where agent.isTemporary {
                guard !runs.contains(where: { other in
                    other.id != run.id && !other.status.isFinished
                        && other.agentSnapshot.contains(where: { $0.id == agent.id })
                }) else { continue }
                do {
                    try await retireTemporaryAgentUseCase(id: agent.id)
                    let refreshed = try await loadDashboard()
                    lab = refreshed.0
                } catch {
                    errorMessage = "The quick-task agent could not be removed: \(error.localizedDescription)"
                }
            }
        }
        reconcilePendingRunControls()
        mergeHelperActivitiesFromRuns()
        if let refreshedGraph = try? await buildGraph(
            assignments: run.assignments,
            codexTasks: codexTasks,
            providerID: selectedProviderID
        ) {
            replaceGraphPreservingManualLayout(refreshedGraph)
        }
        if selectedRunID == run.id {
            selectedRunGraph = (try? await buildGraph(
                assignments: run.assignments,
                codexTasks: codexHelperActivities(in: run),
                providerID: selectedProviderID
            )) ?? selectedRunGraph
        }
        pendingApprovals = await manageApproval.pending()
        notifyStateDidChange()
    }

    private func mergeHelperActivitiesFromRuns() {
        let helpers = runs.flatMap(\.helperTasks)
        var providerByIdentity: [ProviderTaskIdentity: ProviderTaskActivity] = [:]
        for task in providerTasks {
            if let existing = providerByIdentity[task.identity], existing.updatedAt > task.updatedAt {
                continue
            }
            providerByIdentity[task.identity] = task
        }
        for helper in helpers {
            providerByIdentity[helper.identity] = helper
        }
        providerTasks = providerByIdentity.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
            return $0.identity.nativeID < $1.identity.nativeID
        }

        var codexByID = Dictionary(uniqueKeysWithValues: codexTasks.map { ($0.id, $0) })
        for activity in helpers.compactMap(Self.codexActivity) {
            codexByID[activity.id] = activity
        }
        codexTasks = codexByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    private func codexHelperActivities(in run: RunRecord) -> [CodexTaskActivity] {
        run.helperTasks.compactMap(Self.codexActivity)
    }

    private static func codexActivity(_ task: ProviderTaskActivity) -> CodexTaskActivity? {
        guard task.providerID == .codex else { return nil }
        let status: CodexTaskStatus = switch task.status {
        case .working: .active
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .saved: .idle
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
        return CodexTaskActivity(
            id: task.identity.nativeID,
            projectID: task.projectID,
            title: task.title,
            summary: task.summary,
            status: status,
            updatedAt: task.updatedAt,
            isSubagent: true,
            agentRole: task.agentRole,
            parentThreadID: task.parentTaskIdentity?.nativeID
        )
    }

    private static func providerActivity(_ task: CodexTaskActivity) -> ProviderTaskActivity {
        let status: ProviderTaskStatus = switch task.status {
        case .active: .working
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .idle: .saved
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
        return ProviderTaskActivity(
            identity: ProviderTaskIdentity(providerID: .codex, nativeID: task.id),
            projectID: task.projectID,
            title: task.title,
            summary: task.summary,
            status: status,
            updatedAt: task.updatedAt,
            parentTaskIdentity: task.parentThreadID.map {
                ProviderTaskIdentity(providerID: .codex, nativeID: $0)
            },
            agentRole: task.agentRole
        )
    }

    private func copy(
        _ plan: RoutingPlan,
        routes: [ProjectRoute],
        gitOperations: [PlannedGitOperation]
    ) -> RoutingPlan {
        RoutingPlanRevision.make(
            from: plan,
            routes: routes,
            gitOperations: gitOperations,
            projects: lab.projects
        )
    }

    private func mergedHealth(
        _ snapshot: SystemHealthSnapshot,
        account: CodexAccountSnapshot?
    ) -> SystemHealthSnapshot {
        let authentication = HealthCheck(
            kind: .authentication,
            status: account?.authenticated == true ? .passed : .failed,
            summary: account?.authenticated == true ? "Signed in" : "Sign in to Codex is required",
            detail: account?.planName
        )
        return SystemHealthSnapshot(checks: snapshot.checks + [authentication], checkedAt: snapshot.checkedAt)
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(count == 1 ? singular : singular + "s")"
    }

    private static let imageFileExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private struct PromptAttachmentSnapshot: Sendable {
        let sourceURL: URL
        let stagedURL: URL?
        let byteCount: Int?
        let rejectedDirectory: Bool
    }

    nonisolated private static func stagePromptAttachment(_ source: URL, root: URL?) -> PromptAttachmentSnapshot {
        let source = source.standardizedFileURL
        let sourcePath = source.path(percentEncoded: false)
        let descriptor = open(sourcePath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= 25 * 1_024 * 1_024 else {
            let rejectedDirectory = info.st_mode & S_IFMT == S_IFDIR
            close(descriptor)
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: rejectedDirectory
            )
        }
        defer { close(descriptor) }
        guard let data = readBoundedPromptAttachment(
            descriptor: descriptor,
            expectedByteCount: Int(info.st_size),
            maximumByteCount: 25 * 1_024 * 1_024
        ) else {
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }

        guard let storage = PromptAttachmentStorage.openOrCreateRoot(root) else {
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }
        defer { close(storage.descriptor) }
        guard let destination = PromptAttachmentStorage.write(
            data,
            fileExtension: source.pathExtension.isEmpty ? "" : String(source.pathExtension.prefix(32)),
            root: storage.url,
            descriptor: storage.descriptor
        ) else {
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }
        guard let stagedIdentity = GADFileSystemIdentity.capture(destination),
              stagedIdentity.kind == .regularFile else {
            PromptAttachmentStorage.removeDirectChild(
                root: storage.url,
                descriptor: storage.descriptor,
                url: destination
            )
            return PromptAttachmentSnapshot(
                sourceURL: source,
                stagedURL: nil,
                byteCount: nil,
                rejectedDirectory: false
            )
        }
        return PromptAttachmentSnapshot(
            sourceURL: source,
            stagedURL: destination,
            byteCount: data.count,
            rejectedDirectory: false
        )
    }

    nonisolated static func readBoundedPromptAttachment(
        descriptor: Int32,
        expectedByteCount: Int,
        maximumByteCount: Int
    ) -> Data? {
        guard expectedByteCount >= 0, expectedByteCount <= maximumByteCount else { return nil }
        var result = Data()
        result.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while result.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - result.count
            guard remaining > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            result.append(contentsOf: buffer.prefix(count))
        }

        // Reject both growth and truncation after the descriptor was checked.
        // The bound is enforced during the read, before a changing source can
        // allocate or block Goby beyond the attachment policy.
        guard result.count == expectedByteCount,
              result.count <= maximumByteCount else { return nil }
        return result
    }

    nonisolated private static func stagePromptImage(
        data: Data,
        fileExtension: String,
        root: URL?
    ) -> URL? {
        guard !data.isEmpty, data.count <= 25 * 1_024 * 1_024,
              let storage = PromptAttachmentStorage.openOrCreateRoot(root) else { return nil }
        defer { close(storage.descriptor) }
        let candidate = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let supportedExtensions: Set<String> = [
            "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
        ]
        let safeExtension = supportedExtensions.contains(candidate) ? candidate : "png"
        guard let destination = PromptAttachmentStorage.write(
            data,
            fileExtension: safeExtension,
            root: storage.url,
            descriptor: storage.descriptor
        ) else { return nil }
        guard let identity = GADFileSystemIdentity.capture(destination),
              identity.kind == .regularFile else {
            PromptAttachmentStorage.removeDirectChild(
                root: storage.url,
                descriptor: storage.descriptor,
                url: destination
            )
            return nil
        }
        return destination
    }

    struct PromptAttachmentStorageUsage: Equatable, Sendable {
        let fileCount: Int
        let byteCount: Int64
    }

    nonisolated static func promptAttachmentStorageUsage(at root: URL) -> PromptAttachmentStorageUsage? {
        guard let descriptor = PromptAttachmentStorage.openExistingRoot(root) else {
            return FileManager.default.fileExists(atPath: root.path) ? nil : .init(fileCount: 0, byteCount: 0)
        }
        defer { close(descriptor) }
        guard let usage = PromptAttachmentStorage.usage(descriptor: descriptor) else { return nil }
        return .init(fileCount: usage.fileCount, byteCount: usage.byteCount)
    }

    nonisolated static func sweepPromptAttachmentStorage(
        at root: URL,
        retaining referencedURLs: Set<URL>
    ) {
        guard let descriptor = PromptAttachmentStorage.openExistingRoot(root) else { return }
        defer { close(descriptor) }
        PromptAttachmentStorage.sweep(
            root: root,
            descriptor: descriptor,
            retaining: referencedURLs
        )
    }

    nonisolated private static func removeOwnedPromptAttachment(at url: URL, root: URL?) {
        guard let root,
              let descriptor = PromptAttachmentStorage.openExistingRoot(root) else { return }
        defer { close(descriptor) }
        PromptAttachmentStorage.removeDirectChild(root: root, descriptor: descriptor, url: url)
    }

    nonisolated private static func droppedImageDisplayName(
        _ suggestedName: String?,
        fileExtension: String
    ) -> String {
        let candidate = suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = candidate?.isEmpty == false ? candidate! : "Dropped Screenshot.\(fileExtension)"
        return String(name.prefix(160))
    }

    private static func inferredSnippetLanguage(_ text: String) -> String? {
        let sample = String(text.prefix(4_000))
        if sample.contains("import SwiftUI") || sample.contains("func ") && sample.contains("let ") {
            return "Swift"
        }
        if sample.first == "{" || sample.first == "[",
           (try? JSONSerialization.jsonObject(with: Data(sample.utf8))) != nil {
            return "JSON"
        }
        if sample.contains("</") || sample.contains("<!DOCTYPE") { return "HTML" }
        if sample.contains("const ") || sample.contains("=>") { return "JavaScript" }
        if sample.contains("def ") || sample.contains("import ") && sample.contains(":") { return "Python" }
        if sample.hasPrefix("#!/") || sample.contains("set -e") { return "Shell" }
        return nil
    }
}

private struct ProviderRefreshSlice: Sendable {
    let account: ProviderAccountSnapshot
    let tasks: [ProviderTaskActivity]
}

private extension ProviderConnectionState {
    var isConfigured: Bool {
        switch self {
        case .connected, .connecting, .disconnected: true
        case .notChecked, .unavailable, .needsAuthentication, .failed: false
        }
    }
}

private enum RemoteInstructionMutationError: LocalizedError {
    case stale
    case changed

    var errorDescription: String? {
        switch self {
        case .stale: "This instruction pack is no longer available."
        case .changed: "This instruction pack changed on another device."
        }
    }
}
