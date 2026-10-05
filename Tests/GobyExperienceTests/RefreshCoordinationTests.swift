import Foundation
import GobyApplication
import GobyDomain
import GobyExperience
import Testing

@Suite("Refresh command coordination")
@MainActor
struct RefreshCoordinationTests {
    @Test("Overlapping provider refreshes coalesce and draft saves wait for admission")
    func refreshAndDraftAreSerialized() async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let refresh = Task { await store.refreshProviders([.codex, .claude]) }
        #expect(await client.waitForCount(1))
        let duplicate = Task { await store.refreshProviders([.codex], activityOnly: true) }
        store.updateDraft("Keep this edit")
        let save = Task { await store.flushDraft() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await client.recorded().count == 1)
        await client.release()
        #expect(await refresh.value?.disposition == .accepted)
        #expect(await duplicate.value?.disposition == .accepted)
        await save.value
        let commands = await client.recorded()
        #expect(commands.count == 2)
        #expect(commands.last?.payload == .replaceDraft(.init(
            expectedRevision: .zero, text: "Keep this edit", projectIDs: [], agentTargets: [], groupID: nil
        )))
        #expect(await client.maximumConcurrentSends == 1)
        #expect(store.draftText == "Keep this edit")
        await store.disconnect()
    }

    @Test("Approval delivery and disclosure pass queued polls without overlapping commands", arguments: [false, true])
    func approvalsPassQueuedActivity(disclosure: Bool) async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let running = Task { await store.refreshProviders([.codex], activityOnly: true) }
        #expect(await client.waitForCount(1))
        let queued = Task { await store.refreshProviders([.claude], activityOnly: true) }
        try await Task.sleep(for: .milliseconds(30))
        let approval = Task {
            if disclosure { _ = await store.approvalDisclosure(for: "approval") }
            else {
                _ = await store.respond(to: .init(id: "approval", runID: "run", assignmentID: "assignment",
                    kind: .command, summary: "Inspect", details: nil, actions: [.allowOnce, .decline],
                    approvalSessionID: nil, expiresAt: .distantFuture), action: .allowOnce)
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.recorded().count == 1)
        await client.release()
        _ = await running.value
        _ = await queued.value
        await approval.value
        let commands = await client.recorded()
        #expect(commands.count == 3)
        if disclosure { #expect(commands[1].payload == .requestApprovalDisclosure("approval")) }
        else {
            guard case .respondToApproval = commands[1].payload else {
                Issue.record("Approval should be sent before the queued poll")
                await store.disconnect()
                return
            }
        }
        #expect(commands[2].payload == .refreshProviderActivity([.claude]))
        #expect(await client.maximumConcurrentSends == 1)
        await store.disconnect()
    }

    @Test("A new plan passes queued activity polls while another provider task is active")
    func planPassesQueuedActivity() async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let activePoll = Task { await store.refreshProviders([.codex], activityOnly: true) }
        #expect(await client.waitForCount(1))
        let queuedPoll = Task { await store.refreshProviders([.claude], activityOnly: true) }
        try await Task.sleep(for: .milliseconds(30))
        let plan = Task { await store.preparePlan() }
        try await Task.sleep(for: .milliseconds(30))

        await client.release()
        _ = await activePoll.value
        _ = await plan.value
        _ = await queuedPoll.value
        #expect(await client.recorded().map(\.payload) == [
            .refreshProviderActivity([.codex]),
            .preparePlan,
            .refreshProviderActivity([.claude])
        ])
        #expect(await client.maximumConcurrentSends == 1)
        await store.disconnect()
    }

    @Test("A new task draft passes queued activity polls")
    func draftPassesQueuedActivity() async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let activePoll = Task { await store.refreshProviders([.codex], activityOnly: true) }
        #expect(await client.waitForCount(1))
        let queuedPoll = Task { await store.refreshProviders([.claude], activityOnly: true) }
        try await Task.sleep(for: .milliseconds(30))
        store.updateDraft("New task for another agent")
        let draft = Task { await store.flushDraft() }
        try await Task.sleep(for: .milliseconds(30))

        await client.release()
        _ = await activePoll.value
        await draft.value
        _ = await queuedPoll.value
        let commands = await client.recorded()
        #expect(commands.count == 3)
        guard case let .replaceDraft(saved) = commands[1].payload else {
            Issue.record("The draft should be saved before the queued poll")
            await store.disconnect()
            return
        }
        #expect(saved.text == "New task for another agent")
        #expect(commands[2].payload == .refreshProviderActivity([.claude]))
        #expect(await client.maximumConcurrentSends == 1)
        await store.disconnect()
    }

    @Test("Approval priority preserves earlier user mutations and queued approval order")
    func approvalsPreserveMutationOrder() async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let running = Task { await store.refreshProviders([.codex], activityOnly: true) }
        #expect(await client.waitForCount(1))
        let mutation = Task { await store.followUp(runID: "run", text: "User instruction") }
        try await Task.sleep(for: .milliseconds(20))
        let poll = Task { await store.refreshProviders([.claude], activityOnly: true) }
        try await Task.sleep(for: .milliseconds(20))
        let first = Task { await store.approvalDisclosure(for: "first") }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { await store.approvalDisclosure(for: "second") }
        try await Task.sleep(for: .milliseconds(20))
        await client.release()
        _ = await running.value
        _ = await mutation.value
        _ = await poll.value
        _ = await first.value
        _ = await second.value
        let commands = await client.recorded()
        #expect(commands.map(\.payload) == [
            .refreshProviderActivity([.codex]),
            .followUp(.init(runID: "run", text: "User instruction")),
            .requestApprovalDisclosure("first"), .requestApprovalDisclosure("second"),
            .refreshProviderActivity([.claude])
        ])
        #expect(await client.maximumConcurrentSends == 1)
        await store.disconnect()
    }

    @Test("New hosts get activity-only polling; older hosts retain the legacy refresh")
    func activityCompatibility() async {
        for version in [GADProtocolVersion(major: 3, minor: 8), .current] {
            let client = RefreshTestClient(version: version)
            let store = makeStore(client)
            await store.connect()
            _ = await store.refreshProviders([.claude], activityOnly: true)
            let payload = await client.recorded().first?.payload
            #expect(payload == (version >= .init(major: 3, minor: 9)
                ? .refreshProviderActivity([.claude]) : .refreshProviders([.claude])))
            await store.disconnect()
        }
    }

    @Test("Explicit pre-admission deferral retries the identical request")
    func retriesOnlyExplicitDeferral() async {
        let client = RefreshTestClient(replies: [.deferred, .accepted])
        let store = makeStore(client)
        await store.connect()
        #expect(await store.refreshProviders([.codex])?.disposition == .accepted)
        let commands = await client.recorded()
        #expect(commands.count == 2)
        #expect(commands.first == commands.last)
        await store.disconnect()
    }

    @Test("Plan review retries one stale global revision when the draft is unchanged")
    func planReviewRecoversFromBackgroundRevision() async {
        let client = RefreshTestClient(replies: [.staleWithBackgroundUpdate, .accepted])
        let store = makeStore(client)
        await store.connect()

        #expect(await store.preparePlan()?.disposition == .accepted)
        let commands = await client.recorded()
        #expect(commands.count == 2)
        #expect(commands.map(\.payload) == [.preparePlan, .preparePlan])
        #expect(commands[0].idempotencyKey != commands[1].idempotencyKey)
        #expect(commands[1].baseRevision == commands[0].baseRevision.advanced())
        await store.disconnect()
    }

    @Test("Plan review does not retry when the canonical draft changed")
    func planReviewPreservesDraftConflict() async {
        let client = RefreshTestClient(replies: [.staleWithDraftChange])
        let store = makeStore(client)
        await store.connect()

        #expect(await store.preparePlan()?.disposition == .rejectedStale)
        #expect(await client.recorded().count == 1)
        #expect(store.projection?.draft.text == "Changed on another device")
        await store.disconnect()
    }

    @Test("Run start retries a pre-admission stale revision when the reviewed plan is unchanged")
    func runStartRecoversFromBackgroundRevision() async {
        let client = RefreshTestClient(replies: [.staleWithBackgroundUpdate, .accepted])
        let plan = makePlan()
        await client.setPlan(plan)
        let store = makeStore(client)
        await store.connect()

        #expect(await store.startRun(plan.id)?.disposition == .accepted)
        let commands = await client.recorded()
        #expect(commands.count == 2)
        #expect(commands.map(\.payload) == [
            .startRun(.init(planID: plan.id)), .startRun(.init(planID: plan.id))
        ])
        #expect(commands[0].idempotencyKey != commands[1].idempotencyKey)
        #expect(commands[1].baseRevision == commands[0].baseRevision.advanced())
        await store.disconnect()
    }

    @Test("Run start does not retry when the reviewed plan changed")
    func runStartPreservesPlanConflict() async {
        let client = RefreshTestClient(replies: [.staleWithPlanChange])
        let plan = makePlan()
        await client.setPlan(plan)
        let store = makeStore(client)
        await store.connect()

        #expect(await store.startRun(plan.id)?.disposition == .rejectedStale)
        #expect(await client.recorded().count == 1)
        #expect(store.projection?.plan?.goal == "Changed plan")
        await store.disconnect()
    }

    @Test("Generic failure, indeterminate results and lost replies are never retried")
    func uncertainRequestsAreNotReplayed() async {
        for reply in [RefreshTestClient.Reply.recoverable, .indeterminate, .lostReply] {
            let client = RefreshTestClient(replies: [reply])
            let store = makeStore(client)
            await store.connect()
            _ = await store.refreshProviders([.codex])
            #expect(await client.recorded().count == 1)
            await store.disconnect()
        }
    }

    @Test("User execution commands are not automatically retried even when deferred")
    func executionIsNotReplayed() async {
        let client = RefreshTestClient(replies: [.deferred])
        let store = makeStore(client)
        await store.connect()
        _ = await store.followUp(runID: .init(rawValue: "run"), text: "Continue")
        #expect(await client.recorded().count == 1)
        await store.disconnect()
    }

    @Test("Unchanged drafts do not contend with a refresh")
    func unchangedDraftIsNotSent() async {
        let client = RefreshTestClient()
        let store = makeStore(client)
        await store.connect()
        await store.flushDraft()
        #expect(await client.recorded().isEmpty)
        await store.disconnect()
    }

    @Test("Edits made while a draft save waits are not overwritten by its acknowledgement")
    func preservesNewerDraft() async {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        store.updateDraft("First edit")
        let save = Task { await store.flushDraft() }
        #expect(await client.waitForCount(1))
        store.updateDraft("Newer edit")
        await client.release()
        await save.value
        #expect(store.draftText == "Newer edit")
        #expect(store.draftSyncPhase == .locallyModified)
        await store.disconnect()
    }

    @Test("Disconnect discards queued commands and late replies from the old session")
    func disconnectDiscardsQueue() async throws {
        let client = RefreshTestClient(blockFirst: true)
        let store = makeStore(client)
        await store.connect()
        let refresh = Task { await store.refreshProviders([.codex]) }
        #expect(await client.waitForCount(1))
        let followUp = Task { await store.followUp(runID: .init(rawValue: "run"), text: "Continue") }
        try await Task.sleep(for: .milliseconds(30))
        await store.disconnect()
        await client.release()
        #expect(await refresh.value == nil)
        #expect(await followUp.value == nil)
        #expect(await client.recorded().count == 1)
        #expect(store.connectionPhase == .disconnected)
    }

    @Test("Activity payload and optional pre-admission flag preserve wire compatibility")
    func wireCompatibility() throws {
        let payload = GADCommandPayload.refreshProviderActivity([.codex, .claude])
        #expect(try JSONDecoder().decode(GADCommandPayload.self, from: JSONEncoder().encode(payload)) == payload)
        let old = Data(#"{"commandID":"command","disposition":"failedRecoverable","revision":0,"message":"Busy"}"#.utf8)
        let acknowledgement = try JSONDecoder().decode(GADCommandAcknowledgement.self, from: old)
        #expect(acknowledgement.wasDeferredBeforeAdmission == nil)
    }

    @Test("A background flush preserves the current provider, model and exact recipients")
    func backgroundFlushPreservesRoutingContext() async throws {
        let client = RefreshTestClient()
        let draft = GADDraftProjection(
            text: "Canonical draft", providerID: .claude, model: "fixture-model", platform: .iOS,
            projectIDs: [.init(rawValue: "project-a"), .init(rawValue: "project-b")],
            agentTargets: [.init(providerID: .claude, agentID: .init(rawValue: "agent-a"), projectID: .init(rawValue: "project-a"))],
            groupID: nil
        )
        await client.setDraft(draft)
        let store = makeStore(client)
        await store.connect()
        store.updateDraft("Pending background edit")
        await store.flushPendingDraft()
        let command = try #require(await client.recorded().last)
        #expect(command.payload == .replaceDraft(.init(
            expectedRevision: draft.revision, text: "Pending background edit",
            providerID: draft.providerID, model: draft.model, platform: draft.platform,
            projectIDs: draft.projectIDs, agentTargets: draft.agentTargets, groupID: draft.groupID
        )))
        await store.disconnect()
        await store.connect()
        #expect(store.projection?.draft.model == draft.model)
        #expect(store.projection?.draft.providerID == draft.providerID)
        #expect(store.projection?.draft.agentTargets == draft.agentTargets)
        #expect(store.draftText == "Pending background edit")
        await store.disconnect()
    }

    private func makeStore(_ client: RefreshTestClient) -> ContinuityStore {
        ContinuityStore(client: client, deviceID: .init(rawValue: "desktop"))
    }

    private func makePlan(goal: String = "Review analytics") -> GADPlanProjection {
        GADPlanProjection(
            id: .init(rawValue: "plan"), goal: goal,
            routes: [.init(projectID: .init(rawValue: "project"), agentIDs: [.init(rawValue: "agent")], reason: "Selected")],
            risk: .readOnly, confidence: 1, gitOperations: [], warnings: [],
            selectedResourceIDs: [], createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private actor RefreshTestClient: GobyClient {
    enum Reply: Sendable {
        case accepted, deferred, recoverable, indeterminate, lostReply
        case staleWithBackgroundUpdate, staleWithDraftChange, staleWithPlanChange
    }
    private let version: GADProtocolVersion
    private let blockFirst: Bool
    private var replies: [Reply]
    private var commands: [GADCommand] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var activeSends = 0
    private(set) var maximumConcurrentSends = 0
    private var projection = DashboardProjection(
        generatedAt: .now,
        host: .init(id: .init(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: .now)
    )

    init(version: GADProtocolVersion = .current, blockFirst: Bool = false, replies: [Reply] = []) {
        self.version = version
        self.blockFirst = blockFirst
        self.replies = replies
    }

    func connect() async throws -> ClientSession {
        .init(hostID: projection.host.id, hostEpoch: .init(rawValue: "epoch"), protocolVersion: version,
              revision: projection.revision, capabilities: GADCapability.productionHost.sorted { $0.rawValue < $1.rawValue })
    }

    func snapshot() async throws -> DashboardProjection { projection }
    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> { AsyncStream { _ in } }
    func disconnect() async {}
    func recorded() -> [GADCommand] { commands }
    func setDraft(_ draft: GADDraftProjection) {
        projection = projection.applying([.draft(draft)], revision: projection.revision.advanced(), generatedAt: .now)
    }
    func setPlan(_ plan: GADPlanProjection) {
        projection = projection.applying([.plan(plan)], revision: projection.revision.advanced(), generatedAt: .now)
    }
    func release() { gate?.resume(); gate = nil }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if commands.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        commands.append(command)
        activeSends += 1
        maximumConcurrentSends = max(maximumConcurrentSends, activeSends)
        defer { activeSends -= 1 }
        if blockFirst, commands.count == 1 { await withCheckedContinuation { gate = $0 } }
        let reply = replies.isEmpty ? .accepted : replies.removeFirst()
        if reply == .lostReply { throw GADHostIPCClientError.hostUnavailable("Reply lost") }
        if reply == .staleWithBackgroundUpdate {
            projection = projection.applying([.host(.init(
                id: projection.host.id, displayName: "Updated Mac",
                reachability: .online, lastUpdatedAt: .now
            ))], revision: projection.revision.advanced(), generatedAt: .now)
        } else if reply == .staleWithDraftChange {
            projection = projection.applying([.draft(.init(
                revision: projection.draft.revision.advanced(), text: "Changed on another device",
                projectIDs: [], agentTargets: [], groupID: nil
            ))], revision: projection.revision.advanced(), generatedAt: .now)
        } else if reply == .staleWithPlanChange, let plan = projection.plan {
            projection = projection.applying([.plan(.init(
                id: plan.id, goal: "Changed plan", routes: plan.routes, risk: plan.risk,
                confidence: plan.confidence, gitOperations: plan.gitOperations,
                warnings: plan.warnings, selectedResourceIDs: plan.selectedResourceIDs,
                createdAt: plan.createdAt
            ))], revision: projection.revision.advanced(), generatedAt: .now)
        }
        if reply == .accepted, case let .replaceDraft(draft) = command.payload {
            projection = projection.applying([.draft(.init(
                revision: projection.draft.revision.advanced(), text: draft.text,
                providerID: draft.providerID, model: draft.model, platform: draft.platform,
                projectIDs: draft.projectIDs, agentTargets: draft.agentTargets, groupID: draft.groupID
            ))], revision: projection.revision.advanced(), generatedAt: .now)
        }
        let isStale = reply == .staleWithBackgroundUpdate
            || reply == .staleWithDraftChange || reply == .staleWithPlanChange
        return .init(commandID: command.id,
                     disposition: isStale ? .rejectedStale : (reply == .accepted ? .accepted : (reply == .indeterminate ? .failedIndeterminate : .failedRecoverable)),
                     revision: projection.revision,
                     message: isStale ? "Canonical state changed; review the refreshed scope."
                         : (reply == .accepted ? nil : "Another dashboard change is finishing."),
                     wasDeferredBeforeAdmission: reply == .deferred ? true : nil)
    }
}
