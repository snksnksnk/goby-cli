import Foundation
import Testing
@testable import GobyDomain

struct RunGroupingTests {
    @Test("Run statuses map to the Mac and iOS Home lanes; drafts have no lane")
    func lanes() {
        #expect(RunLane(.needsAttention) == .needsAttention)
        #expect(RunLane(.failed) == .needsAttention)
        #expect(RunLane(.ready) == .active)
        #expect(RunLane(.running) == .active)
        #expect(RunLane(.completed) == .recentlyCompleted)
        #expect(RunLane(.cancelled) == .recentlyCompleted)
        #expect(RunLane(.draft) == nil)
    }

    @Test("A run touches a project through its plan, snapshot, or assignments")
    func projectScope() {
        let routed = run("routed", updated: 30, routeProject: "atlas")
        let assigned = run("assigned", updated: 10, assignmentProject: "atlas")
        let snapshotted = run("snapshotted", updated: 20, snapshotProject: "atlas")
        let elsewhere = run("elsewhere", updated: 40, routeProject: "orbit")
        let runs = [assigned, elsewhere, snapshotted, routed]

        #expect(runs.touching("atlas").map(\.id) == ["routed", "snapshotted", "assigned"])
        #expect(runs.touching("orbit").map(\.id) == ["elsewhere"])
        #expect(runs.touching("missing").isEmpty)
    }

    @Test("Runs updated at the same moment keep a stable order")
    func stableTies() {
        let runs = [run("b", updated: 5, routeProject: "atlas"), run("a", updated: 5, routeProject: "atlas")]
        #expect(runs.touching("atlas").map(\.id) == ["a", "b"])
    }

    private func run(
        _ id: RunID,
        updated: TimeInterval,
        routeProject: ProjectID? = nil,
        assignmentProject: ProjectID? = nil,
        snapshotProject: ProjectID? = nil
    ) -> RunRecord {
        RunRecord(
            id: id,
            plan: .init(
                interpretedGoal: "Review",
                routes: routeProject.map { [ProjectRoute(projectID: $0, agentIDs: [], reason: "Matched")] } ?? [],
                risk: .readOnly,
                confidence: 1
            ),
            status: .completed,
            assignments: assignmentProject.map {
                [AgentAssignment(runID: id, projectID: $0, agentID: "agent", status: .completed, currentTask: "Review")]
            } ?? [],
            projectSnapshot: snapshotProject.map {
                [LabProject(id: $0, name: "Atlas", rootURL: URL(fileURLWithPath: "/tmp/atlas"), platforms: [.web], isGitRepository: true)]
            } ?? [],
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }
}
