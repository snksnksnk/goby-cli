import Foundation
import GobyDomain

#if DEBUG
/// One deterministic, redacted canonical session shared by the native macOS,
/// iPhone, and iPad UI-test surfaces. This fixture deliberately uses the real
/// coordinator and client contract while avoiding Keychain, network, shell,
/// file-system, Git, or provider access.
public enum GADPairedContinuationFixture {
    public static let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
    public static let hostID = HostID(rawValue: "paired-home-mac")
    public static let hostEpoch = HostEpoch(rawValue: "paired-host-epoch")
    public static let macDeviceID = DeviceID(rawValue: "paired-macos")
    public static let phoneDeviceID = DeviceID(rawValue: "paired-ios")
    public static let projectID = ProjectID(rawValue: "paired-goby-project")
    public static let agentID = AgentID(rawValue: "paired-release-agent")
    public static let bindingID = ProviderAgentBindingID(rawValue: "paired-codex-binding")
    public static let resourceID = SharedResourceID(rawValue: "paired-release-resource")
    public static let instructionID = InstructionPackID(rawValue: "paired-release-instructions")
    public static let runID = RunID(rawValue: "paired-release-run")
    public static let assignmentID = AssignmentID(rawValue: "paired-release-assignment")
    public static let providerTaskID = "paired-provider-task"
    public static let helperTaskID = "paired-helper-task"
    public static let automationID = AutomationID(rawValue: "paired-weekly-release-review")
    public static let firstAutomationActionID = AutomationActionID(
        rawValue: "paired-release-research-action"
    )
    public static let secondAutomationActionID = AutomationActionID(
        rawValue: "paired-release-verification-action"
    )
    public static let automationOccurrenceID = AutomationOccurrenceID(
        rawValue: "paired-release-review-occurrence"
    )
    public static let automationPlanID = RunID(rawValue: "paired-release-review-plan")
    public static let initialDraft = "Complete the Goby v1 beta"

    /// Typed steps as a protocol 3.11 host sends them: narration, folded
    /// exploration, a command and one step still running.
    static func fixtureActivity(assignmentID: AssignmentID, at timestamp: Date) -> [GADRunActivityProjection] {
        func step(_ id: String, _ kind: String, _ title: String, _ status: String = "succeeded", exit: Int? = nil) -> GADRunActivityProjection {
            GADRunActivityProjection(
                id: id, assignmentID: assignmentID, kind: kind, title: title, status: status,
                exitCode: exit, startedAt: timestamp, finishedAt: status == "running" ? nil : timestamp
            )
        }
        return [
            step("m1", "message", "I'll check the release checklist and the paired flow before verifying."),
            step("r1", "read", "Read RELEASE_CHECKLIST.md"),
            step("r2", "read", "Read UX_FLOWS.md"),
            step("s1", "search", "Searched “pairing” in iOS"),
            step("c1", "command", "swift test --filter Continuity", exit: 0),
            step("m2", "message", "The checklist is current. Verifying the paired continuation flow now."),
            step("c2", "command", "xcodebuild -scheme \"Goby iOS\" test", "running"),
        ]
    }

    public static var projection: DashboardProjection {
        makeProjection(automations: .empty)
    }

    /// A focused projection for native automation UI evidence. The first
    /// action is waiting for review and the second demonstrates that an exact
    /// agent can continue the ordered sequence without creating a workflow
    /// graph or invoking a real provider.
    public static var automationProjection: DashboardProjection {
        makeProjection(
            automations: AutomationSnapshot(
                definitions: [automationDefinition],
                occurrences: [automationOccurrence]
            )
        )
    }

    /// A paired but projectless state used to prove that Automations never
    /// strands the user behind a disabled creation control.
    public static var emptyAutomationProjection: DashboardProjection {
        makeProjection(automations: .empty, includesProject: false)
    }

    private static func makeProjection(
        automations: AutomationSnapshot,
        includesProject: Bool = true
    ) -> DashboardProjection {
        DashboardProjection(
            revision: StateRevision(rawValue: 4),
            generatedAt: timestamp,
            host: GADHostProjection(
                id: hostID,
                displayName: "Home Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            ),
            draft: GADDraftProjection(
                revision: EntityRevision(rawValue: 2),
                text: initialDraft,
                providerID: .codex,
                platform: .iOS,
                projectIDs: includesProject ? [projectID] : [],
                agentTargets: [],
                groupID: nil
            ),
            projects: includesProject ? [
                GADProjectProjection(
                    id: projectID,
                    name: "Goby Agentic Dashboard",
                    platforms: [.iOS],
                    frameworks: ["SwiftUI"],
                    isGitRepository: true,
                    providerIDs: [.codex],
                    approvalOrdinal: 1
                )
            ] : [],
            agents: includesProject ? [
                GADAgentProjection(
                    id: agentID,
                    name: "Release Agent",
                    summary: "Verifies the shared beta candidate",
                    capabilities: [.iOS, .testing, .release],
                    scope: .project(projectID),
                    isEnabled: true,
                    isActiveInCodex: true,
                    hasDefinition: true
                )
            ] : [],
            resources: includesProject ? [
                GADResourceProjection(
                    id: resourceID,
                    name: "Release",
                    access: .readOnly,
                    isEnabled: true,
                    approvalOrdinal: 1
                )
            ] : [],
            instructions: includesProject ? [
                GADInstructionProjection(
                    id: instructionID,
                    name: "Release Guardrails",
                    scope: .projects([projectID]),
                    version: 3,
                    isEnabled: true,
                    updatedAt: timestamp
                )
            ] : [],
            runs: includesProject ? [
                GADRunProjection(
                    id: runID,
                    goal: initialDraft,
                    risk: .medium,
                    status: .running,
                    assignments: [
                        GADAssignmentProjection(
                            id: assignmentID,
                            projectID: projectID,
                            agentID: agentID,
                            status: .working,
                            currentTask: "Verifying the paired continuation flow",
                            progress: 0.65,
                            statusReason: nil
                        )
                    ],
                    helperTasks: [helperTask],
                    outcome: nil,
                    journal: [
                        GADJournalProjection(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                            kind: .assignmentChanged,
                            message: "Work is live on the authoritative Mac.",
                            assignmentID: assignmentID,
                            occurredAt: timestamp
                        )
                    ],
                    activity: fixtureActivity(assignmentID: assignmentID, at: timestamp),
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ] : [],
            automations: automations,
            providerAccounts: [
                GADProviderAccountProjection(
                    providerID: .codex,
                    connectionState: .connected(version: "fixture"),
                    planName: "Pro",
                    selectedModel: nil,
                    availableModels: ["gpt-5.6-sol", "gpt-6-astra"],
                    usage: [],
                    observedAt: timestamp
                )
            ],
            providerTasks: includesProject ? [providerTask, helperTask] : [],
            providerBindings: includesProject ? [
                GADProviderBindingProjection(
                    id: bindingID,
                    providerID: .codex,
                    agentID: agentID,
                    projectID: projectID,
                    capabilities: [.iOS, .testing, .release],
                    state: .configured,
                    hasInstructionsOverride: false
                )
            ] : [],
            health: [
                GADHealthProjection(
                    kind: .codex,
                    status: .passed,
                    summary: "Connected through Home Mac"
                )
            ]
        )
    }

    private static var automationDefinition: AutomationDefinition {
        let schedule = AutomationSchedule(
            cadence: .weekly(weekday: 2, hour: 9, minute: 30),
            timeZoneIdentifier: "Europe/Nicosia"
        )
        return AutomationDefinition(
            id: automationID,
            name: "Weekly release review",
            schedule: schedule,
            actions: automationActions,
            nextRunAt: schedule.nextDate(after: timestamp),
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private static var automationActions: [AutomationAction] {
        [
            AutomationAction(
                id: firstAutomationActionID,
                instruction: "Research the latest iOS release risks and propose priorities.",
                target: .project(providerID: .codex, projectID: projectID)
            ),
            AutomationAction(
                id: secondAutomationActionID,
                instruction: "Verify the proposed priorities against the beta release checklist.",
                target: .agent(AgentRouteTarget(
                    providerID: .codex,
                    agentID: agentID,
                    projectID: projectID
                ))
            )
        ]
    }

    private static var automationOccurrence: AutomationOccurrence {
        let plan = RoutingPlan(
            id: automationPlanID,
            interpretedGoal: automationActions[0].instruction,
            routes: [
                ProjectRoute(
                    projectID: projectID,
                    providerID: .codex,
                    model: "gpt-5.6-sol",
                    agentIDs: [agentID],
                    providerBindings: [ProviderRouteBinding(
                        agentID: agentID,
                        bindingID: bindingID
                    )],
                    reason: "Exact scheduled release-review scope"
                )
            ],
            risk: .medium,
            confidence: 0.94,
            warnings: ["This action can change files in its approved working copy."],
            createdAt: timestamp
        )
        return AutomationOccurrence(
            id: automationOccurrenceID,
            automationID: automationID,
            automationName: automationDefinition.name,
            definitionRevision: automationDefinition.revision,
            actions: automationActions,
            trigger: .scheduled,
            scheduledAt: timestamp,
            status: .needsAttention,
            attempts: [
                AutomationActionAttempt(
                    actionID: firstAutomationActionID,
                    plan: plan,
                    status: .waitingForReview,
                    message: "Scope review is required before this action starts.",
                    updatedAt: timestamp
                )
            ],
            message: "Review the first action before the ordered sequence continues.",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private static var providerTask: GADProviderTaskProjection {
        GADProviderTaskProjection(
            id: providerTaskID,
            providerID: .codex,
            projectID: projectID,
            title: "Verify paired continuation",
            summary: "The primary provider task is coordinating the release check.",
            status: .working,
            updatedAt: timestamp,
            agentRole: "Release Agent",
            agentID: agentID
        )
    }

    private static var helperTask: GADProviderTaskProjection {
        GADProviderTaskProjection(
            id: helperTaskID,
            providerID: .codex,
            projectID: projectID,
            title: "Inspect iOS parity",
            summary: "The helper confirmed that live Mac work is visible on iPhone.",
            status: .completed,
            updatedAt: timestamp,
            agentRole: "Explorer",
            parentTaskID: providerTaskID
        )
    }

    /// `now` defaults to the fixture's fixed time. Clients that stamp
    /// commands with the real clock pass `{ .now }`.
    public static func makeCoordinator(now: @escaping @Sendable () -> Date = { timestamp }) -> GADCoordinator {
        makeCoordinator(initialProjection: projection, now: now)
    }

    public static func makeAutomationCoordinator() -> GADCoordinator {
        makeCoordinator(initialProjection: automationProjection)
    }

    public static func makeEmptyAutomationCoordinator() -> GADCoordinator {
        makeCoordinator(initialProjection: emptyAutomationProjection)
    }

    private static func makeCoordinator(
        initialProjection: DashboardProjection,
        now: @escaping @Sendable () -> Date = { timestamp }
    ) -> GADCoordinator {
        GADCoordinator(
            hostID: hostID,
            hostEpoch: hostEpoch,
            initialProjection: initialProjection,
            capabilities: Set(GADCapability.allCases),
            authorizedDevices: [macDeviceID, phoneDeviceID],
            handler: GADPairedContinuationFixtureHandler(),
            now: now
        )
    }

    public static func makeClient(
        coordinator: GADCoordinator,
        deviceID: DeviceID
    ) -> LocalGobyClient {
        LocalGobyClient(coordinator: coordinator, deviceID: deviceID)
    }
}
#endif

/// The fixture's command handler: the shared projection handler plus a
/// deterministic temporary chat, so UI tests can exercise the flow without a
/// provider.
actor GADPairedContinuationFixtureHandler: GADCommandHandling {
    private let base = ProjectionGADCommandHandler()

    static let sampleAnswer = """
    **391.** 17 × 23 = 391.

    - Temporary chats aren't saved.
    - Codex can't see your projects or files here.
    """

    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect {
        switch payload {
        case let .askTemporaryChat(question):
            let current = projection.host.temporaryChat
            if let chatID = question.chatID, current?.id != chatID {
                throw GADCommandFailure(.rejectedStale, TemporaryChatError.staleChat.localizedDescription)
            }
            guard current?.canAsk ?? true, let text = TemporaryChat.normalizedQuestion(question.text) else {
                throw GADCommandFailure(.rejectedPolicy, TemporaryChatError.answering.localizedDescription)
            }
            let now = projection.generatedAt
            var chat = (question.chatID == nil ? nil : current).map(TemporaryChat.init(projection:))
                ?? TemporaryChat(startedAt: now, updatedAt: now)
            chat.append(.init(role: .user, text: text, createdAt: now))
            chat.appendAnswerText(Self.sampleAnswer, at: now)
            chat.status = .ready
            return GADCommandEffect(changes: [.host(host(projection.host, chat: chat))])
        case let .endTemporaryChat(chatID):
            guard projection.host.temporaryChat?.id == chatID else { return GADCommandEffect() }
            return GADCommandEffect(changes: [.host(host(projection.host, chat: nil))])
        default:
            return try await base.apply(payload, to: projection, deviceID: deviceID)
        }
    }

    private func host(_ host: GADHostProjection, chat: TemporaryChat?) -> GADHostProjection {
        GADHostProjection(
            id: host.id,
            displayName: host.displayName,
            reachability: host.reachability,
            lastUpdatedAt: host.lastUpdatedAt,
            omittedHistoryRunCount: host.omittedHistoryRunCount,
            omittedAutomationOccurrenceCount: host.omittedAutomationOccurrenceCount,
            temporaryChat: chat.map { GADTemporaryChatProjection($0) { String($0.prefix($1)) } }
        )
    }
}
