import GobyDomain
import Testing
@testable import GobyExperience

@Suite("Automation target choice policy")
struct AutomationTargetChoicePolicyTests {
    private let codexProject = AutomationTarget.project(
        providerID: .codex,
        projectID: "codex-project"
    )
    private let claudeProject = AutomationTarget.project(
        providerID: .claude,
        projectID: "claude-project"
    )
    private let removedAgent = AutomationTarget.agent(AgentRouteTarget(
        providerID: .githubCopilot,
        agentID: "removed-agent",
        projectID: "removed-project"
    ))

    @Test("An unavailable existing target remains selected and cannot masquerade as available")
    func preservesUnavailableTarget() {
        let choices = AutomationTargetChoicePolicy.choices(
            preserving: removedAgent,
            availableTargets: [codexProject, claudeProject]
        )

        #expect(choices.map(\.target) == [removedAgent, codexProject, claudeProject])
        #expect(choices.map(\.isAvailable) == [false, true, true])
        #expect(!AutomationTargetChoicePolicy.isAvailable(
            removedAgent,
            in: choices.filter(\.isAvailable).map(\.target)
        ))
    }

    @Test("Available targets retain their order without duplicating bindings")
    func deduplicatesAvailableTargets() {
        let choices = AutomationTargetChoicePolicy.choices(
            preserving: claudeProject,
            availableTargets: [codexProject, claudeProject, codexProject]
        )

        #expect(choices.map(\.target) == [codexProject, claudeProject])
        #expect(choices.allSatisfy { $0.isAvailable })
    }
}
