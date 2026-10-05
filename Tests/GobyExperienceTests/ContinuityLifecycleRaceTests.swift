import Foundation
import GobyApplication
import GobyDomain
import GobyExperience
import Testing

@Suite("Continuity lifecycle races")
@MainActor
struct ContinuityLifecycleRaceTests {
    @Test("An incompatible lifecycle event invalidates an in-flight reconnect snapshot")
    func incompatibleDuringHandshake() async throws {
        let client = LifecycleRaceClient()
        let store = ContinuityStore(client: client, deviceID: .init(rawValue: "race-test"),
                                    reconnectRepeatDelay: .milliseconds(10))
        let gate = await client.holdSnapshot()
        let startup = Task { await store.connect() }
        try #require(await gate.waitForEntry())
        await client.reportIncompatible()
        try #require(await eventually { store.connectionPhase == .incompatible })
        await gate.release()
        await startup.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.connectionPhase == .incompatible)
        #expect(!store.isRecoveringConnection)
        #expect(store.projection == nil)
        #expect(await client.connectionCount == 1)
        await store.disconnect()
    }

    @Test("A late snapshot cannot revive a disconnected session", arguments: [false, true])
    func snapshotAfterDisconnect(fails: Bool) async throws {
        let client = LifecycleRaceClient()
        let store = makeStore(client)
        await store.connect()
        let gate = await client.holdSnapshot(fails: fails)
        let request = Task { await store.followUp(runID: .init(rawValue: "run"), text: "Fixture") }
        try #require(await gate.waitForEntry())
        await store.disconnect()
        await gate.release()
        #expect(await request.value == nil)
        #expect(store.connectionPhase == .disconnected)
    }

    @Test("A snapshot from before reconnect cannot replace a newer same-epoch projection")
    func snapshotAfterReconnect() async throws {
        let client = LifecycleRaceClient()
        let store = makeStore(client)
        await store.connect()
        let gate = await client.holdSnapshot()
        let request = Task { await store.followUp(runID: .init(rawValue: "run"), text: "Fixture") }
        try #require(await gate.waitForEntry())
        let newer = changedProjection("New connection")
        await client.setProjection(newer)
        await store.connect()
        await gate.release()
        _ = await request.value
        #expect(store.connectionPhase == .live)
        #expect(store.projection == newer)
        #expect(store.draftText == "New connection")
        await store.disconnect()
    }

    @Test("Revocation stays terminal when a snapshot finishes late")
    func snapshotAfterRevocation() async throws {
        let client = LifecycleRaceClient()
        let cache = LifecycleRaceCache()
        let store = makeStore(client, cache: cache)
        await store.connect()
        let gate = await client.holdSnapshot()
        let request = Task { await store.followUp(runID: .init(rawValue: "run"), text: "Fixture") }
        try #require(await gate.waitForEntry())
        await client.revoke()
        try #require(await eventually { store.connectionPhase == .revoked })
        await gate.release()
        _ = await request.value
        #expect(store.connectionPhase == .revoked)
        #expect(store.session == nil)
        #expect(store.projection == nil)
        #expect(store.draftText.isEmpty)
        #expect(await cache.load() == nil)
        await store.connect()
        #expect(store.connectionPhase == .revoked)
    }

    @Test("Event-cache completion cannot overwrite text typed during persistence")
    func typingDuringEventPersistence() async throws {
        let client = LifecycleRaceClient()
        let cache = LifecycleRaceCache()
        let store = makeStore(client, cache: cache)
        await store.connect()
        let gate = await cache.holdSave()
        await client.publish(changedProjection("Canonical edit"))
        try #require(await gate.waitForEntry())
        store.updateDraft("Keep my newer typing")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.draftText == "Keep my newer typing")
        #expect(store.draftSyncPhase == .locallyModified)
        await store.disconnect()
    }

    @Test("Revocation purges caches after an already-admitted event write finishes")
    func revocationDrainsPersistence() async throws {
        let client = LifecycleRaceClient()
        let cache = LifecycleRaceCache()
        let store = makeStore(client, cache: cache)
        await store.connect()
        let gate = await cache.holdSave()
        await client.publish(changedProjection("Private draft"))
        try #require(await gate.waitForEntry())
        await client.revoke()
        try #require(await eventually { store.connectionPhase == .revoked })
        await gate.release()
        try #require(await eventually { await cache.load() == nil })
        #expect(store.connectionPhase == .revoked)
        #expect(store.projection == nil)
        #expect(store.draftText.isEmpty)
    }

    @Test("A cancelled startup draft-cache read cannot restore data after disconnect")
    func startupCacheAfterDisconnect() async throws {
        let client = LifecycleRaceClient()
        let cache = LifecycleRaceCache()
        let gate = await cache.holdDraftLoad()
        let store = makeStore(client, cache: cache)
        let startup = Task { await store.connect() }
        try #require(await gate.waitForEntry())
        await store.disconnect()
        await gate.release()
        await startup.value
        #expect(store.connectionPhase == .disconnected)
        #expect(store.draftText.isEmpty)
        #expect(await client.connectionCount == 0)
    }

    @Test("A late startup projection-cache read cannot reopen a stopped session", arguments: [false, true], [false, true])
    func projectionCacheAfterStop(hasCachedProjection: Bool, revoked: Bool) async throws {
        let client = LifecycleRaceClient()
        let cache = LifecycleRaceCache()
        let gate = await cache.holdLoad(hasCachedProjection: hasCachedProjection)
        let store = makeStore(client, cache: cache)
        let startup = Task { await store.connect() }
        try #require(await gate.waitForEntry())
        if revoked {
            await client.revoke()
            try #require(await eventually { store.connectionPhase == .revoked })
        } else {
            await store.disconnect()
        }
        await gate.release()
        await startup.value
        #expect(store.connectionPhase == (revoked ? .revoked : .disconnected))
        #expect(store.projection == nil)
        #expect(store.draftText.isEmpty)
        #expect(await client.connectionCount == 0)
    }

    @Test("Reconnect waits for an older transport disconnect to finish")
    func reconnectDrainsDisconnect() async throws {
        let client = LifecycleRaceClient()
        let store = makeStore(client)
        await store.connect()
        let gate = await client.holdDisconnect()
        let shutdown = Task { await store.disconnect() }
        try #require(await gate.waitForEntry())
        let startup = Task { await store.connect() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.connectionCount == 1)
        #expect(store.connectionPhase == .connecting)
        await gate.release()
        await shutdown.value
        await startup.value
        #expect(store.connectionPhase == .live)
        #expect(await client.connectionCount == 2)
        await store.disconnect()
    }

    @Test("Explicit reconnect reports connecting while transport teardown drains")
    func reconnectPublishesPendingState() async throws {
        let client = LifecycleRaceClient()
        let store = makeStore(client)
        await store.connect()
        let gate = await client.holdDisconnect()

        let reconnect = Task { await store.reconnect() }
        try #require(await gate.waitForEntry())
        #expect(store.connectionPhase == .connecting)
        #expect(await client.connectionCount == 1)

        await gate.release()
        await reconnect.value
        #expect(store.connectionPhase == .live)
        #expect(await client.connectionCount == 2)
        await store.disconnect()
    }

    @Test("Queued draft saves cannot overwrite an unreviewed remote revision", arguments: [false, true])
    func queuedDraftConflict(replacingConflict: Bool) async throws {
        let client = LifecycleRaceClient()
        let store = makeStore(client)
        await store.connect()
        store.updateDraft("Keep the local edit")
        if replacingConflict {
            await client.publish(changedProjection("First remote edit"))
            try #require(await eventually {
                store.draftSyncPhase == .conflict(canonicalText: "First remote edit")
            })
        }
        let gate = await client.holdSnapshot()
        let preceding = Task { await store.followUp(runID: .init(rawValue: "run"), text: "Fixture") }
        try #require(await gate.waitForEntry())
        let save = Task {
            if replacingConflict { await store.deliberatelyReplaceConflictingDraft() }
            else { await store.flushDraft() }
        }
        // The preceding command remains held by the controllable snapshot gate.
        try await Task.sleep(for: .milliseconds(30))
        let current = try #require(store.projection)
        let newer = current.applying([.draft(.init(
            revision: current.draft.revision.advanced(), text: "Unreviewed remote edit",
            projectIDs: [], agentTargets: [], groupID: nil
        ))], revision: current.revision.advanced(), generatedAt: .now)
        await client.publish(newer)
        try #require(await eventually {
            store.draftSyncPhase == .conflict(canonicalText: "Unreviewed remote edit")
        })
        await gate.release()
        _ = await preceding.value
        await save.value
        #expect(await client.draftSendCount == 0)
        #expect(store.projection?.draft.text == "Unreviewed remote edit")
        #expect(store.draftText == "Keep the local edit")
        #expect(store.draftSyncPhase == .conflict(canonicalText: "Unreviewed remote edit"))
        await store.disconnect()
    }

    private func makeStore(_ client: LifecycleRaceClient, cache: LifecycleRaceCache? = nil) -> ContinuityStore {
        ContinuityStore(client: client, deviceID: .init(rawValue: "race-test"), cache: cache, draftCache: cache)
    }

    private func changedProjection(_ text: String) -> DashboardProjection {
        let original = GADPairedContinuationFixture.projection
        return original.applying([.draft(.init(revision: original.draft.revision.advanced(), text: text,
                                               platform: .iOS, projectIDs: [], agentTargets: [], groupID: nil))],
                                 revision: original.revision.advanced(), generatedAt: .now)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor LifecycleRaceGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func waitForEntry() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor LifecycleRaceClient: GobyClient {
    private var projection = GADPairedContinuationFixture.projection
    private var eventsPair = AsyncStream<GADStateDelta>.makeStream()
    private var lifecyclePair = AsyncStream<GobyClientLifecycleEvent>.makeStream()
    private var snapshotGate: (LifecycleRaceGate, Bool)?
    private var disconnectGate: LifecycleRaceGate?
    private(set) var connectionCount = 0
    private(set) var draftSendCount = 0
    func connect() async throws -> ClientSession {
        connectionCount += 1
        return .init(hostID: projection.host.id, hostEpoch: .init(rawValue: "same-epoch"),
                     protocolVersion: .current, revision: projection.revision, capabilities: [.activeRunFollowUp])
    }
    func snapshot() async throws -> DashboardProjection {
        let captured = projection
        if let (gate, fails) = snapshotGate {
            snapshotGate = nil
            await gate.suspend()
            if fails { throw GADHostIPCClientError.hostUnavailable("Delayed snapshot failure") }
        }
        return captured
    }
    func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        if case .replaceDraft = command.payload { draftSendCount += 1 }
        return .init(commandID: command.id, disposition: .accepted, revision: projection.revision)
    }
    func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        eventsPair = AsyncStream<GADStateDelta>.makeStream()
        return eventsPair.stream
    }
    func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent> {
        lifecyclePair = AsyncStream<GobyClientLifecycleEvent>.makeStream()
        return lifecyclePair.stream
    }
    func disconnect() async {
        if let gate = disconnectGate { disconnectGate = nil; await gate.suspend() }
    }
    func holdSnapshot(fails: Bool = false) -> LifecycleRaceGate {
        let gate = LifecycleRaceGate(); snapshotGate = (gate, fails); return gate
    }
    func holdDisconnect() -> LifecycleRaceGate {
        let gate = LifecycleRaceGate(); disconnectGate = gate; return gate
    }
    func setProjection(_ projection: DashboardProjection) { self.projection = projection }
    func publish(_ updated: DashboardProjection) {
        projection = updated
        eventsPair.continuation.yield(.init(hostEpoch: .init(rawValue: "same-epoch"), revision: updated.revision,
                                           occurredAt: .now, originatingCommandID: nil, changes: [.draft(updated.draft)]))
    }
    func revoke() { lifecyclePair.continuation.yield(.revoked) }
    func reportIncompatible() { lifecyclePair.continuation.yield(.incompatible) }
}

private actor LifecycleRaceCache: GADProjectionCaching, GADLocalDraftCaching {
    private var projection: DashboardProjection?
    private var draft: String?
    private var saveGate: LifecycleRaceGate?
    private var loadGate: LifecycleRaceGate?
    private var draftLoadGate: LifecycleRaceGate?
    func load() async -> DashboardProjection? {
        let captured = projection
        if let gate = loadGate { loadGate = nil; await gate.suspend() }
        return captured
    }
    func save(_ projection: DashboardProjection) async {
        if let gate = saveGate { saveGate = nil; await gate.suspend() }
        self.projection = projection
    }
    func clear() async { projection = nil }
    func loadLocalDraft() async -> String? {
        if let gate = draftLoadGate { draftLoadGate = nil; await gate.suspend(); return "Old cached draft" }
        return draft
    }
    func saveLocalDraft(_ text: String?) async { draft = text }
    func holdSave() -> LifecycleRaceGate { let gate = LifecycleRaceGate(); saveGate = gate; return gate }
    func holdLoad(hasCachedProjection: Bool) -> LifecycleRaceGate {
        projection = hasCachedProjection ? GADPairedContinuationFixture.projection : nil
        let gate = LifecycleRaceGate(); loadGate = gate; return gate
    }
    func holdDraftLoad() -> LifecycleRaceGate { let gate = LifecycleRaceGate(); draftLoadGate = gate; return gate }
}
