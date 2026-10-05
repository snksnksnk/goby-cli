import GobyApplication
import GobyDomain
import Testing
@testable import GobyExperience

@Suite("Draft provider selection")
struct DraftProviderSelectionTests {
    @Test("An exact-only recipient retains its project when the provider changes")
    func exactOnlyScope() {
        let project = ProjectID(rawValue: "explicit-project")
        let draft = GADDraftProjection(agentTargets: [
            .init(providerID: .codex, agentID: .init(rawValue: "explicit-role"), projectID: project)
        ])
        let selected = draft.selectingProvider(.claude)
        #expect(selected.agentTargets.isEmpty)
        #expect(selected.projectIDs == [project])
    }

    @Test("Provider changes remove incompatible exact bindings without widening project scope", arguments: AgentProviderID.builtIn)
    func providerBoundary(provider: AgentProviderID) {
        let projects = [ProjectID(rawValue: "first-project"), ProjectID(rawValue: "second-project")]
        let targets = AgentProviderID.builtIn.flatMap { candidate in
            projects.map { project in
                AgentRouteTarget(providerID: candidate, agentID: .init(rawValue: "shared-role"), projectID: project)
            }
        }
        let draft = GADDraftProjection(
            revision: .zero.advanced(), text: "Keep the reviewed projects", providerID: .codex,
            model: "explicit-codex-model", platform: .iOS, projectIDs: projects,
            agentTargets: targets, groupID: .init(rawValue: "reviewed-group")
        )
        let selected = draft.selectingProvider(provider)
        #expect(selected.providerID == provider)
        #expect(selected.agentTargets == targets.filter { $0.providerID == provider })
        #expect(selected.model == (provider == .codex ? draft.model : nil))
        #expect(selected.text == draft.text)
        #expect(selected.projectIDs == projects)
        #expect(selected.groupID == draft.groupID)
        #expect(selected.platform == draft.platform)
        #expect(selected.revision == draft.revision)
        #expect(draft.agentTargets == targets)
    }
}
