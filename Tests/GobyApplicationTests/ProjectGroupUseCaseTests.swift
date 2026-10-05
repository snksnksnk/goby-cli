import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct ProjectGroupUseCaseTests {
    @Test("A valid project group is normalized and saved")
    func savesValidGroup() async throws {
        let repository = GroupCatalogStub(snapshot: lab())
        let proposed = ProjectGroup(
            id: "product",
            name: "  Pyxida Manager  ",
            members: [
                ProjectGroupMember(projectID: "backend", role: .backend),
                ProjectGroupMember(projectID: "frontend", role: .frontend)
            ]
        )

        let saved = try await SaveProjectGroupUseCase(catalog: repository, groups: repository)(proposed)

        #expect(saved.name == "Pyxida Manager")
        #expect(saved.members.map(\.projectID) == ["backend", "frontend"])
        #expect(await repository.savedGroup() == saved)
    }

    @Test("A project cannot belong to two logical products")
    func rejectsOverlappingMembership() async {
        let existing = ProjectGroup(
            id: "existing",
            name: "Existing Product",
            members: [
                ProjectGroupMember(projectID: "frontend", role: .frontend),
                ProjectGroupMember(projectID: "other", role: .service)
            ]
        )
        let repository = GroupCatalogStub(snapshot: lab(projectGroups: [existing]))
        let proposed = ProjectGroup(
            id: "new",
            name: "New Product",
            members: [
                ProjectGroupMember(projectID: "frontend", role: .frontend),
                ProjectGroupMember(projectID: "backend", role: .backend)
            ]
        )

        await #expect(throws: GobyApplicationError.projectAlreadyGrouped(
            projectName: "Frontend",
            groupName: "Existing Product"
        )) {
            _ = try await SaveProjectGroupUseCase(catalog: repository, groups: repository)(proposed)
        }
    }

    @Test("A logical product needs at least two distinct projects")
    func rejectsSingleProjectGroup() async {
        let repository = GroupCatalogStub(snapshot: lab())
        let proposed = ProjectGroup(
            name: "Incomplete",
            members: [ProjectGroupMember(projectID: "frontend", role: .frontend)]
        )

        await #expect(throws: GobyApplicationError.projectGroupNeedsMultipleProjects) {
            _ = try await SaveProjectGroupUseCase(catalog: repository, groups: repository)(proposed)
        }
    }

    private func lab(projectGroups: [ProjectGroup] = []) -> LabSnapshot {
        LabSnapshot(
            projects: [
                project(id: "frontend", name: "Frontend", platform: .web),
                project(id: "backend", name: "Backend", platform: .backend),
                project(id: "other", name: "Other", platform: .general)
            ],
            agents: [],
            projectGroups: projectGroups
        )
    }

    private func project(id: ProjectID, name: String, platform: ProjectPlatform) -> LabProject {
        LabProject(
            id: id,
            name: name,
            rootURL: URL(fileURLWithPath: "/tmp/\(id.rawValue)"),
            platforms: [platform],
            isGitRepository: true
        )
    }
}

private actor GroupCatalogStub: LabCatalogRepository, ProjectGroupCatalogManaging {
    private let value: LabSnapshot
    private var saved: ProjectGroup?
    private var removedID: ProjectGroupID?

    init(snapshot: LabSnapshot) { value = snapshot }
    func snapshot() -> LabSnapshot { value }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func saveProjectGroup(_ group: ProjectGroup) { saved = group }
    func removeProjectGroup(id: ProjectGroupID) { removedID = id }
    func savedGroup() -> ProjectGroup? { saved }
}
