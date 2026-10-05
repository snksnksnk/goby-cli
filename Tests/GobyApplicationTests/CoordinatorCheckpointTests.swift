import Foundation
import GobyApplication
import GobyDomain
import Testing

@Suite("Coordinator checkpoint")
struct CoordinatorCheckpointTests {
    @Test("Accepted command acknowledgement and revision survive owner recreation")
    func acceptedCommandIsNotReplayed() async throws {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let repository = CoordinatorCheckpointMemoryRepository()
        let firstHandler = CountingDraftHandler()
        let first = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: firstHandler,
            persistCheckpoint: { checkpoint in
                await repository.save(checkpoint)
            },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let command = GADCommand(
            id: CommandID(rawValue: "command"),
            idempotencyKey: "draft-1",
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: Date(timeIntervalSince1970: 90),
            expiresAt: Date(timeIntervalSince1970: 200),
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Continue from iPhone",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )

        let accepted = await first.send(command)
        let checkpoint = try #require(await repository.checkpoint)
        #expect(accepted.disposition == .accepted)
        #expect(await firstHandler.applicationCount == 1)

        let replacementHandler = CountingDraftHandler()
        let restored = GADCoordinator(
            hostID: hostID,
            hostEpoch: .make(),
            initialProjection: projection(hostID: hostID),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: replacementHandler,
            restoredCheckpoint: checkpoint,
            persistCheckpoint: { updated in
                await repository.save(updated)
            },
            now: { Date(timeIntervalSince1970: 110) }
        )

        let replay = await restored.send(command)
        let changedBody = GADCommand(
            id: command.id,
            idempotencyKey: command.idempotencyKey,
            hostEpoch: command.hostEpoch,
            deviceID: command.deviceID,
            baseRevision: command.baseRevision,
            issuedAt: command.issuedAt,
            expiresAt: command.expiresAt,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Different body after restart",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )
        let rejectedReuse = await restored.send(changedBody)
        let restoredProjection = await restored.currentProjection()
        #expect(replay == accepted)
        #expect(rejectedReuse.disposition == .rejectedPolicy)
        #expect(await replacementHandler.applicationCount == 0)
        #expect(await restored.hostEpoch == epoch)
        #expect(restoredProjection.draft.text == "Continue from iPhone")
        #expect(restoredProjection.revision == StateRevision(rawValue: 1))
    }

    @Test("A command is not applied when its durable reservation fails")
    func failedReservationDoesNotMutate() async {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let handler = CountingDraftHandler()
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: handler,
            persistCheckpoint: { _ in throw CheckpointTestError.unavailable },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let command = GADCommand(
            idempotencyKey: "draft-1",
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: Date(timeIntervalSince1970: 90),
            expiresAt: Date(timeIntervalSince1970: 200),
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Must not apply",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )

        let acknowledgement = await coordinator.send(command)

        #expect(acknowledgement.disposition == .failedRecoverable)
        #expect(await handler.applicationCount == 0)
        #expect(await coordinator.currentProjection().draft.text.isEmpty)
    }

    @Test("Restored idempotency acknowledgements are redacted before replay")
    func restoredAcknowledgementsAreRedacted() async throws {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let now = Date(timeIntervalSince1970: 100)
        let command = GADCommand(
            idempotencyKey: "restored-error",
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: now.addingTimeInterval(-5),
            expiresAt: now.addingTimeInterval(60),
            payload: .requestApprovalDisclosure("approval")
        )
        let first = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { now }
        )
        _ = await first.send(command)
        let checkpoint = await first.checkpoint()
        let entry = try #require(checkpoint.idempotency.first)
        let unsafeEntry = GADCoordinatorIdempotencyCheckpoint(
            idempotencyKey: entry.idempotencyKey,
            commandID: entry.commandID,
            deviceID: entry.deviceID,
            hostEpoch: entry.hostEpoch,
            baseRevision: entry.baseRevision,
            payloadKind: entry.payloadKind,
            commandDigest: entry.commandDigest,
            acknowledgement: .init(
                commandID: entry.acknowledgement.commandID,
                disposition: entry.acknowledgement.disposition,
                revision: entry.acknowledgement.revision,
                message: "Failed at /Users/alice/Secret/project token=super-secret-token"
            ),
            recordedAt: entry.recordedAt
        )
        let restored = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            restoredCheckpoint: .init(
                hostID: checkpoint.hostID,
                hostEpoch: checkpoint.hostEpoch,
                protocolVersion: checkpoint.protocolVersion,
                projection: checkpoint.projection,
                journal: checkpoint.journal,
                idempotency: [unsafeEntry],
                savedAt: checkpoint.savedAt
            ),
            now: { now }
        )

        let replay = await restored.send(command)

        #expect(replay.message?.contains("/Users/") == false)
        #expect(replay.message?.contains("super-secret-token") == false)
    }

    @Test("Durable idempotency omits command bodies and transient artifacts")
    func durableCheckpointIsDataMinimized() async throws {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let repository = CoordinatorCheckpointMemoryRepository()
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [.activeRunFollowUp, .runtimeApprovalOnce],
            authorizedDevices: [deviceID],
            handler: PrivacyCheckpointHandler(),
            persistCheckpoint: { checkpoint in
                await repository.save(checkpoint)
            },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let followUpSecret = "private-follow-up-body"
        let disclosureSecret = "private-approval-detail"

        _ = await coordinator.send(GADCommand(
            idempotencyKey: "follow-up",
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: Date(timeIntervalSince1970: 90),
            expiresAt: Date(timeIntervalSince1970: 200),
            payload: .followUp(.init(
                runID: RunID(rawValue: "run"),
                text: followUpSecret
            ))
        ))
        let transient = await coordinator.send(GADCommand(
            idempotencyKey: "disclosure",
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: Date(timeIntervalSince1970: 91),
            expiresAt: Date(timeIntervalSince1970: 200),
            payload: .requestApprovalDisclosure("approval")
        ))

        #expect(transient.artifact != nil)
        let checkpoint = try #require(await repository.checkpoint)
        let encoded = try JSONEncoder().encode(checkpoint)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(followUpSecret))
        #expect(!text.contains(disclosureSecret))
        #expect(checkpoint.idempotency.allSatisfy { $0.commandDigest?.count == 64 })
        let disclosure = try #require(checkpoint.idempotency.first {
            $0.idempotencyKey == "disclosure"
        })
        #expect(disclosure.acknowledgement.artifact == nil)
        #expect(disclosure.acknowledgement.disposition == .failedRecoverable)
    }

    @Test("Recent idempotency records are bounded before new work is applied")
    func idempotencyCapacityIsBounded() async throws {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let now = Date(timeIntervalSince1970: 100)
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            journalLimit: 1,
            idempotencyLimit: 2,
            now: { now }
        )

        func command(key: String, payload: GADCommandPayload) -> GADCommand {
            GADCommand(
                id: CommandID(rawValue: key),
                idempotencyKey: key,
                hostEpoch: epoch,
                deviceID: deviceID,
                baseRevision: .zero,
                issuedAt: now.addingTimeInterval(-10),
                expiresAt: now.addingTimeInterval(60),
                payload: payload
            )
        }

        let first = command(key: "unsupported-1", payload: .requestApprovalDisclosure("one"))
        let second = command(key: "unsupported-2", payload: .requestApprovalDisclosure("two"))
        #expect(await coordinator.send(first).disposition == .rejectedCapability)
        #expect(await coordinator.send(second).disposition == .rejectedCapability)

        let valid = command(key: "draft", payload: .replaceDraft(.init(
            expectedRevision: .zero,
            text: "Must not apply while the recent-command ledger is full",
            projectIDs: [],
            agentTargets: [],
            groupID: nil
        )))
        #expect(await coordinator.send(valid).disposition == .rejectedPolicy)
        #expect(await coordinator.currentProjection().draft.text.isEmpty)
        #expect(await coordinator.checkpoint().idempotency.count == 2)
        #expect(await coordinator.send(first).disposition == .rejectedCapability)
    }

    @Test("Concurrent semantic mutations return a retryable conflict")
    func concurrentMutationsAreSerialized() async throws {
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let deviceID = DeviceID(rawValue: "phone")
        let now = Date(timeIntervalSince1970: 100)
        let handler = BlockingDraftHandler()
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection(hostID: hostID),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: handler,
            now: { now }
        )

        func command(key: String, text: String) -> GADCommand {
            GADCommand(
                id: CommandID(rawValue: key),
                idempotencyKey: key,
                hostEpoch: epoch,
                deviceID: deviceID,
                baseRevision: .zero,
                issuedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(60),
                payload: .replaceDraft(.init(
                    expectedRevision: .zero,
                    text: text,
                    projectIDs: [],
                    agentTargets: [],
                    groupID: nil
                ))
            )
        }

        let firstTask = Task { await coordinator.send(command(key: "first", text: "First")) }
        await handler.waitUntilStarted()
        let conflicting = await coordinator.send(command(key: "second", text: "Second"))
        await handler.release()
        let first = await firstTask.value

        #expect(conflicting.disposition == .failedRecoverable)
        #expect(conflicting.wasDeferredBeforeAdmission == true)
        #expect(conflicting.message?.contains("Refresh") == true)
        #expect(first.disposition == .accepted)
        #expect(await handler.applicationCount == 1)
        #expect(await coordinator.currentProjection().draft.text == "First")
    }

    private func projection(hostID: HostID) -> DashboardProjection {
        DashboardProjection(
            generatedAt: Date(timeIntervalSince1970: 1),
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }
}

private actor CountingDraftHandler: GADCommandHandling {
    private(set) var applicationCount = 0

    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        applicationCount += 1
        guard case let .replaceDraft(replacement) = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported test command")
        }
        return GADCommandEffect(changes: [
            .draft(.init(
                revision: projection.draft.revision.advanced(),
                text: replacement.text,
                providerID: replacement.providerID,
                platform: replacement.platform,
                projectIDs: replacement.projectIDs,
                agentTargets: replacement.agentTargets,
                groupID: replacement.groupID
            ))
        ])
    }
}

private actor BlockingDraftHandler: GADCommandHandling {
    private(set) var applicationCount = 0
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect {
        applicationCount += 1
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        guard case let .replaceDraft(replacement) = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported test command")
        }
        return GADCommandEffect(changes: [
            .draft(.init(
                revision: projection.draft.revision.advanced(),
                text: replacement.text,
                providerID: replacement.providerID,
                platform: replacement.platform,
                projectIDs: replacement.projectIDs,
                agentTargets: replacement.agentTargets,
                groupID: replacement.groupID
            ))
        ])
    }
}

private actor CoordinatorCheckpointMemoryRepository {
    private(set) var checkpoint: GADCoordinatorCheckpoint?

    func save(_ checkpoint: GADCoordinatorCheckpoint) {
        self.checkpoint = checkpoint
    }
}

private actor PrivacyCheckpointHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) -> GADCommandEffect {
        switch payload {
        case .followUp:
            GADCommandEffect(artifact: .operationReceipt(.init(
                id: "receipt",
                summary: "Delivered",
                isUndoAvailable: false
            )))
        case .requestApprovalDisclosure:
            GADCommandEffect(artifact: .approvalDisclosure(.init(
                approvalID: "approval",
                summary: "Review required",
                details: "private-approval-detail",
                expiresAt: Date(timeIntervalSince1970: 120)
            )))
        default:
            GADCommandEffect()
        }
    }
}

private enum CheckpointTestError: Error {
    case unavailable
}
