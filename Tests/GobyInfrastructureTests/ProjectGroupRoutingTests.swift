import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct ProjectGroupRoutingTests {
    @Test("A logical product routes every member folder and excludes unrelated projects")
    func projectGroupRoutesAllMembers() async throws {
        let frontend = project(id: "frontend", platform: .web)
        let backend = project(id: "backend", platform: .backend)
        let unrelated = project(id: "unrelated", platform: .web)
        let group = ProjectGroup(
            name: "Pyxida Manager",
            members: [
                ProjectGroupMember(projectID: frontend.id, role: .frontend),
                ProjectGroupMember(projectID: backend.id, role: .backend)
            ]
        )
        let router = AgentProfile(
            id: "router",
            name: "Routing Agent",
            summary: "Coordinates product work",
            capabilities: [.routing],
            scope: .union
        )
        let lab = LabSnapshot(
            projects: [frontend, backend, unrelated],
            agents: [router],
            projectGroups: [group]
        )

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "coordinate this change", scope: .projects(group.projectIDs)),
            in: lab
        )

        #expect(Set(plan.routes.map(\.projectID)) == group.projectIDs)
        #expect(!plan.routes.contains { $0.projectID == unrelated.id })
        #expect(plan.routes.allSatisfy { $0.agentIDs == [router.id] })
    }

    @Test("Routing only selects agents configured on the requested provider plane")
    func routingRequiresRequestedProviderBinding() async throws {
        let project = project(id: "frontend", platform: .web)
        let agent = AgentProfile(
            id: "builder",
            name: "Builder",
            summary: "Builds the frontend",
            capabilities: [.web],
            scope: .project(project.id)
        )
        let codexOnly = LabSnapshot(projects: [project], agents: [agent])
        let request = RouteRequest(prompt: "Inspect the frontend", providerID: .claude)

        let unavailablePlan = try await DeterministicRouter().plan(for: request, in: codexOnly)
        #expect(unavailablePlan.routes.isEmpty)

        let claudeBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: agent.id,
            projectID: project.id,
            nativeID: "builder",
            capabilities: agent.capabilities
        )
        let configured = LabSnapshot(
            projects: [project],
            agents: [agent],
            providerBindings: [claudeBinding]
        )
        let availablePlan = try await DeterministicRouter().plan(for: request, in: configured)

        #expect(availablePlan.routes.count == 1)
        #expect(availablePlan.routes.first?.providerID == .claude)
        #expect(availablePlan.routes.first?.agentIDs == [agent.id])
    }

    private func project(id: ProjectID, platform: ProjectPlatform) -> LabProject {
        LabProject(
            id: id,
            name: id.rawValue.capitalized,
            rootURL: URL(fileURLWithPath: "/tmp/\(id.rawValue)"),
            platforms: [platform],
            isGitRepository: true
        )
    }
}
