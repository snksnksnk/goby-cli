import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct DeliveryPipelineExecutionTests {
    private let project = LabProject(
        id: "app",
        name: "Shop",
        rootURL: FileManager.default.temporaryDirectory,
        platforms: [.macOS],
        isGitRepository: false
    )

    private func agent(_ id: String, _ capabilities: Set<AgentCapability>) -> AgentProfile {
        AgentProfile(
            id: AgentID(rawValue: id),
            name: id.capitalized,
            summary: id,
            capabilities: capabilities,
            scope: .project(project.id)
        )
    }

    private var fullTeam: [AgentProfile] {
        [
            agent("engineer", [.macOS]),
            agent("planner", [.research]),
            agent("tester", [.testing]),
            agent("guard", [.security]),
            agent("shipper", [.release]),
        ]
    }

    private let fullRequest = """
        Add an "Export run summary as Markdown" action to Run Detail. Plan it first, implement it, \
        verify with unit tests, stress-test exporting a run with 5,000 journal entries, check the export \
        for leaked secrets or file paths, then prepare it for release.
        """

    // MARK: Router

    @Test("A full request gets all six stages with specialist owners and needs review")
    func fullChain() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let plan = try await DeterministicRouter().plan(for: RouteRequest(prompt: fullRequest), in: lab)
        let pipeline = try #require(plan.deliveryPipeline)
        #expect(pipeline.stages.map(\.kind) == DeliveryStageKind.allCases)
        #expect(pipeline.isValid)
        #expect(pipeline.stages.map(\.target.agentID.rawValue)
            == ["planner", "engineer", "tester", "tester", "guard", "shipper"])
        #expect(Set(plan.routes.flatMap(\.agentIDs).map(\.rawValue))
            == ["engineer", "planner", "tester", "guard", "shipper"])
        #expect(plan.requiresApproval)
        #expect(!plan.canStartAutomatically)
        #expect(plan.routes.first?.reason.contains("Stages: Plan → Engineer → QA") == true)
    }

    @Test("A simple fix adds QA only when a separate tester exists")
    func simpleFix() async throws {
        let withTester = LabSnapshot(projects: [project], agents: [agent("engineer", [.macOS]), agent("tester", [.testing])])
        let staged = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Fix the typo Recieve in the Settings view"), in: withTester
        )
        #expect(staged.deliveryPipeline?.stages.map(\.kind) == [.implement, .qualityAssurance])

        let soloLab = LabSnapshot(projects: [project], agents: [agent("engineer", [.macOS])])
        let solo = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Fix the typo Recieve in the Settings view"), in: soloLab
        )
        #expect(solo.deliveryPipeline == nil)
        #expect(solo.routes.first?.agentIDs == ["engineer"])
    }

    @Test("A stage without a separate specialist folds into the engineer stage")
    func missingSpecialist() async throws {
        let lab = LabSnapshot(projects: [project], agents: [agent("engineer", [.macOS]), agent("tester", [.testing])])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Fix the login form and check it for security vulnerabilities"), in: lab
        )
        let pipeline = try #require(plan.deliveryPipeline)
        #expect(pipeline.stages.map(\.kind) == [.implement, .qualityAssurance])
        #expect(pipeline.stages[0].reason.contains("also covers Security test"))
        #expect(pipeline.stages[0].passCriteria.contains("No exploitable vulnerability"))
        #expect(plan.warnings.contains { $0.contains("no separate Security test specialist") })
    }

    @Test("A verification-only request runs as stages without an engineer")
    func verificationOnly() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Stress test and pentest the macOS app"), in: lab
        )
        let pipeline = try #require(plan.deliveryPipeline)
        #expect(pipeline.stages.map(\.kind) == [.stressTest, .securityTest])
        #expect(pipeline.stages.map(\.target.agentID) == ["tester", "guard"])
        #expect(plan.risk == .readOnly)
        #expect(!plan.canStartAutomatically)
    }

    @Test("A docs change keeps the docs agent and gets no automatic QA")
    func docsChange() async throws {
        let lab = LabSnapshot(projects: [project], agents: [
            agent("docs", [.documentation]), agent("tester", [.testing]), agent("engineer", [.macOS]),
        ])
        let plan = try await DeterministicRouter().plan(for: RouteRequest(prompt: "update the readme"), in: lab)
        #expect(plan.deliveryPipeline == nil)
        #expect(plan.routes.first?.agentIDs == ["docs"])
    }

    @Test("Direct agent targets and read-only questions keep single-step routing")
    func singleStepCases() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let direct = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: fullRequest,
                agentTargets: [AgentRouteTarget(providerID: .codex, agentID: "engineer", projectID: project.id)]
            ),
            in: lab
        )
        #expect(direct.deliveryPipeline == nil)
        let question = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Explain how the macOS settings screen loads"), in: lab
        )
        #expect(question.deliveryPipeline == nil)
    }

    @Test("Editing scope drops stages owned by a removed agent")
    func scopeEditing() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let plan = try await DeterministicRouter().plan(for: RouteRequest(prompt: fullRequest), in: lab)
        let route = try #require(plan.routes.first)
        let edited = ProjectRoute(
            projectID: route.projectID,
            providerID: route.providerID,
            agentIDs: route.agentIDs.filter { $0 != "tester" && $0 != "guard" },
            providerBindings: route.providerBindings.filter { $0.agentID != "tester" && $0.agentID != "guard" },
            reason: route.reason
        )
        let restricted = plan.deliveryPipeline?.restricted(to: [edited])
        // Without any verification, Release is dropped too.
        #expect(restricted?.stages.map(\.kind) == [.plan, .implement])
    }

    // MARK: Staging

    @Test("Staging creates one ordered assignment per stage")
    func staging() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let plan = try await DeterministicRouter().plan(for: RouteRequest(prompt: fullRequest), in: lab)
        let repository = PipelineTestRepository(lab: lab, runs: [])
        let run = try await StageRunUseCase(
            repository: repository, catalog: repository, instructions: repository,
            resources: repository, approvals: PipelineAllowingApproval()
        )(plan: plan, receipt: nil)
        #expect(run.assignments.map(\.deliveryStageID) == plan.deliveryPipeline?.stages.map(\.id))
        #expect(run.assignments.map(\.agentID.rawValue)
            == ["planner", "engineer", "tester", "tester", "guard", "shipper"])
        #expect(run.providerBindingSnapshot.count == 5)
    }

    @Test("Staging rejects an invalid pipeline")
    func stagingRejectsInvalidPipeline() async throws {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let plan = try await DeterministicRouter().plan(for: RouteRequest(prompt: fullRequest), in: lab)
        let pipeline = try #require(plan.deliveryPipeline)
        let reversed = RoutingPlan(
            id: plan.id, interpretedGoal: plan.interpretedGoal, routes: plan.routes,
            risk: plan.risk, confidence: plan.confidence,
            deliveryPipeline: DeliveryPipeline(stages: pipeline.stages.reversed())
        )
        let repository = PipelineTestRepository(lab: lab, runs: [])
        await #expect(throws: GobyApplicationError.self) {
            try await StageRunUseCase(
                repository: repository, catalog: repository, instructions: repository,
                resources: repository, approvals: PipelineAllowingApproval()
            )(plan: reversed, receipt: nil)
        }
        #expect(await repository.records.isEmpty)
    }

    // MARK: Execution

    private func stagedRun(
        prompt: String,
        maximumRework: Int = 2
    ) async throws -> (RunRecord, LabSnapshot) {
        let lab = LabSnapshot(projects: [project], agents: fullTeam)
        let routed = try await DeterministicRouter().plan(for: RouteRequest(prompt: prompt), in: lab)
        let pipeline = try #require(routed.deliveryPipeline)
        let plan = RoutingPlan(
            id: routed.id, interpretedGoal: routed.interpretedGoal, routes: routed.routes,
            risk: .low, confidence: 1,
            deliveryPipeline: DeliveryPipeline(stages: pipeline.stages, maximumReworkCycles: maximumRework)
        )
        let repository = PipelineTestRepository(lab: lab, runs: [])
        let run = try await StageRunUseCase(
            repository: repository, catalog: repository, instructions: repository,
            resources: repository, approvals: PipelineAllowingApproval()
        )(plan: plan, receipt: nil)
        return (run, lab)
    }

    @Test("Stages run in order and each receives earlier results")
    func runsInOrder() async throws {
        let (run, lab) = try await stagedRun(prompt: fullRequest)
        let repository = PipelineTestRepository(lab: lab, runs: [run])
        let runtime = ScriptedStageRuntime(failuresBeforePass: [:])
        try await orchestrator(repository, runtime).execute(runID: run.id)

        let final = try #require(await repository.records.first)
        #expect(final.status == .completed)
        let prompts = await runtime.prompts
        #expect(prompts.count == 6)
        #expect(prompts[0].contains("You are the Plan stage"))
        #expect(prompts[1].contains("### Plan"))
        #expect(prompts[2].contains("STAGE RESULT: PASS"))
        #expect(prompts[4].contains("never external hosts"))
        #expect(prompts[5].contains("Do not push, merge, tag, or publish"))
    }

    @Test("A failed check returns findings to the engineer and re-verifies")
    func reworkLoop() async throws {
        let (run, lab) = try await stagedRun(prompt: fullRequest)
        let repository = PipelineTestRepository(lab: lab, runs: [run])
        let runtime = ScriptedStageRuntime(failuresBeforePass: ["Security test": 1])
        try await orchestrator(repository, runtime).execute(runID: run.id)

        let final = try #require(await repository.records.first)
        #expect(final.status == .completed)
        let prompts = await runtime.prompts
        let stages = prompts.map(ScriptedStageRuntime.stageName)
        #expect(stages == ["Plan", "Engineer", "QA", "Stress test", "Security test",
                           "Engineer", "QA", "Stress test", "Security test", "Release"])
        #expect(prompts[5].contains("Rework: a verification stage failed"))
        #expect(prompts[5].contains("Security test finding"))
        let progress = DeliveryPipelineSchedule.progress(of: try #require(final.plan.deliveryPipeline), assignments: final.assignments)
        #expect(progress.allSatisfy { $0.state == .passed })
        #expect(progress.first { $0.stage.kind == .implement }?.attempts == 2)
    }

    @Test("The rework limit stops the run for the user")
    func reworkLimit() async throws {
        let (run, lab) = try await stagedRun(prompt: fullRequest, maximumRework: 1)
        let repository = PipelineTestRepository(lab: lab, runs: [run])
        let runtime = ScriptedStageRuntime(failuresBeforePass: ["QA": 5])
        try await orchestrator(repository, runtime).execute(runID: run.id)

        let final = try #require(await repository.records.first)
        #expect(final.status == .failed)
        let stages = await runtime.prompts.map(ScriptedStageRuntime.stageName)
        #expect(stages == ["Plan", "Engineer", "QA", "Engineer", "QA"])
        let last = try #require(DeliveryPipelineSchedule.activeAssignments(final.assignments).first { $0.status == .failed })
        #expect(last.statusReason?.contains("rework limit (1) is reached") == true)
    }

    @Test("A verification stage without a result fails closed")
    func missingVerdict() async throws {
        let (run, lab) = try await stagedRun(prompt: "Fix the Settings typo and add tests")
        let repository = PipelineTestRepository(lab: lab, runs: [run])
        let runtime = ScriptedStageRuntime(failuresBeforePass: [:], omitsVerdict: true)
        try await orchestrator(repository, runtime).execute(runID: run.id)

        let final = try #require(await repository.records.first)
        #expect(final.status == .failed)
        #expect(await runtime.prompts.count == 2)
        #expect(final.assignments.last?.statusReason?.contains("did not report PASS or FAIL") == true)
    }

    private func orchestrator(
        _ repository: PipelineTestRepository,
        _ runtime: ScriptedStageRuntime
    ) -> ProviderRunOrchestrator {
        ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: PipelineTestWorkspace(),
            verifier: ProjectVerifier()
        )
    }
}

/// Completes each stage immediately. Verification stages report FAIL for the
/// configured number of attempts, then PASS.
private actor ScriptedStageRuntime: AgentRuntimeServing {
    nonisolated let providerID: AgentProviderID = .codex
    private let eventStream: AsyncStream<ProviderRunEvent>
    private let eventContinuation: AsyncStream<ProviderRunEvent>.Continuation
    private var remainingFailures: [String: Int]
    private let omitsVerdict: Bool
    private(set) var prompts: [String] = []

    init(failuresBeforePass: [String: Int], omitsVerdict: Bool = false) {
        remainingFailures = failuresBeforePass
        self.omitsVerdict = omitsVerdict
        let pair = AsyncStream<ProviderRunEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    static func stageName(_ prompt: String) -> String {
        guard let start = prompt.range(of: "You are the "),
              let end = prompt.range(of: " stage", range: start.upperBound..<prompt.endIndex) else { return "" }
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    func capabilities() -> ProviderCapabilities { ProviderCapabilities([.execution, .interruption]) }
    func connectionState() -> ProviderConnectionState { .connected(version: "test") }
    func connect() -> ProviderConnectionState { .connected(version: "test") }
    func accountSnapshot() -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(providerID: providerID, connectionState: .connected(version: "test"))
    }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }

    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> ProviderExecutionHandle {
        prompts.append(assignment.currentTask)
        let stage = Self.stageName(assignment.currentTask)
        let outcome: String
        if !assignment.currentTask.contains(DeliveryStageVerdict.marker) {
            outcome = "\(stage) done."
        } else if omitsVerdict {
            outcome = "\(stage) looked at it."
        } else if let failures = remainingFailures[stage], failures > 0 {
            remainingFailures[stage] = failures - 1
            outcome = "- \(stage) finding: input is not escaped\nSTAGE RESULT: FAIL"
        } else {
            outcome = "All good.\nSTAGE RESULT: PASS"
        }
        eventContinuation.yield(.assignmentStarted(providerID, assignment.id))
        eventContinuation.yield(.assignmentCompleted(providerID, assignment.id, outcome: outcome))
        return ProviderExecutionHandle(providerID: providerID, taskID: "task-\(assignment.id.rawValue)")
    }

    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { eventStream }
}

private actor PipelineTestRepository: LabCatalogRepository, RunRepository, InstructionRepository, SharedResourceRepository {
    let lab: LabSnapshot
    var records: [RunRecord]

    init(lab: LabSnapshot, runs: [RunRecord]) {
        self.lab = lab
        records = runs
    }

    func snapshot() -> LabSnapshot { lab }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func allRuns() -> [RunRecord] { records }
    func save(_ run: RunRecord) {
        records.removeAll { $0.id == run.id }
        records.append(run)
    }
    func allInstructionPacks() -> [InstructionPack] { [] }
    func save(_ pack: InstructionPack) {}
    func allResources() -> [SharedResource] { [] }
    func saveResource(_ resource: SharedResource) {}
    func setResourceEnabled(id: SharedResourceID, enabled: Bool) {}
}

private struct PipelineAllowingApproval: ApprovalChecking {
    func validate(plan: RoutingPlan, receipt: ApprovalReceipt?) async throws {}
}

private actor PipelineTestWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) -> String? { nil }
}
