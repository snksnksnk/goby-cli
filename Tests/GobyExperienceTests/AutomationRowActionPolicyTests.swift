import GobyDomain
import Testing
@testable import GobyExperience

@Suite("Automation row action policy")
struct AutomationRowActionPolicyTests {
    private let automationID = AutomationID(rawValue: "automation")
    private let actionID = AutomationActionID(rawValue: "action")
    private let occurrenceID = AutomationOccurrenceID(rawValue: "occurrence")
    private let runID = RunID(rawValue: "run")

    @Test("A schedule with no unfinished occurrence can run now")
    func idleScheduleRunsNow() {
        #expect(AutomationRowActionPolicy.primaryAction(for: nil) == .runNow)
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .completed)
            ) == .runNow
        )
    }

    @Test("A prepared scope needing approval opens review")
    func preparedScopeOpensReview() {
        let attempt = AutomationActionAttempt(
            actionID: actionID,
            plan: plan(),
            status: .waitingForReview
        )
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .needsAttention, attempt: attempt)
            ) == .review(occurrenceID)
        )
    }

    @Test("A provider run needing attention opens that run")
    func providerAttentionOpensRun() {
        let attempt = AutomationActionAttempt(
            actionID: actionID,
            runID: runID,
            status: .needsAttention
        )
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .needsAttention, attempt: attempt)
            ) == .openRun(runID)
        )
    }

    @Test("A preparation failure without a run exposes recovery")
    func preparationFailureResolves() {
        let attempt = AutomationActionAttempt(
            actionID: actionID,
            status: .needsAttention,
            message: "The exact target is unavailable."
        )
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .needsAttention, attempt: attempt)
            ) == .resolve(occurrenceID)
        )
    }

    @Test("Active provider work opens its run and pre-stage work shows progress")
    func activeWorkDoesNotOfferRunNow() {
        let runningAttempt = AutomationActionAttempt(
            actionID: actionID,
            runID: runID,
            status: .running
        )
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .running, attempt: runningAttempt)
            ) == .openRun(runID)
        )
        #expect(
            AutomationRowActionPolicy.primaryAction(
                for: occurrence(status: .queued)
            ) == .progress
        )
    }

    private func occurrence(
        status: AutomationOccurrenceStatus,
        attempt: AutomationActionAttempt? = nil
    ) -> AutomationOccurrence {
        AutomationOccurrence(
            id: occurrenceID,
            automationID: automationID,
            definitionRevision: 1,
            actions: [action()],
            trigger: .manual,
            scheduledAt: .now,
            status: status,
            attempts: attempt.map { [$0] } ?? []
        )
    }

    private func action() -> AutomationAction {
        AutomationAction(
            id: actionID,
            instruction: "Research the release.",
            target: .project(
                providerID: .codex,
                projectID: ProjectID(rawValue: "project")
            )
        )
    }

    private func plan() -> RoutingPlan {
        RoutingPlan(
            interpretedGoal: "Research the release.",
            routes: [],
            risk: .medium,
            confidence: 1,
            warnings: []
        )
    }
}
