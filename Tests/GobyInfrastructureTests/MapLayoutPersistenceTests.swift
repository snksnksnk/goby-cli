import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

struct MapLayoutPersistenceTests {
    @Test("Custom map positions survive a store relaunch")
    func mapLayoutSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-map-layout-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectID = ProjectID(rawValue: "project")
        let agentNode = GraphNodeID.agent(AgentID(rawValue: "agent"), project: projectID)
        let layout = MapLayoutOverrides(
            projectOffsets: [projectID: GraphPoint(x: 72, y: -31)],
            nodeOffsets: [agentNode: GraphPoint(x: -18, y: 24)]
        )

        try await PersistentStore(directoryURL: directory).saveMapLayout(layout)
        let restored = try await PersistentStore(directoryURL: directory).loadMapLayout()

        #expect(restored == layout)
        #expect(restored.offset(for: agentNode) == GraphPoint(x: 54, y: -7))
    }

    @Test("Agent visibility survives both legacy and desktop presentation store relaunches")
    func agentVisibilitySurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "goby-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = AgentRouteTarget(providerID: .githubCopilot, agentID: "reviewer", projectID: "app")
        let layout = MapLayoutOverrides.empty.settingAgentVisibility(target, isVisible: false)
        try await PersistentStore(directoryURL: directory).saveMapLayout(layout)
        #expect(try await PersistentStore(directoryURL: directory).loadMapLayout() == layout)

        let fileURL = directory.appending(path: "Presentation/map-layout.json")
        let repository = LocalMapLayoutRepository(fileURL: fileURL)
        #expect(try await repository.loadMapLayout() == .empty)
        try await repository.saveMapLayout(layout)
        let relaunched = LocalMapLayoutRepository(fileURL: fileURL)
        #expect(try await relaunched.loadMapLayout() == layout)
        try await relaunched.saveMapLayout(layout.settingAgentVisibility(target, isVisible: true))
        #expect(try await LocalMapLayoutRepository(fileURL: fileURL).loadMapLayout() == .empty)
        #expect(try await PersistentStore(directoryURL: directory).loadMapLayout() == layout,
                "Presentation saves must not write the operational host's layout file.")
    }

    @Test("A new store starts with the automatic map layout")
    func newStoreHasEmptyMapLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-empty-map-layout-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let layout = try await PersistentStore(directoryURL: directory).loadMapLayout()

        #expect(layout == .empty)
    }

    @Test("Preferred map coordinates survive a store relaunch")
    func preferredMapCoordinatesSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-preferred-map-layout-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = ProjectID(rawValue: "project")
        let agentNode = GraphNodeID.agent(AgentID(rawValue: "agent"), project: projectID)
        let projectPosition = GraphPoint(x: 420, y: -135)
        let layout = MapLayoutOverrides.empty
            .preferring(.project(projectID), at: projectPosition)
            .preferring(
                agentNode,
                at: GraphPoint(x: 515, y: -92),
                relativeTo: projectPosition
            )

        try await PersistentStore(directoryURL: directory).saveMapLayout(layout)
        let restored = try await PersistentStore(directoryURL: directory).loadMapLayout()

        #expect(restored == layout)
    }
}
