import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

struct ProjectGroupPersistenceTests {
    @Test("A project group survives a persistent-store relaunch")
    func groupSurvivesRelaunch() async throws {
        let directory = temporaryDirectory("relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = makeProjects()
        let group = makeGroup(projects: projects)
        let writer = PersistentStore(directoryURL: directory)

        try await writer.register(projects: projects, agents: [])
        try await writer.saveProjectGroup(group)

        let restored = try await PersistentStore(directoryURL: directory).snapshot()
        #expect(restored.projectGroups == [group])
        #expect(restored.projects.count == projects.count)
    }

    @Test("A version-one catalog without projectGroups migrates as an empty list")
    func legacyCatalogDefaultsToNoGroups() async throws {
        let directory = temporaryDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PersistentStore(directoryURL: directory)
        try await writer.register(projects: makeProjects(), agents: [])
        let catalogURL = directory.appending(path: "catalog.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        object.removeValue(forKey: "projectGroups")
        try JSONSerialization.data(withJSONObject: object).write(to: catalogURL, options: .atomic)

        let restored = try await PersistentStore(directoryURL: directory).snapshot()
        #expect(restored.projectGroups.isEmpty)
        #expect(restored.projects.count == 3)
    }

    @Test("Removing members updates then dissolves a project group without touching other folders")
    func projectRemovalMaintainsGroupInvariant() async throws {
        let directory = temporaryDirectory("removal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = makeProjects()
        let store = PersistentStore(directoryURL: directory)
        try await store.register(projects: projects, agents: [])
        try await store.saveProjectGroup(makeGroup(projects: projects))

        try await store.removeProject(id: projects[2].id)
        var snapshot = try await store.snapshot()
        #expect(snapshot.projectGroups.first?.projectIDs == [projects[0].id, projects[1].id])
        #expect(snapshot.projects.count == 2)

        try await store.removeProject(id: projects[1].id)
        snapshot = try await store.snapshot()
        #expect(snapshot.projectGroups.isEmpty)
        #expect(snapshot.projects.map(\.id) == [projects[0].id])
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "goby-project-groups-\(suffix)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeProjects() -> [LabProject] {
        [
            project(id: "frontend", name: "Frontend", platform: .web),
            project(id: "backend", name: "Backend", platform: .backend),
            project(id: "worker", name: "Worker", platform: .backend)
        ]
    }

    private func makeGroup(projects: [LabProject]) -> ProjectGroup {
        ProjectGroup(
            id: "product",
            name: "Pyxida Manager",
            members: [
                ProjectGroupMember(projectID: projects[0].id, role: .frontend),
                ProjectGroupMember(projectID: projects[1].id, role: .backend),
                ProjectGroupMember(projectID: projects[2].id, role: .service)
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
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
