import Foundation
import GobyApplication
@testable import GobyCLIKit
import GobyDomain
import Testing

@Suite("Goby session views")
struct SessionViewsTests {
    private let state = GADPairedContinuationFixture.projection
    private let views = GobySessionViews(style: .plain, now: GADPairedContinuationFixture.timestamp)

    @Test("Every catalog view renders without escape sequences in plain style")
    func plainViewsArePlain() {
        let rendered = [
            views.overview(state), views.map(state), views.projects(state),
            views.agents(state, project: nil), views.runs(state, project: nil), views.automations(state),
            views.providers(state, selectedProvider: .codex, model: nil),
            views.models(state, provider: .codex, selected: nil),
            views.instructions(state), views.resources(state), views.groups(state),
            views.handoffs(state), views.health(state),
        ]
        for view in rendered {
            #expect(!view.isEmpty)
            #expect(!view.contains("\u{1B}["))
        }
    }

    @Test("The map lists every project with its agents and a status word")
    func mapShowsProjectsAndAgents() {
        let map = views.map(state)
        for project in state.projects { #expect(map.contains(project.name)) }
        for agent in views.agents(in: GADPairedContinuationFixture.projectID, state: state) {
            #expect(map.contains(agent.name))
        }
        let words = ["Available", "Working", "Queued", "Waiting for approval", "Paused", "Disabled", "Completed", "Failed", "Cancelled"]
        #expect(words.contains { map.contains($0) })
    }

    @Test("A conversation shows the request and the consolidated result")
    func conversationShowsRequestAndResult() throws {
        let run = try #require(state.runs.first)
        let conversation = views.conversation(run, state: state)
        #expect(conversation.contains(run.goal))
        #expect(conversation.contains(run.status.displayName))
    }

    @Test("Slash commands are recognized, paths are not")
    func slashCommandDetection() {
        #expect(GobyTerminalWorkflow.isSlashCommand("/model"))
        #expect(GobyTerminalWorkflow.isSlashCommand("/agents web"))
        #expect(!GobyTerminalWorkflow.isSlashCommand("/Users/me/notes.md summarize this"))
        #expect(!GobyTerminalWorkflow.isSlashCommand("fix the /login route"))
        #expect(!GobyTerminalWorkflow.isSlashCommand("/"))
    }

    @Test("Every session command has a usage line and help lists it")
    func helpListsEveryCommand() {
        let help = GobyTerminalPresenter(style: .plain, width: 100)
            .sessionHelp(GobyTerminalWorkflow.sessionCommands.map { ($0.usage, $0.summary) })
        for command in GobyTerminalWorkflow.sessionCommands {
            #expect(command.usage.hasPrefix("/" + command.name))
            #expect(help.contains(command.usage))
        }
    }

    @Test("Relative times read naturally")
    func relativeTimes() {
        let now = GADPairedContinuationFixture.timestamp
        #expect(views.relative(now.addingTimeInterval(-120)) == "2m ago")
        #expect(views.relative(now.addingTimeInterval(3 * 3_600)) == "in 3h")
        #expect(views.relative(now) == "now")
    }
}
