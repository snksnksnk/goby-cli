import Foundation
import GobyDomain
import Testing

struct MapActivityReflectionTests {
    private let project = LabProject(
        id: "activity-project",
        name: "Activity Project",
        rootURL: URL(fileURLWithPath: "/tmp/activity-project"),
        platforms: [.macOS],
        isGitRepository: true
    )

    @Test("A live provider task always marks its project but not every agent")
    func rootTaskMarksOnlyProject() {
        let fixture = makeLab()
        let projection = MapActivityReflectionProjection(
            providerID: .codex,
            lab: fixture.lab,
            tasks: [task(role: nil, status: .working)]
        )

        #expect(projection.projects[project.id]?.status == .working)
        #expect(projection.projects[project.id]?.taskCount == 1)
        #expect(projection.agents.isEmpty)
        #expect(projection.agentTargetsByTask.isEmpty)
    }

    @Test("A normalized provider role marks the exact logical agent binding")
    func roleMarksExactAgent() throws {
        let fixture = makeLab()
        let activity = task(role: "security_baseline", status: .working)
        let projection = MapActivityReflectionProjection(
            providerID: .codex,
            lab: fixture.lab,
            tasks: [activity]
        )
        let target = AgentRouteTarget(
            providerID: .codex,
            agentID: fixture.securityAgent.id,
            projectID: project.id
        )

        #expect(projection.agents[target]?.status == .working)
        #expect(projection.agents[target]?.latestTaskTitle == "Audit the release")
        #expect(projection.agentTargetsByTask[activity.identity] == target)
    }

    @Test("A waiting task takes precedence over working activity")
    func waitingTakesPrecedence() {
        let fixture = makeLab()
        let projection = MapActivityReflectionProjection(
            providerID: .codex,
            lab: fixture.lab,
            tasks: [
                task(id: "working", role: "Security Baseline", status: .working),
                task(id: "waiting", role: "Security Baseline", status: .waitingForInput)
            ]
        )
        let target = AgentRouteTarget(
            providerID: .codex,
            agentID: fixture.securityAgent.id,
            projectID: project.id
        )

        #expect(projection.projects[project.id]?.status == .waitingForApproval)
        #expect(projection.agents[target]?.status == .waitingForApproval)
    }

    @Test("Terminal provider history does not leave map nodes active")
    func terminalTasksAreIgnored() {
        let fixture = makeLab()
        let completed = task(
            id: "completed",
            role: "Security Baseline",
            status: .completed
        )
        let projection = MapActivityReflectionProjection(
            providerID: .codex,
            lab: fixture.lab,
            tasks: [
                task(id: "saved", role: "Security Baseline", status: .saved),
                completed,
                task(id: "failed", role: "Security Baseline", status: .failed)
            ]
        )

        #expect(projection.projects.isEmpty)
        #expect(projection.agents.isEmpty)
        #expect(
            projection.agentTargetsByTask[completed.identity]?.agentID
                == fixture.securityAgent.id
        )
    }

    @Test("A project-scoped binding cannot claim another project's task")
    func projectScopePreventsCrossProjectAttribution() {
        let fixture = makeLab()
        let otherProject = LabProject(
            id: "other-project",
            name: "Other Project",
            rootURL: URL(fileURLWithPath: "/tmp/other-project"),
            platforms: [.macOS],
            isGitRepository: true
        )
        let crossProjectTask = ProviderTaskActivity(
            identity: ProviderTaskIdentity(providerID: .codex, nativeID: "cross-project"),
            projectID: otherProject.id,
            title: "Other work",
            status: .working,
            updatedAt: .now,
            agentRole: "Security Baseline"
        )
        let lab = LabSnapshot(
            projects: [project, otherProject],
            agents: fixture.lab.agents,
            providerBindings: fixture.lab.providerBindings
        )
        let projection = MapActivityReflectionProjection(
            providerID: .codex,
            lab: lab,
            tasks: [crossProjectTask]
        )

        #expect(projection.projects[otherProject.id]?.status == .working)
        #expect(projection.agents.isEmpty)
    }

    private func makeLab() -> (lab: LabSnapshot, securityAgent: AgentProfile) {
        let securityAgent = AgentProfile(
            id: "security-baseline",
            name: "Security Baseline",
            summary: "Reviews the release",
            capabilities: [.security],
            scope: .project(project.id),
            codexRegistrationKey: "security_baseline"
        )
        let researchAgent = AgentProfile(
            id: "research",
            name: "Research",
            summary: "Researches options",
            capabilities: [.research],
            scope: .project(project.id),
            codexRegistrationKey: "research"
        )
        return (
            LabSnapshot(projects: [project], agents: [securityAgent, researchAgent]),
            securityAgent
        )
    }

    private func task(
        id: String = "live-task",
        role: String?,
        status: ProviderTaskStatus
    ) -> ProviderTaskActivity {
        ProviderTaskActivity(
            identity: ProviderTaskIdentity(providerID: .codex, nativeID: id),
            projectID: project.id,
            title: "Audit the release",
            status: status,
            updatedAt: .now,
            agentRole: role
        )
    }
}
