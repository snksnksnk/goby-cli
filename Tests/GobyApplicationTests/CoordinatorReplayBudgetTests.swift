import Foundation
import GobyApplication
import GobyDomain
import Testing

@Suite("Coordinator replay budget")
struct CoordinatorReplayBudgetTests {
    private let hostID = HostID(rawValue: "replay-host")
    private let epoch = HostEpoch(rawValue: "replay-epoch")
    private let deviceID = DeviceID(rawValue: "replay-device")

    @Test("Legacy checkpoint decoding bounds replay while preserving canonical state and receipts")
    func legacyReplayIsBounded() throws {
        let canonical = projection(revision: 100)
        let receipt = GADCoordinatorIdempotencyCheckpoint(
            idempotencyKey: "accepted", commandID: .init(rawValue: "accepted"), deviceID: deviceID,
            hostEpoch: epoch, baseRevision: .zero, payloadKind: "replace-draft", commandDigest: "digest",
            acknowledgement: .init(commandID: .init(rawValue: "accepted"), disposition: .accepted,
                                   revision: canonical.revision), recordedAt: .now
        )
        let legacy = GADCoordinatorCheckpoint(
            hostID: hostID, hostEpoch: epoch, protocolVersion: .current, projection: canonical,
            journal: (1...100).map { delta(revision: UInt64($0), size: 32_000) },
            idempotency: [receipt], savedAt: .now
        )
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(GADCoordinatorCheckpoint.self, from: encoder.encode(legacy))
        #expect(decoded.projection == canonical)
        #expect(decoded.hostEpoch == legacy.hostEpoch)
        #expect(decoded.idempotency == [receipt])
        #expect(decoded.savedAt == legacy.savedAt)
        #expect(!decoded.journal.isEmpty)
        #expect(decoded.journal.count < legacy.journal.count)
        #expect(decoded.journal.last?.revision == canonical.revision)
        #expect(try encoder.encode(decoded.journal).count <= GADCoordinatorCheckpoint.maximumReplayJournalBytes)
        #expect(decoded.journal == Array(legacy.journal.suffix(decoded.journal.count)))
    }

    @Test("Live provider replay stays byte-bounded without discarding the canonical projection")
    func liveReplayIsBounded() async throws {
        let coordinator = makeCoordinator()
        for index in 1...75 {
            let update = projection(revision: UInt64(index), text: String(repeating: "x", count: 32_000) + "\(index)")
            await coordinator.synchronize(update)
        }
        let checkpoint = await coordinator.checkpoint()
        #expect(checkpoint.journal.count < 75)
        #expect(checkpoint.projection.draft.text.hasSuffix("75"))
        #expect(checkpoint.journal.last?.revision == checkpoint.projection.revision)
        #expect(try JSONEncoder().encode(checkpoint.journal).count <= GADCoordinatorCheckpoint.maximumReplayJournalBytes)
    }

    @Test("Evicted replay uses a full snapshot for both batch and streaming clients", arguments: [false, true])
    func evictedReplayResynchronizes(oversized: Bool) async throws {
        let coordinator = makeCoordinator(journalLimit: 1)
        await coordinator.synchronize(projection(revision: 1, text: "First"))
        let latest = projection(revision: 2, text: oversized
                                ? String(repeating: "x", count: GADCoordinatorCheckpoint.maximumReplayJournalBytes)
                                : "Second")
        await coordinator.synchronize(latest)
        let checkpoint = await coordinator.checkpoint()
        #expect(checkpoint.journal.isEmpty == oversized)
        let replay = try await coordinator.replay(deviceID: deviceID, after: .zero, maximumCount: 20)
        try #require(replay.count == 1)
        #expect(replay[0].isResyncSnapshot)
        #expect(replay[0].revision == checkpoint.projection.revision)
        let stream = await coordinator.events(deviceID: deviceID, after: .zero)
        var iterator = stream.makeAsyncIterator()
        let streamed = try #require(await iterator.next())
        // Each request creates its own envelope ID around the same snapshot.
        #expect(streamed.isResyncSnapshot)
        #expect(streamed.hostEpoch == replay[0].hostEpoch)
        #expect(streamed.revision == replay[0].revision)
        #expect(streamed.changes == replay[0].changes)
        #expect(try await coordinator.replay(deviceID: deviceID, after: checkpoint.projection.revision,
                                            maximumCount: 20).isEmpty)
    }

    private func makeCoordinator(journalLimit: Int = GADCoordinatorCheckpoint.maximumReplayJournalCount) -> GADCoordinator {
        GADCoordinator(hostID: hostID, hostEpoch: epoch, initialProjection: projection(revision: 0),
                       capabilities: [.sharedDraft], authorizedDevices: [deviceID],
                       handler: ProjectionGADCommandHandler(), journalLimit: journalLimit,
                       now: { Date(timeIntervalSince1970: 100) })
    }

    private func projection(revision: UInt64, text: String = "Canonical draft") -> DashboardProjection {
        DashboardProjection(revision: .init(rawValue: revision), generatedAt: Date(timeIntervalSince1970: 100),
                            host: .init(id: hostID, displayName: "Fixture Mac", reachability: .online,
                                        lastUpdatedAt: Date(timeIntervalSince1970: 100)))
            .applying([.draft(.init(revision: .init(rawValue: revision), text: text))],
                      revision: .init(rawValue: revision), generatedAt: Date(timeIntervalSince1970: 100))
    }

    private func delta(revision: UInt64, size: Int) -> GADStateDelta {
        .init(hostEpoch: epoch, revision: .init(rawValue: revision), occurredAt: Date(timeIntervalSince1970: 100),
              originatingCommandID: nil, changes: [.draft(.init(revision: .init(rawValue: revision),
                                                               text: String(repeating: "x", count: size)))])
    }
}
