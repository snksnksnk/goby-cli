import Foundation
import GobyApplication
import GobyDomain
import Testing
import Observation
import Synchronization
@testable import GobyExperience

@Suite("Continuity experience")
struct ContinuityStoreTests {
    @Test("An open automation review follows the host's current plan and withdrawal")
    @MainActor
    func automationReviewFollowsCanonicalOccurrence() async throws {
        let coordinator = GADPairedContinuationFixture.makeAutomationCoordinator()
        let store = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.phoneDeviceID
            ),
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await store.connect()

        let occurrenceID = GADPairedContinuationFixture.automationOccurrenceID
        let original = try #require(
            GADPairedContinuationFixture.automationProjection.automations.occurrences.first
        )
        let originalState = try #require(
            AutomationReviewState.current(occurrenceID: occurrenceID, in: store.projection)
        )
        let currentAction = try #require(
            original.actions.indices.contains(original.currentActionIndex)
                ? original.actions[original.currentActionIndex]
                : nil
        )
        let replacementPlan = RoutingPlan(
            id: RunID(rawValue: "replacement-automation-plan"),
            interpretedGoal: "Review the revised release scope",
            routes: originalState.plan.routes,
            risk: originalState.plan.risk,
            confidence: originalState.plan.confidence,
            createdAt: GADPairedContinuationFixture.timestamp
        )
        let replacement = AutomationOccurrence(
            id: original.id,
            automationID: original.automationID,
            automationName: original.automationName,
            definitionRevision: original.definitionRevision,
            actions: original.actions,
            trigger: original.trigger,
            scheduledAt: original.scheduledAt,
            status: .needsAttention,
            currentActionIndex: original.currentActionIndex,
            attempts: [.init(
                actionID: currentAction.id,
                plan: replacementPlan,
                status: .waitingForReview,
                updatedAt: GADPairedContinuationFixture.timestamp
            )],
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        let base = GADPairedContinuationFixture.automationProjection
        let newSnapshot = AutomationSnapshot(
            definitions: base.automations.definitions,
            occurrences: [replacement]
        )
        await coordinator.synchronize(base.applying(
            [.automations(newSnapshot)],
            revision: base.revision,
            generatedAt: base.generatedAt
        ))
        #expect(await eventually {
            AutomationReviewState.current(occurrenceID: occurrenceID, in: store.projection)?.plan.id
                == replacementPlan.id
        })
        #expect(originalState.binding.planID != replacementPlan.id)

        let withdrawn = AutomationSnapshot(definitions: base.automations.definitions)
        await coordinator.synchronize(base.applying(
            [.automations(withdrawn)],
            revision: base.revision,
            generatedAt: base.generatedAt
        ))
        #expect(await eventually {
            AutomationReviewState.current(occurrenceID: occurrenceID, in: store.projection) == nil
        })
        await store.disconnect()
    }

    @Test("Refreshing unchanged host draft preserves a pending local edit")
    @MainActor
    func unrelatedProjectionRefreshDoesNotConflictWithLocalDraft() async {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let store = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.macDeviceID
            ),
            deviceID: GADPairedContinuationFixture.macDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await store.connect()
        let updated = "Check whether iOS supports the latest changes"
        store.updateDraft(updated)

        await store.refreshProjection()

        #expect(store.draftText == updated)
        #expect(store.draftSyncPhase == .locallyModified)
        await store.flushDraft()
        #expect(store.draftSyncPhase == .synced)
        #expect(store.projection?.draft.text == updated)
        await store.disconnect()
    }

    @Test("Mac and iPhone continue one canonical draft without silently losing a conflict")
    @MainActor
    func pairedDevicesContinueCanonicalDraft() async {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let mac = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.macDeviceID
            ),
            deviceID: GADPairedContinuationFixture.macDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        let phone = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.phoneDeviceID
            ),
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )

        await mac.connect()
        await phone.connect()

        #expect(mac.connectionPhase == .live)
        #expect(phone.connectionPhase == .live)
        #expect(phone.draftText == GADPairedContinuationFixture.initialDraft)

        let continuedOnMac = "Complete the Goby v1 beta from the Mac"
        mac.updateDraft(continuedOnMac)
        await mac.flushDraft(
            platform: .iOS,
            projectIDs: [GADPairedContinuationFixture.projectID]
        )

        #expect(await eventually {
            phone.draftText == continuedOnMac && phone.draftSyncPhase == .synced
        })
        #expect(phone.projection?.draft.platform == .iOS)

        let localPhoneEdit = "Complete the Goby v1 beta from the iPhone"
        phone.updateDraft(localPhoneEdit)
        let canonicalMacEdit = "Complete the Goby v1 beta after Mac review"
        mac.updateDraft(canonicalMacEdit)
        await mac.flushDraft(
            platform: .iOS,
            projectIDs: [GADPairedContinuationFixture.projectID]
        )

        #expect(await eventually {
            phone.draftText == localPhoneEdit
                && phone.draftSyncPhase == .conflict(canonicalText: canonicalMacEdit)
        })

        await phone.deliberatelyReplaceConflictingDraft(
            platform: .iOS,
            projectIDs: [GADPairedContinuationFixture.projectID]
        )

        #expect(await eventually {
            mac.draftText == localPhoneEdit && mac.draftSyncPhase == .synced
        })
        #expect(phone.draftSyncPhase == .synced)
        #expect(mac.projection?.revision == phone.projection?.revision)

        await mac.disconnect()
        await phone.disconnect()
    }

    @Test("Ordinary saves cannot resolve a cross-device draft conflict", arguments: [false, true])
    @MainActor
    func conflictedDraftRequiresExplicitResolution(continuesEditing: Bool) async throws {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let mac = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator, deviceID: GADPairedContinuationFixture.macDeviceID
            ),
            deviceID: GADPairedContinuationFixture.macDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        let phone = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator, deviceID: GADPairedContinuationFixture.phoneDeviceID
            ),
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await mac.connect()
        await phone.connect()
        phone.updateDraft("Local phone draft")
        mac.updateDraft("Newer Mac draft")
        await mac.flushDraft()
        try #require(await eventually {
            phone.draftSyncPhase == .conflict(canonicalText: "Newer Mac draft")
        })
        let canonicalRevision = phone.projection?.draft.revision

        if continuesEditing { phone.updateDraft("Local phone draft with more typing") }
        #expect(phone.draftSyncPhase == .conflict(canonicalText: "Newer Mac draft"))
        // Focus loss, backgrounding and plan review all use this ordinary save.
        await phone.flushDraft()
        #expect(phone.draftSyncPhase == .conflict(canonicalText: "Newer Mac draft"))
        #expect(phone.projection?.draft.text == "Newer Mac draft")
        #expect(phone.projection?.draft.revision == canonicalRevision)
        #expect(phone.draftText == (continuesEditing ? "Local phone draft with more typing" : "Local phone draft"))

        await phone.deliberatelyReplaceConflictingDraft()
        #expect(phone.draftSyncPhase == .synced)
        #expect(await eventually { mac.draftText == phone.draftText })
        await mac.disconnect()
        await phone.disconnect()
    }

    @Test("A host restart preserves an unsent iPhone draft as an explicit conflict")
    @MainActor
    func hostRestartPreservesOfflineDraft() async {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(
            session: .init(
                hostID: GADPairedContinuationFixture.hostID,
                hostEpoch: GADPairedContinuationFixture.hostEpoch,
                protocolVersion: .current,
                revision: original.revision,
                capabilities: [.sharedDraft]
            ),
            projection: original
        )
        let phone = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )

        await phone.connect()
        #expect(await client.waitForEventSubscriber())
        let localDraft = "Finish the beta after the phone reconnects"
        phone.updateDraft(localDraft)

        let canonicalDraft = GADDraftProjection(
            revision: original.draft.revision.advanced(),
            text: "Finish the beta after the Mac restarts",
            providerID: .codex,
            platform: .iOS,
            projectIDs: [GADPairedContinuationFixture.projectID],
            agentTargets: [],
            groupID: nil
        )
        let restartedProjection = original.applying(
            [.draft(canonicalDraft)],
            revision: original.revision.advanced(),
            generatedAt: GADPairedContinuationFixture.timestamp.addingTimeInterval(1)
        )
        let restartedEpoch = HostEpoch(rawValue: "paired-host-epoch-after-restart")
        await client.restart(
            session: .init(
                hostID: GADPairedContinuationFixture.hostID,
                hostEpoch: restartedEpoch,
                protocolVersion: .current,
                revision: restartedProjection.revision,
                capabilities: [.sharedDraft]
            ),
            projection: restartedProjection
        )

        #expect(await eventually { phone.connectionPhase.isStale })
        await phone.connect()

        #expect(phone.connectionPhase == .live)
        #expect(phone.session?.hostEpoch == restartedEpoch)
        #expect(phone.draftText == localDraft)
        #expect(phone.draftSyncPhase == .conflict(canonicalText: canonicalDraft.text))
        await phone.disconnect()
    }

    @Test("Desktop reconnection restores a new host epoch without losing the unsent draft", arguments: [false, true])
    @MainActor
    func desktopAutomaticallyReconnects(attachmentOnly: Bool) async {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)]
        )
        await store.connect()
        #expect(await client.waitForEventSubscriber())
        let text = attachmentOnly ? original.draft.text : "Keep my unsent work"
        let attachment = PromptAttachment(kind: .snippet, displayName: "Unsent snippet", source: .text("Keep this context"))
        store.updateDraft(text, attachments: [attachment])
        let nextEpoch = HostEpoch(rawValue: "recovered-host")
        await client.restart(session: reconnectSession(epoch: nextEpoch), projection: original, connectionFailures: 1)

        #expect(await eventually { store.connectionPhase == .live && store.session?.hostEpoch == nextEpoch })
        #expect(store.draftText == text)
        #expect(store.draftAttachments == [attachment])
        #expect(store.draftSyncPhase == .conflict(canonicalText: original.draft.text))
        #expect(await client.connectionCount == 3)
        #expect(await client.sentCommandCount == 0)
        #expect(store.lastClientErrorMessage == nil)
        await store.disconnect()
    }

    @Test("Continued recovery survives outages beyond the initial retry budget")
    @MainActor
    func continuedDesktopRecovery() async {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(10), .milliseconds(10)],
            reconnectRepeatDelay: .milliseconds(10)
        )
        await store.connect()
        #expect(await client.waitForEventSubscriber())
        store.updateDraft("Keep editing during the outage")
        let epoch = HostEpoch(rawValue: "returned-host")
        await client.restart(session: reconnectSession(epoch: epoch), projection: original, connectionFailures: 5)
        #expect(await eventually { store.session?.hostEpoch == epoch && store.connectionPhase == .live })
        #expect(await client.connectionCount == 7)
        #expect(await client.sentCommandCount == 0)
        #expect(store.draftText == "Keep editing during the outage")
        #expect(!store.isRecoveringConnection)
        await store.disconnect()
    }

    @Test("Continued recovery also handles an initially unavailable host without cached data")
    @MainActor
    func recoversInitialConnection() async {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        await client.restart(session: reconnectSession(), projection: original, connectionFailures: 3)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(10)], reconnectRepeatDelay: .milliseconds(10)
        )
        store.updateDraft("Unsent startup draft")
        await store.connect()
        #expect(store.projection == nil)
        #expect(store.isRecoveringConnection)
        #expect(await eventually { store.connectionPhase == .live })
        #expect(store.draftText == "Unsent startup draft")
        #expect(await client.connectionCount == 4)
        #expect(await client.sentCommandCount == 0)
        await store.disconnect()
    }

    @Test("Disconnect and revocation cancel continued recovery", arguments: [false, true])
    @MainActor
    func continuedRecoveryStops(revoke: Bool) async throws {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectRepeatDelay: .milliseconds(30)
        )
        await store.connect()
        #expect(await client.waitForEventSubscriber())
        await client.restart(session: reconnectSession(), projection: original, connectionFailures: 50)
        #expect(await eventually { store.isRecoveringConnection })
        if revoke {
            await client.revoke()
            #expect(await eventually { store.connectionPhase == .revoked })
        } else {
            await store.disconnect()
        }
        let count = await client.connectionCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.connectionCount == count)
        #expect(!store.isRecoveringConnection)
    }

    @Test("Incompatible local protocols stop continued recovery")
    @MainActor
    func incompatibleRecoveryStops() async throws {
        let client = RestartingGobyClient(
            session: reconnectSession(), projection: GADPairedContinuationFixture.projection,
            connectionError: .incompatibleVersion
        )
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectRepeatDelay: .milliseconds(10)
        )
        await store.connect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.connectionPhase == .incompatible)
        #expect(!store.isRecoveringConnection)
        #expect(await client.connectionCount == 1)
        #expect(await client.disconnectCount == 1)
        await store.disconnect()
    }

    @Test("A replaced app bundle stops recovery, keeps the draft and requests one relaunch")
    @MainActor
    func replacedApplicationRequestsRelaunch() async throws {
        let client = RestartingGobyClient(
            session: reconnectSession(), projection: GADPairedContinuationFixture.projection,
            connectionError: .applicationReplaced
        )
        let draftCache = MemoryLocalDraftCache()
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            draftCache: draftCache,
            reconnectRepeatDelay: .milliseconds(10)
        )
        var relaunchRequests = 0
        store.applicationRelaunchDidBecomeRequired = { relaunchRequests += 1 }
        store.updateDraft("analytics are terrible. make me a plan")
        await store.connect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.connectionPhase == .incompatible)
        #expect(store.requiresApplicationRelaunch)
        #expect(!store.isRecoveringConnection)
        #expect(relaunchRequests == 1)
        #expect(await client.connectionCount == 1)
        #expect(await draftCache.text == "analytics are terrible. make me a plan")
        await store.disconnect()
    }

    @Test("Bounded reconnection stops at its retry budget and retains the real error")
    @MainActor
    func desktopReconnectionIsBounded() async throws {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(10), .milliseconds(10)]
        )
        await store.connect()
        #expect(await client.waitForEventSubscriber())
        await client.restart(session: reconnectSession(), projection: original, connectionFailures: 10)
        try await Task.sleep(for: .milliseconds(150))

        #expect(await client.connectionCount == 3)
        #expect(store.connectionPhase.isStale)
        #expect(store.lastClientErrorMessage == "Test host is temporarily unavailable.")
        #expect(store.projection == original)
        await store.disconnect()
    }

    @Test("Explicit disconnect cancels a pending desktop reconnection")
    @MainActor
    func disconnectCancelsReconnection() async throws {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(session: reconnectSession(), projection: original)
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(100)]
        )
        await store.connect()
        #expect(await client.waitForEventSubscriber())
        await client.restart(session: reconnectSession(), projection: original)
        #expect(await eventually { store.connectionPhase.isStale })
        await store.disconnect()
        try await Task.sleep(for: .milliseconds(150))

        #expect(await client.connectionCount == 1)
        #expect(store.connectionPhase == .disconnected)
    }

    @Test("A lost command reply reconnects the desktop without replaying the command")
    @MainActor
    func reconnectionNeverReplaysCommands() async {
        let client = RestartingGobyClient(
            session: reconnectSession(), projection: GADPairedContinuationFixture.projection
        )
        let store = ContinuityStore(
            client: client, deviceID: GADPairedContinuationFixture.macDeviceID,
            reconnectDelays: [.milliseconds(10)], reconnectRepeatDelay: .milliseconds(10)
        )
        await store.connect()
        await client.failSends()
        #expect(await store.control(runID: "interrupted-run", action: .resume) == nil)
        #expect(await eventually { store.connectionPhase == .live })
        #expect(await client.sentCommandCount == 1)
        #expect(await client.connectionCount == 2)
        await store.disconnect()
    }

    private func reconnectSession(
        epoch: HostEpoch = GADPairedContinuationFixture.hostEpoch
    ) -> ClientSession {
        .init(
            hostID: GADPairedContinuationFixture.hostID, hostEpoch: epoch,
            protocolVersion: .current, revision: GADPairedContinuationFixture.projection.revision,
            capabilities: [.sharedDraft]
        )
    }

    @Test("A cold iPhone relaunch restores its protected unsent draft")
    @MainActor
    func coldRelaunchRestoresUnsentDraft() async {
        let original = GADPairedContinuationFixture.projection
        let client = RestartingGobyClient(
            session: .init(
                hostID: GADPairedContinuationFixture.hostID,
                hostEpoch: GADPairedContinuationFixture.hostEpoch,
                protocolVersion: .current,
                revision: original.revision,
                capabilities: [.sharedDraft]
            ),
            projection: original
        )
        let draftCache = MemoryLocalDraftCache()
        let firstLaunch = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            draftCache: draftCache,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await firstLaunch.connect()
        let unsentDraft = "Protected work that must survive relaunch"
        firstLaunch.updateDraft(unsentDraft)
        await firstLaunch.disconnect()
        #expect(await draftCache.text == unsentDraft)

        let relaunched = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            draftCache: draftCache,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await relaunched.connect()

        #expect(relaunched.draftText == unsentDraft)
        #expect(relaunched.draftSyncPhase == .conflict(canonicalText: original.draft.text))
        await relaunched.disconnect()
    }

    @Test("A live local draft debounces to the coordinator and clears its recovery copy")
    @MainActor
    func draftDebounceSynchronizesAndClearsRecoveryCopy() async {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let draftCache = MemoryLocalDraftCache()
        let phone = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.phoneDeviceID
            ),
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            draftCache: draftCache,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await phone.connect()
        let updated = "Debounced canonical continuation"
        phone.updateDraft(updated)

        #expect(await eventually(attempts: 200) {
            phone.draftSyncPhase == .synced && phone.projection?.draft.text == updated
        })
        #expect(await draftCache.text == nil)
        await phone.disconnect()
    }

    @Test("A revoked iPhone loses its canonical session and sensitive draft")
    @MainActor
    func revocationClearsClientState() async {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let draftCache = MemoryLocalDraftCache()
        let phone = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(
                coordinator: coordinator,
                deviceID: GADPairedContinuationFixture.phoneDeviceID
            ),
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            draftCache: draftCache,
            now: { GADPairedContinuationFixture.timestamp }
        )

        await phone.connect()
        phone.updateDraft("Sensitive local continuation")
        await coordinator.revoke(GADPairedContinuationFixture.phoneDeviceID)
        #expect(await eventually { phone.connectionPhase == .revoked })
        let rejectedCommand = await phone.preparePlan()

        #expect(rejectedCommand == nil)
        #expect(phone.connectionPhase == .revoked)
        #expect(phone.session == nil)
        #expect(phone.projection == nil)
        #expect(phone.draftText.isEmpty)
        #expect(phone.draftSyncPhase == .synced)
        #expect(await draftCache.text == nil)
    }

    @Test("A duplicate state delivery is ignored after its revision is applied")
    @MainActor
    func duplicateDeliveryIsIdempotent() async {
        let original = GADPairedContinuationFixture.projection
        let client = ReplayGobyClient(
            session: .init(
                hostID: GADPairedContinuationFixture.hostID,
                hostEpoch: GADPairedContinuationFixture.hostEpoch,
                protocolVersion: .current,
                revision: original.revision,
                capabilities: [.sharedDraft]
            ),
            projection: original
        )
        let phone = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        var projectionChangeCount = 0
        phone.projectionDidChange = { _ in projectionChangeCount += 1 }
        await phone.connect()

        let changedDraft = GADDraftProjection(
            revision: original.draft.revision.advanced(),
            text: "One canonical delivery",
            providerID: .codex,
            platform: .iOS,
            projectIDs: [GADPairedContinuationFixture.projectID],
            agentTargets: [],
            groupID: nil
        )
        let delta = GADStateDelta(
            hostEpoch: GADPairedContinuationFixture.hostEpoch,
            revision: original.revision.advanced(),
            occurredAt: GADPairedContinuationFixture.timestamp,
            originatingCommandID: nil,
            changes: [.draft(changedDraft)]
        )
        await client.deliver(delta)
        await client.deliver(delta)

        #expect(await eventually {
            phone.projection?.revision == delta.revision
                && phone.draftText == changedDraft.text
        })
        #expect(projectionChangeCount == 2)
        #expect(phone.connectionPhase == .live)
        await phone.disconnect()
    }

    @Test("The client starts from a disconnected state")
    func disconnectedStateIsStable() {
        #expect(GADClientConnectionPhase.disconnected == .disconnected)
    }

    @Test("A future protocol major fails closed before accepting canonical state")
    @MainActor
    func futureProtocolIsIncompatible() async {
        let timestamp = Date(timeIntervalSince1970: 50_000)
        let hostID = HostID(rawValue: "future-studio-mac")
        let projection = DashboardProjection(
            revision: .init(rawValue: 4),
            generatedAt: timestamp,
            host: .init(id: hostID, displayName: "Future Studio Mac", reachability: .online, lastUpdatedAt: timestamp)
        )
        let client = RestartingGobyClient(
            session: .init(
                hostID: hostID,
                hostEpoch: .init(rawValue: "future-epoch"),
                protocolVersion: .init(major: GADProtocolVersion.current.major + 1, minor: 0),
                revision: projection.revision,
                capabilities: [.sharedDraft]
            ),
            projection: projection
        )
        let store = ContinuityStore(client: client, deviceID: .init(rawValue: "phone"))

        await store.connect()

        #expect(store.connectionPhase == .incompatible)
        #expect(store.session == nil)
        #expect(store.projection == nil)
        #expect(await client.disconnectCount == 1)
    }

    @Test("A closed live stream becomes stale instead of appearing connected")
    @MainActor
    func closedEventStreamBecomesStale() async throws {
        let timestamp = Date(timeIntervalSince1970: 50_000)
        let hostID = HostID(rawValue: "studio-mac")
        let epoch = HostEpoch(rawValue: "epoch-1")
        let projection = DashboardProjection(
            revision: .init(rawValue: 4),
            generatedAt: timestamp,
            host: .init(id: hostID, displayName: "Studio Mac", reachability: .online, lastUpdatedAt: timestamp)
        )
        let client = EndingGobyClient(
            session: .init(
                hostID: hostID,
                hostEpoch: epoch,
                protocolVersion: .version1,
                revision: projection.revision,
                capabilities: [.sharedDraft]
            ),
            projection: projection
        )
        let store = ContinuityStore(client: client, deviceID: .init(rawValue: "phone"))

        await store.connect()
        #expect(store.connectionPhase == .live)

        await client.finishEvents()
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.connectionPhase == .stale(lastSuccessfulAt: timestamp))
    }

    @Test("Revocation cancels pending desktop recovery, erases local state and notifies the app shell")
    @MainActor
    func liveRevocationErasesState() async {
        let projection = GADPairedContinuationFixture.projection
        let client = LifecycleGobyClient(
            session: .init(
                hostID: projection.host.id,
                hostEpoch: GADPairedContinuationFixture.hostEpoch,
                protocolVersion: .current,
                revision: projection.revision,
                capabilities: [.sharedDraft]
            ),
            projection: projection
        )
        let draftCache = MemoryLocalDraftCache()
        let store = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            draftCache: draftCache,
            reconnectDelays: [.milliseconds(100)]
        )
        var callbackCount = 0
        store.revocationDidOccur = { callbackCount += 1 }
        await store.connect()
        store.updateDraft("Sensitive unsent text", attachments: [
            .init(
                kind: .snippet,
                displayName: "Private snippet",
                source: .text("Sensitive unsent text")
            )
        ])
        #expect(await client.waitForLifecycleSubscriber())

        await client.loseTransport()
        #expect(await eventually { store.connectionPhase.isStale })
        await client.revoke()
        #expect(await eventually {
            store.connectionPhase == .revoked && callbackCount == 1
        })
        #expect(store.session == nil)
        #expect(store.projection == nil)
        #expect(store.draftText.isEmpty)
        #expect(store.draftAttachments.isEmpty)
        #expect(await draftCache.text == nil)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await client.connectionCount == 1)
    }

    @Test("Revocation cleanup failure keeps the client fail closed")
    @MainActor
    func revocationCleanupFailureDoesNotRestorePairedState() async {
        let projection = GADPairedContinuationFixture.projection
        let client = LifecycleGobyClient(
            session: .init(
                hostID: projection.host.id,
                hostEpoch: GADPairedContinuationFixture.hostEpoch,
                protocolVersion: .current,
                revision: projection.revision,
                capabilities: [.sharedDraft]
            ),
            projection: projection
        )
        let cache = FailingRevocationCache()
        let store = ContinuityStore(
            client: client,
            deviceID: GADPairedContinuationFixture.phoneDeviceID,
            cache: cache,
            draftCache: cache
        )
        var callbackCount = 0
        store.revocationDidOccur = { callbackCount += 1 }
        await store.connect()
        #expect(await client.waitForLifecycleSubscriber())

        await client.revoke()
        #expect(await eventually {
            if case .failed = store.connectionPhase { return callbackCount == 1 }
            return false
        })
        #expect(store.session == nil)
        #expect(store.projection == nil)
        #expect(store.draftText.isEmpty)
    }

    @Test("A transient diagnostic artifact is removed from observable store state")
    @MainActor
    func redactedDiagnosticsDoNotRemainCached() async {
        let timestamp = Date(timeIntervalSince1970: 50_000)
        let projection = DashboardProjection(
            revision: .init(rawValue: 4),
            generatedAt: timestamp,
            host: .init(
                id: .init(rawValue: "studio-mac"),
                displayName: "Studio Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let report = Data("{\"status\":\"redacted\"}".utf8)
        let client = DiagnosticGobyClient(projection: projection, report: report)
        let store = ContinuityStore(client: client, deviceID: .init(rawValue: "phone"))
        await store.connect()

        let received = await store.redactedDiagnostics(using: .init(
            id: "preview-1",
            hash: "hash-1",
            expiresAt: .distantFuture,
            requiresLocalAuthentication: false,
            effects: []
        ))

        #expect(received == report)
        #expect(store.lastAcknowledgement == nil)
    }

    @Test("Receipt expiry and disconnect notify visible approval controls without a scroll", arguments: [false, true])
    @MainActor
    func receiptInvalidationIsObserved(disconnect: Bool) async {
        let timestamp = Date.now
        let projection = DashboardProjection(
            revision: .init(rawValue: 4), generatedAt: timestamp,
            host: .init(id: .init(rawValue: "mac"), displayName: "Mac", reachability: .online, lastUpdatedAt: timestamp)
        )
        let client = ApprovalGobyClient(projection: projection, disclosure: .init(
            approvalID: "permission-request", requestDigest: "receipt", summary: "Allow network",
            details: "Exact network permission profile", expiresAt: timestamp.addingTimeInterval(2)
        ))
        let store = ContinuityStore(client: client, deviceID: .init(rawValue: "mac"))
        await store.connect()
        #expect(await store.approvalDisclosure(for: "permission-request") != nil)
        #expect(store.hasCurrentApprovalDisclosure(for: "permission-request"))
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.hasCurrentApprovalDisclosure(for: "permission-request")
        } onChange: { changed.withLock { $0 = true } }
        if disconnect { await store.disconnect() }
        #expect(await eventually(attempts: 500) { changed.withLock { $0 } })
        #expect(!store.hasCurrentApprovalDisclosure(for: "permission-request"))
        if disconnect {
            await store.connect()
            #expect(!store.hasCurrentApprovalDisclosure(for: "permission-request"))
        }
        await store.disconnect()
    }

    @Test("An exact approval disclosure receipt is consumed after one response")
    @MainActor
    func approvalDisclosureReceiptIsSingleUse() async {
        let timestamp = Date(timeIntervalSince1970: 50_000)
        let projection = DashboardProjection(
            revision: .init(rawValue: 4),
            generatedAt: timestamp,
            host: .init(
                id: .init(rawValue: "studio-mac"),
                displayName: "Studio Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let client = ApprovalGobyClient(
            projection: projection,
            disclosure: .init(
                approvalID: "approval-1",
                requestDigest: "exact-request-digest",
                summary: "Run the reviewed command",
                details: "Project: [project: Demo]",
                expiresAt: timestamp.addingTimeInterval(120)
            )
        )
        let store = ContinuityStore(
            client: client,
            deviceID: .init(rawValue: "phone"),
            now: { timestamp }
        )
        let approval = GADApprovalProjection(
            id: "approval-1",
            runID: .init(rawValue: "run-1"),
            assignmentID: .init(rawValue: "assignment-1"),
            kind: .command,
            summary: "Approval required",
            details: nil,
            actions: [.decline, .allowOnce, .allowForRun],
            approvalSessionID: .init(rawValue: "compatibility-only"),
            expiresAt: timestamp.addingTimeInterval(120)
        )
        await store.connect()

        #expect(await store.approvalDisclosure(for: approval.id) != nil)
        _ = await store.respond(
            to: approval,
            action: .allowOnce,
            authorizationAssertion: "user-presence-required"
        )
        _ = await store.respond(
            to: approval,
            action: .allowOnce,
            authorizationAssertion: "user-presence-required"
        )

        let responses = await client.approvalResponses()
        #expect(responses.count == 2)
        #expect(responses.first?.disclosureDigest == "exact-request-digest")
        #expect(responses.last?.disclosureDigest == nil)
        #expect(responses.allSatisfy { $0.action == .allowOnce })
    }
}

@MainActor
private func eventually(
    attempts: Int = 100,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private extension GADClientConnectionPhase {
    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

private actor RestartingGobyClient: GobyClient {
    private var session: ClientSession
    private var projection: DashboardProjection
    private var streams: [AsyncStream<GADStateDelta>.Continuation] = []
    private var connectionFailures = 0
    private var sendsFail = false
    private let connectionError: GADHostIPCClientError?
    private var lifecyclePair = AsyncStream<GobyClientLifecycleEvent>.makeStream()
    private(set) var connectionCount = 0
    private(set) var disconnectCount = 0
    private(set) var sentCommandCount = 0

    init(session: ClientSession, projection: DashboardProjection, connectionError: GADHostIPCClientError? = nil) {
        self.session = session
        self.projection = projection
        self.connectionError = connectionError
    }

    func connect() async throws -> ClientSession {
        connectionCount += 1
        if let connectionError { throw connectionError }
        if connectionFailures > 0 {
            connectionFailures -= 1
            throw GADHostIPCClientError.hostUnavailable("Test host is temporarily unavailable.")
        }
        return session
    }
    func snapshot() async throws -> DashboardProjection { projection }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        sentCommandCount += 1
        if sendsFail { throw GADHostIPCClientError.hostUnavailable("Test command reply was lost.") }
        return GADCommandAcknowledgement(
            commandID: command.id,
            disposition: .accepted,
            revision: projection.revision
        )
    }

    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        let pair = AsyncStream<GADStateDelta>.makeStream()
        streams.append(pair.continuation)
        return pair.stream
    }

    func disconnect() async { disconnectCount += 1 }

    func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent> {
        lifecyclePair = AsyncStream<GobyClientLifecycleEvent>.makeStream()
        return lifecyclePair.stream
    }

    func revoke() { lifecyclePair.continuation.yield(.revoked) }

    func failSends() { sendsFail = true }

    func restart(session: ClientSession, projection: DashboardProjection, connectionFailures: Int = 0) {
        streams.forEach { $0.finish() }
        streams.removeAll()
        self.session = session
        self.projection = projection
        self.connectionFailures = connectionFailures
    }

    func waitForEventSubscriber() async -> Bool {
        for _ in 0..<100 {
            if !streams.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !streams.isEmpty
    }
}

private actor ReplayGobyClient: GobyClient {
    let session: ClientSession
    let projection: DashboardProjection
    private let eventPair = AsyncStream<GADStateDelta>.makeStream()

    init(session: ClientSession, projection: DashboardProjection) {
        self.session = session
        self.projection = projection
    }

    func connect() async throws -> ClientSession { session }
    func snapshot() async throws -> DashboardProjection { projection }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: command.id,
            disposition: .accepted,
            revision: projection.revision
        )
    }

    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        eventPair.stream
    }

    func disconnect() async {
        eventPair.continuation.finish()
    }

    func deliver(_ delta: GADStateDelta) {
        eventPair.continuation.yield(delta)
    }
}

private actor MemoryLocalDraftCache: GADLocalDraftCaching {
    private(set) var text: String?

    func loadLocalDraft() -> String? { text }

    func saveLocalDraft(_ text: String?) {
        self.text = text
    }
}

private actor FailingRevocationCache: GADProjectionCaching, GADLocalDraftCaching {
    enum Failure: Error { case eraseUnavailable }

    func load() -> DashboardProjection? { nil }
    func save(_ projection: DashboardProjection) {}
    func clear() throws { throw Failure.eraseUnavailable }
    func loadLocalDraft() -> String? { nil }
    func saveLocalDraft(_ text: String?) throws {
        if text == nil { throw Failure.eraseUnavailable }
    }
}

private actor EndingGobyClient: GobyClient {
    let session: ClientSession
    let projection: DashboardProjection
    let eventPair = AsyncStream<GADStateDelta>.makeStream()

    init(session: ClientSession, projection: DashboardProjection) {
        self.session = session
        self.projection = projection
    }

    func connect() async throws -> ClientSession { session }
    func snapshot() async throws -> DashboardProjection { projection }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: command.id,
            disposition: .accepted,
            revision: projection.revision
        )
    }

    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        eventPair.stream
    }

    func disconnect() async {}

    func finishEvents() {
        eventPair.continuation.finish()
    }
}

private actor DiagnosticGobyClient: GobyClient {
    let projection: DashboardProjection
    let report: Data
    let eventPair = AsyncStream<GADStateDelta>.makeStream()

    init(projection: DashboardProjection, report: Data) {
        self.projection = projection
        self.report = report
    }

    func connect() async throws -> ClientSession {
        .init(
            hostID: projection.host.id,
            hostEpoch: .init(rawValue: "epoch-1"),
            protocolVersion: .version1,
            revision: projection.revision,
            capabilities: [.redactedDiagnostics]
        )
    }

    func snapshot() async throws -> DashboardProjection { projection }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: command.id,
            disposition: .accepted,
            revision: projection.revision,
            artifact: .redactedDiagnostics(report)
        )
    }

    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        eventPair.stream
    }

    func disconnect() async {}
}

private actor ApprovalGobyClient: GobyClient {
    let projection: DashboardProjection
    let disclosure: GADApprovalDisclosure
    let eventPair = AsyncStream<GADStateDelta>.makeStream()
    private var responses: [GADApprovalResponse] = []

    init(projection: DashboardProjection, disclosure: GADApprovalDisclosure) {
        self.projection = projection
        self.disclosure = disclosure
    }

    func connect() async throws -> ClientSession {
        .init(
            hostID: projection.host.id,
            hostEpoch: .init(rawValue: "epoch-1"),
            protocolVersion: .current,
            revision: projection.revision,
            capabilities: [.runtimeApprovalOnce]
        )
    }

    func snapshot() async throws -> DashboardProjection { projection }

    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        let artifact: GADCommandArtifact?
        switch command.payload {
        case .requestApprovalDisclosure:
            artifact = .approvalDisclosure(disclosure)
        case let .respondToApproval(response):
            responses.append(response)
            artifact = nil
        default:
            artifact = nil
        }
        return .init(
            commandID: command.id,
            disposition: .accepted,
            revision: projection.revision,
            artifact: artifact
        )
    }

    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        eventPair.stream
    }

    func disconnect() async {}

    func approvalResponses() -> [GADApprovalResponse] { responses }
}

private actor LifecycleGobyClient: GobyClient {
    let session: ClientSession
    let projection: DashboardProjection
    private let eventPair = AsyncStream<GADStateDelta>.makeStream()
    private let lifecyclePair = AsyncStream<GobyClientLifecycleEvent>.makeStream()
    private var lifecycleSubscribed = false
    private(set) var connectionCount = 0

    init(session: ClientSession, projection: DashboardProjection) {
        self.session = session
        self.projection = projection
    }

    func connect() async throws -> ClientSession {
        connectionCount += 1
        return session
    }
    func snapshot() async throws -> DashboardProjection { projection }
    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        .init(commandID: command.id, disposition: .accepted, revision: projection.revision)
    }
    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> { eventPair.stream }
    func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent> {
        lifecycleSubscribed = true
        return lifecyclePair.stream
    }
    func disconnect() async {}
    func revoke() { lifecyclePair.continuation.yield(.revoked) }
    func loseTransport() { lifecyclePair.continuation.yield(.transportLost) }
    func waitForLifecycleSubscriber() async -> Bool {
        for _ in 0..<100 where !lifecycleSubscribed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lifecycleSubscribed
    }
}
