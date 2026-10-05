import Foundation
import Testing
@testable import GobyDomain

struct DeliveryPipelineTests {
    private func stage(
        _ kind: DeliveryStageKind,
        project: ProjectID = "app",
        agent: AgentID = "agent"
    ) -> DeliveryStage {
        DeliveryStage(
            kind: kind,
            target: AgentHandoffEndpoint(
                providerID: .codex,
                bindingID: ProviderAgentBindingID(rawValue: "binding-\(kind.rawValue)"),
                agentID: agent,
                projectID: project
            ),
            reason: "Selected for \(kind.displayName)",
            passCriteria: "Checks pass"
        )
    }

    private func plan(_ pipeline: DeliveryPipeline?) -> RoutingPlan {
        RoutingPlan(
            interpretedGoal: "Ship feature",
            routes: [],
            risk: .readOnly,
            confidence: 1,
            deliveryPipeline: pipeline
        )
    }

    @Test("Full chain in canonical order is valid")
    func fullChainIsValid() {
        let pipeline = DeliveryPipeline(stages: DeliveryStageKind.allCases.map { stage($0) })
        #expect(pipeline.isValid)
        #expect(pipeline.includesRelease)
    }

    @Test("Out-of-order and duplicate stages are reported")
    func invalidOrdering() {
        let pipeline = DeliveryPipeline(stages: [
            stage(.implement), stage(.qualityAssurance), stage(.implement), stage(.qualityAssurance),
        ])
        #expect(pipeline.issues.contains(.outOfOrder(.implement)))
        #expect(pipeline.issues.contains(.duplicateStage(.qualityAssurance, "app")))
    }

    @Test("Release requires an earlier verification stage")
    func releaseNeedsVerification() {
        let pipeline = DeliveryPipeline(stages: [stage(.implement), stage(.release)])
        #expect(pipeline.issues == [.releaseWithoutVerification])
        #expect(DeliveryPipeline(stages: []).issues == [.empty])
    }

    @Test("Failed verification returns to the same project's implementation stage")
    func reworkTarget() {
        let implement = stage(.implement)
        let otherImplement = stage(.implement, project: "other")
        let qa = stage(.qualityAssurance)
        let security = stage(.securityTest)
        let pipeline = DeliveryPipeline(stages: [implement, otherImplement, qa, security])
        #expect(pipeline.reworkTarget(forFailed: security.id) == implement)
        #expect(pipeline.reworkTarget(forFailed: implement.id) == nil)
        #expect(pipeline.stage(after: qa.id) == security)
        #expect(pipeline.stage(after: security.id) == nil)

        let verificationOnly = DeliveryPipeline(stages: [security])
        #expect(verificationOnly.reworkTarget(forFailed: security.id) == nil)
    }

    @Test("Rework cycles are clamped", arguments: [(-4, 0), (0, 0), (2, 2), (9, 3)])
    func reworkClamp(input: Int, expected: Int) throws {
        #expect(DeliveryPipeline(stages: [stage(.implement)], maximumReworkCycles: input)
            .maximumReworkCycles == expected)
        let json = #"{"stages":[],"maximumReworkCycles":\#(input)}"#
        let decoded = try JSONDecoder().decode(DeliveryPipeline.self, from: Data(json.utf8))
        #expect(decoded.maximumReworkCycles == expected)
    }

    @Test("Only implementation owns the working copy")
    func workingCopyOwner() {
        #expect(DeliveryStageKind.allCases.filter(\.mutatesWorkingCopy) == [.implement])
    }

    @Test("Multi-stage and release pipelines require approval and never auto-start")
    func approvalBoundary() {
        #expect(plan(nil).canStartAutomatically)
        #expect(!plan(nil).requiresApproval)

        let single = plan(DeliveryPipeline(stages: [stage(.qualityAssurance)]))
        #expect(single.canStartAutomatically)
        #expect(!single.requiresApproval)

        let chain = plan(DeliveryPipeline(stages: [stage(.implement), stage(.qualityAssurance)]))
        #expect(chain.requiresApproval)
        #expect(!chain.canStartAutomatically)
    }

    @Test("Empty pipeline normalizes to legacy single-step behavior")
    func emptyNormalizes() {
        #expect(plan(DeliveryPipeline(stages: [])).deliveryPipeline == nil)
    }

    @Test("Plans saved before stages existed decode without a pipeline and round-trip with one")
    func legacyAndRoundTrip() throws {
        let original = plan(DeliveryPipeline(stages: [stage(.implement), stage(.qualityAssurance)]))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RoutingPlan.self, from: data) == original)

        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document.removeValue(forKey: "deliveryPipeline")
        let legacy = try JSONDecoder().decode(
            RoutingPlan.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
        #expect(legacy.deliveryPipeline == nil)
    }

    @Test("Editing plan scope drops stages for removed projects and agents")
    func restriction() {
        let pipeline = DeliveryPipeline(
            stages: [stage(.implement), stage(.qualityAssurance, agent: "tester"), stage(.implement, project: "other")],
            maximumReworkCycles: 1
        )
        let appRoute = ProjectRoute(projectID: "app", agentIDs: ["agent", "tester"], reason: "r")
        let restricted = pipeline.restricted(to: [appRoute])
        #expect(restricted?.stages.map(\.kind) == [.implement, .qualityAssurance])
        #expect(restricted?.maximumReworkCycles == 1)
        // One remaining stage falls back to single-step execution.
        let withoutTester = ProjectRoute(projectID: "app", agentIDs: ["agent"], reason: "r")
        #expect(pipeline.restricted(to: [withoutTester]) == nil)
        #expect(pipeline.restricted(to: []) == nil)
    }
}

struct DeliveryPipelineScheduleTests {
    private func stage(_ kind: DeliveryStageKind) -> DeliveryStage {
        DeliveryStage(
            kind: kind,
            target: AgentHandoffEndpoint(
                providerID: .codex,
                bindingID: ProviderAgentBindingID(rawValue: "binding-\(kind.rawValue)"),
                agentID: AgentID(rawValue: kind.rawValue),
                projectID: "app"
            ),
            reason: "r",
            passCriteria: "p"
        )
    }

    private func attempt(_ stage: DeliveryStage, _ status: AgentStatus, reason: String? = nil) -> AgentAssignment {
        AgentAssignment(
            runID: "run", projectID: "app", agentID: stage.target.agentID, status: status,
            currentTask: "goal", statusReason: reason, deliveryStageID: stage.id
        )
    }

    @Test("Verdict parsing reads the last marked line and fails closed", arguments: [
        ("Checks ran.\nSTAGE RESULT: PASS", DeliveryStageVerdict.passed),
        ("**STAGE RESULT: FAIL**", .failed),
        ("stage result: pass\nlater text", .passed),
        ("STAGE RESULT: PASS\nSTAGE RESULT: FAIL", .failed),
        ("Everything looks fine", .missing),
    ])
    func verdicts(text: String, expected: DeliveryStageVerdict) {
        #expect(DeliveryStageVerdict.parse(text) == expected)
    }

    @Test("Rework appends implementation and re-verification up to the failed stage")
    func rework() throws {
        let implement = stage(.implement), qa = stage(.qualityAssurance), security = stage(.securityTest), release = stage(.release)
        let pipeline = DeliveryPipeline(stages: [implement, qa, security, release], maximumReworkCycles: 1)
        let failed = attempt(security, .completed, reason: "STAGE RESULT: FAIL")
        let assignments = [attempt(implement, .completed), attempt(qa, .completed), failed, attempt(release, .queued)]

        let rework = try #require(DeliveryPipelineSchedule.reworkAttempts(afterFailed: failed, in: pipeline, assignments: assignments))
        #expect(rework.map(\.deliveryStageID) == [implement.id, qa.id, security.id])
        #expect(rework.allSatisfy { $0.status == .queued })

        // After one cycle the limit is reached.
        let afterCycle = assignments + rework
        let secondFailure = try #require(afterCycle.last)
        #expect(DeliveryPipelineSchedule.reworkAttempts(afterFailed: secondFailure, in: pipeline, assignments: afterCycle) == nil)
    }

    @Test("Superseded attempts are skipped and final status uses the latest attempts")
    func supersededAndFinalStatus() {
        let implement = stage(.implement), qa = stage(.qualityAssurance)
        let pipeline = DeliveryPipeline(stages: [implement, qa])
        let assignments = [
            attempt(implement, .completed), attempt(qa, .failed),
            attempt(implement, .completed), attempt(qa, .queued),
        ]
        #expect(DeliveryPipelineSchedule.isSuperseded(assignments[1], in: assignments))
        #expect(DeliveryPipelineSchedule.nextAssignment(in: assignments)?.id == assignments[3].id)
        #expect(DeliveryPipelineSchedule.finalStatus(pipeline, assignments: assignments) == .needsAttention)

        let done = Array(assignments.dropLast()) + [attempt(qa, .completed)]
        #expect(DeliveryPipelineSchedule.finalStatus(pipeline, assignments: done) == .completed)
        let progress = DeliveryPipelineSchedule.progress(of: pipeline, assignments: done)
        #expect(progress.map(\.state) == [.passed, .passed])
        #expect(progress.map(\.attempts) == [2, 2])
    }

    @Test("Stage prompts carry earlier results, rework findings, and the verdict instruction")
    func prompts() {
        let plan = stage(.plan), implement = stage(.implement), qa = stage(.qualityAssurance)
        let pipeline = DeliveryPipeline(stages: [plan, implement, qa])
        let assignments = [
            attempt(plan, .completed, reason: "Plan: touch Export.swift"),
            attempt(implement, .completed),
            attempt(qa, .failed, reason: "Missing escape\nSTAGE RESULT: FAIL"),
            attempt(implement, .queued),
        ]
        let implementPrompt = DeliveryStagePrompt.render(stage: implement, pipeline: pipeline, goal: "Add export", assignments: assignments)
        #expect(implementPrompt.contains("Plan: touch Export.swift"))
        #expect(implementPrompt.contains("Missing escape"))
        #expect(!implementPrompt.contains("End your answer"))

        let qaPrompt = DeliveryStagePrompt.render(stage: qa, pipeline: pipeline, goal: "Add export", assignments: assignments)
        #expect(qaPrompt.contains("STAGE RESULT: PASS"))
        #expect(qaPrompt.contains("Plan → Engineer → QA"))
    }

    @Test("Assignments saved before stages existed decode without a stage")
    func legacyAssignment() throws {
        let data = try JSONEncoder().encode(attempt(stage(.implement), .queued))
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document.removeValue(forKey: "deliveryStageID")
        let decoded = try JSONDecoder().decode(AgentAssignment.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(decoded.deliveryStageID == nil)
    }
}
