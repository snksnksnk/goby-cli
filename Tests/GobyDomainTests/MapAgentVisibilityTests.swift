import Foundation
import Testing
import GobyDomain

struct MapAgentVisibilityTests {
    @Test("Visibility belongs to one exact provider, agent, and project")
    func visibilityIsScopedAndReversible() {
        let target = AgentRouteTarget(providerID: .claude, agentID: "reviewer", projectID: "app")
        let node = GraphNodeID.agent(target.agentID, project: target.projectID)
        let hidden = MapLayoutOverrides.empty.settingAgentVisibility(target, isVisible: false)

        #expect(hidden.isAgentHidden(node, providerID: .claude))
        #expect(!hidden.isAgentHidden(node, providerID: .codex))
        #expect(!hidden.isAgentHidden(node, providerID: .githubCopilot))
        #expect(!hidden.isAgentHidden(.agent("reviewer", project: "other"), providerID: .claude))
        #expect(!hidden.isAgentHidden(.agent("writer", project: "app"), providerID: .claude))
        #expect(!hidden.isAgentHidden(.project("app"), providerID: .claude))
        #expect(!hidden.isAgentHidden(.codexTask("task", project: "app"), providerID: .claude))
        #expect(hidden.settingAgentVisibility(target, isVisible: true) == .empty)
        #expect(hidden.settingAgentVisibility(target, isVisible: false) == hidden)
    }

    @Test("Existing layout files keep their positions and show all agents")
    func legacyLayoutDecoding() throws {
        let legacy = MapLayoutOverrides(
            preferredProjectPositions: ["app": GraphPoint(x: 45, y: 72)]
        )
        let encoded = try JSONEncoder().encode(legacy)
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document.removeValue(forKey: "hiddenAgentTargets")
        let restored = try JSONDecoder().decode(
            MapLayoutOverrides.self, from: JSONSerialization.data(withJSONObject: document)
        )
        #expect(restored == legacy)
        #expect(restored.hiddenAgentTargets.isEmpty)
    }

    @Test("Moving, resetting, and refreshing layout preserve visibility across planes")
    func geometryDoesNotChangeVisibility() {
        let target = AgentRouteTarget(agentID: "reviewer", projectID: "app")
        let node = GraphNodeID.agent(target.agentID, project: target.projectID)
        let point = GraphPoint(x: 30, y: 40)
        let hidden = MapLayoutOverrides.empty.settingAgentVisibility(target, isVisible: false)
        let moved = hidden.preferring(node, at: point, relativeTo: .zero)
        #expect(moved.hiddenAgentTargets == [target])
        #expect(moved.moving(node, by: point).hiddenAgentTargets == [target])
        #expect(moved.moving(.project("app"), by: point).hiddenAgentTargets == [target])
        #expect(moved.resetting(node).hiddenAgentTargets == [target])
        #expect(moved.resetting(.project("app")).hiddenAgentTargets == [target])
        #expect(moved.resettingPositions() == hidden)
        let previous = GraphLayoutSnapshot(nodes: [
            GraphNode(id: .cluster(.web), kind: .cluster(.web, projectCount: 0, activeCount: 0, attentionCount: 0), position: .zero)
        ], edges: [])
        #expect(moved.rebased(preservingPositionsFrom: previous, to: .empty).hiddenAgentTargets == [target])
        #expect(moved.settingAgentVisibility(target, isVisible: true).preferredAgentPositionsRelativeToProject[node] == point)
    }
}
