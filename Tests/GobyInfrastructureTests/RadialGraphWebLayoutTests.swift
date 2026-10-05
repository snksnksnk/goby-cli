import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

struct RadialGraphWebLayoutTests {
    @Test("Three hundred projects use bounded non-overlapping platform rings")
    func projectsUseBoundedPlatformRings() async throws {
        let projects = (0..<300).map { index in
            LabProject(
                id: ProjectID(rawValue: "radial-project-\(index)"),
                name: "Radial Project \(index)",
                rootURL: URL(fileURLWithPath: "/tmp/radial-project-\(index)"),
                platforms: [ProjectPlatform.allCases[index % ProjectPlatform.allCases.count]],
                isGitRepository: true
            )
        }

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: projects, agents: []),
            assignments: []
        )
        let points = try projects.map { project in
            try #require(graph.nodes.first(where: { $0.id == .project(project.id) })?.position)
        }
        let maximumRadius = points.map { hypot($0.x, $0.y) }.max() ?? 0
        var minimumDistance = Double.greatestFiniteMagnitude
        for firstIndex in points.indices {
            for secondIndex in points.indices where secondIndex > firstIndex {
                minimumDistance = min(
                    minimumDistance,
                    hypot(
                        points[firstIndex].x - points[secondIndex].x,
                        points[firstIndex].y - points[secondIndex].y
                    )
                )
            }
        }

        #expect(maximumRadius <= 1_800.001)
        #expect(minimumDistance >= 159.5)
        #expect(graph.nodes.filter { if case .cluster = $0.kind { true } else { false } }.count == ProjectPlatform.allCases.count)
    }

    @Test("Project children expand away from the Codex core")
    func childrenUseOutwardWebFan() async throws {
        let project = LabProject(
            id: "web-layout-project",
            name: "Web Layout",
            rootURL: URL(fileURLWithPath: "/tmp/web-layout"),
            platforms: [.web],
            isGitRepository: true
        )
        let agents = (0..<14).map { index in
            AgentProfile(
                id: AgentID(rawValue: "web-agent-\(index)"),
                name: "Web Agent \(index)",
                summary: "Web layout fixture",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [project], agents: agents),
            assignments: []
        )
        let projectPoint = try #require(
            graph.nodes.first(where: { $0.id == .project(project.id) })?.position
        )
        let childPoints = graph.nodes.compactMap { node -> GraphPoint? in
            guard case .agent = node.id else { return nil }
            return node.position
        }

        #expect(childPoints.count == agents.count)
        for point in childPoints {
            let branchX = point.x - projectPoint.x
            let branchY = point.y - projectPoint.y
            let outwardDotProduct = branchX * projectPoint.x + branchY * projectPoint.y
            #expect(outwardDotProduct > 0)
        }
    }

    @Test("Four full-size agent cards keep collision clearance")
    func fourAgentCardsDoNotOverlap() async throws {
        let project = LabProject(
            id: "collision-project",
            name: "Collision Project",
            rootURL: URL(fileURLWithPath: "/tmp/collision-project"),
            platforms: [.web],
            isGitRepository: true
        )
        let agents = (0..<4).map { index in
            AgentProfile(
                id: AgentID(rawValue: "collision-agent-\(index)"),
                name: "Collision Agent \(index)",
                summary: "Collision fixture",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }
        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [project], agents: agents),
            assignments: []
        )
        let projectPoint = try #require(
            graph.nodes.first(where: { $0.id == .project(project.id) })?.position
        )
        let childPoints = graph.nodes.compactMap { node -> GraphPoint? in
            guard case .agent = node.id else { return nil }
            return node.position
        }

        #expect(childPoints.count == 4)
        for point in childPoints {
            #expect(distance(point, projectPoint) >= 275.9)
        }
        for firstIndex in childPoints.indices {
            for secondIndex in childPoints.indices where secondIndex > firstIndex {
                #expect(distance(childPoints[firstIndex], childPoints[secondIndex]) >= 214)
            }
        }
    }

    @Test("Dense project clusters keep deterministic positions")
    func webLayoutIsStable() async {
        let projects = (0..<8).map { index in
            LabProject(
                id: ProjectID(rawValue: "project-\(index)"),
                name: "Project \(index)",
                rootURL: URL(fileURLWithPath: "/tmp/project-\(index)"),
                platforms: [index.isMultiple(of: 2) ? .web : .iOS],
                isGitRepository: true
            )
        }
        let agents = projects.flatMap { project in
            (0..<4).map { index in
                AgentProfile(
                    id: AgentID(rawValue: "\(project.id.rawValue)-agent-\(index)"),
                    name: "Agent \(index)",
                    summary: "Stable layout fixture",
                    capabilities: [.routing],
                    scope: .project(project.id)
                )
            }
        }
        let layout = RadialGraphLayout()

        let first = await layout.layout(
            lab: LabSnapshot(projects: projects, agents: agents),
            assignments: []
        )
        let second = await layout.layout(
            lab: LabSnapshot(projects: projects, agents: agents),
            assignments: []
        )

        #expect(first.nodes.map(\.position) == second.nodes.map(\.position))
    }

    @Test("Project-group members receive a visible membership link")
    func projectGroupAddsMembershipLink() async throws {
        let frontend = LabProject(
            id: "frontend",
            name: "Frontend",
            rootURL: URL(fileURLWithPath: "/tmp/frontend"),
            platforms: [.web],
            isGitRepository: true
        )
        let backend = LabProject(
            id: "backend",
            name: "Backend",
            rootURL: URL(fileURLWithPath: "/tmp/backend"),
            platforms: [.backend],
            isGitRepository: true
        )
        let group = ProjectGroup(
            name: "Product",
            members: [
                ProjectGroupMember(projectID: frontend.id, role: .frontend),
                ProjectGroupMember(projectID: backend.id, role: .backend)
            ]
        )

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [frontend, backend], agents: [], projectGroups: [group]),
            assignments: []
        )
        let edge = try #require(graph.edges.first(where: { $0.kind == .membership }))

        #expect(Set([edge.source, edge.destination]) == Set([
            GraphNodeID.project(frontend.id),
            GraphNodeID.project(backend.id)
        ]))
    }

    @Test("A live Codex role task attaches to its exact map agent")
    func codexRoleTaskAttachesToAgent() async throws {
        let project = LabProject(
            id: "codex-activity-project",
            name: "Codex Activity",
            rootURL: URL(fileURLWithPath: "/tmp/codex-activity"),
            platforms: [.macOS],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "release-review",
            name: "Release Review",
            summary: "Reviews releases",
            capabilities: [.release],
            scope: .project(project.id),
            codexRegistrationKey: "release_review"
        )
        let task = CodexTaskActivity(
            id: "live-codex-task",
            projectID: project.id,
            title: "Reviewing the release",
            status: .active,
            updatedAt: .now,
            isSubagent: true,
            agentRole: "release-review"
        )

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            assignments: [],
            codexTasks: [task]
        )

        let edge = try #require(graph.edges.first {
            $0.destination == .codexTask(task.id, project: project.id)
        })
        #expect(edge.source == .agent(agent.id, project: project.id))
        #expect(edge.kind == .activity)
    }

    private func distance(_ lhs: GraphPoint, _ rhs: GraphPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
