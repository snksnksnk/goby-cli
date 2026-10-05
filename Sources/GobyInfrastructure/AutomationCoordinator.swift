import Foundation
import GobyApplication
import GobyDomain

/// Durable, provider-neutral scheduling for user-created recurring work.
/// The actor serializes claims so one automation can own at most one unfinished occurrence.
public actor AutomationCoordinator: AutomationCoordinating {
    private struct PendingOccurrenceCheckpoint: Sendable {
        let expected: AutomationOccurrence
        let updated: AutomationOccurrence
        let notifyOnSuccess: Bool
    }

    private let repository: any AutomationRepository
    private let automationAuthority: any AutomationExecutionAuthorityProviding
    private let runs: any RunRepository
    private let preparePlan: PrepareRoutingPlanUseCase
    private let stageRun: StageRunUseCase
    private let orchestrator: any RunOrchestrating
    private let notifier: (any AutomationNotifying)?
    private let pollInterval: Duration
    private var timerTask: Task<Void, Never>?
    private var runObservationTask: Task<Void, Never>?
    private var claimedAutomationIDs: Set<AutomationID> = []
    /// A completed provider action must be checkpointed before the next action
    /// can be planned. Transient storage failures stay fail-closed here and are
    /// retried by the scheduler instead of allowing an unrecorded continuation.
    private var pendingActionAdvances: [AutomationOccurrenceID: AutomationOccurrence] = [:]
    /// Terminal and attention states are retried after transient storage
    /// failures. The exact predecessor snapshot prevents a delayed retry from
    /// overwriting a newer user or provider decision.
    private var pendingOccurrenceCheckpoints: [AutomationOccurrenceID: PendingOccurrenceCheckpoint] = [:]
    /// Cancellation is monotonic for the lifetime of an occurrence. Keeping an
    /// in-memory claim closes actor-reentrancy windows while a stale planner,
    /// run update, or persistence call is suspended.
    private var cancelledOccurrenceIDs: Set<AutomationOccurrenceID> = []
    private let updateStream: AsyncStream<AutomationSnapshot>
    private let updateContinuation: AsyncStream<AutomationSnapshot>.Continuation

    public init(
        repository: any AutomationRepository & RunRepository & AutomationExecutionAuthorityProviding,
        catalog: any LabCatalogRepository,
        router: any Routing,
        instructions: any InstructionRepository,
        resources: any SharedResourceRepository,
        approvals: any ApprovalChecking,
        orchestrator: any RunOrchestrating,
        notifier: (any AutomationNotifying)? = nil,
        pollInterval: Duration = .seconds(30)
    ) {
        self.repository = repository
        self.automationAuthority = repository
        self.runs = repository
        self.preparePlan = PrepareRoutingPlanUseCase(catalog: catalog, router: router)
        self.stageRun = StageRunUseCase(
            repository: repository,
            catalog: catalog,
            instructions: instructions,
            resources: resources,
            approvals: approvals,
            automationAuthority: repository
        )
        self.orchestrator = orchestrator
        self.notifier = notifier
        self.pollInterval = pollInterval
        let pair = AsyncStream<AutomationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.updateStream = pair.stream
        self.updateContinuation = pair.continuation
    }

    deinit {
        timerTask?.cancel()
        runObservationTask?.cancel()
        updateContinuation.finish()
    }

    public func updates() -> AsyncStream<AutomationSnapshot> {
        updateStream
    }

    public func start() async {
        guard timerTask == nil else { return }
        observeRunsIfNeeded()
        await reconcileInterruptedOccurrences()
        await tick(at: .now)
        let interval = pollInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self?.tick(at: .now)
            }
        }
    }

    public func stop() async {
        timerTask?.cancel()
        runObservationTask?.cancel()
        // Cancellation does not finish a tick suspended in repository I/O.
        // Retain the tasks until drained so a reentrant start cannot create a
        // replacement observer while the previous owner is shutting down.
        await timerTask?.value
        await runObservationTask?.value
        timerTask = nil
        runObservationTask = nil
    }

    public func tick(at date: Date) async {
        observeRunsIfNeeded()
        await retryPendingOccurrenceCheckpoints()
        await retryPendingActionAdvances()
        guard let snapshot = try? await repository.automationSnapshot() else { return }
        for automation in snapshot.definitions where
            automation.state == .active
                && (automation.nextRunAt ?? .distantPast) <= date {
            guard claimedAutomationIDs.insert(automation.id).inserted else { continue }
            defer { claimedAutomationIDs.remove(automation.id) }

            // Actor methods are reentrant at every repository await. Re-read
            // while holding the in-memory claim so Run Now and a timer tick
            // cannot both create an occurrence from the same earlier snapshot.
            guard let current = try? await repository.automationSnapshot(),
                  let currentAutomation = current.definitions.first(where: { $0.id == automation.id }),
                  currentAutomation.state == .active,
                  (currentAutomation.nextRunAt ?? .distantPast) <= date else { continue }
            let hasUnfinishedOccurrence = current.occurrences.contains {
                $0.automationID == automation.id && !$0.status.isFinished
            }
            if hasUnfinishedOccurrence {
                // A long-running occurrence owns this schedule slot. Advance the
                // durable cursor so completion does not trigger an immediate
                // catch-up run and scheduled work can never form a backlog.
                let advanced = copy(
                    currentAutomation,
                    nextRunAt: currentAutomation.schedule.nextDate(after: date),
                    updatedAt: date
                )
                try? await repository.saveAutomation(advanced, replacing: currentAutomation)
                await publishSnapshot()
                continue
            }

            let advanced = copy(
                currentAutomation,
                nextRunAt: currentAutomation.schedule.nextDate(after: date),
                updatedAt: date
            )
            do {
                let occurrence = AutomationOccurrence(
                    automationID: currentAutomation.id,
                    automationName: currentAutomation.name,
                    definitionRevision: currentAutomation.revision,
                    actions: currentAutomation.actions,
                    trigger: .scheduled,
                    scheduledAt: currentAutomation.nextRunAt ?? date,
                    createdAt: date,
                    updatedAt: date
                )
                try await repository.claimAutomationOccurrence(
                    occurrence,
                    advancing: advanced,
                    replacing: currentAutomation
                )
                await publishSnapshot()
                await prepareCurrentAction(in: occurrence, at: date)
            } catch {
                continue
            }
        }
    }

    public func runNow(
        automationID: AutomationID,
        expectedRevision: Int,
        at date: Date = .now
    ) async throws -> AutomationOccurrence {
        observeRunsIfNeeded()
        guard claimedAutomationIDs.insert(automationID).inserted else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(automationID)
        }
        defer { claimedAutomationIDs.remove(automationID) }
        let snapshot = try await repository.automationSnapshot()
        guard let automation = snapshot.definitions.first(where: { $0.id == automationID }) else {
            throw GobyApplicationError.unknownAutomation(automationID)
        }
        guard automation.revision == expectedRevision else {
            throw GobyApplicationError.invalidAutomation(
                "This automation changed. Review the refreshed schedule before running it."
            )
        }
        guard !snapshot.occurrences.contains(where: {
            $0.automationID == automationID && !$0.status.isFinished
        }) else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(automationID)
        }
        let occurrence = AutomationOccurrence(
            automationID: automation.id,
            automationName: automation.name,
            definitionRevision: automation.revision,
            actions: automation.actions,
            trigger: .manual,
            scheduledAt: date,
            createdAt: date,
            updatedAt: date
        )
        try await repository.claimAutomationOccurrence(
            occurrence,
            advancing: automation,
            replacing: automation
        )
        await publishSnapshot()
        await prepareCurrentAction(in: occurrence, at: date)
        let refreshed = try await repository.automationSnapshot()
        return refreshed.occurrences.first(where: { $0.id == occurrence.id }) ?? occurrence
    }

    public func reviewAndRun(
        occurrenceID: AutomationOccurrenceID,
        reviewBinding: AutomationReviewBinding,
        receipt: ApprovalReceipt?,
        selectedResourceIDs: Set<SharedResourceID> = []
    ) async throws {
        guard !isCancellationClaimed(occurrenceID) else {
            throw GobyApplicationError.automationOccurrenceNotReviewable(occurrenceID)
        }
        let snapshot = try await repository.automationSnapshot()
        guard !isCancellationClaimed(occurrenceID) else {
            throw GobyApplicationError.automationOccurrenceNotReviewable(occurrenceID)
        }
        guard let occurrence = snapshot.occurrences.first(where: { $0.id == occurrenceID }) else {
            throw GobyApplicationError.unknownAutomationOccurrence(occurrenceID)
        }
        guard occurrence.actions.indices.contains(occurrence.currentActionIndex),
              let attemptIndex = occurrence.attempts.firstIndex(where: {
                  $0.actionID == occurrence.actions[occurrence.currentActionIndex].id
                      && $0.status == .waitingForReview
              }),
              let plan = occurrence.attempts[attemptIndex].plan else {
            throw GobyApplicationError.automationOccurrenceNotReviewable(occurrenceID)
        }

        guard occurrence.currentReviewBinding == reviewBinding else {
            throw GobyApplicationError.automationOccurrenceNotReviewable(occurrenceID)
        }

        let automaticRuntimeApproval = snapshot.definitions.contains {
            $0.id == occurrence.automationID
                && $0.revision == occurrence.definitionRevision
                && $0.actions == occurrence.actions
                && $0.automaticallyApproveRuntimeRequests
        } && Self.automaticPlanReceipt(for: occurrence.actions[occurrence.currentActionIndex], plan: plan) != nil

        let run = try await stageRun(
            plan: plan,
            receipt: receipt,
            selectedResourceIDs: selectedResourceIDs,
            requiredAutomationAuthorityDigest: try await automationAuthority
                .automationExecutionAuthorityDigest(),
            automaticallyApproveRuntimeRequests: automaticRuntimeApproval
        )
        guard !isCancellationClaimed(occurrenceID) else {
            try? await orchestrator.cancel(runID: run.id)
            throw GobyApplicationError.automationOccurrenceNotReviewable(occurrenceID)
        }
        var attempts = occurrence.attempts
        attempts[attemptIndex] = AutomationActionAttempt(
            actionID: attempts[attemptIndex].actionID,
            plan: plan,
            runID: run.id,
            status: .running,
            updatedAt: .now
        )
        let running = copy(
            occurrence,
            status: .running,
            attempts: attempts,
            message: nil,
            updatedAt: .now
        )
        do {
            try await repository.saveAutomationOccurrence(running, replacing: occurrence)
        } catch {
            // Staging created a provider run, but it is not authorized to
            // execute until the automation checkpoint is durable.
            try? await orchestrator.cancel(runID: run.id)
            throw error
        }
        guard !isCancellationClaimed(occurrenceID) else {
            try? await orchestrator.cancel(runID: run.id)
            return
        }
        await publishSnapshot()
        guard !isCancellationClaimed(occurrenceID) else {
            try? await orchestrator.cancel(runID: run.id)
            return
        }
        execute(runID: run.id, occurrenceID: occurrence.id)
    }

    public func cancel(occurrenceID: AutomationOccurrenceID) async throws {
        cancelledOccurrenceIDs.insert(occurrenceID)
        pendingActionAdvances.removeValue(forKey: occurrenceID)
        pendingOccurrenceCheckpoints.removeValue(forKey: occurrenceID)
        let snapshot = try await repository.automationSnapshot()
        guard let occurrence = snapshot.occurrences.first(where: { $0.id == occurrenceID }) else {
            throw GobyApplicationError.unknownAutomationOccurrence(occurrenceID)
        }
        if occurrence.status.isFinished { return }
        let runID = occurrence.attempts.last?.runID
        let attempts = occurrence.attempts.map { attempt in
            guard ![.completed, .failed, .cancelled].contains(attempt.status) else { return attempt }
            return AutomationActionAttempt(
                actionID: attempt.actionID,
                plan: attempt.plan,
                runID: attempt.runID,
                status: .cancelled,
                message: "Cancelled by user",
                updatedAt: .now
            )
        }
        try await repository.saveAutomationOccurrence(
            copy(
                occurrence,
                status: .cancelled,
                attempts: attempts,
                message: "Cancelled by user",
                updatedAt: .now
            ),
            replacing: occurrence
        )
        if let runID {
            try? await orchestrator.cancel(runID: runID)
        }
        await publishSnapshot()
    }

    private func prepareCurrentAction(
        in occurrence: AutomationOccurrence,
        at date: Date
    ) async {
        guard !isCancellationClaimed(occurrence.id) else { return }
        guard occurrence.actions.indices.contains(occurrence.currentActionIndex) else {
            await finish(occurrence, status: .completed, message: "All actions completed.", at: date)
            return
        }
        let action = occurrence.actions[occurrence.currentActionIndex]
        do {
            let authorityDigest = try await automationAuthority
                .automationExecutionAuthorityDigest()
            let plan = try await preparePlan(action.target.routeRequest(for: action.instruction))
            let snapshot = try await repository.automationSnapshot()
            let automaticRuntimeApproval = snapshot.definitions.contains {
                $0.id == occurrence.automationID
                    && $0.revision == occurrence.definitionRevision
                    && $0.actions == occurrence.actions
                    && $0.automaticallyApproveRuntimeRequests
            }
            guard !isCancellationClaimed(occurrence.id) else { return }
            let automaticPlanReceipt = automaticRuntimeApproval
                ? Self.automaticPlanReceipt(for: action, plan: plan)
                : nil
            if (plan.canStartAutomatically && !automaticRuntimeApproval) || automaticPlanReceipt != nil {
                let run = try await stageRun(
                    plan: plan,
                    receipt: automaticPlanReceipt,
                    requiredAutomationAuthorityDigest: authorityDigest,
                    automaticallyApproveRuntimeRequests: automaticRuntimeApproval
                )
                if automaticPlanReceipt != nil {
                    let latest = try await repository.automationSnapshot()
                    guard latest.definitions.contains(where: {
                        $0.id == occurrence.automationID
                            && $0.revision == occurrence.definitionRevision
                            && $0.actions == occurrence.actions
                            && $0.automaticallyApproveRuntimeRequests
                    }) else {
                        try? await orchestrator.cancel(runID: run.id)
                        throw GobyApplicationError.automationChanged(occurrence.automationID)
                    }
                }
                guard !isCancellationClaimed(occurrence.id) else {
                    try? await orchestrator.cancel(runID: run.id)
                    return
                }
                let attempt = AutomationActionAttempt(
                    actionID: action.id,
                    plan: plan,
                    runID: run.id,
                    status: .running,
                    updatedAt: date
                )
                let running = copy(
                    occurrence,
                    status: .running,
                    attempts: replacingAttempt(attempt, in: occurrence.attempts),
                    message: nil,
                    updatedAt: date
                )
                do {
                    try await repository.saveAutomationOccurrence(running, replacing: occurrence)
                } catch {
                    // Never execute a staged provider run without first
                    // persisting the occurrence-to-run relationship.
                    try? await orchestrator.cancel(runID: run.id)
                    throw error
                }
                guard !isCancellationClaimed(occurrence.id) else {
                    try? await orchestrator.cancel(runID: run.id)
                    return
                }
                await publishSnapshot()
                guard !isCancellationClaimed(occurrence.id) else {
                    try? await orchestrator.cancel(runID: run.id)
                    return
                }
                execute(runID: run.id, occurrenceID: occurrence.id)
            } else {
                let attempt = AutomationActionAttempt(
                    actionID: action.id,
                    plan: plan,
                    status: .waitingForReview,
                    message: reviewReason(for: plan),
                    updatedAt: date
                )
                let waiting = copy(
                    occurrence,
                    status: .needsAttention,
                    attempts: replacingAttempt(attempt, in: occurrence.attempts),
                    message: reviewReason(for: plan),
                    updatedAt: date
                )
                try await repository.saveAutomationOccurrence(waiting, replacing: occurrence)
                guard !isCancellationClaimed(occurrence.id) else { return }
                await publishSnapshot()
                await notifier?.notify(for: waiting)
            }
        } catch {
            guard !isCancellationClaimed(occurrence.id) else { return }
            let attempt = AutomationActionAttempt(
                actionID: action.id,
                status: .needsAttention,
                message: error.localizedDescription,
                updatedAt: date
            )
            let waiting = copy(
                occurrence,
                status: .needsAttention,
                attempts: replacingAttempt(attempt, in: occurrence.attempts),
                message: error.localizedDescription,
                updatedAt: date
            )
            await saveRecoverableCheckpoint(
                waiting,
                replacing: occurrence,
                notifyOnSuccess: true
            )
        }
    }

    private func execute(runID: RunID, occurrenceID: AutomationOccurrenceID) {
        Task { [weak self] in
            await self?.executeIfCurrent(runID: runID, occurrenceID: occurrenceID)
        }
    }

    private func executeIfCurrent(
        runID: RunID,
        occurrenceID: AutomationOccurrenceID
    ) async {
        guard !isCancellationClaimed(occurrenceID) else {
            try? await orchestrator.cancel(runID: runID)
            return
        }
        guard let snapshot = try? await repository.automationSnapshot(),
              let occurrence = snapshot.occurrences.first(where: { $0.id == occurrenceID }),
              occurrence.status == .running,
              occurrence.attempts.contains(where: {
                  $0.runID == runID && $0.status == .running
              }) else {
            try? await orchestrator.cancel(runID: runID)
            return
        }
        do {
            try await orchestrator.execute(runID: runID)
        } catch {
            await executionFailed(
                occurrenceID: occurrenceID,
                runID: runID,
                message: error.localizedDescription
            )
        }
    }

    private func observeRunsIfNeeded() {
        guard runObservationTask == nil else { return }
        runObservationTask = Task { [weak self, orchestrator] in
            let updates = await orchestrator.updates()
            for await run in updates {
                await self?.handle(run)
            }
        }
    }

    private func handle(_ run: RunRecord) async {
        guard [.running, .completed, .failed, .cancelled, .needsAttention].contains(run.status),
              let snapshot = try? await repository.automationSnapshot(),
              let occurrence = snapshot.occurrences.first(where: { occurrence in
                  occurrence.attempts.contains { $0.runID == run.id }
              }),
              let attemptIndex = occurrence.attempts.firstIndex(where: { $0.runID == run.id }),
              [.running, .needsAttention].contains(occurrence.attempts[attemptIndex].status),
              !isCancellationClaimed(occurrence.id) else { return }

        var attempts = occurrence.attempts
        switch run.status {
        case .running:
            guard occurrence.attempts[attemptIndex].status == .needsAttention
                    || occurrence.status == .needsAttention else { return }
            attempts[attemptIndex] = copy(
                attempts[attemptIndex],
                status: .running,
                message: nil,
                updatedAt: run.updatedAt
            )
            try? await repository.saveAutomationOccurrence(
                copy(
                    occurrence,
                    status: .running,
                    attempts: attempts,
                    message: nil,
                    updatedAt: run.updatedAt
                ),
                replacing: occurrence
            )
            await publishSnapshot()
        case .completed:
            attempts[attemptIndex] = AutomationActionAttempt(
                actionID: attempts[attemptIndex].actionID,
                plan: attempts[attemptIndex].plan,
                runID: run.id,
                status: .completed,
                message: run.outcome,
                updatedAt: run.updatedAt
            )
            let nextIndex = occurrence.currentActionIndex + 1
            if occurrence.actions.indices.contains(nextIndex) {
                let advanced = copy(
                    occurrence,
                    status: .queued,
                    currentActionIndex: nextIndex,
                    attempts: attempts,
                    message: nil,
                    updatedAt: run.updatedAt
                )
                do {
                    try await repository.saveAutomationOccurrence(advanced, replacing: occurrence)
                    pendingActionAdvances.removeValue(forKey: occurrence.id)
                } catch {
                    // The verified source run remains available, but the next
                    // action cannot start until this transition is durable.
                    pendingActionAdvances[occurrence.id] = advanced
                    return
                }
                guard !isCancellationClaimed(occurrence.id) else { return }
                await publishSnapshot()
                guard !isCancellationClaimed(occurrence.id) else { return }
                await prepareCurrentAction(in: advanced, at: run.updatedAt)
            } else {
                await finish(
                    copy(
                        occurrence,
                        currentActionIndex: nextIndex,
                        attempts: attempts,
                        updatedAt: run.updatedAt
                    ),
                    replacing: occurrence,
                    status: .completed,
                    message: "All actions completed.",
                    at: run.updatedAt
                )
            }
        case .failed:
            attempts[attemptIndex] = copy(
                attempts[attemptIndex],
                status: .failed,
                message: run.outcome ?? "The action failed.",
                updatedAt: run.updatedAt
            )
            await finish(
                copy(occurrence, attempts: attempts),
                replacing: occurrence,
                status: .failed,
                message: run.outcome ?? "The action failed.",
                at: run.updatedAt
            )
        case .cancelled:
            attempts[attemptIndex] = copy(
                attempts[attemptIndex],
                status: .cancelled,
                message: "The run was cancelled.",
                updatedAt: run.updatedAt
            )
            await finish(
                copy(occurrence, attempts: attempts),
                replacing: occurrence,
                status: .cancelled,
                message: "The run was cancelled.",
                at: run.updatedAt
            )
        case .needsAttention:
            attempts[attemptIndex] = copy(
                attempts[attemptIndex],
                status: .needsAttention,
                message: run.outcome ?? "The run needs attention.",
                updatedAt: run.updatedAt
            )
            await finish(
                copy(occurrence, attempts: attempts),
                replacing: occurrence,
                status: .needsAttention,
                message: run.outcome ?? "The run needs attention.",
                at: run.updatedAt
            )
        default:
            break
        }
    }

    private func retryPendingActionAdvances() async {
        let occurrenceIDs = pendingActionAdvances.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for occurrenceID in occurrenceIDs {
            guard let advanced = pendingActionAdvances[occurrenceID] else { continue }
            guard !isCancellationClaimed(occurrenceID) else {
                pendingActionAdvances.removeValue(forKey: occurrenceID)
                continue
            }
            guard let snapshot = try? await repository.automationSnapshot(),
                  let current = snapshot.occurrences.first(where: { $0.id == occurrenceID }),
                  actionAdvance(advanced, stillAppliesTo: current) else {
                pendingActionAdvances.removeValue(forKey: occurrenceID)
                continue
            }
            do {
                try await repository.saveAutomationOccurrence(advanced, replacing: current)
            } catch {
                continue
            }
            pendingActionAdvances.removeValue(forKey: occurrenceID)
            guard !isCancellationClaimed(occurrenceID) else { continue }
            await publishSnapshot()
            guard !isCancellationClaimed(occurrenceID) else { continue }
            await prepareCurrentAction(in: advanced, at: .now)
        }
    }

    private func retryPendingOccurrenceCheckpoints() async {
        let occurrenceIDs = pendingOccurrenceCheckpoints.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for occurrenceID in occurrenceIDs {
            guard let checkpoint = pendingOccurrenceCheckpoints[occurrenceID] else { continue }
            guard !isCancellationClaimed(occurrenceID),
                  let snapshot = try? await repository.automationSnapshot(),
                  let current = snapshot.occurrences.first(where: { $0.id == occurrenceID }),
                  current == checkpoint.expected else {
                pendingOccurrenceCheckpoints.removeValue(forKey: occurrenceID)
                continue
            }
            do {
                try await repository.saveAutomationOccurrence(checkpoint.updated, replacing: current)
            } catch {
                continue
            }
            pendingOccurrenceCheckpoints.removeValue(forKey: occurrenceID)
            await publishSnapshot()
            if checkpoint.notifyOnSuccess {
                await notifier?.notify(for: checkpoint.updated)
            }
        }
    }

    private func actionAdvance(
        _ advanced: AutomationOccurrence,
        stillAppliesTo current: AutomationOccurrence
    ) -> Bool {
        guard current.definitionRevision == advanced.definitionRevision,
              [.running, .needsAttention].contains(current.status),
              current.currentActionIndex + 1 == advanced.currentActionIndex,
              advanced.actions.indices.contains(current.currentActionIndex) else {
            return false
        }
        let completedActionID = advanced.actions[current.currentActionIndex].id
        guard let completedAttempt = advanced.attempts.first(where: {
            $0.actionID == completedActionID && $0.status == .completed
        }),
        let currentAttempt = current.attempts.first(where: {
            $0.actionID == completedActionID && $0.runID == completedAttempt.runID
        }) else {
            return false
        }
        return [.running, .needsAttention].contains(currentAttempt.status)
    }

    private func executionFailed(
        occurrenceID: AutomationOccurrenceID,
        runID: RunID,
        message: String
    ) async {
        guard !isCancellationClaimed(occurrenceID),
              let snapshot = try? await repository.automationSnapshot(),
              let occurrence = snapshot.occurrences.first(where: { $0.id == occurrenceID }),
              let attemptIndex = occurrence.attempts.firstIndex(where: { $0.runID == runID }),
              occurrence.attempts[attemptIndex].status == .running else { return }
        var attempts = occurrence.attempts
        attempts[attemptIndex] = copy(
            attempts[attemptIndex],
            status: .failed,
            message: message,
            updatedAt: .now
        )
        await finish(
            copy(occurrence, attempts: attempts),
            replacing: occurrence,
            status: .failed,
            message: message,
            at: .now
        )
    }

    private func reconcileInterruptedOccurrences() async {
        guard let snapshot = try? await repository.automationSnapshot() else { return }
        for occurrence in snapshot.occurrences where occurrence.status == .queued {
            // Queued is a durable pre-stage checkpoint. A process exit between
            // persisting the occurrence and staging its next provider run must
            // never silently replay work on launch.
            await finish(
                occurrence,
                status: .needsAttention,
                message: "Goby restarted before this action was staged. Cancel this occurrence, then run the automation again when ready.",
                at: .now,
                notifyOnSuccess: true
            )
        }
        for occurrence in snapshot.occurrences where occurrence.status == .running {
            guard let runID = occurrence.attempts.last?.runID else {
                await finish(
                    occurrence,
                    status: .needsAttention,
                    message: "Goby restarted before this action was staged. Review it before continuing.",
                    at: .now,
                    notifyOnSuccess: true
                )
                continue
            }
            // The run recovery path publishes the authoritative terminal state.
            // Leave genuinely active runs alone and flag missing records rather than replaying work.
            if let run = try? await runs.allRuns().first(where: { $0.id == runID }) {
                await handle(run)
            } else {
                await finish(
                    occurrence,
                    status: .needsAttention,
                    message: "The linked run could not be recovered. Goby did not replay the action.",
                    at: .now,
                    notifyOnSuccess: true
                )
            }
        }
        await publishSnapshot()
    }

    private func finish(
        _ occurrence: AutomationOccurrence,
        replacing expected: AutomationOccurrence? = nil,
        status: AutomationOccurrenceStatus,
        message: String,
        at date: Date,
        notifyOnSuccess: Bool = false
    ) async {
        guard !isCancellationClaimed(occurrence.id) || status == .cancelled else { return }
        let updated = copy(
            occurrence,
            status: status,
            message: message,
            updatedAt: date
        )
        await saveRecoverableCheckpoint(
            updated,
            replacing: expected ?? occurrence,
            notifyOnSuccess: notifyOnSuccess
        )
    }

    private func saveRecoverableCheckpoint(
        _ updated: AutomationOccurrence,
        replacing expected: AutomationOccurrence,
        notifyOnSuccess: Bool = false
    ) async {
        do {
            try await repository.saveAutomationOccurrence(updated, replacing: expected)
            pendingOccurrenceCheckpoints.removeValue(forKey: updated.id)
            await publishSnapshot()
            if notifyOnSuccess {
                await notifier?.notify(for: updated)
            }
        } catch {
            pendingOccurrenceCheckpoints[updated.id] = PendingOccurrenceCheckpoint(
                expected: expected,
                updated: updated,
                notifyOnSuccess: notifyOnSuccess
            )
        }
    }

    private func isCancellationClaimed(_ occurrenceID: AutomationOccurrenceID) -> Bool {
        cancelledOccurrenceIDs.contains(occurrenceID)
    }

    private func publishSnapshot() async {
        if let snapshot = try? await repository.automationSnapshot() {
            updateContinuation.yield(snapshot)
        }
    }

    private func replacingAttempt(
        _ attempt: AutomationActionAttempt,
        in attempts: [AutomationActionAttempt]
    ) -> [AutomationActionAttempt] {
        var updated = attempts.filter { $0.actionID != attempt.actionID }
        updated.append(attempt)
        return updated
    }

    private func reviewReason(for plan: RoutingPlan) -> String {
        if plan.requiresApproval {
            return "Review the disclosed scope and approve this action before it runs."
        }
        if !plan.warnings.isEmpty {
            return plan.warnings.joined(separator: " ")
        }
        return "Review this action before it runs because routing confidence is limited."
    }

    /// The saved automation grant covers the exact action's routed plan,
    /// regardless of the plan's approval count or Git operation kinds.
    /// Changed provider, project, agent target or instruction is never covered.
    static func automaticPlanReceipt(
        for action: AutomationAction,
        plan: RoutingPlan
    ) -> ApprovalReceipt? {
        guard plan.attachments.isEmpty,
              plan.interpretedGoal == action.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
              plan.routes.count == 1,
              let route = plan.routes.first,
              route.providerID == .codex,
              route.providerID == action.target.providerID,
              route.projectID == action.target.projectID,
              !route.agentIDs.isEmpty,
              action.target.agentID.map({ route.agentIDs == [$0] }) ?? true,
              plan.gitOperations.allSatisfy({ $0.projectID == route.projectID }) else { return nil }
        return ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(plan.gitOperations.map(\.id))
        )
    }

    private func copy(
        _ automation: AutomationDefinition,
        nextRunAt: Date?,
        updatedAt: Date
    ) -> AutomationDefinition {
        AutomationDefinition(
            id: automation.id,
            name: automation.name,
            schedule: automation.schedule,
            actions: automation.actions,
            state: automation.state,
            automaticallyApproveRuntimeRequests: automation.automaticallyApproveRuntimeRequests,
            nextRunAt: nextRunAt,
            revision: automation.revision,
            createdAt: automation.createdAt,
            updatedAt: updatedAt
        )
    }

    private func copy(
        _ occurrence: AutomationOccurrence,
        status: AutomationOccurrenceStatus? = nil,
        currentActionIndex: Int? = nil,
        attempts: [AutomationActionAttempt]? = nil,
        message: String? = nil,
        updatedAt: Date? = nil
    ) -> AutomationOccurrence {
        AutomationOccurrence(
            id: occurrence.id,
            automationID: occurrence.automationID,
            automationName: occurrence.automationName,
            definitionRevision: occurrence.definitionRevision,
            actions: occurrence.actions,
            trigger: occurrence.trigger,
            scheduledAt: occurrence.scheduledAt,
            status: status ?? occurrence.status,
            currentActionIndex: currentActionIndex ?? occurrence.currentActionIndex,
            attempts: attempts ?? occurrence.attempts,
            message: message,
            createdAt: occurrence.createdAt,
            updatedAt: updatedAt ?? occurrence.updatedAt
        )
    }

    private func copy(
        _ attempt: AutomationActionAttempt,
        status: AutomationActionStatus,
        message: String?,
        updatedAt: Date
    ) -> AutomationActionAttempt {
        AutomationActionAttempt(
            actionID: attempt.actionID,
            plan: attempt.plan,
            runID: attempt.runID,
            status: status,
            message: message,
            updatedAt: updatedAt
        )
    }
}
