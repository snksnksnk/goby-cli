import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

@Suite("Projection history budget")
struct ProjectionHistoryBudgetTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("Small history keeps complete results without a window notice")
    func smallHistoryIsUnchanged() {
        let projection = makeProjection(runs: [run("small", bytes: 2_000)])
        #expect(ProjectionHistoryBudget.apply(
            to: projection, totalRunCount: 1, totalOccurrenceCount: 0
        ) == projection)
    }

    @Test("Budget preserves active work and approval targets ahead of newer history")
    func operationalRecordsSurvive() {
        let active = run("active", status: .running, bytes: 60_000)
        let approved = run("approval-target", bytes: 60_000)
        let history = (0..<20).map { run("history-\($0)", bytes: 60_000, age: -Double($0 + 1)) }
        let approval = GADApprovalProjection(
            id: "pending", runID: approved.id, assignmentID: "assignment", kind: .command,
            summary: "Review", details: nil, actions: [.decline], approvalSessionID: nil,
            expiresAt: now.addingTimeInterval(100)
        )
        let original = makeProjection(runs: history + [active, approved], approvals: [approval])
        let result = ProjectionHistoryBudget.apply(
            to: original, totalRunCount: original.runs.count, totalOccurrenceCount: 0
        )
        #expect(result.runs.contains(active))
        #expect(result.runs.contains(approved))
        #expect(result.approvals == [approval])
        #expect(result.runs.count < original.runs.count)
        #expect(result.host.omittedHistoryRunCount == original.runs.count - result.runs.count)
        for retained in result.runs {
            #expect(original.runs.first(where: { $0.id == retained.id }) == retained)
        }
    }

    @Test("Automation history retains its run targets together and keeps active occurrences")
    func automationReferencesRemainUsable() {
        let runs = (0..<20).map { run("run-\($0)", bytes: 60_000, age: Double($0)) }
        let occurrences = runs.enumerated().map { index, run in
            occurrence("occurrence-\(index)", runID: run.id,
                       status: index == 19 ? .needsAttention : .completed,
                       age: Double(index))
        }
        let result = ProjectionHistoryBudget.apply(
            to: makeProjection(runs: runs, occurrences: occurrences),
            totalRunCount: runs.count, totalOccurrenceCount: occurrences.count
        )
        #expect(result.automations.occurrences.contains(occurrences[19]))
        #expect(result.runs.contains(runs[19]))
        #expect(result.automations.occurrences.count < occurrences.count)
        #expect(result.host.omittedAutomationOccurrenceCount == occurrences.count - result.automations.occurrences.count)
        let retainedIDs = Set(result.runs.map(\.id))
        for occurrence in result.automations.occurrences {
            #expect(Set(occurrence.attempts.compactMap(\.runID)).isSubset(of: retainedIDs))
        }
    }

    @Test("An active automation keeps its older run beyond the initial history count limit")
    func builderKeepsOlderOperationalReference() {
        let records = (0..<270).map { index in
            let id = RunID(rawValue: "run-\(index)")
            return RunRecord(
                id: id, plan: .init(id: id, interpretedGoal: "Review \(index)", routes: [], risk: .readOnly, confidence: 1),
                status: .completed, assignments: [], outcome: "Result \(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index))
            )
        }
        let active = occurrence("active", runID: records[0].id, status: .needsAttention)
        let result = RemoteProjectionBuilder().build(
            host: host, revision: .zero, lab: .empty, runs: records,
            automations: .init(occurrences: [active]), approvals: [], resources: [],
            codexTasks: [], account: nil, health: .init(checks: []), generatedAt: now
        )
        #expect(result.runs.contains(where: { $0.id == records[0].id }))
        #expect(result.automations.occurrences.first?.attempts.first?.runID == records[0].id)
        #expect(result.host.omittedHistoryRunCount == records.count - result.runs.count)
    }

    private var host: GADHostProjection {
        .init(id: HostID(rawValue: "fixture"), displayName: "Mac", reachability: .online, lastUpdatedAt: now)
    }

    private func makeProjection(
        runs: [GADRunProjection], approvals: [GADApprovalProjection] = [],
        occurrences: [AutomationOccurrence] = []
    ) -> DashboardProjection {
        .init(generatedAt: now, host: host, runs: runs, automations: .init(occurrences: occurrences), approvals: approvals)
    }

    private func run(_ id: String, status: RunStatus = .completed, bytes: Int, age: TimeInterval = 0) -> GADRunProjection {
        .init(id: RunID(rawValue: id), goal: "Review", risk: .readOnly, status: status,
              assignments: [], outcome: String(repeating: "x", count: bytes), journal: [],
              createdAt: now.addingTimeInterval(-age), updatedAt: now.addingTimeInterval(-age))
    }

    private func occurrence(
        _ id: String, runID: RunID, status: AutomationOccurrenceStatus, age: TimeInterval = 0
    ) -> AutomationOccurrence {
        .init(id: .init(rawValue: id), automationID: "automation", definitionRevision: 1,
              actions: [], trigger: .manual, scheduledAt: now, status: status,
              attempts: [.init(actionID: "action", runID: runID, status: .completed, updatedAt: now)],
              createdAt: now.addingTimeInterval(-age), updatedAt: now.addingTimeInterval(-age))
    }
}
