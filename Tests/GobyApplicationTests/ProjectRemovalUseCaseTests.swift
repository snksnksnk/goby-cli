import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct ProjectRemovalUseCaseTests {
    @Test("A completed project can be unregistered from Goby")
    func completedProjectCanBeRemoved() async throws {
        let project = makeProject()
        let run = makeRun(project: project, status: .completed)
        let repository = ProjectRemovalRepository(runs: [run])

        try await RemoveProjectUseCase(catalog: repository, runs: repository)(project: project)

        #expect(await repository.removedProjectID() == project.id)
    }

    @Test("An unfinished project run blocks catalog removal")
    func unfinishedRunBlocksRemoval() async {
        let project = makeProject()
        let run = makeRun(project: project, status: .ready)
        let repository = ProjectRemovalRepository(runs: [run])

        await #expect(throws: GobyApplicationError.projectHasUnfinishedRun(project.name)) {
            try await RemoveProjectUseCase(catalog: repository, runs: repository)(project: project)
        }
        #expect(await repository.removedProjectID() == nil)
    }

    private func makeProject() -> LabProject {
        LabProject(
            id: "removable-project",
            name: "Removable Project",
            rootURL: URL(fileURLWithPath: "/tmp/removable-project"),
            platforms: [.web],
            isGitRepository: true
        )
    }

    private func makeRun(project: LabProject, status: RunStatus) -> RunRecord {
        let agentID: AgentID = "removable-agent"
        let plan = RoutingPlan(
            id: RunID(rawValue: "removal-run-\(status.rawValue)"),
            interpretedGoal: "Test project removal",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agentID], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        return RunRecord(
            id: plan.id,
            plan: plan,
            status: status,
            assignments: [
                AgentAssignment(
                    runID: plan.id,
                    projectID: project.id,
                    agentID: agentID,
                    status: status == .completed ? .completed : .queued,
                    currentTask: "Test project removal"
                )
            ]
        )
    }
}

private actor ProjectRemovalRepository: ProjectCatalogManaging, RunRepository {
    private let runs: [RunRecord]
    private var removedID: ProjectID?

    init(runs: [RunRecord]) {
        self.runs = runs
    }

    func allRuns() -> [RunRecord] { runs }

    func save(_ run: RunRecord) {}

    func removeProject(id: ProjectID) {
        removedID = id
    }

    func removedProjectID() -> ProjectID? { removedID }
}
