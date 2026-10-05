import CryptoKit
import Foundation
import GobyApplication
import GobyDomain

public enum OrchestratorError: LocalizedError, Sendable {
    case runNotFound(RunID)
    case projectNotFound(ProjectID)
    case agentNotFound(AgentID)
    case runNotExecutable(RunStatus)
    case savedPlanNeedsChangeReview
    case unsupportedProvider(AgentProviderID)
    case missingProviderBinding(AgentProviderID, AgentID, ProjectID)
    case activeSteeringUnavailable(AgentProviderID?)
    case providerExecutionFailed(String)
    case indeterminateProviderStart(AgentProviderID, AssignmentID)
    case projectAuthorizationChanged(String)
    case resourceAuthorizationChanged(String)
    case attachmentAuthorizationChanged(String)
    case runAlreadyExecuting(RunID)
    case approvalStillPending(RunID)

    public var errorDescription: String? {
        switch self {
        case let .runNotFound(id): "Run not found: \(id.rawValue)."
        case let .projectNotFound(id): "Project not found: \(id.rawValue)."
        case let .agentNotFound(id): "Agent not found: \(id.rawValue)."
        case let .runNotExecutable(status): "A \(status.displayName.lowercased()) run cannot start."
        case .savedPlanNeedsChangeReview:
            "This saved run was planned read-only, but its request asks for changes. Cancel it and reuse the request to review a new change-making plan."
        case let .unsupportedProvider(providerID):
            "No execution-capable \(providerID.displayName) runtime is registered."
        case let .missingProviderBinding(providerID, agentID, projectID):
            "No configured \(providerID.displayName) binding exists for agent \(agentID.rawValue) in project \(projectID.rawValue)."
        case let .activeSteeringUnavailable(providerID):
            if let providerID {
                "\(providerID.displayName) cannot accept a follow-up for this active run. Pause or cancel remains available."
            } else {
                "No active assignment can accept a follow-up right now."
            }
        case let .providerExecutionFailed(message): message
        case let .indeterminateProviderStart(providerID, assignmentID):
            "\(providerID.displayName) did not confirm whether assignment \(assignmentID.rawValue) started. Goby will not retry it automatically; cancel the run and inspect the isolated working copy before reusing the request."
        case let .projectAuthorizationChanged(name):
            "The registered folder for \(name) changed or needs renewed access. Choose its folder in Projects, then select Refresh Selected before running."
        case let .resourceAuthorizationChanged(name):
            "The shared resource \(name) changed or predates identity-bound authorization. Add it again before running."
        case let .attachmentAuthorizationChanged(name):
            "The attached file \(name) changed after selection. Select it again."
        case .runAlreadyExecuting:
            "This run is already working. Refresh to see its current progress."
        case .approvalStillPending:
            "This run still has an approval waiting for a decision. Respond to it or cancel the run before retrying."
        }
    }
}

public actor ProviderRunOrchestrator: RunOrchestrating {
    private enum AssignmentResult: Sendable {
        case completed(String, evidence: [ProviderCommandExecutionEvidence])
        case failed(String)
        case cancelled
    }

    private struct RecoveredAssignmentContext: Sendable {
        let assignment: AgentAssignment
        let project: LabProject
        let executableProject: LabProject
        let workingDirectory: URL
        let runSnapshot: RunRecord
    }

    private let catalog: any LabCatalogRepository
    private let runs: any RunRepository
    private let runtimes: any AgentRuntimeResolving
    private let workspaces: any WorkspacePreparing
    private let verifier: any VerificationRunning
    private let notifier: (any RunNotifying)?
    private let handoffCatalog: (any HandoffCatalogManaging)?
    private let automationAuthority: (any AutomationExecutionAuthorityProviding)?
    private let rememberedApprovals: (any RememberedCommandApprovalStoring)?
    private let automationRepository: (any AutomationRepository)?
    private var rememberedRulesRevision: UInt64 = 0
    private var rememberedRuleWritesInFlight = Set<ProviderApprovalIdentity>()
    private var rememberedRuleWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumConcurrentAssignments: Int
    private let rateLimitPollInterval: TimeInterval
    private var listeners: [AgentProviderID: Task<Void, Never>] = [:]
    private var cachedRuns: [RunID: RunRecord] = [:]
    private var runByAssignment: [AssignmentID: RunID] = [:]
    private var waiters: [AssignmentID: CheckedContinuation<AssignmentResult, Never>] = [:]
    private var bufferedResults: [AssignmentID: AssignmentResult] = [:]
    private var commandEvidenceByAssignment: [AssignmentID: [ProviderCommandExecutionEvidence]] = [:]
    /// Assignments this process watched from their start. Only for these is
    /// the absence of an approved file edit known rather than assumed.
    private var assignmentsObservedFromStart: Set<AssignmentID> = []
    private var pendingActivity: [RunID: [RunActivityStep]] = [:]
    private var activityFlushTasks: [RunID: Task<Void, Never>] = [:]
    private var assignmentsWithApprovedWrites: Set<AssignmentID> = []
    private var approvalRequests: [ProviderApprovalIdentity: ProviderApprovalRequest] = [:]
    private var approvalResponsesInFlight = Set<ProviderApprovalIdentity>()
    private var executingRuns = Set<RunID>()
    /// Order in which runs began executing. A run waits only for conflicting
    /// runs admitted before it, so two runs can never wait on each other.
    private var admissionOrder: [RunID: Int] = [:]
    private var nextAdmission = 0
    /// Runs the user chose to start despite a conflict (Run Anyway).
    private var conflictWaitOverrides = Set<RunID>()
    private let conflictPollInterval: TimeInterval = 2
    private var modelChangingRuns = Set<RunID>()
    private var retiringRuns = Set<RunID>()
    private var executionStopWaiters: [RunID: [CheckedContinuation<Void, Never>]] = [:]
    private var recoveredRunTasks: [RunID: Task<Void, Never>] = [:]
    private var updateContinuations: [UUID: AsyncStream<RunRecord>.Continuation] = [:]

    public init(
        catalog: any LabCatalogRepository,
        runs: any RunRepository,
        runtimes: any AgentRuntimeResolving,
        workspaces: any WorkspacePreparing,
        verifier: any VerificationRunning,
        notifier: (any RunNotifying)? = nil,
        handoffCatalog: (any HandoffCatalogManaging)? = nil,
        automationAuthority: (any AutomationExecutionAuthorityProviding)? = nil,
        rememberedApprovals: (any RememberedCommandApprovalStoring)? = nil,
        automationRepository: (any AutomationRepository)? = nil,
        maximumConcurrentAssignments: Int = 3,
        rateLimitPollInterval: TimeInterval = 60
    ) {
        self.catalog = catalog
        self.runs = runs
        self.runtimes = runtimes
        self.workspaces = workspaces
        self.verifier = verifier
        self.notifier = notifier
        self.handoffCatalog = handoffCatalog
        self.automationAuthority = automationAuthority
        self.rememberedApprovals = rememberedApprovals
        self.automationRepository = automationRepository
        self.maximumConcurrentAssignments = max(1, maximumConcurrentAssignments)
        self.rateLimitPollInterval = max(0.01, rateLimitPollInterval)
    }

    public init(
        catalog: any LabCatalogRepository,
        runs: any RunRepository,
        codex: any CodexServing,
        workspaces: any WorkspacePreparing,
        verifier: any VerificationRunning,
        notifier: (any RunNotifying)? = nil,
        handoffCatalog: (any HandoffCatalogManaging)? = nil,
        automationAuthority: (any AutomationExecutionAuthorityProviding)? = nil,
        rememberedApprovals: (any RememberedCommandApprovalStoring)? = nil,
        automationRepository: (any AutomationRepository)? = nil,
        maximumConcurrentAssignments: Int = 3,
        rateLimitPollInterval: TimeInterval = 60
    ) {
        self.catalog = catalog
        self.runs = runs
        self.runtimes = AgentRuntimeRegistry(runtimes: [
            CodexAgentRuntimeAdapter(codex: codex),
        ])
        self.workspaces = workspaces
        self.verifier = verifier
        self.notifier = notifier
        self.handoffCatalog = handoffCatalog
        self.automationAuthority = automationAuthority
        self.rememberedApprovals = rememberedApprovals
        self.automationRepository = automationRepository
        self.maximumConcurrentAssignments = max(1, maximumConcurrentAssignments)
        self.rateLimitPollInterval = max(0.01, rateLimitPollInterval)
    }

    public func updates() -> AsyncStream<RunRecord> {
        let subscriberID = UUID()
        let pair = AsyncStream<RunRecord>.makeStream(bufferingPolicy: .bufferingNewest(200))
        updateContinuations[subscriberID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateSubscriber(subscriberID) }
        }
        return pair.stream
    }

    private func removeUpdateSubscriber(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    public func recoverInterruptedRuns() async throws -> [RunRecord] {
        let storedRuns = try await runs.allRuns()
        let interruptedRuns = storedRuns.filter { run in
            run.status == .running
                || (run.status == .needsAttention
                    && run.assignments.contains(where: Self.wasInFlight))
        }
        guard !interruptedRuns.isEmpty else { return [] }
        var recoveredRuns: [RunRecord] = []

        for storedRun in interruptedRuns {
            cachedRuns[storedRun.id] = storedRun
            for assignment in storedRun.assignments {
                runByAssignment[assignment.id] = storedRun.id
            }

            let providerIDs = Set(storedRun.assignments.compactMap { assignment in
                Self.wasInFlight(assignment) ? assignment.providerID : nil
            })
            await ensureListening(to: providerIDs)

            var assignments: [AgentAssignment] = []
            var contexts: [RecoveredAssignmentContext] = []
            var waitingForAttention = false
            let automationAuthorityIsCurrent = await isAutomationAuthorityCurrent(for: storedRun)

            for assignment in storedRun.assignments {
                guard Self.wasInFlight(assignment) else {
                    assignments.append(assignment)
                    continue
                }
                guard automationAuthorityIsCurrent,
                      let project = storedRun.projectSnapshot.first(where: {
                    $0.id == assignment.projectID
                }),
                      let workingDirectory = assignment.workingDirectory,
                      let workingDirectoryIdentity = assignment.workingDirectoryIdentity,
                      workingDirectoryIdentity.kind == .directory,
                      workingDirectoryIdentity.matchesCurrentObject(at: workingDirectory),
                      assignment.providerTaskID != nil,
                      let runtime = await runtimes.runtime(for: assignment.providerID),
                      (await runtime.capabilities()).supports(.resume) else {
                    assignments.append(pausedAfterRelaunch(assignment))
                    waitingForAttention = true
                    continue
                }

                guard Self.hasCurrentIdentity(project),
                      storedRun.resourceSnapshot.allSatisfy(Self.hasCurrentIdentity),
                      assignment.attachments.allSatisfy(Self.hasCurrentIdentity) else {
                    assignments.append(pausedAfterRelaunch(assignment))
                    waitingForAttention = true
                    continue
                }

                let executableProject = LabProject(
                    id: project.id,
                    name: project.name,
                    rootURL: workingDirectory,
                    platforms: project.platforms,
                    frameworks: project.frameworks,
                    testCommands: Self.sandboxCompatibleTestCommands(project.testCommands, runID: storedRun.id),
                    instructionFiles: project.instructionFiles,
                    isGitRepository: project.isGitRepository,
                    registeredAt: project.registeredAt,
                    fileSystemIdentity: workingDirectoryIdentity
                )

                do {
                    guard let recovery = try await runtime.recover(
                        assignment: assignment,
                        project: executableProject,
                        resources: storedRun.resourceSnapshot
                    ), recovery.handle.providerID == assignment.providerID,
                       recovery.handle.taskID == assignment.providerTaskID else {
                        assignments.append(pausedAfterRelaunch(assignment))
                        waitingForAttention = true
                        continue
                    }

                    let recoveredAssignment: AgentAssignment
                    switch recovery.status {
                    case .working, .waitingForInput:
                        recoveredAssignment = copy(
                            assignment,
                            status: .working,
                            currentTask: recovery.message ?? assignment.currentTask,
                            progress: recovery.progress ?? assignment.progress,
                            statusReason: "Reconnected to the existing \(assignment.providerID.displayName) task after relaunch."
                        )
                    case .waitingForApproval:
                        recoveredAssignment = copy(
                            assignment,
                            status: .waitingForApproval,
                            currentTask: recovery.message ?? "Waiting for provider approval",
                            progress: recovery.progress ?? assignment.progress,
                            statusReason: "The recovered \(assignment.providerID.displayName) task still needs approval."
                        )
                        waitingForAttention = true
                    case .completed:
                        recoveredAssignment = copy(
                            assignment,
                            status: .working,
                            currentTask: "Finalizing work completed while Goby was closed",
                            progress: max(assignment.progress ?? 0, 0.85),
                            statusReason: "Recovered the provider's completed task; verification is continuing."
                        )
                        bufferedResults[assignment.id] = .completed(
                            recovery.outcome ?? recovery.message ?? "Provider task completed while Goby was closed.",
                            evidence: recovery.evidence
                        )
                    case .failed:
                        recoveredAssignment = copy(
                            assignment,
                            status: .failed,
                            currentTask: "Failed",
                            progress: assignment.progress,
                            statusReason: recovery.message ?? "The provider reported that the recovered task failed."
                        )
                        waitingForAttention = true
                    case .cancelled:
                        recoveredAssignment = copy(
                            assignment,
                            status: .cancelled,
                            currentTask: "Cancelled",
                            progress: assignment.progress,
                            statusReason: recovery.message ?? "The provider reported that the recovered task was cancelled."
                        )
                        waitingForAttention = true
                    case .saved:
                        recoveredAssignment = pausedAfterRelaunch(assignment)
                        waitingForAttention = true
                    }
                    assignments.append(recoveredAssignment)

                    if [.working, .waitingForApproval, .waitingForInput, .completed].contains(recovery.status) {
                        commandEvidenceByAssignment[assignment.id] = recovery.evidence
                        contexts.append(RecoveredAssignmentContext(
                            assignment: recoveredAssignment,
                            project: project,
                            executableProject: executableProject,
                            workingDirectory: workingDirectory,
                            runSnapshot: storedRun
                        ))
                    }
                } catch {
                    assignments.append(copy(
                        pausedAfterRelaunch(assignment),
                        status: .paused,
                        currentTask: assignment.currentTask,
                        progress: assignment.progress,
                        statusReason: "Goby could not confirm the existing \(assignment.providerID.displayName) task: \(error.localizedDescription)"
                    ))
                    waitingForAttention = true
                }
            }

            let hasReconnectedWork = !contexts.isEmpty
            let status: RunStatus = hasReconnectedWork && !waitingForAttention ? .running : .needsAttention
            let summary: String
            if hasReconnectedWork {
                summary = waitingForAttention
                    ? "Reconnected to surviving provider work. Some assignments still need attention."
                    : "Reconnected to surviving provider work without replaying any instruction."
            } else {
                summary = "No provider confirmed a live task. Interrupted assignments were paused without replaying any instruction."
            }
            let recovered = RunRecord(
                id: storedRun.id,
                plan: storedRun.plan,
                status: status,
                assignments: assignments,
                helperTasks: storedRun.helperTasks,
                outcome: summary,
                approvalReceipts: storedRun.approvalReceipts,
                instructionSnapshot: storedRun.instructionSnapshot,
                agentSnapshot: storedRun.agentSnapshot,
                providerBindingSnapshot: storedRun.providerBindingSnapshot,
                projectSnapshot: storedRun.projectSnapshot,
                automationExecutionAuthorityDigest: storedRun.automationExecutionAuthorityDigest,
                automaticallyApproveRuntimeRequests: storedRun.automaticallyApproveRuntimeRequests,
                journal: RunJournalCompactor.compact(storedRun.journal + [
                    RunJournalEntry(kind: .recovery, message: summary),
                ]),
                resourceSnapshot: storedRun.resourceSnapshot,
                activity: storedRun.activity,
                createdAt: storedRun.createdAt,
                updatedAt: .now
            )
            try await saveAndPublish(recovered)
            recoveredRuns.append(cachedRuns[storedRun.id] ?? recovered)

            if hasReconnectedWork {
                executingRuns.insert(storedRun.id)
                recoveredRunTasks[storedRun.id] = Task { [weak self] in
                    await self?.monitorRecoveredRun(storedRun.id, contexts: contexts)
                }
            }
        }
        return recoveredRuns
    }

    public func pendingApprovals() -> [ProviderApprovalRequest] {
        approvalRequests.values.sorted { $0.routingID < $1.routingID }
    }

    public func execute(runID: RunID) async throws {
        guard !modelChangingRuns.contains(runID) else {
            throw OrchestratorError.runAlreadyExecuting(runID)
        }
        guard executingRuns.insert(runID).inserted else {
            throw OrchestratorError.runAlreadyExecuting(runID)
        }
        nextAdmission += 1
        admissionOrder[runID] = nextAdmission
        defer {
            markExecutionStopped(runID)
            Task { await workspaces.releaseRepositoryLocks(for: runID) }
        }

        let storedRuns = try await runs.allRuns()
        guard var run = storedRuns.first(where: { $0.id == runID }) else {
            throw OrchestratorError.runNotFound(runID)
        }
        guard [.ready, .needsAttention, .failed].contains(run.status) else {
            throw OrchestratorError.runNotExecutable(run.status)
        }
        guard !RouteMutationIntent.needsFreshChangePlan(run.plan) else {
            throw OrchestratorError.savedPlanNeedsChangeReview
        }
        if let assignment = run.assignments.first(where: { $0.hasIndeterminateProviderStart }) {
            throw OrchestratorError.indeterminateProviderStart(
                assignment.providerID,
                assignment.id
            )
        }
        let providerIDs = Set(run.assignments.filter { $0.status != .completed }.map(\.providerID))
        for providerID in providerIDs {
            guard let runtime = await runtimes.runtime(for: providerID),
                  (await runtime.capabilities()).supports(.execution) else {
                for assignment in run.assignments where
                    assignment.providerID == providerID && assignment.status != .completed {
                    await updateHandoff(
                        for: assignment,
                        state: .needsAttention,
                        reason: "No execution-capable \(providerID.displayName) runtime is registered."
                    )
                }
                throw OrchestratorError.unsupportedProvider(providerID)
            }
        }
        cachedRuns[runID] = run

        await ensureListening(to: providerIDs)
        let pipeline = run.plan.deliveryPipeline
        let runnableAssignments = run.assignments.map { assignment in
            if assignment.status == .completed { return assignment }
            // Superseded stage attempts are history, not work to retry.
            if pipeline != nil, DeliveryPipelineSchedule.isSuperseded(assignment, in: run.assignments) {
                return assignment
            }
            return freshAttempt(
                from: assignment,
                reviewedTask: run.plan.interpretedGoal
            )
        }
        run = copy(run, status: .running, assignments: runnableAssignments, outcome: nil)
        try await saveAndPublish(run)
        for assignment in runnableAssignments {
            runByAssignment[assignment.id] = runID
        }

        if let pipeline {
            await executeStages(runID: runID, pipeline: pipeline)
            guard let latest = cachedRuns[runID] else { return }
            if latest.status == .cancelled || latest.status == .needsAttention { return }
            let finalStatus = DeliveryPipelineSchedule.finalStatus(pipeline, assignments: latest.assignments)
            let final = copy(
                latest,
                status: finalStatus,
                assignments: latest.assignments,
                outcome: RunOutcomeSummary.consolidate(
                    DeliveryPipelineSchedule.activeAssignments(latest.assignments)
                ) ?? latest.outcome
            )
            try await saveAndPublish(final)
            await notifier?.notify(for: final)
            return
        }

        let pending = runnableAssignments.filter { $0.status != .completed }
        let projectQueues = Dictionary(grouping: pending, by: \.projectID)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
        await withTaskGroup(of: Void.self) { group in
            var iterator = projectQueues.makeIterator()
            for _ in 0..<min(maximumConcurrentAssignments, projectQueues.count) {
                if let assignments = iterator.next() {
                    group.addTask {
                        for assignment in assignments {
                            await self.perform(assignment: assignment)
                        }
                    }
                }
            }
            while await group.next() != nil {
                if let assignments = iterator.next() {
                    group.addTask {
                        for assignment in assignments {
                            await self.perform(assignment: assignment)
                        }
                    }
                }
            }
        }

        guard let latest = cachedRuns[runID] else { return }
        if latest.status == .cancelled || latest.status == .needsAttention { return }
        let finalStatus: RunStatus = latest.assignments.allSatisfy { $0.status == .completed } ? .completed : .failed
        let final = copy(
            latest,
            status: finalStatus,
            assignments: latest.assignments,
            outcome: RunOutcomeSummary.consolidate(latest.assignments)
        )
        try await saveAndPublish(final)
        await notifier?.notify(for: final)
    }

    /// Runs one stage at a time. A verification stage that reports FAIL sends
    /// its findings back to implementation within the reviewed rework limit;
    /// a missing result, failure, pause, or exhausted limit stops the chain.
    private func executeStages(runID: RunID, pipeline: DeliveryPipeline) async {
        while let latest = cachedRuns[runID], latest.status == .running,
              let next = DeliveryPipelineSchedule.nextAssignment(in: latest.assignments),
              let stage = pipeline.stages.first(where: { $0.id == next.deliveryStageID }) {
            let task = DeliveryStagePrompt.render(
                stage: stage,
                pipeline: pipeline,
                goal: latest.plan.interpretedGoal,
                assignments: latest.assignments
            )
            runByAssignment[next.id] = runID
            await perform(assignment: copy(
                next,
                status: next.status,
                currentTask: task,
                progress: next.progress,
                statusReason: next.statusReason
            ))

            guard let after = cachedRuns[runID], after.status == .running,
                  let finished = after.assignments.first(where: { $0.id == next.id }),
                  finished.status == .completed else { return }
            guard stage.kind.isVerification else { continue }
            let verdict = DeliveryStageVerdict.parse(finished.statusReason)
            if verdict == .passed { continue }

            let findings = finished.statusReason ?? ""
            let rework = verdict == .failed
                ? DeliveryPipelineSchedule.reworkAttempts(
                    afterFailed: finished,
                    in: pipeline,
                    assignments: after.assignments
                )
                : nil
            let reason: String
            if verdict == .missing {
                reason = "\(stage.kind.displayName) did not report PASS or FAIL. Review its result before resuming.\n\n\(findings)"
            } else if rework != nil {
                reason = "\(stage.kind.displayName) found problems; findings returned to the Engineer stage.\n\n\(findings)"
            } else {
                reason = "\(stage.kind.displayName) found problems and the rework limit (\(pipeline.maximumReworkCycles)) is reached.\n\n\(findings)"
            }
            var assignments = after.assignments.map { assignment in
                guard assignment.id == finished.id else { return assignment }
                return copy(
                    assignment,
                    status: .failed,
                    currentTask: "\(stage.kind.displayName) failed",
                    progress: nil,
                    statusReason: reason
                )
            }
            if let rework, let index = assignments.firstIndex(where: { $0.id == finished.id }) {
                assignments.insert(contentsOf: rework, at: index + 1)
                for attempt in rework { runByAssignment[attempt.id] = runID }
            }
            do {
                try await saveAndPublish(copy(after, status: after.status, assignments: assignments, outcome: after.outcome))
            } catch {
                return
            }
            if rework == nil { return }
        }
    }

    public func pause(runID: RunID) async throws {
        let run = try await requiredRun(runID)
        let assignments = run.assignments.map {
            ($0.status == .working || $0.status == .queued || $0.status == .waitingForApproval)
                ? copy($0, status: .paused, currentTask: $0.currentTask, progress: $0.progress, statusReason: "Paused by user")
                : $0
        }
        try await saveAndPublish(copy(run, status: .needsAttention, assignments: assignments, outcome: "Paused"))
        for assignment in assignments where assignment.status == .paused {
            await updateHandoff(
                for: assignment,
                state: .needsAttention,
                reason: "Destination continuation paused by the user."
            )
        }
        await cancelRuntimeApprovals(for: Set(run.assignments.map(\.id)))
        for assignment in run.assignments where assignment.status == .working || assignment.status == .waitingForApproval {
            if let runtime = await runtimes.runtime(for: assignment.providerID) {
                try? await runtime.interrupt(assignmentID: assignment.id)
            }
            finish(assignment.id, with: .cancelled)
        }
    }

    public func resume(runID: RunID) async throws {
        guard !modelChangingRuns.contains(runID) else {
            throw OrchestratorError.runAlreadyExecuting(runID)
        }
        let run = try await requiredRun(runID)
        guard !RouteMutationIntent.needsFreshChangePlan(run.plan) else {
            throw OrchestratorError.savedPlanNeedsChangeReview
        }
        if executingRuns.contains(runID) {
            guard run.status != .running else {
                throw OrchestratorError.runAlreadyExecuting(runID)
            }
            let assignmentIDs = Set(run.assignments.map(\.id))
            guard !approvalRequests.values.contains(where: { assignmentIDs.contains($0.assignmentID) }) else {
                throw OrchestratorError.approvalStillPending(runID)
            }

            // A provider is allowed to acknowledge a decline without emitting a
            // second terminal event. Older attempts could therefore retain the
            // assignment continuation after the run had already moved to Needs
            // Attention. Retire that attempt before creating a fresh one.
            for assignment in run.assignments where assignment.status != .completed {
                if let runtime = await runtimes.runtime(for: assignment.providerID) {
                    try? await runtime.interrupt(assignmentID: assignment.id)
                }
                finish(assignment.id, with: .cancelled)
            }
            await waitForExecutionToStop(runID)
            for assignmentID in assignmentIDs {
                bufferedResults.removeValue(forKey: assignmentID)
                commandEvidenceByAssignment.removeValue(forKey: assignmentID)
            }
        }
        try await execute(runID: runID)
    }

    public func resume(runID: RunID, modelChange: RunModelChange) async throws {
        try await prepareModelChange(runID: runID, modelChange: modelChange)
        try await execute(runID: runID)
    }

    private func prepareModelChange(runID: RunID, modelChange: RunModelChange) async throws {
        guard modelChangingRuns.insert(runID).inserted else {
            throw OrchestratorError.runAlreadyExecuting(runID)
        }
        defer {
            modelChangingRuns.remove(runID)
            retiringRuns.remove(runID)
        }
        let original = try await requiredRun(runID)
        guard [.needsAttention, .failed].contains(original.status),
              modelChange.matchesRunVersion(original.updatedAt) else {
            throw GobyApplicationError.invalidRunModelChange("This run changed. Review its latest state before changing the model.")
        }
        if let assignment = original.assignments.first(where: { $0.hasIndeterminateProviderStart }) {
            throw OrchestratorError.indeterminateProviderStart(assignment.providerID, assignment.id)
        }
        let unfinished = original.assignments.filter { $0.status != .completed }
        guard unfinished.contains(where: { $0.providerID == modelChange.providerID && $0.model != modelChange.model }) else {
            throw GobyApplicationError.invalidRunModelChange("Choose a different model for an unfinished assignment.")
        }
        let providerIDs = Set(unfinished.map(\.providerID))
        for providerID in providerIDs {
            guard let runtime = await runtimes.runtime(for: providerID),
                  (await runtime.capabilities()).supports(.execution) else {
                throw OrchestratorError.unsupportedProvider(providerID)
            }
            if providerID == modelChange.providerID {
                let account = try await runtime.accountSnapshot()
                guard !modelChange.model.isEmpty,
                      account.availableModels.contains(modelChange.model) || account.selectedModel == modelChange.model else {
                    throw GobyApplicationError.invalidRunModelChange("That model is no longer available from \(providerID.displayName). Refresh provider status and choose again.")
                }
            }
        }
        // Account lookup suspends. Do not retire an attempt that changed while
        // the user's displayed model choice was being validated.
        let current = try await requiredRun(runID)
        let assignmentIDs = Set(unfinished.map(\.id))
        guard current.updatedAt == original.updatedAt,
              !approvalResponsesInFlight.contains(where: { assignmentIDs.contains($0.assignmentID) }) else {
            throw GobyApplicationError.invalidRunModelChange("This run changed. Review its latest state before changing the model.")
        }
        let paused = current.assignments.map { assignment in
            assignment.status == .completed ? assignment : copy(
                assignment, status: .paused, currentTask: assignment.currentTask,
                progress: assignment.progress, statusReason: "Stopping the previous attempt before changing model"
            )
        }
        retiringRuns.insert(runID)
        try await saveAndPublish(copy(current, status: .needsAttention, assignments: paused, outcome: "Previous attempt paused for a model change"))
        await cancelRuntimeApprovals(for: assignmentIDs)
        for assignment in unfinished {
            if assignment.providerTaskID != nil || [.working, .waitingForApproval, .paused].contains(assignment.status) {
                guard let runtime = await runtimes.runtime(for: assignment.providerID) else {
                    throw OrchestratorError.unsupportedProvider(assignment.providerID)
                }
                // A failed interrupt leaves the run stopped for review. Never
                // start a second provider task when cancellation is unconfirmed.
                try await runtime.interrupt(assignmentID: assignment.id)
            }
            finish(assignment.id, with: .cancelled)
        }
        await waitForExecutionToStop(runID)
        let stopped = try await requiredRun(runID)
        guard stopped.status == .needsAttention else {
            throw GobyApplicationError.invalidRunModelChange("The run was cancelled while changing model. No replacement task was started.")
        }
        for assignmentID in assignmentIDs {
            bufferedResults.removeValue(forKey: assignmentID)
            commandEvidenceByAssignment.removeValue(forKey: assignmentID)
        }
        let assignments = stopped.assignments.map { assignment in
            guard assignment.status != .completed else { return assignment }
            return freshAttempt(
                from: assignment, reviewedTask: stopped.plan.interpretedGoal,
                model: assignment.providerID == modelChange.providerID ? modelChange.model : nil
            )
        }
        let updated = RunRecord(
            id: stopped.id, plan: stopped.plan, status: .needsAttention,
            assignments: assignments, helperTasks: stopped.helperTasks, outcome: "Model changed; starting a fresh attempt",
            approvalReceipts: stopped.approvalReceipts, instructionSnapshot: stopped.instructionSnapshot,
            agentSnapshot: stopped.agentSnapshot, providerBindingSnapshot: stopped.providerBindingSnapshot,
            projectSnapshot: stopped.projectSnapshot,
            automationExecutionAuthorityDigest: stopped.automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: stopped.automaticallyApproveRuntimeRequests,
            journal: RunJournalCompactor.compact(stopped.journal + [RunJournalEntry(
                kind: .recovery,
                message: "User selected \(modelChange.model) for unfinished \(modelChange.providerID.displayName) assignments. Pending requests were cancelled; unfinished work restarts in fresh provider tasks."
            )]),
            resourceSnapshot: stopped.resourceSnapshot, activity: stopped.activity, createdAt: stopped.createdAt, updatedAt: .now
        )
        try await saveAndPublish(updated)
    }

    public func cancel(runID: RunID) async throws {
        let run = try await requiredRun(runID)
        await cancelRuntimeApprovals(for: Set(run.assignments.map(\.id)))
        for assignment in run.assignments where ![.completed, .failed, .cancelled].contains(assignment.status) {
            if let runtime = await runtimes.runtime(for: assignment.providerID) {
                try? await runtime.interrupt(assignmentID: assignment.id)
            }
            finish(assignment.id, with: .cancelled)
        }
        let assignments = run.assignments.map {
            [.completed, .failed].contains($0.status)
                ? $0
                : copy($0, status: .cancelled, currentTask: $0.currentTask, progress: $0.progress, statusReason: "Cancelled by user")
        }
        try await saveAndPublish(copy(run, status: .cancelled, assignments: assignments, outcome: "Cancelled by user"))
        for assignment in assignments where assignment.status == .cancelled {
            await updateHandoff(
                for: assignment,
                state: .cancelled,
                reason: "Destination continuation cancelled by the user."
            )
        }
    }

    public func followUp(runID: RunID, text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GobyApplicationError.emptyPrompt }
        let run = try await requiredRun(runID)
        guard [.running, .needsAttention].contains(run.status) else {
            throw OrchestratorError.runNotExecutable(run.status)
        }
        let assignments = run.assignments.filter { $0.status == .working }
        guard !assignments.isEmpty else {
            throw OrchestratorError.activeSteeringUnavailable(nil)
        }

        var targets: [(AgentAssignment, any AgentRuntimeServing)] = []
        for assignment in assignments {
            guard let runtime = await runtimes.runtime(for: assignment.providerID),
                  (await runtime.capabilities()).supports(.activeSteering) else {
                throw OrchestratorError.activeSteeringUnavailable(assignment.providerID)
            }
            targets.append((assignment, runtime))
        }

        var delivered = 0
        do {
            for (assignment, runtime) in targets {
                try await runtime.steer(
                    assignmentID: assignment.id,
                    text: String(normalized.prefix(32_000))
                )
                delivered += 1
            }
        } catch {
            let suffix = delivered == 0
                ? "No assignment confirmed delivery."
                : "Delivery was confirmed for \(delivered) of \(targets.count) active assignments; refresh the run before retrying."
            throw OrchestratorError.providerExecutionFailed(
                "The follow-up could not be confirmed for the complete run. \(suffix)"
            )
        }

        let journal = targets.reduce(into: run.journal) { entries, target in
            entries.append(RunJournalEntry(
                kind: .assignmentChanged,
                message: "Follow-up delivered to \(target.0.providerID.displayName).",
                assignmentID: target.0.id
            ))
        }
        let updated = RunRecord(
            id: run.id,
            plan: run.plan,
            status: run.status,
            assignments: run.assignments,
            helperTasks: run.helperTasks,
            outcome: run.outcome,
            approvalReceipts: run.approvalReceipts,
            instructionSnapshot: run.instructionSnapshot,
            agentSnapshot: run.agentSnapshot,
            providerBindingSnapshot: run.providerBindingSnapshot,
            projectSnapshot: run.projectSnapshot,
            automationExecutionAuthorityDigest: run.automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: run.automaticallyApproveRuntimeRequests,
            journal: RunJournalCompactor.compact(journal),
            resourceSnapshot: run.resourceSnapshot,
            activity: run.activity,
            createdAt: run.createdAt,
            updatedAt: .now
        )
        try await saveAndPublish(updated)
    }

    public func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws {
        try await respond(to: approval, decision: decision, rememberedAuthority: nil, automationAuthority: nil)
    }

    private func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision,
        rememberedAuthority: (revision: UInt64, rule: RememberedCommandApproval)?,
        automationAuthority: (runID: RunID, digest: Data)?
    ) async throws {
        if let runID = runByAssignment[approval.assignmentID], modelChangingRuns.contains(runID) {
            throw GobyApplicationError.invalidRunModelChange("The previous attempt is being cancelled for a model change.")
        }
        let identity = approval.identity
        guard let request = approvalRequests[identity], request == approval else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        guard let runtime = await runtimes.runtime(for: request.providerID) else {
            throw OrchestratorError.unsupportedProvider(request.providerID)
        }
        if let automationAuthority {
            guard let currentRun = cachedRuns[automationAuthority.runID],
                  currentRun.automaticallyApproveRuntimeRequests,
                  currentRun.status == .running,
                  currentRun.automationExecutionAuthorityDigest == automationAuthority.digest,
                  await automationRunAuthorityIsCurrent(currentRun, digest: automationAuthority.digest),
                  approvalRequests[identity] == request,
                  runByAssignment[request.assignmentID] == automationAuthority.runID else {
                throw ProviderApprovalBindingError.missingOrChangedOperationDigest
            }
        }
        if let rememberedAuthority {
            let currentRule = await rememberedRule(for: request)
            guard rememberedAuthority.revision == rememberedRulesRevision,
                  currentRule.map({ rememberedAuthority.rule.covers($0) }) == true else {
                throw RememberedCommandApprovalError.unavailable
            }
        }
        let newRememberedRule: RememberedCommandApproval?
        if decision == .acceptAlways {
            guard rememberedApprovals != nil, let rule = await rememberedRule(for: request) else {
                throw RememberedCommandApprovalError.unavailable
            }
            newRememberedRule = rule
        } else {
            newRememberedRule = nil
        }
        guard approvalRequests[identity] == request,
              let runID = runByAssignment[request.assignmentID],
              !retiringRuns.contains(runID), !modelChangingRuns.contains(runID) else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        let effectiveDecision = try protocolDecision(for: request, requested: decision)
        guard approvalResponsesInFlight.insert(identity).inserted else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        if newRememberedRule != nil {
            rememberedRulesRevision &+= 1
            rememberedRuleWritesInFlight.insert(identity)
        }
        defer {
            approvalResponsesInFlight.remove(identity)
            if rememberedRuleWritesInFlight.remove(identity) != nil {
                rememberedRulesRevision &+= 1
                if rememberedRuleWritesInFlight.isEmpty {
                    let waiters = rememberedRuleWriteWaiters
                    rememberedRuleWriteWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
        }
        if effectiveDecision != .decline, effectiveDecision != .cancel {
            // In a read-only sandbox, any approved request (an edit, or a
            // command allowed outside the sandbox) may change files. Recorded
            // before delivery so a lost reply still counts.
            assignmentsWithApprovedWrites.insert(request.assignmentID)
        }
        try await runtime.respond(to: request, decision: effectiveDecision)
        guard approvalRequests[identity] == request else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        approvalRequests.removeValue(forKey: identity)
        if let rememberedRule = newRememberedRule {
            // A failed provider write never leaves a persistent authority behind.
            do { try await rememberedApprovals?.save(rememberedRule) }
            catch {
                try? await recordApprovalResponse(
                    request, decision: effectiveDecision,
                    automationGrant: automationAuthority != nil
                )
                throw OrchestratorError.providerExecutionFailed(
                    "This request was allowed once, but Goby could not securely save Always Allow. Future requests will still ask."
                )
            }
        }
        // Persist user authority before publishing run history. A journal failure
        // must not silently turn a successfully delivered Always Allow into once.
        do {
            try await recordApprovalResponse(
                request, decision: effectiveDecision,
                automationGrant: automationAuthority != nil
            )
        }
        catch {
            if newRememberedRule != nil {
                throw OrchestratorError.providerExecutionFailed(
                    "Always Allow was saved and this request was allowed, but Goby could not update the run history."
                )
            }
            throw error
        }
        if effectiveDecision == .decline || effectiveDecision == .cancel {
            commandEvidenceByAssignment.removeValue(forKey: request.assignmentID)
            finish(request.assignmentID, with: .failed("Approval declined"))
        }
    }

    private func perform(assignment: AgentAssignment) async {
        guard let runID = runByAssignment[assignment.id],
              let run = cachedRuns[runID] else { return }
        do {
            try await validateAutomationAuthority(for: run)
            guard let runtime = await runtimes.runtime(for: assignment.providerID),
                  (await runtime.capabilities()).supports(.execution) else {
                throw OrchestratorError.unsupportedProvider(assignment.providerID)
            }
            guard let project = run.projectSnapshot.first(where: {
                $0.id == assignment.projectID
            }) else {
                throw OrchestratorError.projectNotFound(assignment.projectID)
            }
            guard let agent = run.agentSnapshot.first(where: { $0.id == assignment.agentID }) else {
                throw OrchestratorError.agentNotFound(assignment.agentID)
            }
            let binding = try ProviderBindingResolver.resolve(
                agentID: assignment.agentID,
                providerID: assignment.providerID,
                projectID: assignment.projectID,
                bindingID: assignment.providerBindingID,
                in: run.providerBindingSnapshot
            )
            try await waitForUsageCapacity(
                runtime: runtime,
                assignmentID: assignment.id,
                runID: runID
            )
            try await waitForConflictingRuns(assignment: assignment, runID: runID)
            try Self.validateAuthorizedPaths(
                project: project,
                resources: run.resourceSnapshot,
                attachments: assignment.attachments
            )
            let workingDirectoryPlacement = try await workspaces.prepare(project: project, for: run)
            guard workingDirectoryPlacement.matchesCurrentObject() else {
                throw OrchestratorError.projectAuthorizationChanged(project.name)
            }
            let workingDirectory = workingDirectoryPlacement.rootURL
            let executableAssignment = AgentAssignment(
                id: assignment.id,
                runID: assignment.runID,
                projectID: assignment.projectID,
                agentID: assignment.agentID,
                status: assignment.status,
                currentTask: run.plan.commitsWorkingCopy(of: project.id)
                    ? Self.commitMessageTask(
                        request: assignment.currentTask,
                        pushes: run.plan.pushOperations.contains { $0.projectID == project.id },
                        changes: GitWorkspaceManager.workingCopyChanges(in: workingDirectory)
                    )
                    : run.plan.runsInProjectFolder(of: project.id)
                        ? Self.pushSummaryTask(
                            request: assignment.currentTask,
                            branch: run.plan.pushOperations.first { $0.projectID == project.id }?.branch
                        )
                        : assignment.currentTask,
                attachments: assignment.attachments,
                progress: assignment.progress,
                startedAt: assignment.startedAt,
                statusReason: "Working directory prepared.",
                workingDirectory: workingDirectory,
                workingDirectoryIdentity: workingDirectoryPlacement.fileSystemIdentity,
                codexThreadID: assignment.codexThreadID,
                codexTurnID: assignment.codexTurnID,
                providerID: assignment.providerID,
                providerBindingID: assignment.providerBindingID,
                model: assignment.model,
                providerTaskID: assignment.providerTaskID,
                providerTurnID: assignment.providerTurnID,
                handoffID: assignment.handoffID,
                deliveryStageID: assignment.deliveryStageID
            )
            let executableProject = LabProject(
                id: project.id,
                name: project.name,
                rootURL: workingDirectory,
                platforms: project.platforms,
                frameworks: project.frameworks,
                testCommands: Self.sandboxCompatibleTestCommands(project.testCommands, runID: run.id),
                instructionFiles: project.instructionFiles,
                isGitRepository: project.isGitRepository,
                registeredAt: project.registeredAt,
                fileSystemIdentity: workingDirectoryPlacement.fileSystemIdentity
            )
            let instructions = run.instructionSnapshot.filter { $0.scope.includes(project) }
            let executionAgent = AgentProfile(
                id: agent.id,
                name: agent.name,
                summary: agent.summary,
                instructions: binding.instructionsOverride ?? agent.instructions,
                capabilities: agent.capabilities,
                scope: agent.scope,
                sourceURL: agent.sourceURL,
                toolPreset: agent.toolPreset,
                reviewedDefinitionDigest: agent.reviewedDefinitionDigest,
                definitionReviewProvenance: agent.definitionReviewProvenance,
                codexRegistrationKey: agent.codexRegistrationKey,
                isEnabled: agent.isEnabled
            )
            guard let latestBeforeStart = cachedRuns[runID], latestBeforeStart.status == .running else { return }
            commandEvidenceByAssignment[assignment.id] = []
            assignmentsObservedFromStart.insert(assignment.id)
            assignmentsWithApprovedWrites.remove(assignment.id)
            let prepared = replacingAssignment(
                in: latestBeforeStart,
                id: assignment.id,
                status: .working,
                currentTask: "Starting \(agent.name) in \(project.name)",
                progress: 0.02,
                statusReason: "Working directory prepared.",
                workingDirectory: workingDirectory,
                workingDirectoryIdentity: workingDirectoryPlacement.fileSystemIdentity
            )
            try await saveAndPublish(prepared)
            try Self.validateAuthorizedPaths(
                project: project,
                resources: run.resourceSnapshot,
                attachments: assignment.attachments
            )
            guard workingDirectoryPlacement.matchesCurrentObject() else {
                throw OrchestratorError.projectAuthorizationChanged(project.name)
            }
            try await validateAutomationAuthority(for: run)
            if run.plan.runsInProjectFolder(of: project.id), !run.plan.commitsWorkingCopy(of: project.id) {
                // A push needs no agent: Goby pushes the reviewed branch itself.
                let pushed = try await workspaces.finalize(
                    project: project, workingDirectory: workingDirectory, for: run, commitMessage: nil
                )
                guard let latest = cachedRuns[runID], latest.status != .cancelled else { return }
                try await saveAndPublish(replacingAssignment(
                    in: latest,
                    id: assignment.id,
                    status: .completed,
                    currentTask: "Completed \(project.name)",
                    progress: 1,
                    statusReason: pushed
                ))
                return
            }
            let handle = try await runtime.start(
                assignment: executableAssignment,
                project: executableProject,
                agent: executionAgent,
                binding: binding,
                instructions: instructions,
                resources: run.resourceSnapshot,
                // Committing the user's own changes: the agent only reads them.
                risk: run.plan.runsInProjectFolder(of: project.id) ? .readOnly : run.plan.risk
            )
            if let latestWithTurn = cachedRuns[runID] {
                try await saveAndPublish(attaching(handle: handle, to: assignment.id, in: latestWithTurn))
            }
            await updateHandoff(
                for: assignment,
                state: .working,
                taskIdentity: ProviderTaskIdentity(providerID: handle.providerID, nativeID: handle.taskID),
                reason: "Destination provider started the reviewed continuation."
            )
            try await awaitAndFinalizeAssignment(
                assignment,
                project: project,
                executableProject: executableProject,
                workingDirectory: workingDirectory,
                runSnapshot: run
            )
        } catch {
            guard let latest = cachedRuns[runID], latest.status != .cancelled else { return }
            if latest.assignments.first(where: { $0.id == assignment.id })?.status == .paused {
                return
            }
            if case let CodexTransportError.indeterminateTurnStart(threadID) = error {
                let message = error.localizedDescription
                    + " Cancel this run and inspect its isolated working copy before reusing the request."
                let assignments = latest.assignments.map { current in
                    guard current.id == assignment.id else { return current }
                    return attachingIndeterminateCodexThread(
                        threadID,
                        to: current,
                        reason: message
                    )
                }
                try? await saveAndPublish(copy(
                    latest,
                    status: .needsAttention,
                    assignments: assignments,
                    outcome: message
                ))
                await updateHandoff(
                    for: assignment,
                    state: .needsAttention,
                    taskIdentity: ProviderTaskIdentity(providerID: .codex, nativeID: threadID),
                    reason: message
                )
                return
            }
            let failed = replacingAssignment(
                in: latest,
                id: assignment.id,
                status: .failed,
                currentTask: "Failed",
                progress: nil,
                statusReason: error.localizedDescription
            )
            try? await saveAndPublish(failed)
            await updateHandoff(
                for: assignment,
                state: .failed,
                reason: error.localizedDescription
            )
        }
    }

    private func monitorRecoveredRun(
        _ runID: RunID,
        contexts: [RecoveredAssignmentContext]
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for context in contexts {
                group.addTask { await self.monitorRecoveredAssignment(context) }
            }
        }

        recoveredRunTasks.removeValue(forKey: runID)
        markExecutionStopped(runID)
        guard let latest = cachedRuns[runID], latest.status != .cancelled else { return }
        let finalStatus: RunStatus
        if let pipeline = latest.plan.deliveryPipeline {
            // Remaining stages resume through the normal Resume action.
            finalStatus = DeliveryPipelineSchedule.finalStatus(pipeline, assignments: latest.assignments)
        } else if latest.assignments.allSatisfy({ $0.status == .completed }) {
            finalStatus = .completed
        } else if latest.assignments.contains(where: { $0.status == .paused || $0.status == .waitingForApproval }) {
            finalStatus = .needsAttention
        } else if latest.assignments.contains(where: { $0.status == .failed }) {
            finalStatus = .failed
        } else {
            finalStatus = .needsAttention
        }
        let final = copy(
            latest,
            status: finalStatus,
            assignments: latest.assignments,
            outcome: RunOutcomeSummary.consolidate(latest.assignments) ?? latest.outcome
        )
        try? await saveAndPublish(final)
        if finalStatus == .completed || finalStatus == .failed {
            await notifier?.notify(for: final)
        }
    }

    private func monitorRecoveredAssignment(_ context: RecoveredAssignmentContext) async {
        do {
            try await awaitAndFinalizeAssignment(
                context.assignment,
                project: context.project,
                executableProject: context.executableProject,
                workingDirectory: context.workingDirectory,
                runSnapshot: context.runSnapshot
            )
        } catch {
            guard let latest = cachedRuns[context.assignment.runID], latest.status != .cancelled else { return }
            if latest.assignments.first(where: { $0.id == context.assignment.id })?.status == .paused {
                return
            }
            let failed = replacingAssignment(
                in: latest,
                id: context.assignment.id,
                status: .failed,
                currentTask: "Failed",
                progress: nil,
                statusReason: error.localizedDescription
            )
            try? await saveAndPublish(failed)
            await updateHandoff(
                for: context.assignment,
                state: .failed,
                reason: error.localizedDescription
            )
        }
    }

    /// The agent's task when Goby commits the user's own changes: read them
    /// and write the message. Goby makes the commit and any approved push.
    static func commitMessageTask(request: String, pushes: Bool, changes: String?) -> String {
        let source = changes.map {
            "Do not run any commands: Goby already read the changes for you, below.\n\n\($0)"
        } ?? "Read the changes with `git status` and `git diff HEAD`, and change nothing."
        return """
        The user asked: \(request)

        Goby will commit every uncommitted change in this folder on the current branch\(pushes ? " and then push it" : "") itself, after you reply. Your only job is the commit message. Do not edit files, stage, commit or push.

        Reply with only the commit message: a summary line of at most 72 characters in the imperative mood, a blank line, then a short body listing the main changes. No preamble, no Markdown fences.

        \(source)
        """
    }

    /// The agent's task when Goby pushes a branch an earlier run committed:
    /// describe what is on it. Goby makes the push itself.
    static func pushSummaryTask(request: String, branch: String?) -> String {
        let name = branch.map { "`\($0)`" } ?? "the reviewed branch"
        return """
        The user asked: \(request)

        Goby will push \(name) itself after you reply. Your only job is a short summary of what is being pushed. Read it with `git log --oneline -10 \(branch ?? "HEAD")` and change nothing: do not edit files, stage, commit or push.

        Reply in one or two sentences naming the commits being pushed. No preamble.
        """
    }

    private func awaitAndFinalizeAssignment(
        _ assignment: AgentAssignment,
        project: LabProject,
        executableProject: LabProject,
        workingDirectory: URL,
        runSnapshot: RunRecord
    ) async throws {
        let result = await waitForResult(assignment.id)
        guard let currentRun = cachedRuns[assignment.runID], currentRun.status != .cancelled else { return }
        switch result {
        case let .completed(agentOutcome, evidence):
            guard currentRun.status == .running
                    || (currentRun.status == .needsAttention && executingRuns.contains(currentRun.id)) else { return }
            let verifying = replacingAssignment(
                in: currentRun,
                id: assignment.id,
                status: .working,
                currentTask: "Verifying \(project.name)",
                progress: 0.9,
                statusReason: nil
            )
            try await saveAndPublish(verifying)
            let verification: VerificationResult
            if Self.readOnlyAssignmentSkipsProjectChecks(
                risk: runSnapshot.plan.runsInProjectFolder(of: project.id) ? .readOnly : runSnapshot.plan.risk,
                observedFromStart: assignmentsObservedFromStart.contains(assignment.id),
                approvedWrites: assignmentsWithApprovedWrites.contains(assignment.id)
            ) {
                verification = VerificationResult(
                    succeeded: true,
                    summary: Self.readOnlyVerificationSummary
                )
            } else {
                verification = await verifier.verify(
                    project: executableProject,
                    workingDirectory: workingDirectory,
                    evidence: evidence
                )
            }
            guard verification.succeeded else {
                // The provider's answer is still the user's work product.
                // Keep it, clearly marked unverified, instead of reducing the
                // run to a bare verification failure.
                throw WorkspaceError.commandFailed(
                    command: "project verification",
                    status: 1,
                    output: UnverifiedAgentResult.reason(
                        verificationIssue: verification.summary,
                        answer: agentOutcome
                    )
                )
            }
            let commitsWorkingCopy = runSnapshot.plan.commitsWorkingCopy(of: project.id)
            let commit = try await workspaces.finalize(
                project: project,
                workingDirectory: workingDirectory,
                for: runSnapshot,
                commitMessage: commitsWorkingCopy ? agentOutcome : nil
            )
            // The agent's reply was the commit message; the result is what
            // Goby committed and pushed.
            let summary = (runSnapshot.plan.runsInProjectFolder(of: project.id)
                ? (commitsWorkingCopy ? [commit] : [agentOutcome, commit])
                : [agentOutcome, verification.summary, commit])
                .compactMap { $0 }
                .joined(separator: "\n\n")
            guard let latest = cachedRuns[assignment.runID] else { return }
            let completed = replacingAssignment(
                in: latest,
                id: assignment.id,
                status: .completed,
                currentTask: "Completed \(project.name)",
                progress: 1,
                statusReason: summary
            )
            try await saveAndPublish(completed)
            await updateHandoff(for: assignment, state: .completed, reason: summary)
        case let .failed(message):
            throw OrchestratorError.providerExecutionFailed(message)
        case .cancelled:
            return
        }
    }

    private func updateHandoff(
        for assignment: AgentAssignment,
        state: HandoffState,
        taskIdentity: ProviderTaskIdentity? = nil,
        reason: String?
    ) async {
        guard let handoffCatalog, let handoffID = assignment.handoffID,
              let snapshot = try? await catalog.snapshot(),
              let record = snapshot.handoffs.first(where: { $0.id == handoffID }) else { return }
        let updated = HandoffRecord(
            bundle: record.bundle,
            state: state,
            destinationRunID: record.destinationRunID ?? assignment.runID,
            destinationAssignmentID: assignment.id,
            destinationTaskIdentity: taskIdentity ?? record.destinationTaskIdentity,
            attemptCount: max(1, record.attemptCount),
            statusReason: reason,
            updatedAt: .now
        )
        try? await handoffCatalog.saveHandoff(updated)
    }

    private func ensureListening(to providerIDs: Set<AgentProviderID>) async {
        for providerID in providerIDs.sorted() where listeners[providerID] == nil {
            guard let runtime = await runtimes.runtime(for: providerID) else { continue }
            let events = await runtime.events()
            listeners[providerID] = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        }
    }

    private func waitForUsageCapacity(
        runtime: any AgentRuntimeServing,
        assignmentID: AssignmentID,
        runID: RunID
    ) async throws {
        while let account = try? await runtime.accountSnapshot(),
              let exhausted = (
                  account.usage
                      .filter { $0.kind == .consumedPercentage && $0.value >= 95 }
                      .max(by: { $0.value < $1.value })
              ) {
            let resetDescription = exhausted.resetsAt.map {
                $0.formatted(date: .omitted, time: .shortened)
            } ?? "the next usage window"
            await update(
                id: assignmentID,
                status: .queued,
                task: "Waiting for \(runtime.providerID.displayName) capacity until \(resetDescription)",
                progress: nil,
                reason: "Usage is \(exhausted.value.formatted(.number.precision(.fractionLength(0))))% used; the assignment remains queued."
            )
            guard cachedRuns[runID]?.status == .running else { throw CancellationError() }
            let interval = min(
                max(exhausted.resetsAt?.timeIntervalSinceNow ?? rateLimitPollInterval, 0.01),
                rateLimitPollInterval
            )
            try await Task.sleep(for: .seconds(interval))
        }
    }

    /// Holds an assignment while an earlier request in the same project would
    /// interfere with it (`ParallelRequestPolicy`). It starts by itself when
    /// that request ends, or at once after Run Anyway.
    private func waitForConflictingRuns(assignment: AgentAssignment, runID: RunID) async throws {
        while !conflictWaitOverrides.contains(runID),
              let run = cachedRuns[runID],
              let (blocker, conflict) = earliestConflict(for: run, projectID: assignment.projectID) {
            let title = Self.shortGoal(blocker.plan.interpretedGoal)
            await update(
                id: assignment.id,
                status: .queued,
                task: "Waiting for “\(title)” to finish",
                progress: nil,
                reason: "\(ParallelRequestPolicy.waitReasonPrefix)\(title)” to finish: \(conflict.reason). It starts by itself when that request ends."
            )
            guard cachedRuns[runID]?.status == .running else { throw CancellationError() }
            try await Task.sleep(for: .seconds(conflictPollInterval))
        }
    }

    private func earliestConflict(
        for run: RunRecord,
        projectID: ProjectID
    ) -> (RunRecord, ParallelRequestPolicy.Conflict)? {
        guard let mine = admissionOrder[run.id] else { return nil }
        let earlier = cachedRuns.values
            .filter { other in
                other.id != run.id
                    && other.status == .running
                    && (admissionOrder[other.id] ?? .max) < mine
                    && other.assignments.contains {
                        $0.projectID == projectID && ![.completed, .failed, .cancelled].contains($0.status)
                    }
            }
            .sorted { (admissionOrder[$0.id] ?? 0) < (admissionOrder[$1.id] ?? 0) }
        for other in earlier {
            if let conflict = ParallelRequestPolicy.conflict(later: run.plan, earlier: other.plan, in: projectID) {
                return (other, conflict)
            }
        }
        return nil
    }

    /// Starts a waiting run now, accepting the reported conflict.
    public func startWithoutWaiting(runID: RunID) async throws {
        guard executingRuns.contains(runID) else { return }
        conflictWaitOverrides.insert(runID)
    }

    nonisolated static func shortGoal(_ goal: String) -> String {
        let line = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? goal
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    private func cancelRuntimeApprovals(for assignmentIDs: Set<AssignmentID>) async {
        let matching = approvalRequests.values.filter { assignmentIDs.contains($0.assignmentID) }
        for request in matching {
            let identity = request.identity
            guard approvalRequests[identity] == request else { continue }
            guard approvalResponsesInFlight.insert(identity).inserted else {
                approvalRequests.removeValue(forKey: identity)
                continue
            }
            if let runtime = await runtimes.runtime(for: request.providerID) {
                try? await runtime.respond(to: request, decision: .cancel)
            }
            approvalResponsesInFlight.remove(identity)
            guard approvalRequests[identity] == request else { continue }
            approvalRequests.removeValue(forKey: identity)
        }
    }

    /// Delivery can immediately produce the next approval. Wait until concurrent
    /// Always Allow decisions finish saving (or fail) before deciding to ask again.
    private func respondUsingRememberedRule(to request: ProviderApprovalRequest) async -> Bool {
        let identity = request.identity
        while approvalRequests[identity] == request {
            while !rememberedRuleWritesInFlight.isEmpty {
                await withCheckedContinuation { rememberedRuleWriteWaiters.append($0) }
            }
            let revision = rememberedRulesRevision
            let candidate = await rememberedRule(for: request)
            let rules = try? await rememberedApprovals?.all()
            // Recheck after every asynchronous scope/storage read. A save or
            // revocation racing this read requires a fresh authority decision.
            guard revision == rememberedRulesRevision, rememberedRuleWritesInFlight.isEmpty else { continue }
            guard approvalRequests[identity] == request else { return true }
            guard let candidate, let rules,
                  rules.contains(where: { $0.isEnabled && $0.covers(candidate) }) else { return false }
            do {
                try await respond(to: request, decision: .accept,
                                  rememberedAuthority: (revision, candidate), automationAuthority: nil)
                await update(id: request.assignmentID, status: .working,
                             task: request.kind == .fileChange ? "Allowed by a remembered file-edit rule" : "Allowed by a remembered command rule", progress: nil,
                             reason: request.kind == .fileChange ? "Patch paths matched the approved folder and automation scope" : "Exact command, project, provider and permissions matched")
                return true
            } catch {
                // Delivered approvals cannot be offered again if journalling fails.
                guard approvalRequests[identity] == request else { return true }
                if revision != rememberedRulesRevision { continue }
                return false
            }
        }
        return true
    }

    /// Manual plan grants remain scoped; saved automation grants cover complete
    /// Codex operations for the current action. Both respond one request at a time.
    private func respondUsingRunAuthorization(
        to request: ProviderApprovalRequest, runID: RunID
    ) async -> Bool {
        guard let run = cachedRuns[runID], run.automaticallyApproveRuntimeRequests,
              run.status == .running,
              request.canAccept, request.hasCompleteOperationBinding,
              let assignment = run.assignments.first(where: { $0.id == request.assignmentID }),
              assignment.providerID == request.providerID,
              assignment.handoffID == nil,
              let directory = assignment.workingDirectory,
              let identity = assignment.workingDirectoryIdentity,
              identity.matchesCurrentObject(at: directory),
              let project = run.projectSnapshot.first(where: { $0.id == assignment.projectID }),
              Self.hasCurrentIdentity(project),
              run.resourceSnapshot.allSatisfy(Self.hasCurrentIdentity) else { return false }

        let isAutomationGrant = run.automationExecutionAuthorityDigest != nil
        if let digest = run.automationExecutionAuthorityDigest {
            guard await automationRunAuthorityIsCurrent(run, digest: digest) else { return false }
            guard RunRuntimeApprovalPolicy.completeCodexOperationIsBound(request) else { return false }
        } else {
            guard run.plan.risk != .high,
                  !run.plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval }) else { return false }
            if request.providerID != .codex {
                guard RunRuntimeApprovalPolicy.bridgedOperationIsWithinScope(
                    request, workingDirectory: directory
                ) else { return false }
            } else {
            switch request.kind {
            case .command:
                guard let scope = request.rememberedCommandScope,
                      scope.workingDirectory == directory.path,
                      RunRuntimeApprovalPolicy.commandIsWithinScope(request, command: scope.command) else { return false }
            case .fileChange:
                guard let scope = CodexRememberedFileChangeScope.scope(
                    for: request, directory: directory,
                    readOnlyRoots: run.resourceSnapshot.filter { $0.access == .readOnly }.map(\.url)
                ), scope == request.rememberedFileChangeScope else { return false }
            case .permissions:
                return false
            }
            }
        }

        guard approvalRequests[request.identity] == request,
              cachedRuns[runID]?.automaticallyApproveRuntimeRequests == true else { return false }
        do {
            try await respond(to: request, decision: .accept, rememberedAuthority: nil,
                              automationAuthority: run.automationExecutionAuthorityDigest.map { (runID, $0) })
            await update(id: request.assignmentID, status: .working,
                         task: "Allowed within the reviewed run scope", progress: nil,
                         reason: isAutomationGrant
                             ? "The current automation grants every complete Codex approval for this run"
                             : "Run uninterrupted was enabled in the approved plan")
            return true
        } catch {
            return approvalRequests[request.identity] != request
        }
    }

    private func handle(_ event: ProviderRunEvent) async {
        switch event {
        case let .assignmentStarted(providerID, id):
            guard isExpected(providerID: providerID, assignmentID: id) else { return }
            await update(
                id: id,
                status: .working,
                task: "\(providerID.displayName) is working",
                progress: 0.05,
                reason: nil
            )
        case let .progress(providerID, id, fraction, message):
            guard isExpected(providerID: providerID, assignmentID: id) else { return }
            await update(id: id, status: .working, task: message, progress: fraction, reason: nil)
        case let .approvalRequired(requestInput):
            guard isExpected(providerID: requestInput.providerID, assignmentID: requestInput.assignmentID) else {
                if let runtime = await runtimes.runtime(for: requestInput.providerID) {
                    try? await runtime.respond(to: requestInput, decision: .cancel)
                }
                return
            }
            guard let runID = runByAssignment[requestInput.assignmentID],
                  let run = cachedRuns[runID],
                  run.status == .running
                    || (run.status == .needsAttention && executingRuns.contains(runID)) else {
                if let runtime = await runtimes.runtime(for: requestInput.providerID) {
                    try? await runtime.respond(to: requestInput, decision: .cancel)
                }
                return
            }
            let request: ProviderApprovalRequest
            if requestInput.kind == .fileChange,
               let directory = run.assignments.first(where: { $0.id == requestInput.assignmentID })?.workingDirectory {
                request = requestInput.offeringFileChanges(CodexRememberedFileChangeScope.scope(
                    for: requestInput, directory: directory,
                    readOnlyRoots: run.resourceSnapshot.filter { $0.access == .readOnly }.map(\.url)
                ))
            } else { request = requestInput }
            let identity = request.identity
            guard approvalRequests[identity] == nil else {
                approvalRequests.removeValue(forKey: identity)
                if let runtime = await runtimes.runtime(for: request.providerID) {
                    try? await runtime.respond(to: request, decision: .cancel)
                }
                commandEvidenceByAssignment.removeValue(forKey: request.assignmentID)
                finish(
                    request.assignmentID,
                    with: .failed(
                        ProviderApprovalBindingError.duplicatePendingApproval.localizedDescription
                    )
                )
                return
            }
            approvalRequests[identity] = request
            if await respondUsingRememberedRule(to: request) { return }
            if await respondUsingRunAuthorization(to: request, runID: runID) { return }
            guard approvalRequests[identity] == request else { return }
            await update(id: request.assignmentID, status: .waitingForApproval, task: request.summary, progress: nil, reason: "Approval required")
            guard let waitingRun = cachedRuns[runID], waitingRun.status == .running else { return }
            try? await saveAndPublish(copy(
                waitingRun,
                status: .needsAttention,
                assignments: waitingRun.assignments,
                outcome: "Approval required"
            ))
            if let assignment = waitingRun.assignments.first(where: { $0.id == request.assignmentID }) {
                await updateHandoff(
                    for: assignment,
                    state: .needsAttention,
                    reason: "Destination provider requires a separate runtime approval."
                )
            }
            if let latest = cachedRuns[runID] { await notifier?.notify(for: latest) }
        case let .commandExecutionCompleted(id, evidence):
            guard isExpected(providerID: evidence.providerID, assignmentID: id) else { return }
            commandEvidenceByAssignment[id, default: []].append(evidence)
        case let .helperUpdated(id, activity):
            guard isExpected(providerID: activity.providerID, assignmentID: id),
                  let runID = runByAssignment[id],
                  let run = cachedRuns[runID] else { return }
            var helpers = run.helperTasks.filter { $0.identity != activity.identity }
            helpers.append(activity)
            helpers.sort {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.identity.nativeID < $1.identity.nativeID
            }
            try? await saveAndPublish(copy(
                run,
                status: run.status,
                assignments: run.assignments,
                helperTasks: helpers,
                outcome: run.outcome
            ))
        case let .activity(providerID, id, step):
            guard isExpected(providerID: providerID, assignmentID: id),
                  step.assignmentID == id,
                  let runID = runByAssignment[id] else { return }
            enqueueActivity(step, runID: runID)
        case let .assignmentCompleted(providerID, id, outcome):
            guard isExpected(providerID: providerID, assignmentID: id) else { return }
            if let runID = runByAssignment[id] { await flushActivity(runID) }
            await update(
                id: id,
                status: .working,
                task: "\(providerID.displayName) finished; verification is starting",
                progress: 0.85,
                reason: nil
            )
            let evidence = commandEvidenceByAssignment.removeValue(forKey: id) ?? []
            finish(id, with: .completed(outcome, evidence: evidence))
        case let .assignmentFailed(providerID, id, message):
            guard isExpected(providerID: providerID, assignmentID: id) else { return }
            if let runID = runByAssignment[id] { await flushActivity(runID) }
            commandEvidenceByAssignment.removeValue(forKey: id)
            approvalRequests = approvalRequests.filter { $0.value.assignmentID != id }
            finish(id, with: .failed(message))
        }
    }

    private func isExpected(providerID: AgentProviderID, assignmentID: AssignmentID) -> Bool {
        guard let runID = runByAssignment[assignmentID],
              let assignment = cachedRuns[runID]?.assignments.first(where: { $0.id == assignmentID }) else {
            return false
        }
        return assignment.providerID == providerID && !retiringRuns.contains(runID)
    }

    public func canRememberCommand(_ request: ProviderApprovalRequest) async -> Bool {
        let rule = await rememberedRule(for: request)
        return approvalRequests[request.identity] == request && rule != nil
    }

    public func rememberedCommandApprovals() async throws -> [RememberedCommandApproval] {
        try await rememberedApprovals?.all() ?? []
    }

    public func revokeRememberedCommandApproval(_ id: UUID) async throws {
        rememberedRulesRevision &+= 1
        guard let rememberedApprovals else { throw RememberedCommandApprovalError.unavailable }
        try await rememberedApprovals.revoke(id)
    }

    public func setRememberedApprovalProjectEnabled(_ projectID: ProjectID, enabled: Bool) async throws {
        rememberedRulesRevision &+= 1
        guard let rememberedApprovals else { throw RememberedCommandApprovalError.unavailable }
        try await rememberedApprovals.setProjectEnabled(projectID, enabled: enabled)
    }

    private struct AutomationCommandAuthority: Encodable {
        let automationID: AutomationID
        let revision: Int
        let action: AutomationAction
        let executionAuthorityDigest: Data
    }

    private func automationRunAuthorityIsCurrent(_ run: RunRecord, digest: Data) async -> Bool {
        guard let automationRepository, let automationAuthority,
              let snapshot = try? await automationRepository.automationSnapshot() else { return false }
        let matches = snapshot.occurrences.filter { occurrence in
            occurrence.attempts.contains { $0.runID == run.id }
        }
        guard matches.count == 1, let occurrence = matches.first,
              !occurrence.status.isFinished,
              occurrence.actions.indices.contains(occurrence.currentActionIndex),
              let definition = snapshot.definitions.first(where: { $0.id == occurrence.automationID }),
              definition.revision == occurrence.definitionRevision,
              definition.actions == occurrence.actions,
              definition.automaticallyApproveRuntimeRequests,
              AutomationCoordinator.automaticPlanReceipt(
                  for: occurrence.actions[occurrence.currentActionIndex], plan: run.plan
              ) != nil,
              occurrence.attempts.contains(where: {
                  $0.runID == run.id && $0.actionID == occurrence.actions[occurrence.currentActionIndex].id
              }),
              (try? await automationAuthority.automationExecutionAuthorityDigest()) == digest else { return false }
        return true
    }

    private func rememberedRule(for request: ProviderApprovalRequest) async -> RememberedCommandApproval? {
        guard let runID = runByAssignment[request.assignmentID], let run = cachedRuns[runID] else { return nil }
        var automation: AutomationCommandAuthority?
        var automationName: String?
        if let digest = run.automationExecutionAuthorityDigest {
            // Resolve durable scheduler provenance, never provider-supplied names.
            guard let automationRepository, let automationAuthority,
                  let snapshot = try? await automationRepository.automationSnapshot() else { return nil }
            let matches = snapshot.occurrences.filter { occurrence in
                occurrence.attempts.contains { $0.runID == runID }
            }
            guard matches.count == 1, let occurrence = matches.first,
                  !occurrence.status.isFinished,
                  occurrence.actions.indices.contains(occurrence.currentActionIndex),
                  let definition = snapshot.definitions.first(where: { $0.id == occurrence.automationID }),
                  definition.revision == occurrence.definitionRevision,
                  definition.actions == occurrence.actions else { return nil }
            let action = occurrence.actions[occurrence.currentActionIndex]
            guard occurrence.attempts.contains(where: { $0.runID == runID && $0.actionID == action.id }),
                  (try? await automationAuthority.automationExecutionAuthorityDigest()) == digest else { return nil }
            automation = AutomationCommandAuthority(automationID: definition.id, revision: definition.revision,
                action: action, executionAuthorityDigest: digest)
            automationName = definition.name
        }
        // Progress/journal updates may arrive while scheduler authority is read.
        // Compare only the actual grant boundaries, not the entire changing run.
        guard let currentRun = cachedRuns[runID],
              currentRun.automationExecutionAuthorityDigest == run.automationExecutionAuthorityDigest,
              let original = makeRememberedRule(for: request, run: run, automation: automation, automationName: automationName),
              let current = makeRememberedRule(for: request, run: currentRun, automation: automation, automationName: automationName),
              original.covers(current) else { return nil }
        return current
    }

    private func makeRememberedRule(
        for request: ProviderApprovalRequest, run: RunRecord,
        automation: AutomationCommandAuthority?, automationName: String?
    ) -> RememberedCommandApproval? {
        guard rememberedApprovals != nil, request.canAccept, request.hasCompleteOperationBinding,
              let runID = runByAssignment[request.assignmentID], !retiringRuns.contains(runID),
              !modelChangingRuns.contains(runID),
              run.plan.risk != .high,
              !run.plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval }),
              let assignment = run.assignments.first(where: { $0.id == request.assignmentID }),
              assignment.providerID == request.providerID,
              let directory = assignment.workingDirectory,
              let identity = assignment.workingDirectoryIdentity,
              identity.matchesCurrentObject(at: directory),
              let project = run.projectSnapshot.first(where: { $0.id == assignment.projectID }),
              Self.hasCurrentIdentity(project),
              run.resourceSnapshot.allSatisfy(Self.hasCurrentIdentity) else { return nil }
        let commandScope: RememberedCommandScope?
        let fileScope: RememberedFileChangeScope?
        switch request.kind {
        case .command:
            guard let scope = request.rememberedCommandScope, scope.workingDirectory == directory.path else { return nil }
            commandScope = scope
            fileScope = nil
        case .fileChange:
            guard let scope = CodexRememberedFileChangeScope.scope(for: request, directory: directory,
                readOnlyRoots: run.resourceSnapshot.filter { $0.access == .readOnly }.map(\.url)),
                scope == request.rememberedFileChangeScope else { return nil }
            commandScope = nil
            fileScope = scope
        case .permissions: return nil
        }
        struct GitAuthority: Encodable {
            let kind: GitOperationKind
            let branch: String?
            let remote: String?
        }
        struct ProjectAuthority: Encodable {
            let id: ProjectID
            let root: URL
            let identity: GADFileSystemIdentity?
            let registeredAt: Date
            let isGitRepository: Bool
        }
        struct Authority: Encodable {
            let project: ProjectAuthority
            let directory: URL
            let identity: GADFileSystemIdentity
            let resources: [SharedResource]
            let risk: PlanRisk
            let binding: ProviderAgentBindingID?
            let git: [GitAuthority]
            let automation: AutomationCommandAuthority?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Authority(
            project: ProjectAuthority(id: project.id, root: project.rootURL,
                                      identity: project.fileSystemIdentity,
                                      registeredAt: project.registeredAt,
                                      isGitRepository: project.isGitRepository),
            directory: directory, identity: identity,
            resources: run.resourceSnapshot.sorted { $0.id.rawValue < $1.id.rawValue },
            risk: run.plan.risk, binding: assignment.providerBindingID,
            git: run.plan.gitOperations.filter { $0.projectID == project.id }.map {
                GitAuthority(kind: $0.kind, branch: $0.branch, remote: $0.remote)
            }, automation: automation
        )) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let fileScope {
            return RememberedCommandApproval(providerID: request.providerID, projectID: project.id,
                projectName: project.name, fileChangeScope: fileScope, automationName: automationName,
                authorizationDigest: digest)
        }
        guard let commandScope else { return nil }
        return RememberedCommandApproval(providerID: request.providerID, projectID: project.id,
            projectName: project.name, scope: commandScope, automationName: automationName, authorizationDigest: digest)
    }

    private func protocolDecision(
        for request: ProviderApprovalRequest,
        requested decision: ProviderApprovalDecision
    ) throws -> ProviderApprovalDecision {
        if !request.canAccept || !request.hasCompleteOperationBinding {
            switch decision {
            case .accept, .acceptAlways, .acceptForSession, .acceptAllForRun:
                throw ProviderApprovalBindingError.missingOrChangedOperationDigest
            case .decline, .cancel:
                return decision
            }
        }
        // Provider-native session grants and text-fingerprinted run grants are
        // not safe scope authorities. Until adapters expose a structured,
        // trusted operation and exact resource set, both wider choices are
        // deliberately reduced to one approval.
        switch decision {
        case .acceptAlways, .acceptForSession, .acceptAllForRun:
            return .accept
        case .accept, .decline, .cancel:
            return decision
        }
    }

    private func recordApprovalResponse(
        _ request: ProviderApprovalRequest,
        decision: ProviderApprovalDecision,
        automationGrant: Bool
    ) async throws {
        guard let runID = runByAssignment[request.assignmentID], let run = cachedRuns[runID] else { return }
        let accepted = decision == .accept || decision == .acceptForSession
        let status: AgentStatus = accepted ? .working : .failed
        let updated = replacingAssignment(
            in: run,
            id: request.assignmentID,
            status: status,
            currentTask: accepted ? "Continuing after approval" : "Approval declined",
            progress: nil,
            statusReason: decision.rawValue
        )
        let assignmentIDs = Set(updated.assignments.map(\.id))
        let hasPendingApproval = approvalRequests.values.contains { assignmentIDs.contains($0.assignmentID) }
        let needsAttention = hasPendingApproval || updated.assignments.contains {
            $0.status == .failed || $0.status == .paused || $0.status == .waitingForApproval
        }
        let journal = automationGrant && accepted
            ? updated.journal + [RunJournalEntry(
                kind: .approval,
                message: "Automatically accepted Codex \(request.kind.rawValue) approval for this automation.",
                assignmentID: request.assignmentID
            )]
            : updated.journal
        try await saveAndPublish(copy(
            updated,
            status: needsAttention ? .needsAttention : .running,
            assignments: updated.assignments,
            outcome: updated.outcome,
            journal: RunJournalCompactor.compact(journal)
        ))
    }

    private func update(
        id: AssignmentID,
        status: AgentStatus,
        task: String,
        progress: Double?,
        reason: String?
    ) async {
        guard let runID = runByAssignment[id],
              let run = cachedRuns[runID],
              run.status == .running || (run.status == .needsAttention && executingRuns.contains(runID)),
              let assignment = run.assignments.first(where: { $0.id == id }),
              ![.paused, .cancelled, .completed, .failed].contains(assignment.status) else { return }
        let updated = replacingAssignment(in: run, id: id, status: status, currentTask: task, progress: progress, statusReason: reason)
        try? await saveAndPublish(updated)
    }

    private func waitForResult(_ id: AssignmentID) async -> AssignmentResult {
        if let result = bufferedResults.removeValue(forKey: id) { return result }
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
    }

    private func finish(_ id: AssignmentID, with result: AssignmentResult) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: result)
        } else {
            bufferedResults[id] = result
        }
    }

    private func waitForExecutionToStop(_ runID: RunID) async {
        guard executingRuns.contains(runID) else { return }
        await withCheckedContinuation { continuation in
            executionStopWaiters[runID, default: []].append(continuation)
        }
    }

    private func markExecutionStopped(_ runID: RunID) {
        guard executingRuns.remove(runID) != nil else { return }
        admissionOrder.removeValue(forKey: runID)
        conflictWaitOverrides.remove(runID)
        let continuations = executionStopWaiters.removeValue(forKey: runID) ?? []
        continuations.forEach { $0.resume() }
    }

    private func requiredRun(_ id: RunID) async throws -> RunRecord {
        if let run = cachedRuns[id] { return run }
        guard let run = try await runs.allRuns().first(where: { $0.id == id }) else {
            throw OrchestratorError.runNotFound(id)
        }
        cachedRuns[id] = run
        return run
    }

    static let readOnlyVerificationSummary =
        "Read-only request: no edits or out-of-sandbox commands were approved, so project checks were not required."

    /// A read-only request answered without any approved edit or escalated
    /// command changed nothing that project checks could validate. Recovered assignments, whose
    /// history before this process is unknown, are always verified.
    nonisolated static func readOnlyAssignmentSkipsProjectChecks(
        risk: PlanRisk,
        observedFromStart: Bool,
        approvedWrites: Bool
    ) -> Bool {
        risk == .readOnly && observedFromStart && !approvedWrites
    }

    nonisolated static func sandboxCompatibleTestCommands(_ commands: [String], runID: RunID? = nil) -> [String] {
        commands.map { command in
            let components = command.split(whereSeparator: \Character.isWhitespace)
            guard components.count >= 2, components[0] == "swift", components[1] == "test" else {
                return command
            }
            var compatible = command
            if !components.contains("--disable-sandbox") {
                compatible += " --disable-sandbox"
            }
            if let runID, !components.contains("--scratch-path") {
                let safeID = runID.rawValue.replacingOccurrences(
                    of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression
                )
                compatible += " --scratch-path /private/tmp/goby-swift-verification-\(safeID)"
            }
            return compatible
        }
    }

    nonisolated private static func validateAuthorizedPaths(
        project: LabProject,
        resources: [SharedResource],
        attachments: [PromptAttachment]
    ) throws {
        guard hasCurrentIdentity(project) else {
            throw OrchestratorError.projectAuthorizationChanged(project.name)
        }
        if let resource = resources.first(where: { !hasCurrentIdentity($0) }) {
            throw OrchestratorError.resourceAuthorizationChanged(resource.name)
        }
        if let attachment = attachments.first(where: { !hasCurrentIdentity($0) }) {
            throw OrchestratorError.attachmentAuthorizationChanged(attachment.displayName)
        }
    }

    nonisolated private static func hasCurrentIdentity(_ project: LabProject) -> Bool {
        project.fileSystemIdentity?.kind == .directory
            && project.fileSystemIdentity?.matchesCurrentObject(at: project.rootURL) == true
    }

    nonisolated private static func hasCurrentIdentity(_ resource: SharedResource) -> Bool {
        resource.fileSystemIdentity?.kind == .directory
            && resource.fileSystemIdentity?.matchesCurrentObject(at: resource.url) == true
    }

    nonisolated private static func hasCurrentIdentity(_ attachment: PromptAttachment) -> Bool {
        switch attachment.source {
        case let .localFile(url):
            attachment.fileSystemIdentity?.kind == .regularFile
                && attachment.fileSystemIdentity?.matchesCurrentObject(at: url) == true
                && attachment.contentSHA256 != nil
                && attachment.contentSHA256 == GADFileSystemIdentity.contentSHA256(at: url)
        case .text, nil:
            true
        }
    }

    nonisolated private static func wasInFlight(_ assignment: AgentAssignment) -> Bool {
        assignment.status == .queued
            || assignment.status == .working
            || assignment.status == .waitingForApproval
    }

    private func pausedAfterRelaunch(_ assignment: AgentAssignment) -> AgentAssignment {
        copy(
            assignment,
            status: .paused,
            currentTask: assignment.currentTask,
            progress: assignment.progress,
            statusReason: "Goby could not confirm that the provider task is still running. Review and resume to start a new provider turn."
        )
    }

    private func saveAndPublish(_ run: RunRecord) async throws {
        let journalled = addingJournalEntry(to: run, previous: cachedRuns[run.id])
        cachedRuns[journalled.id] = journalled
        try await runs.save(journalled)
        for continuation in updateContinuations.values {
            continuation.yield(journalled)
        }
    }

    private func replacingAssignment(
        in run: RunRecord,
        id: AssignmentID,
        status: AgentStatus,
        currentTask: String,
        progress: Double?,
        statusReason: String?,
        workingDirectory: URL? = nil,
        workingDirectoryIdentity: GADFileSystemIdentity? = nil
    ) -> RunRecord {
        let assignments = run.assignments.map { assignment in
            guard assignment.id == id else { return assignment }
            return copy(
                assignment,
                status: status,
                currentTask: currentTask,
                progress: progress,
                statusReason: statusReason,
                workingDirectory: workingDirectory,
                workingDirectoryIdentity: workingDirectoryIdentity
            )
        }
        return copy(run, status: run.status, assignments: assignments, outcome: run.outcome)
    }

    private func copy(
        _ assignment: AgentAssignment,
        status: AgentStatus,
        currentTask: String,
        progress: Double?,
        statusReason: String?,
        workingDirectory: URL? = nil,
        workingDirectoryIdentity: GADFileSystemIdentity? = nil
    ) -> AgentAssignment {
        AgentAssignment(
            id: assignment.id,
            runID: assignment.runID,
            projectID: assignment.projectID,
            agentID: assignment.agentID,
            status: status,
            currentTask: currentTask,
            attachments: assignment.attachments,
            progress: progress,
            startedAt: assignment.startedAt ?? (status == .working ? .now : nil),
            statusReason: statusReason,
            workingDirectory: workingDirectory ?? assignment.workingDirectory,
            workingDirectoryIdentity: workingDirectoryIdentity ?? assignment.workingDirectoryIdentity,
            codexThreadID: assignment.codexThreadID,
            codexTurnID: assignment.codexTurnID,
            providerID: assignment.providerID,
            providerBindingID: assignment.providerBindingID,
            model: assignment.model,
            providerTaskID: assignment.providerTaskID,
            providerTurnID: assignment.providerTurnID,
            handoffID: assignment.handoffID,
            deliveryStageID: assignment.deliveryStageID
        )
    }

    /// Builds the provider-neutral input for a new execution attempt. Presentation
    /// labels such as "Failed" and "Verifying …" are deliberately not prompts,
    /// and a new attempt must not inherit the prior provider task identity.
    private func freshAttempt(
        from assignment: AgentAssignment,
        reviewedTask: String,
        model: String? = nil
    ) -> AgentAssignment {
        AgentAssignment(
            id: assignment.id,
            runID: assignment.runID,
            projectID: assignment.projectID,
            agentID: assignment.agentID,
            status: .queued,
            currentTask: reviewedTask,
            attachments: assignment.attachments,
            progress: nil,
            startedAt: assignment.startedAt,
            statusReason: nil,
            workingDirectory: assignment.workingDirectory,
            workingDirectoryIdentity: assignment.workingDirectoryIdentity,
            codexThreadID: nil,
            codexTurnID: nil,
            providerID: assignment.providerID,
            providerBindingID: assignment.providerBindingID,
            model: model ?? assignment.model,
            providerTaskID: nil,
            providerTurnID: nil,
            handoffID: assignment.handoffID,
            deliveryStageID: assignment.deliveryStageID
        )
    }

    private func attaching(
        handle: ProviderExecutionHandle,
        to id: AssignmentID,
        in run: RunRecord
    ) -> RunRecord {
        let assignments = run.assignments.map { assignment in
            guard assignment.id == id else { return assignment }
            return AgentAssignment(
                id: assignment.id,
                runID: assignment.runID,
                projectID: assignment.projectID,
                agentID: assignment.agentID,
                status: assignment.status,
                currentTask: assignment.currentTask,
                attachments: assignment.attachments,
                progress: assignment.progress,
                startedAt: assignment.startedAt,
                statusReason: assignment.statusReason,
                workingDirectory: assignment.workingDirectory,
                workingDirectoryIdentity: assignment.workingDirectoryIdentity,
                codexThreadID: handle.providerID == .codex ? handle.taskID : nil,
                codexTurnID: handle.providerID == .codex ? handle.turnID : nil,
                providerID: handle.providerID,
                providerBindingID: assignment.providerBindingID,
                model: assignment.model,
                providerTaskID: handle.taskID,
                providerTurnID: handle.turnID,
                handoffID: assignment.handoffID,
                deliveryStageID: assignment.deliveryStageID
            )
        }
        return copy(run, status: run.status, assignments: assignments, outcome: run.outcome)
    }

    private func attachingIndeterminateCodexThread(
        _ threadID: String,
        to assignment: AgentAssignment,
        reason: String
    ) -> AgentAssignment {
        AgentAssignment(
            id: assignment.id,
            runID: assignment.runID,
            projectID: assignment.projectID,
            agentID: assignment.agentID,
            status: .paused,
            currentTask: "Codex start needs reconciliation",
            attachments: assignment.attachments,
            progress: assignment.progress,
            startedAt: assignment.startedAt,
            statusReason: reason,
            workingDirectory: assignment.workingDirectory,
            workingDirectoryIdentity: assignment.workingDirectoryIdentity,
            codexThreadID: threadID,
            codexTurnID: nil,
            providerID: .codex,
            providerBindingID: assignment.providerBindingID,
            model: assignment.model,
            providerTaskID: threadID,
            providerTurnID: nil,
            handoffID: assignment.handoffID,
            deliveryStageID: assignment.deliveryStageID
        )
    }

    private func copy(
        _ run: RunRecord,
        status: RunStatus,
        assignments: [AgentAssignment],
        helperTasks: [ProviderTaskActivity]? = nil,
        outcome: String?,
        journal: [RunJournalEntry]? = nil,
        activity: [RunActivityStep]? = nil
    ) -> RunRecord {
        RunRecord(
            id: run.id,
            plan: run.plan,
            status: status,
            assignments: assignments,
            helperTasks: helperTasks ?? run.helperTasks,
            outcome: outcome,
            approvalReceipts: run.approvalReceipts,
            instructionSnapshot: run.instructionSnapshot,
            agentSnapshot: run.agentSnapshot,
            providerBindingSnapshot: run.providerBindingSnapshot,
            projectSnapshot: run.projectSnapshot,
            automationExecutionAuthorityDigest: run.automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: run.automaticallyApproveRuntimeRequests,
            journal: journal ?? run.journal,
            resourceSnapshot: run.resourceSnapshot,
            activity: activity ?? run.activity,
            createdAt: run.createdAt,
            updatedAt: .now
        )
    }

    /// Typed steps can arrive many times per second. Buffer them per run and
    /// publish at most once per window so the host never saturates rebuilding
    /// projections (see Docs/Beta/PROMPT_EXECUTION_FIXES_2026-09.md §2).
    static let activityPublishInterval: Duration = .milliseconds(500)

    private func enqueueActivity(_ step: RunActivityStep, runID: RunID) {
        pendingActivity[runID, default: []].append(step)
        guard activityFlushTasks[runID] == nil else { return }
        activityFlushTasks[runID] = Task { [weak self] in
            try? await Task.sleep(for: Self.activityPublishInterval)
            await self?.flushActivity(runID)
        }
    }

    private func flushActivity(_ runID: RunID) async {
        activityFlushTasks.removeValue(forKey: runID)?.cancel()
        guard let steps = pendingActivity.removeValue(forKey: runID), !steps.isEmpty,
              let run = cachedRuns[runID] else { return }
        let activity = steps.reduce(run.activity) { RunActivityLog.upserting($1, into: $0) }
        try? await saveAndPublish(copy(
            run, status: run.status, assignments: run.assignments,
            outcome: run.outcome, activity: activity
        ))
    }

    private func addingJournalEntry(to run: RunRecord, previous: RunRecord?) -> RunRecord {
        let entry: RunJournalEntry?
        if let previous, previous.status != run.status {
            entry = RunJournalEntry(
                kind: .statusChanged,
                message: "Run changed from \(previous.status.displayName) to \(run.status.displayName)."
            )
        } else if let previous,
                  let changed = run.assignments.first(where: { assignment in
                      guard let old = previous.assignments.first(where: { $0.id == assignment.id }) else { return true }
                      return old.status != assignment.status || old.currentTask != assignment.currentTask
                  }) {
            entry = RunJournalEntry(
                kind: changed.status == .waitingForApproval ? .approval : .assignmentChanged,
                message: "\(changed.status.displayName): \(changed.currentTask)",
                assignmentID: changed.id
            )
        } else {
            entry = nil
        }
        guard let entry else { return run }
        return RunRecord(
            id: run.id,
            plan: run.plan,
            status: run.status,
            assignments: run.assignments,
            helperTasks: run.helperTasks,
            outcome: run.outcome,
            approvalReceipts: run.approvalReceipts,
            instructionSnapshot: run.instructionSnapshot,
            agentSnapshot: run.agentSnapshot,
            providerBindingSnapshot: run.providerBindingSnapshot,
            projectSnapshot: run.projectSnapshot,
            automationExecutionAuthorityDigest: run.automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: run.automaticallyApproveRuntimeRequests,
            journal: RunJournalCompactor.compact(run.journal + [entry]),
            resourceSnapshot: run.resourceSnapshot,
            activity: run.activity,
            createdAt: run.createdAt,
            updatedAt: run.updatedAt
        )
    }

    private func isAutomationAuthorityCurrent(for run: RunRecord) async -> Bool {
        do {
            try await validateAutomationAuthority(for: run)
            return true
        } catch {
            return false
        }
    }

    private func validateAutomationAuthority(for run: RunRecord) async throws {
        guard let requiredDigest = run.automationExecutionAuthorityDigest else { return }
        guard let automationAuthority,
              try await automationAuthority.automationExecutionAuthorityDigest() == requiredDigest else {
            throw GobyApplicationError.invalidAutomation(
                "This automation's execution authority changed before provider start. Review the paused schedule before running it."
            )
        }
    }
}

public typealias CodexRunOrchestrator = ProviderRunOrchestrator
