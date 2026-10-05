import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct AutomationCoordinatorTests {
    @Test("Stopping automation coordination waits for a timer tick already in repository I/O", .timeLimit(.minutes(1)))
    func stopDrainsTimerTick() async throws {
        let repository = CoordinatorRepository(snapshot: .empty)
        let coordinator = makeCoordinator(repository: repository, orchestrator: HoldingOrchestrator(), pollInterval: .milliseconds(10))
        await coordinator.start()
        await repository.suspendNextSnapshot()
        for _ in 0..<200 {
            if await repository.isSnapshotSuspended { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await repository.isSnapshotSuspended)
        let probe = CoordinatorStopProbe()
        let stop = Task {
            await coordinator.stop()
            await probe.finish()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.finished == false)
        await repository.releaseSnapshot()
        await stop.value
        #expect(await probe.finished)
        let readCount = await repository.snapshotReadCount
        try await Task.sleep(for: .milliseconds(30))
        #expect(await repository.snapshotReadCount == readCount)
    }

    @Test("A due automation runs each ordered action only after the previous action completes")
    func dueAutomationRunsLinearChain() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "first", instruction: "First read-only action"),
            action(id: "second", instruction: "Second read-only action"),
        ]))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)

        let occurrence = try await waitForOccurrence(in: repository) { $0.status == .completed }
        #expect(occurrence.automationName == "Automation")
        #expect(occurrence.currentActionIndex == 2)
        #expect(occurrence.attempts.map(\.status) == [.completed, .completed])
        #expect(await orchestrator.executedRunIDs().count == 2)
        let refreshed = await repository.automationSnapshot().definitions.first
        #expect(refreshed?.nextRunAt ?? .distantPast > referenceDate)
    }

    @Test("Scheduler carries a reviewed automation runtime grant into its staged run")
    func scheduledRuntimeApprovalGrant() async throws {
        let repository = CoordinatorRepository(automation: automation(
            actions: [action(id: "first", instruction: "Inspect")],
            automaticallyApproveRuntimeRequests: true
        ))
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)

        let run = try #require(await repository.allRuns().first)
        #expect(run.automaticallyApproveRuntimeRequests)
        #expect(run.automationExecutionAuthorityDigest != nil)
        let occurrence = try #require(await repository.automationSnapshot().occurrences.first)
        #expect(occurrence.attempts.first?.runID == run.id)
        try await coordinator.cancel(occurrenceID: occurrence.id)
    }

    @Test("A saved automation grant completes distinct edit prompts with a separate reviewed scope for each")
    func scheduledRoutinePlanGrant() async throws {
        let repository = CoordinatorRepository(automation: automation(
            actions: [
                action(id: "first", instruction: "Improve the approval recovery flow"),
                action(id: "second", instruction: "Improve the automation status flow"),
            ],
            automaticallyApproveRuntimeRequests: true
        ))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(requiresReview: true, routineGit: true)
        )

        await coordinator.tick(at: referenceDate)

        let occurrence = try await waitForOccurrence(in: repository) { $0.status == .completed }
        let runs = await repository.allRuns()
        #expect(occurrence.attempts.count == 2)
        #expect(runs.count == 2)
        #expect(Set(runs.map(\.plan.interpretedGoal)) == Set([
            "Improve the approval recovery flow",
            "Improve the automation status flow",
        ]))
        for run in runs {
            #expect(occurrence.attempts.contains { $0.runID == run.id })
            #expect(run.approvalReceipts.count == 1)
            #expect(run.approvalReceipts.first?.operationIDs == Set(run.plan.gitOperations.map(\.id)))
            #expect(run.automaticallyApproveRuntimeRequests)
        }
    }

    @Test("An all-approval automation grant completes a high-risk plan with a protected Git operation")
    func protectedGitUsesAutomationGrant() async throws {
        let repository = CoordinatorRepository(automation: automation(
            actions: [action(id: "first", instruction: "Improve the project")],
            automaticallyApproveRuntimeRequests: true
        ))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(requiresReview: true, routineGit: true, protectedGit: true, highRisk: true)
        )

        await coordinator.tick(at: referenceDate)

        let occurrence = try await waitForOccurrence(in: repository) { $0.status == .completed }
        let run = try #require(await repository.allRuns().first)
        #expect(occurrence.attempts.first?.runID == run.id)
        #expect(run.plan.risk == .high)
        #expect(run.plan.gitOperations.contains { $0.kind == .push })
        #expect(run.automaticallyApproveRuntimeRequests)
        #expect(run.approvalReceipts.first?.operationIDs == Set(run.plan.gitOperations.map(\.id)))
    }

    @Test("An automatically startable plan outside the saved action cannot receive the broad grant")
    func changedReadOnlyPlanNeedsReview() async throws {
        let repository = CoordinatorRepository(automation: automation(
            actions: [action(id: "first", instruction: "Inspect the project")],
            automaticallyApproveRuntimeRequests: true
        ))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(changesGoal: true)
        )

        await coordinator.tick(at: referenceDate)

        let occurrence = try await waitForOccurrence(in: repository) { $0.status == .needsAttention }
        #expect(occurrence.attempts.first?.status == .waitingForReview)
        #expect(await repository.allRuns().isEmpty)
        #expect(await orchestrator.executedRunIDs().isEmpty)
    }

    @Test("A failed due claim cannot advance the schedule without its occurrence")
    func dueClaimIsAtomicAndRetryable() async throws {
        let original = automation(actions: [
            action(id: "first", instruction: "Run after the durable claim"),
        ])
        let repository = CoordinatorRepository(
            automation: original,
            rejectNextOccurrenceClaim: true
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)

        let afterFailure = await repository.automationSnapshot()
        #expect(afterFailure.definitions == [original])
        #expect(afterFailure.occurrences.isEmpty)
        #expect(await repository.injectedClaimFailureCount() == 1)
        #expect(await orchestrator.executedRunIDs().isEmpty)

        await coordinator.tick(at: referenceDate)

        let completed = try await waitForOccurrence(in: repository) { $0.status == .completed }
        let retriedNextRunAt = await repository.automationSnapshot().definitions.first?.nextRunAt
        #expect(completed.currentActionIndex == 1)
        #expect(retriedNextRunAt ?? .distantPast > referenceDate)
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("A staged run is cancelled when its automation checkpoint cannot be persisted")
    func stagedRunRequiresDurableCheckpoint() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "first", instruction: "Must remain auditable"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .running, actionIndex: 0)
        )
        let orchestrator = HoldingOrchestrator()
        let notifier = RecordingAutomationNotifier()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            notifier: notifier
        )

        await coordinator.tick(at: referenceDate)

        let occurrence = try #require(await repository.automationSnapshot().occurrences.first)
        #expect(occurrence.status == .needsAttention)
        #expect(occurrence.attempts.first?.status == .needsAttention)
        #expect(occurrence.attempts.first?.runID == nil)
        #expect(await repository.injectedFailureCount() == 1)
        #expect(await orchestrator.executedRunIDs().isEmpty)
        #expect(await orchestrator.cancelledRunIDs().count == 1)
        #expect(await notifier.notifications().count == 1)

        await coordinator.tick(at: referenceDate)
        #expect(await notifier.notifications().count == 1)
    }

    @Test("A failed linked-action checkpoint blocks continuation and retries safely")
    func linkedActionAdvanceRequiresDurableCheckpoint() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "first", instruction: "Complete and checkpoint"),
                action(id: "second", instruction: "Start only after the checkpoint"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .queued, actionIndex: 1)
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)
        for _ in 0..<100 {
            if await repository.injectedFailureCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await repository.injectedFailureCount() == 1)
        #expect(await orchestrator.executedRunIDs().count == 1)
        #expect(await repository.automationSnapshot().occurrences.first?.currentActionIndex == 0)

        await coordinator.tick(at: referenceDate)

        let completed = try await waitForOccurrence(in: repository) { $0.status == .completed }
        #expect(completed.currentActionIndex == 2)
        #expect(completed.attempts.map(\.status) == [.completed, .completed])
        #expect(await orchestrator.executedRunIDs().count == 2)
    }

    @Test("A pending action advance never overwrites a newer terminal occurrence")
    func stalePendingAdvanceCannotReviveOccurrence() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "first", instruction: "Complete and checkpoint"),
                action(id: "second", instruction: "Must remain stopped"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .queued, actionIndex: 1)
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)
        for _ in 0..<100 {
            if await repository.injectedFailureCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(await repository.automationSnapshot().occurrences.first)
        try await repository.saveAutomationOccurrence(AutomationOccurrence(
            id: current.id,
            automationID: current.automationID,
            automationName: current.automationName,
            definitionRevision: current.definitionRevision,
            actions: current.actions,
            trigger: current.trigger,
            scheduledAt: current.scheduledAt,
            status: .failed,
            currentActionIndex: current.currentActionIndex,
            attempts: current.attempts,
            message: "A newer terminal decision won.",
            createdAt: current.createdAt,
            updatedAt: .distantFuture
        ), replacing: current)

        await coordinator.tick(at: referenceDate)
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.automationSnapshot().occurrences.first?.status == .failed)
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("A failed terminal checkpoint retries without replaying the provider run")
    func terminalCheckpointRetriesWithoutReplay() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "only", instruction: "Complete exactly once"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .completed, actionIndex: 1)
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)
        for _ in 0..<100 {
            if await repository.injectedFailureCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await repository.injectedFailureCount() == 1)
        #expect(await repository.automationSnapshot().occurrences.first?.status == .running)
        #expect(await orchestrator.executedRunIDs().count == 1)

        await coordinator.tick(at: referenceDate)

        let completed = try await waitForOccurrence(in: repository) { $0.status == .completed }
        #expect(completed.currentActionIndex == 1)
        #expect(completed.attempts.map(\.status) == [.completed])
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("A pending terminal checkpoint never overwrites a newer decision")
    func staleTerminalCheckpointCannotOverwriteOccurrence() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "only", instruction: "Complete exactly once"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .completed, actionIndex: 1)
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)
        for _ in 0..<100 {
            if await repository.injectedFailureCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(await repository.automationSnapshot().occurrences.first)
        try await repository.saveAutomationOccurrence(AutomationOccurrence(
            id: current.id,
            automationID: current.automationID,
            automationName: current.automationName,
            definitionRevision: current.definitionRevision,
            actions: current.actions,
            trigger: current.trigger,
            scheduledAt: current.scheduledAt,
            status: .failed,
            currentActionIndex: current.currentActionIndex,
            attempts: current.attempts,
            message: "A newer decision won.",
            createdAt: current.createdAt,
            updatedAt: .distantFuture
        ), replacing: current)

        await coordinator.tick(at: referenceDate)
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.automationSnapshot().occurrences.first?.status == .failed)
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("A reviewed run is cancelled when its running checkpoint fails")
    func reviewedRunRequiresDurableCheckpoint() async throws {
        let repository = CoordinatorRepository(
            automation: automation(actions: [
                action(id: "review", instruction: "Review before staging"),
            ]),
            rejectedCheckpoint: RejectedOccurrenceCheckpoint(status: .running, actionIndex: 0)
        )
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(requiresReview: true)
        )

        await coordinator.tick(at: referenceDate)
        let waiting = try #require(await repository.automationSnapshot().occurrences.first)
        let plan = try #require(waiting.attempts.first?.plan)

        await #expect(throws: CoordinatorTestError.self) {
            try await coordinator.reviewAndRun(
                occurrenceID: waiting.id,
                reviewBinding: try #require(waiting.currentReviewBinding),
                receipt: ApprovalReceipt(
                    runID: plan.id,
                    decision: .approved,
                    operationIDs: Set(plan.gitOperations.map(\.id))
                )
            )
        }

        #expect(await repository.automationSnapshot().occurrences.first?.status == .needsAttention)
        #expect(await orchestrator.executedRunIDs().isEmpty)
        #expect(await orchestrator.cancelledRunIDs().count == 1)
    }

    @Test("Cancellation remains terminal while the next action is being planned")
    func cancellationWinsOverSuspendedCompletion() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "first", instruction: "Complete before cancellation"),
            action(id: "second", instruction: "Must not start after cancellation"),
        ]))
        let orchestrator = CompletingOrchestrator(repository: repository)
        // Each action reads the catalog once while planning and once while
        // staging. The third read is therefore the second action's planner.
        let catalog = SuspendingCoordinatorCatalog(blockedCall: 3)
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            catalog: catalog
        )

        await coordinator.tick(at: referenceDate)
        for _ in 0..<100 {
            if await catalog.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await catalog.isBlocked)
        let occurrenceID = try #require(
            await repository.automationSnapshot().occurrences.first?.id
        )

        try await coordinator.cancel(occurrenceID: occurrenceID)
        await catalog.release()

        let cancelled = try await waitForOccurrence(in: repository) { $0.status == .cancelled }
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancelled.currentActionIndex == 1)
        #expect(await repository.automationSnapshot().occurrences.first?.status == .cancelled)
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("An uncertain action waits for review instead of starting")
    func uncertainActionWaitsForReview() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "review", instruction: "Needs review"),
        ]))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let notifier = RecordingAutomationNotifier()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(requiresReview: true),
            notifier: notifier
        )

        await coordinator.tick(at: referenceDate)

        let occurrence = try #require(await repository.automationSnapshot().occurrences.first)
        #expect(occurrence.status == .needsAttention)
        #expect(occurrence.attempts.first?.status == .waitingForReview)
        #expect(occurrence.attempts.first?.plan != nil)
        #expect(await orchestrator.executedRunIDs().isEmpty)
        #expect(await notifier.notifications() == [occurrence])
    }

    @Test("A due tick never creates an overlapping occurrence")
    func dueTickRejectsOverlap() async throws {
        let definition = automation(actions: [action(id: "first", instruction: "Inspect")])
        let existing = AutomationOccurrence(
            id: "existing",
            automationID: definition.id,
            definitionRevision: definition.revision,
            actions: definition.actions,
            trigger: .scheduled,
            scheduledAt: referenceDate.addingTimeInterval(-60),
            status: .running
        )
        let repository = CoordinatorRepository(
            snapshot: AutomationSnapshot(definitions: [definition], occurrences: [existing])
        )
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)

        #expect(await repository.automationSnapshot().occurrences == [existing])
        #expect(await orchestrator.executedRunIDs().isEmpty)
        let nextRunAt = await repository.automationSnapshot().definitions.first?.nextRunAt
        #expect(nextRunAt ?? .distantPast > referenceDate)
    }

    @Test("Run Now and a due timer tick cannot claim the same automation concurrently")
    func manualAndScheduledClaimsAreSerialized() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "first", instruction: "Inspect"),
        ]))
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        let manual = Task {
            try? await coordinator.runNow(
                automationID: "automation",
                expectedRevision: 1,
                at: referenceDate
            )
        }
        await coordinator.tick(at: referenceDate)
        _ = await manual.value

        let snapshot = await repository.automationSnapshot()
        #expect(snapshot.occurrences.count == 1)
        #expect(snapshot.occurrences.first?.status == .running)
        try await waitForExecutionCount(1, in: orchestrator)
    }

    @Test("A concurrent user edit wins over a suspended due tick")
    func concurrentDefinitionEditWinsOverDueTick() async throws {
        let original = automation(actions: [
            action(id: "first", instruction: "The stale action must not run"),
        ])
        let repository = CoordinatorRepository(
            automation: original,
            suspendNextDefinitionSave: true
        )
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        let tick = Task { await coordinator.tick(at: referenceDate) }
        for _ in 0..<100 {
            if await repository.isDefinitionSaveBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await repository.isDefinitionSaveBlocked)

        let edited = AutomationDefinition(
            id: original.id,
            name: "Paused by user",
            schedule: original.schedule,
            actions: [action(id: "replacement", instruction: "Run only after a new review")],
            state: .paused,
            nextRunAt: nil,
            revision: original.revision + 1,
            createdAt: original.createdAt,
            updatedAt: referenceDate
        )
        await repository.replaceDefinitionForTest(edited)
        await repository.releaseDefinitionSave()
        await tick.value

        let snapshot = await repository.automationSnapshot()
        #expect(snapshot.definitions == [edited])
        #expect(snapshot.occurrences.isEmpty)
        #expect(await orchestrator.executedRunIDs().isEmpty)
    }

    @Test("Run Now rejects a stale reviewed automation revision without creating work")
    func runNowRejectsStaleRevision() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "first", instruction: "Inspect"),
        ]))
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await #expect(throws: GobyApplicationError.invalidAutomation(
            "This automation changed. Review the refreshed schedule before running it."
        )) {
            try await coordinator.runNow(
                automationID: "automation",
                expectedRevision: 0,
                at: referenceDate
            )
        }

        #expect(await repository.automationSnapshot().occurrences.isEmpty)
        #expect(await orchestrator.executedRunIDs().isEmpty)
    }

    @Test("A queued occurrence found after restart is never replayed")
    func queuedOccurrenceRequiresAttentionAfterRestart() async throws {
        let definition = automation(actions: [action(id: "first", instruction: "Inspect")])
        let interrupted = AutomationOccurrence(
            id: "interrupted",
            automationID: definition.id,
            automationName: definition.name,
            definitionRevision: definition.revision,
            actions: definition.actions,
            trigger: .scheduled,
            scheduledAt: referenceDate.addingTimeInterval(-60)
        )
        let repository = CoordinatorRepository(snapshot: AutomationSnapshot(
            definitions: [definition],
            occurrences: [interrupted]
        ))
        let orchestrator = HoldingOrchestrator()
        let notifier = RecordingAutomationNotifier()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            notifier: notifier
        )

        await coordinator.start()
        let recovered = try #require(
            await repository.automationSnapshot().occurrences.first
        )
        await coordinator.stop()

        #expect(recovered.status == .needsAttention)
        #expect(recovered.message?.contains("did not replay") != true)
        #expect(recovered.message?.contains("run the automation again") == true)
        #expect(await orchestrator.executedRunIDs().isEmpty)
        #expect(await notifier.notifications() == [recovered])
    }

    @Test("A quarantined legacy occurrence ignores a matching late run completion")
    func quarantinedLegacyOccurrenceIgnoresLateRun() async throws {
        let definition = automation(actions: [action(id: "first", instruction: "Must stay stopped")])
        let quarantined = AutomationOccurrence(
            id: "quarantined",
            automationID: definition.id,
            automationName: definition.name,
            definitionRevision: definition.revision,
            actions: definition.actions,
            trigger: .scheduled,
            scheduledAt: referenceDate,
            status: .failed,
            attempts: [AutomationActionAttempt(
                actionID: definition.actions[0].id,
                plan: nil,
                runID: nil,
                status: .failed,
                message: "Authenticity could not be verified."
            )]
        )
        let repository = CoordinatorRepository(snapshot: AutomationSnapshot(
            definitions: [definition],
            occurrences: [quarantined]
        ))
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)
        await coordinator.start()
        let latePlan = RoutingPlan(
            id: "known-active-run",
            interpretedGoal: "Injected continuation",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        await orchestrator.publish(RunRecord(
            id: latePlan.id,
            plan: latePlan,
            status: .completed,
            assignments: [],
            outcome: "Late completion"
        ))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.automationSnapshot().occurrences == [quarantined])
        #expect(await orchestrator.executedRunIDs().isEmpty)
        await coordinator.stop()
    }

    @Test("A failed action stops the ordered chain")
    func failedActionStopsChain() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "first", instruction: "First action fails"),
            action(id: "second", instruction: "This action must not start"),
        ]))
        let orchestrator = CompletingOrchestrator(
            repository: repository,
            terminalStatus: .failed,
            outcome: "Verification failed"
        )
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        await coordinator.tick(at: referenceDate)

        let occurrence = try await waitForOccurrence(in: repository) { $0.status == .failed }
        #expect(occurrence.currentActionIndex == 0)
        #expect(occurrence.attempts.map(\.status) == [.failed])
        #expect(occurrence.message == "Verification failed")
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("Execution authority drift between planning and staging never starts a run")
    func authorityDriftStopsBeforeStaging() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "authority", instruction: "Use only reviewed authority"),
        ]))
        let catalog = SuspendingCoordinatorCatalog(blockedCall: 1)
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            catalog: catalog
        )

        let tick = Task { await coordinator.tick(at: referenceDate) }
        for _ in 0..<100 {
            if await catalog.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await catalog.isBlocked)
        await repository.replaceExecutionAuthorityForTest(Data("changed-authority".utf8))
        await catalog.release()
        await tick.value

        let occurrence = try #require(await repository.automationSnapshot().occurrences.first)
        #expect(occurrence.status == .needsAttention)
        #expect(occurrence.attempts.first?.runID == nil)
        #expect(await repository.allRuns().isEmpty)
        #expect(await orchestrator.executedRunIDs().isEmpty)
    }

    @Test("A reviewed action requires a fresh receipt before it can run")
    func reviewedActionRequiresFreshReceipt() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "review", instruction: "Reviewed action"),
        ]))
        let orchestrator = CompletingOrchestrator(repository: repository)
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            router: CoordinatorRouter(requiresReview: true)
        )

        await coordinator.tick(at: referenceDate)
        let waiting = try #require(await repository.automationSnapshot().occurrences.first)
        let plan = try #require(waiting.attempts.first?.plan)

        // The vulnerable host could mint a current-plan receipt from a stale
        // sheet. A valid B receipt must never rescue an A review binding.
        for staleBinding in [
            AutomationReviewBinding(actionID: "prior-action", planID: "prior-plan"),
            AutomationReviewBinding(actionID: waiting.actions[0].id, planID: "prior-plan"),
        ] {
            await #expect(throws: GobyApplicationError.self) {
                try await coordinator.reviewAndRun(
                    occurrenceID: waiting.id, reviewBinding: staleBinding,
                    receipt: ApprovalReceipt(runID: plan.id, decision: .approved, operationIDs: Set(plan.gitOperations.map(\.id)))
                )
            }
            #expect(await repository.allRuns().isEmpty)
            #expect(await orchestrator.executedRunIDs().isEmpty)
        }

        await #expect(throws: GobyApplicationError.self) {
            try await coordinator.reviewAndRun(occurrenceID: waiting.id, reviewBinding: try #require(waiting.currentReviewBinding), receipt: nil)
        }
        #expect(await orchestrator.executedRunIDs().isEmpty)

        try await coordinator.reviewAndRun(
            occurrenceID: waiting.id,
            reviewBinding: try #require(waiting.currentReviewBinding),
            receipt: ApprovalReceipt(
                runID: plan.id,
                decision: .approved,
                operationIDs: Set(plan.gitOperations.map(\.id))
            )
        )

        let completed = try await waitForOccurrence(in: repository) { $0.status == .completed }
        #expect(completed.attempts.map(\.status) == [.completed])
        #expect(await orchestrator.executedRunIDs().count == 1)
    }

    @Test("A matching low-risk manual review retains its receipt-free path")
    func matchingLowRiskReviewDoesNotRequireReceipt() async throws {
        let action = action(id: "review", instruction: "Read the current state")
        let plan = RoutingPlan(
            id: "read-only-plan",
            interpretedGoal: action.instruction,
            routes: [ProjectRoute(
                projectID: "project",
                providerID: .codex,
                agentIDs: ["agent"],
                reason: "Exact automation target"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let occurrence = AutomationOccurrence(
            id: "manual-review",
            automationID: "automation",
            definitionRevision: 1,
            actions: [action],
            trigger: .manual,
            scheduledAt: referenceDate,
            status: .needsAttention,
            attempts: [.init(actionID: action.id, plan: plan, status: .waitingForReview)],
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
        let repository = CoordinatorRepository(snapshot: .init(occurrences: [occurrence]))
        let orchestrator = HoldingOrchestrator()
        let coordinator = makeCoordinator(repository: repository, orchestrator: orchestrator)

        try await coordinator.reviewAndRun(
            occurrenceID: occurrence.id,
            reviewBinding: try #require(occurrence.currentReviewBinding),
            receipt: nil
        )

        #expect(await repository.allRuns().map(\.id) == [plan.id])
        try await waitForExecutionCount(1, in: orchestrator)
        #expect(await orchestrator.executedRunIDs() == [plan.id])
    }

    @Test("A provider approval resumes the occurrence and continues the ordered chain")
    func runtimeApprovalResumesChain() async throws {
        let repository = CoordinatorRepository(automation: automation(actions: [
            action(id: "approval", instruction: "Action needs a runtime approval"),
            action(id: "after-approval", instruction: "Continue after approval"),
        ]))
        let orchestrator = AttentionThenCompletionOrchestrator(repository: repository)
        let notifier = RecordingAutomationNotifier()
        let coordinator = makeCoordinator(
            repository: repository,
            orchestrator: orchestrator,
            notifier: notifier
        )

        await coordinator.tick(at: referenceDate)

        let waiting = try await waitForOccurrence(in: repository) { $0.status == .needsAttention }
        #expect(waiting.currentActionIndex == 0)
        #expect(waiting.attempts.map(\.status) == [.needsAttention])
        #expect(await orchestrator.executedRunIDs().count == 1)
        #expect(await notifier.notifications().isEmpty)

        try await orchestrator.approveAndCompleteFirstRun()

        let completed = try await waitForOccurrence(in: repository) { $0.status == .completed }
        #expect(completed.currentActionIndex == 2)
        #expect(completed.attempts.map(\.status) == [.completed, .completed])
        #expect(await orchestrator.executedRunIDs().count == 2)
        #expect(await notifier.notifications().isEmpty)
    }

    private var referenceDate: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func automation(
        actions: [AutomationAction],
        automaticallyApproveRuntimeRequests: Bool = false
    ) -> AutomationDefinition {
        AutomationDefinition(
            id: "automation",
            name: "Automation",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "UTC"
            ),
            actions: actions,
            automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests,
            nextRunAt: referenceDate.addingTimeInterval(-10),
            createdAt: referenceDate.addingTimeInterval(-1_000),
            updatedAt: referenceDate.addingTimeInterval(-1_000)
        )
    }

    private func action(id: AutomationActionID, instruction: String) -> AutomationAction {
        AutomationAction(
            id: id,
            instruction: instruction,
            target: .agent(AgentRouteTarget(
                providerID: .codex,
                agentID: "agent",
                projectID: "project"
            ))
        )
    }

    private func makeCoordinator(
        repository: CoordinatorRepository,
        orchestrator: any RunOrchestrating,
        router: CoordinatorRouter = CoordinatorRouter(),
        catalog: any LabCatalogRepository = CoordinatorCatalog(),
        notifier: (any AutomationNotifying)? = nil,
        pollInterval: Duration = .seconds(60)
    ) -> AutomationCoordinator {
        AutomationCoordinator(
            repository: repository,
            catalog: catalog,
            router: router,
            instructions: repository,
            resources: repository,
            approvals: CoordinatorApprovalPolicy(),
            orchestrator: orchestrator,
            notifier: notifier,
            pollInterval: pollInterval
        )
    }

    private func waitForOccurrence(
        in repository: CoordinatorRepository,
        matching predicate: (AutomationOccurrence) -> Bool
    ) async throws -> AutomationOccurrence {
        for _ in 0..<100 {
            if let occurrence = await repository.automationSnapshot().occurrences.first,
               predicate(occurrence) {
                return occurrence
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CoordinatorTestError.timeout
    }

    private func waitForExecutionCount(
        _ expected: Int,
        in orchestrator: HoldingOrchestrator
    ) async throws {
        for _ in 0..<100 {
            if await orchestrator.executedRunIDs().count == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CoordinatorTestError.timeout
    }
}

private actor HoldingOrchestrator: RunOrchestrating {
    private var executed: [RunID] = []
    private var cancelled: [RunID] = []
    private let stream: AsyncStream<RunRecord>
    private let continuation: AsyncStream<RunRecord>.Continuation

    init() {
        let pair = AsyncStream<RunRecord>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func execute(runID: RunID) { executed.append(runID) }
    func pause(runID: RunID) {}
    func resume(runID: RunID) {}
    func cancel(runID: RunID) { cancelled.append(runID) }
    func followUp(runID: RunID, text: String) {}
    func respond(to approval: ProviderApprovalRequest, decision: ProviderApprovalDecision) {}
    func pendingApprovals() -> [ProviderApprovalRequest] { [] }
    func updates() -> AsyncStream<RunRecord> { stream }
    func publish(_ run: RunRecord) { continuation.yield(run) }
    func executedRunIDs() -> [RunID] { executed }
    func cancelledRunIDs() -> [RunID] { cancelled }
}

private enum CoordinatorTestError: Error {
    case timeout
    case injectedPersistenceFailure
}

private actor RecordingAutomationNotifier: AutomationNotifying {
    private var values: [AutomationOccurrence] = []

    func notify(for occurrence: AutomationOccurrence) {
        values.append(occurrence)
    }

    func notifications() -> [AutomationOccurrence] {
        values
    }
}

private struct RejectedOccurrenceCheckpoint: Sendable {
    let status: AutomationOccurrenceStatus
    let actionIndex: Int
}

private actor CoordinatorRepository: AutomationRepository, AutomationExecutionAuthorityProviding, RunRepository, InstructionRepository, SharedResourceRepository {
    private var executionAuthorityDigest = Data("coordinator-authority-v1".utf8)
    private var automationValue: AutomationSnapshot
    private var runValues: [RunRecord] = []
    private let rejectedCheckpoint: RejectedOccurrenceCheckpoint?
    private var didRejectCheckpoint = false
    private var shouldSuspendNextDefinitionSave: Bool
    private var definitionSaveContinuation: CheckedContinuation<Void, Never>?
    private var shouldRejectNextOccurrenceClaim: Bool
    private var didRejectOccurrenceClaim = false

    init(
        automation: AutomationDefinition,
        rejectedCheckpoint: RejectedOccurrenceCheckpoint? = nil,
        suspendNextDefinitionSave: Bool = false,
        rejectNextOccurrenceClaim: Bool = false
    ) {
        automationValue = AutomationSnapshot(definitions: [automation])
        self.rejectedCheckpoint = rejectedCheckpoint
        shouldSuspendNextDefinitionSave = suspendNextDefinitionSave
        shouldRejectNextOccurrenceClaim = rejectNextOccurrenceClaim
    }

    init(snapshot: AutomationSnapshot) {
        automationValue = snapshot
        rejectedCheckpoint = nil
        shouldSuspendNextDefinitionSave = false
        shouldRejectNextOccurrenceClaim = false
    }

    private var shouldSuspendNextSnapshot = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private(set) var snapshotReadCount = 0
    var isSnapshotSuspended: Bool { snapshotContinuation != nil }
    func suspendNextSnapshot() { shouldSuspendNextSnapshot = true }
    func releaseSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }
    func automationSnapshot() async -> AutomationSnapshot {
        snapshotReadCount += 1
        if shouldSuspendNextSnapshot {
            shouldSuspendNextSnapshot = false
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        return automationValue
    }
    func automationExecutionAuthorityDigest() -> Data { executionAuthorityDigest }
    func replaceExecutionAuthorityForTest(_ digest: Data) { executionAuthorityDigest = digest }
    func saveAutomation(
        _ automation: AutomationDefinition,
        replacing expected: AutomationDefinition?
    ) async throws {
        if shouldSuspendNextDefinitionSave {
            shouldSuspendNextDefinitionSave = false
            await withCheckedContinuation { continuation in
                definitionSaveContinuation = continuation
            }
        }
        guard automationValue.definitions.first(where: { $0.id == automation.id }) == expected else {
            throw GobyApplicationError.automationChanged(automation.id)
        }
        var definitions = automationValue.definitions.filter { $0.id != automation.id }
        definitions.append(automation)
        automationValue = AutomationSnapshot(
            definitions: definitions,
            occurrences: automationValue.occurrences
        )
    }
    var isDefinitionSaveBlocked: Bool { definitionSaveContinuation != nil }
    func replaceDefinitionForTest(_ definition: AutomationDefinition) {
        automationValue = AutomationSnapshot(
            definitions: [definition],
            occurrences: automationValue.occurrences
        )
    }
    func releaseDefinitionSave() {
        definitionSaveContinuation?.resume()
        definitionSaveContinuation = nil
    }
    func removeAutomation(
        id: AutomationID,
        replacing expected: AutomationDefinition
    ) throws {
        guard automationValue.definitions.first(where: { $0.id == id }) == expected else {
            throw GobyApplicationError.automationChanged(id)
        }
        automationValue = AutomationSnapshot(
            definitions: automationValue.definitions.filter { $0.id != id },
            occurrences: automationValue.occurrences
        )
    }
    func saveAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        replacing expected: AutomationOccurrence?
    ) throws {
        guard automationValue.occurrences.first(where: { $0.id == occurrence.id }) == expected else {
            throw GobyApplicationError.automationOccurrenceChanged(occurrence.id)
        }
        if !didRejectCheckpoint,
           let rejectedCheckpoint,
           occurrence.status == rejectedCheckpoint.status,
           occurrence.currentActionIndex == rejectedCheckpoint.actionIndex {
            didRejectCheckpoint = true
            throw CoordinatorTestError.injectedPersistenceFailure
        }
        var occurrences = automationValue.occurrences.filter { $0.id != occurrence.id }
        occurrences.append(occurrence)
        automationValue = AutomationSnapshot(
            definitions: automationValue.definitions,
            occurrences: occurrences
        )
    }
    func claimAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        advancing automation: AutomationDefinition,
        replacing expectedAutomation: AutomationDefinition
    ) async throws {
        if shouldSuspendNextDefinitionSave {
            shouldSuspendNextDefinitionSave = false
            await withCheckedContinuation { continuation in
                definitionSaveContinuation = continuation
            }
        }
        guard automationValue.definitions.first(where: { $0.id == expectedAutomation.id })
                == expectedAutomation else {
            throw GobyApplicationError.automationChanged(expectedAutomation.id)
        }
        if shouldRejectNextOccurrenceClaim {
            shouldRejectNextOccurrenceClaim = false
            didRejectOccurrenceClaim = true
            throw CoordinatorTestError.injectedPersistenceFailure
        }
        guard !automationValue.occurrences.contains(where: {
            $0.automationID == expectedAutomation.id && !$0.status.isFinished
        }) else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(expectedAutomation.id)
        }
        var definitions = automationValue.definitions.filter { $0.id != automation.id }
        definitions.append(automation)
        var occurrences = automationValue.occurrences
        occurrences.append(occurrence)
        automationValue = AutomationSnapshot(
            definitions: definitions,
            occurrences: occurrences
        )
    }
    func injectedFailureCount() -> Int { didRejectCheckpoint ? 1 : 0 }
    func injectedClaimFailureCount() -> Int { didRejectOccurrenceClaim ? 1 : 0 }
    func allRuns() -> [RunRecord] { runValues }
    func save(_ run: RunRecord) {
        runValues.removeAll { $0.id == run.id }
        runValues.append(run)
    }
    func allInstructionPacks() -> [InstructionPack] { [] }
    func save(_ pack: InstructionPack) {}
    func allResources() -> [SharedResource] { [] }
    func saveResource(_ resource: SharedResource) {}
    func setResourceEnabled(id: SharedResourceID, enabled: Bool) {}
}

private actor CoordinatorCatalog: LabCatalogRepository {
    func snapshot() -> LabSnapshot {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.research],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Research agent",
            capabilities: [.research],
            scope: .project(project.id)
        )
        return LabSnapshot(projects: [project], agents: [agent])
    }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
}

private actor SuspendingCoordinatorCatalog: LabCatalogRepository {
    private let base = CoordinatorCatalog()
    private let blockedCall: Int
    private var callCount = 0
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedCall: Int) {
        self.blockedCall = blockedCall
    }

    var isBlocked: Bool {
        callCount >= blockedCall && !released
    }

    func snapshot() async -> LabSnapshot {
        callCount += 1
        if callCount == blockedCall && !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return await base.snapshot()
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func register(projects: [LabProject], agents: [AgentProfile]) {}
}

private struct CoordinatorRouter: Routing {
    var requiresReview = false
    var routineGit = false
    var protectedGit = false
    var highRisk = false
    var changesGoal = false

    func plan(for request: RouteRequest, in lab: LabSnapshot) -> RoutingPlan {
        let id = RunID.make()
        return RoutingPlan(
            id: id,
            interpretedGoal: changesGoal ? "\(request.prompt) (changed)" : request.prompt,
            routes: [ProjectRoute(
                projectID: "project",
                providerID: .codex,
                agentIDs: ["agent"],
                reason: "Exact automation target"
            )],
            risk: highRisk ? .high : (requiresReview ? .medium : .readOnly),
            confidence: 1,
            gitOperations: routineGit ? [
                PlannedGitOperation(projectID: "project", kind: .createWorktree),
                PlannedGitOperation(projectID: "project", kind: .createBranch, branch: "codex/goby-\(id.rawValue.prefix(12))"),
                PlannedGitOperation(projectID: "project", kind: .commit),
            ] + (protectedGit ? [PlannedGitOperation(projectID: "project", kind: .push)] : []) : []
        )
    }
}

private struct CoordinatorApprovalPolicy: ApprovalChecking {
    func validate(plan: RoutingPlan, receipt: ApprovalReceipt?) throws {
        if plan.requiresApproval, receipt?.decision != .approved {
            throw GobyApplicationError.approvalRequired
        }
    }
}

private actor CompletingOrchestrator: RunOrchestrating {
    private let repository: CoordinatorRepository
    private let terminalStatus: RunStatus
    private let outcome: String
    private var executed: [RunID] = []
    private let stream: AsyncStream<RunRecord>
    private let continuation: AsyncStream<RunRecord>.Continuation

    init(
        repository: CoordinatorRepository,
        terminalStatus: RunStatus = .completed,
        outcome: String = "Completed"
    ) {
        self.repository = repository
        self.terminalStatus = terminalStatus
        self.outcome = outcome
        let pair = AsyncStream<RunRecord>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func execute(runID: RunID) async throws {
        let stored = try #require(await repository.allRuns().first { $0.id == runID })
        executed.append(runID)
        let completed = RunRecord(
            id: stored.id,
            plan: stored.plan,
            status: terminalStatus,
            assignments: stored.assignments,
            outcome: outcome,
            approvalReceipts: stored.approvalReceipts,
            instructionSnapshot: stored.instructionSnapshot,
            agentSnapshot: stored.agentSnapshot,
            providerBindingSnapshot: stored.providerBindingSnapshot,
            projectSnapshot: stored.projectSnapshot,
            automationExecutionAuthorityDigest: stored.automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: stored.automaticallyApproveRuntimeRequests,
            journal: stored.journal,
            resourceSnapshot: stored.resourceSnapshot,
            createdAt: stored.createdAt,
            updatedAt: .now
        )
        await repository.save(completed)
        continuation.yield(completed)
    }

    func pause(runID: RunID) {}
    func resume(runID: RunID) {}
    func cancel(runID: RunID) {}
    func followUp(runID: RunID, text: String) {}
    func respond(to approval: ProviderApprovalRequest, decision: ProviderApprovalDecision) {}
    func pendingApprovals() -> [ProviderApprovalRequest] { [] }
    func updates() -> AsyncStream<RunRecord> { stream }
    func executedRunIDs() -> [RunID] { executed }
}

private actor AttentionThenCompletionOrchestrator: RunOrchestrating {
    private let repository: CoordinatorRepository
    private var executed: [RunID] = []
    private let stream: AsyncStream<RunRecord>
    private let continuation: AsyncStream<RunRecord>.Continuation

    init(repository: CoordinatorRepository) {
        self.repository = repository
        let pair = AsyncStream<RunRecord>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func execute(runID: RunID) async throws {
        let stored = try #require(await repository.allRuns().first { $0.id == runID })
        executed.append(runID)
        if executed.count == 1 {
            await publish(stored, status: .needsAttention, outcome: "Approve the provider request")
        } else {
            await publish(stored, status: .completed, outcome: "Continued after approval")
        }
    }

    func approveAndCompleteFirstRun() async throws {
        let runID = try #require(executed.first)
        let stored = try #require(await repository.allRuns().first { $0.id == runID })
        await publish(stored, status: .running, outcome: nil)
        await publish(stored, status: .completed, outcome: "Approved action completed")
    }

    func pause(runID: RunID) {}
    func resume(runID: RunID) {}
    func cancel(runID: RunID) {}
    func followUp(runID: RunID, text: String) {}
    func respond(to approval: ProviderApprovalRequest, decision: ProviderApprovalDecision) {}
    func pendingApprovals() -> [ProviderApprovalRequest] { [] }
    func updates() -> AsyncStream<RunRecord> { stream }
    func executedRunIDs() -> [RunID] { executed }

    private func publish(
        _ stored: RunRecord,
        status: RunStatus,
        outcome: String?
    ) async {
        let updated = RunRecord(
            id: stored.id,
            plan: stored.plan,
            status: status,
            assignments: stored.assignments,
            outcome: outcome,
            approvalReceipts: stored.approvalReceipts,
            instructionSnapshot: stored.instructionSnapshot,
            agentSnapshot: stored.agentSnapshot,
            providerBindingSnapshot: stored.providerBindingSnapshot,
            journal: stored.journal,
            resourceSnapshot: stored.resourceSnapshot,
            createdAt: stored.createdAt,
            updatedAt: .now
        )
        await repository.save(updated)
        continuation.yield(updated)
    }
}

private actor CoordinatorStopProbe {
    private(set) var finished = false
    func finish() { finished = true }
}
