import Foundation
import Testing
@testable import GobyDomain

struct RunOutcomeSummaryTests {
    @Test("Nine identical assignment failures produce one error with an affected count")
    func consolidatesRepeatedFailures() {
        let reason = "The prepared working copy failed its repository and path checks."
        let assignments = (0..<9).map { assignment("agent-\($0)", status: .failed, reason: reason) }
        #expect(RunOutcomeSummary.consolidate(assignments) == "9 assignments failed with the same error:\n\n\(reason)")
        let run = run(assignments, outcome: Array(repeating: reason, count: 9).joined(separator: "\n\n"))
        #expect(RunOutcomeSummary.display(for: run) == RunOutcomeSummary.consolidate(assignments))
        #expect(run.outcome?.components(separatedBy: reason).count == 10)
    }

    @Test("Distinct failures and successful results retain their original order and content")
    func preservesDistinctResults() {
        let assignments = [
            assignment("a", status: .failed, reason: "Unavailable"),
            assignment("b", status: .completed, reason: "Verified"),
            assignment("c", status: .failed, reason: "Different failure"),
            assignment("d", status: .failed, reason: "Unavailable"),
            assignment("e", status: .completed, reason: "Verified")
        ]
        #expect(RunOutcomeSummary.consolidate(assignments) == "2 assignments failed with the same error:\n\nUnavailable\n\nVerified\n\nDifferent failure\n\nVerified")
    }

    @Test("Custom outcomes and provider paragraphs are never deduplicated")
    func preservesCustomOutcome() {
        let assignments = [assignment("a", status: .failed, reason: "Error"), assignment("b", status: .failed, reason: "Error")]
        let custom = "Error\n\nError\n\nAdditional provider evidence"
        #expect(RunOutcomeSummary.display(for: run(assignments, outcome: custom)) == custom)
        #expect(RunOutcomeSummary.display(for: run(assignments, outcome: nil)) == nil)
        #expect(RunOutcomeSummary.consolidate([]) == nil)
    }

    private func assignment(_ id: String, status: AgentStatus, reason: String) -> AgentAssignment {
        AgentAssignment(
            id: AssignmentID(rawValue: id), runID: "run", projectID: "project",
            agentID: AgentID(rawValue: id), status: status, currentTask: "Review", statusReason: reason
        )
    }

    private func run(_ assignments: [AgentAssignment], outcome: String?) -> RunRecord {
        RunRecord(
            id: "run", plan: .init(interpretedGoal: "Review", routes: [], risk: .readOnly, confidence: 1),
            status: .failed, assignments: assignments, outcome: outcome
        )
    }
}
