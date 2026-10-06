import Foundation
import GobyApplication
import GobyDomain
import GobyExperience

/// Read-only terminal views of the host snapshot, matching the app's Home,
/// Map/List, Projects, Agents, Runs, Automations, Provider Connections,
/// Instructions, Shared Folders, Groups, Handoffs and Health screens.
/// Every status shows a symbol and a word. Provider and catalog text is
/// sanitized before styling, as in the presenter.
public struct GobySessionViews: Sendable {
    public let style: GobyTerminalStyle
    public let now: Date

    public init(style: GobyTerminalStyle, now: Date = .now) {
        self.style = style
        self.now = now
    }

    // MARK: Home

    public func overview(_ state: DashboardProjection) -> String {
        var lines = [heading("Home")]
        lines.append(label("providers") + state.providerAccounts.map { provider($0) }.joined(separator: style.dim(" · ")))
        let active = state.runs.filter { !$0.status.isFinished }
        if active.isEmpty {
            lines.append(label("working") + style.dim("nothing right now"))
        } else {
            lines.append(label("working"))
            for run in active.prefix(8) { lines.append("  " + runLine(run, state: state)) }
        }
        if !state.approvals.isEmpty {
            lines.append(label("approvals"))
            for approval in state.approvals {
                lines.append("  " + style.warning("! ") + safe(approval.summary) + style.dim(" · goby approve \(approval.id)"))
            }
        }
        if let plan = state.plan {
            lines.append(label("plan") + style.warning("! ") + safe(plan.goal) + style.dim(" · awaiting review · /run \(plan.id.rawValue)"))
        }
        let next = state.automations.definitions.filter { $0.state == .active }.compactMap { definition in
            definition.nextRunAt.map { (definition, $0) }
        }.min { $0.1 < $1.1 }
        if let (definition, date) = next {
            lines.append(label("next") + safe(definition.name) + style.dim(" · " + relative(date)))
        }
        let finished = state.runs.filter(\.status.isFinished).sorted { $0.updatedAt > $1.updatedAt }.prefix(3)
        if !finished.isEmpty {
            lines.append(label("recent"))
            for run in finished { lines.append("  " + runLine(run, state: state)) }
        }
        lines.append(label("catalog") + "\(state.projects.count) project(s) · \(state.agents.count) agent(s) · \(state.automations.definitions.count) automation(s)")
        return lines.joined(separator: "\n")
    }

    // MARK: Map / List

    /// The accessible List form of the network map: groups, then projects,
    /// then the agents that can work in each project.
    public func map(_ state: DashboardProjection) -> String {
        guard !state.projects.isEmpty else { return emptyNote("No projects yet. Run goby in a Git repository to register it.") }
        var lines = [heading("Map") + style.dim(" · \(state.projects.count) project(s) · \(state.agents.count) agent(s)")]
        var placed = Set<ProjectID>()
        var sections: [(title: String?, projects: [GADProjectProjection])] = []
        for group in state.projectGroups {
            let members = group.members.compactMap { member in state.projects.first { $0.id == member.projectID } }
            placed.formUnion(members.map(\.id))
            sections.append((safe(group.name), members))
        }
        let ungrouped = state.projects.filter { !placed.contains($0.id) }
        if !ungrouped.isEmpty { sections.append((sections.isEmpty ? nil : "Ungrouped", ungrouped)) }

        for (sectionIndex, section) in sections.enumerated() {
            let lastSection = sectionIndex == sections.count - 1
            var indent = ""
            if let title = section.title {
                lines.append(style.dim(lastSection ? "└─ " : "├─ ") + style.accent("◆ ") + style.bold(title))
                indent = lastSection ? "   " : "│  "
            }
            for (index, project) in section.projects.enumerated() {
                let lastProject = index == section.projects.count - 1
                lines.append(style.dim(indent + (lastProject ? "└─ " : "├─ ")) + projectLine(project, state: state))
                let agentIndent = indent + (lastProject ? "   " : "│  ")
                let agents = agents(in: project.id, state: state)
                if agents.isEmpty {
                    lines.append(style.dim(agentIndent + "└─ no agents · a temporary agent is created when needed"))
                }
                for (agentIndex, agent) in agents.enumerated() {
                    let branch = agentIndex == agents.count - 1 ? "└─ " : "├─ "
                    lines.append(style.dim(agentIndent + branch) + agentLine(agent, project: project.id, state: state))
                }
            }
        }
        let shared = state.agents.filter { if case .project = $0.scope { false } else { true } }
        if !shared.isEmpty {
            lines.append("")
            lines.append(style.bold("Available in every project"))
            for agent in shared { lines.append("  " + agentLine(agent, project: nil, state: state)) }
        }
        if !state.handoffLinks.isEmpty {
            lines.append("")
            lines.append(style.dim("\(state.handoffLinks.count) handoff link(s) · /handoffs"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Catalog

    public func projects(_ state: DashboardProjection) -> String {
        guard !state.projects.isEmpty else { return emptyNote("No projects yet. Run goby in a Git repository to register it.") }
        var lines = [heading("Projects") + style.dim(" · \(state.projects.count)")]
        for project in state.projects {
            lines.append("  " + projectLine(project, state: state))
            var facts = ["id \(project.id.rawValue)"]
            let runs = state.runs.filter { run in run.assignments.contains { $0.projectID == project.id } }
            if !runs.isEmpty { facts.append("\(runs.count) conversation(s)") }
            if !project.frameworks.isEmpty { facts.append(safe(project.frameworks.joined(separator: ", "))) }
            lines.append("    " + style.dim(facts.joined(separator: " · ")))
        }
        return lines.joined(separator: "\n")
    }

    public func agents(_ state: DashboardProjection, project filter: ProjectID?) -> String {
        let list = filter.map { agents(in: $0, state: state) } ?? state.agents
        guard !list.isEmpty else { return emptyNote("No agents here. Goby creates a temporary agent when a request needs one.") }
        var lines = [heading("Agents") + style.dim(" · \(list.count)")]
        for agent in list {
            lines.append("  " + agentLine(agent, project: filter, state: state))
            var facts = [scopeText(agent.scope, state: state)]
            if !agent.capabilities.isEmpty { facts.append(agent.capabilities.map(\.displayName).joined(separator: ", ")) }
            facts.append(agent.isActiveInCodex ? "active in Codex" : agent.hasDefinition ? "definition only" : "Goby only")
            let bindings = state.providerBindings.filter { $0.agentID == agent.id }
            if !bindings.isEmpty {
                facts.append(bindings.map { "\($0.providerID.displayName) \($0.state.displayName.lowercased())" }.joined(separator: ", "))
            }
            lines.append("    " + style.dim(facts.joined(separator: " · ")))
            if !agent.summary.isEmpty { lines.append("    " + style.dim(safe(agent.summary))) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Runs

    public func runs(_ state: DashboardProjection, project filter: ProjectID?, limit: Int = 20) -> String {
        let list = state.runs
            .filter { run in filter.map { id in run.assignments.contains { $0.projectID == id } } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
        guard !list.isEmpty else { return emptyNote("No conversations yet. Type a request to start one.") }
        var lines = [heading("Runs") + style.dim(" · \(list.count)" + (list.count > limit ? " · newest \(limit)" : ""))]
        for run in list.prefix(limit) { lines.append("  " + runLine(run, state: state)) }
        lines.append(style.dim("  /show <run> opens a conversation"))
        return lines.joined(separator: "\n")
    }

    /// One run as a conversation: request, routing line, agent turns, answer.
    public func conversation(_ run: GADRunProjection, state: DashboardProjection) -> String {
        var lines = [style.accent("› ") + style.bold(safe(run.goal))]
        let projects = Set(run.assignments.map(\.projectID)).compactMap { id in state.projects.first { $0.id == id }?.name }
        let providers = Set(run.assignments.map(\.providerID.displayName)).sorted()
        lines.append(style.dim("  " + ([statusText(run.status)] + projects.map(safe) + ["\(run.assignments.count) agent(s)"] + providers
            + [duration(from: run.createdAt, to: run.status.isFinished ? run.updatedAt : now)]).joined(separator: " · ")))
        for assignment in run.assignments {
            let agent = state.agents.first { $0.id == assignment.agentID }?.name
                ?? (assignment.agentID.rawValue.hasPrefix("temporary-agent") ? "Temporary agent" : assignment.agentID.rawValue)
            lines.append("")
            lines.append("  " + agentStatus(assignment.status) + " " + style.bold(safe(agent))
                + style.dim(" · " + assignment.providerID.displayName + (assignment.model.map { " · \($0)" } ?? "")))
            let steps = run.activity.filter { $0.assignmentID == assignment.id }
            let tools = steps.filter { $0.kind != "message" }
            if !tools.isEmpty {
                let failed = tools.filter { $0.status == "failed" || ($0.exitCode ?? 0) != 0 }
                lines.append(style.dim("    ⎿ \(tools.count) tool call(s)") + (failed.isEmpty ? "" : style.failure(" · \(failed.count) failed")))
            }
            for message in steps.filter({ $0.kind == "message" }).suffix(3) {
                let first = safe(message.title).split(separator: "\n").first.map(String.init) ?? ""
                lines.append(style.dim("    ⎿ ") + first)
            }
            if let reason = assignment.statusReason, !reason.isEmpty, ![.completed, .failed, .cancelled].contains(assignment.status) {
                lines.append("    " + style.dim(safe(reason)))
            }
        }
        lines.append("")
        let answer = GobyTerminalPresenter(style: style, width: 100).markdown(safe(WorkflowTextFormatter.result(run)))
        lines.append(answer.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        if let approval = state.approvals.first(where: { $0.runID == run.id }) {
            lines.append("")
            lines.append(style.warning("! ") + "Needs your OK: " + safe(approval.summary) + style.dim(" · /approve \(approval.id)"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Automations

    public func automations(_ state: DashboardProjection) -> String {
        let snapshot = state.automations
        guard !snapshot.definitions.isEmpty else {
            return emptyNote("No automations. Add one: goby automation add <name> <HH:MM> \"<request>\"")
        }
        var lines = [heading("Automations") + style.dim(" · \(snapshot.definitions.count)")]
        for definition in snapshot.definitions {
            let state = definition.state == .active ? style.success("● Active") : style.dim("‖ Paused")
            lines.append("  " + state + " " + style.bold(safe(definition.name)) + style.dim(" · " + schedule(definition.schedule)))
            var facts = ["id \(definition.id.rawValue)", "\(definition.actions.count) action(s)"]
            if let next = definition.nextRunAt, definition.state == .active { facts.append("next " + relative(next)) }
            if definition.automaticallyApproveRuntimeRequests { facts.append("runtime approvals granted") }
            lines.append("    " + style.dim(facts.joined(separator: " · ")))
            for action in definition.actions.prefix(3) {
                lines.append("    " + style.dim("⎿ ") + safe(action.instruction))
            }
            let occurrences = snapshot.occurrences.filter { $0.automationID == definition.id }
                .sorted { $0.scheduledAt > $1.scheduledAt }.prefix(3)
            for occurrence in occurrences {
                lines.append("    " + occurrenceText(occurrence.status) + style.dim(" · " + relative(occurrence.scheduledAt) + " · \(occurrence.id.rawValue)"))
            }
        }
        lines.append(style.dim("  goby automation pause|resume|run|delete <id> · review|cancel <occurrence>"))
        return lines.joined(separator: "\n")
    }

    // MARK: Providers and models

    public func providers(_ state: DashboardProjection, selectedProvider: AgentProviderID?, model: String?) -> String {
        var lines = [heading("Providers")]
        for account in state.providerAccounts {
            let selected = account.providerID == selectedProvider
            lines.append("  " + (selected ? style.accent("› ") : "  ") + provider(account) + (selected ? style.dim(" · this session") : ""))
            var facts: [String] = []
            if let plan = account.planName { facts.append(safe(plan)) }
            let shownModel = selected ? (model ?? account.selectedModel) : account.selectedModel
            facts.append("model " + (shownModel.map(safe) ?? "provider default"))
            if !account.availableModels.isEmpty { facts.append("\(account.availableModels.count) model(s) · /model") }
            lines.append("      " + style.dim(facts.joined(separator: " · ")))
        }
        return lines.joined(separator: "\n")
    }

    public func models(_ state: DashboardProjection, provider: AgentProviderID, selected: String?) -> String {
        let account = state.providerAccounts.first { $0.providerID == provider }
        let models = account?.availableModels ?? []
        var lines = [heading("Models") + style.dim(" · \(provider.displayName)")]
        lines.append("  " + (selected == nil ? style.accent("● ") : "○ ") + "default" + style.dim(" · " + (account?.selectedModel.map(safe) ?? "provider's choice")))
        for model in models {
            lines.append("  " + (model == selected ? style.accent("● ") : "○ ") + safe(model))
        }
        if models.isEmpty { lines.append(style.dim("  \(provider.displayName) has not reported its models yet. Try again after it connects.")) }
        lines.append(style.dim("  /model <name> chooses one for this session · /model default resets"))
        return lines.joined(separator: "\n")
    }

    // MARK: Other catalogs

    public func instructions(_ state: DashboardProjection) -> String {
        guard !state.instructions.isEmpty else { return emptyNote("No instruction packs. Create them in the Goby app's Instructions screen.") }
        var lines = [heading("Instructions") + style.dim(" · \(state.instructions.count)")]
        for pack in state.instructions {
            let enabled = pack.isEnabled ? style.success("● On ") : style.dim("○ Off")
            lines.append("  " + enabled + " " + style.bold(safe(pack.name)) + style.dim(" · v\(pack.version) · " + instructionScope(pack.scope, state: state)))
        }
        return lines.joined(separator: "\n")
    }

    public func resources(_ state: DashboardProjection) -> String {
        guard !state.resources.isEmpty else { return emptyNote("No shared folders registered.") }
        var lines = [heading("Shared folders") + style.dim(" · \(state.resources.count)")]
        for resource in state.resources {
            let enabled = resource.isEnabled ? style.success("● On ") : style.dim("○ Off")
            lines.append("  " + enabled + " " + style.bold(safe(resource.name)) + style.dim(" · " + resource.access.displayName.lowercased() + " · id \(resource.id.rawValue)"))
        }
        return lines.joined(separator: "\n")
    }

    public func groups(_ state: DashboardProjection) -> String {
        guard !state.projectGroups.isEmpty else { return emptyNote("No project groups. Projects are shown individually in /map.") }
        var lines = [heading("Groups") + style.dim(" · \(state.projectGroups.count)")]
        for group in state.projectGroups {
            lines.append("  " + style.accent("◆ ") + style.bold(safe(group.name)))
            for member in group.members {
                let name = state.projects.first { $0.id == member.projectID }?.name ?? member.projectID.rawValue
                lines.append("    " + safe(name) + style.dim(" · " + String(describing: member.role)))
            }
        }
        return lines.joined(separator: "\n")
    }

    public func handoffs(_ state: DashboardProjection) -> String {
        guard !state.handoffLinks.isEmpty else { return emptyNote("No handoff links.") }
        var lines = [heading("Handoffs") + style.dim(" · \(state.handoffLinks.count)")]
        for link in state.handoffLinks {
            let enabled = link.isEnabled ? style.success("●") : style.dim("○")
            lines.append("  " + enabled + " " + endpoint(link.source, state: state) + style.dim(" → ") + endpoint(link.destination, state: state))
            if !link.purpose.isEmpty { lines.append("    " + style.dim(safe(link.purpose))) }
        }
        return lines.joined(separator: "\n")
    }

    public func health(_ state: DashboardProjection) -> String {
        guard !state.health.isEmpty else { return emptyNote("No health checks have run yet.") }
        var lines = [heading("Health")]
        for check in state.health {
            let mark: String = switch check.status {
            case .passed: style.success("✓ Passed ")
            case .warning: style.warning("! Warning")
            case .failed: style.failure("✗ Failed ")
            }
            lines.append("  " + mark + " " + style.bold(check.kind.displayName) + style.dim(" · " + safe(check.summary)))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Building blocks

    func agents(in project: ProjectID, state: DashboardProjection) -> [GADAgentProjection] {
        state.agents.filter { agent in
            if case let .project(id) = agent.scope { return id == project }
            return false
        }
    }

    private func projectLine(_ project: GADProjectProjection, state: DashboardProjection) -> String {
        var facts = project.platforms.map(\.displayName)
        if project.isGitRepository { facts.append("git") }
        if project.isTrusted == true { facts.append("trusted") }
        let busy = state.runs.contains { run in !run.status.isFinished && run.assignments.contains { $0.projectID == project.id } }
        let mark = busy ? style.accent("● ") : style.dim("○ ")
        return mark + style.bold(safe(project.name)) + (facts.isEmpty ? "" : style.dim(" · " + facts.joined(separator: ", ")))
    }

    private func agentLine(_ agent: GADAgentProjection, project: ProjectID?, state: DashboardProjection) -> String {
        let active = state.runs.filter { !$0.status.isFinished }.flatMap { run in
            run.assignments.filter { $0.agentID == agent.id && (project == nil || $0.projectID == project) }.map { (run, $0) }
        }
        let status: String
        var detail = ""
        if let (run, assignment) = active.first {
            status = agentStatus(assignment.status)
            detail = style.dim(" · " + safe(run.goal))
        } else if !agent.isEnabled {
            status = style.dim("− Disabled")
        } else {
            status = style.dim("○ Available")
        }
        return status + " " + safe(agent.name) + detail
    }

    private func runLine(_ run: GADRunProjection, state: DashboardProjection) -> String {
        let project = run.assignments.first.flatMap { assignment in state.projects.first { $0.id == assignment.projectID }?.name }
        let meta = [project.map(safe), relative(run.createdAt), String(run.id.rawValue.prefix(8))].compactMap { $0 }
        return statusText(run.status) + " " + String(safe(run.goal).prefix(60)) + style.dim(" · " + meta.joined(separator: " · "))
    }

    private func provider(_ account: GADProviderAccountProjection) -> String {
        let name = account.providerID.displayName
        return switch account.connectionState {
        case .connected: style.success("✓ ") + name
        case .connecting, .notChecked: style.dim("◌ ") + name + style.dim(" checking")
        case .needsAuthentication: style.warning("! ") + name + style.dim(" sign in: goby login \(account.providerID == .githubCopilot ? "copilot" : account.providerID.rawValue)")
        case .disconnected: style.dim("○ ") + name + style.dim(" off")
        case .unavailable: style.dim("− ") + name + style.dim(" unavailable")
        case .failed: style.failure("✗ ") + name + style.dim(" failed")
        }
    }

    func statusText(_ status: RunStatus) -> String {
        let text = WorkflowTextFormatter.status(status)
        return switch status {
        case .completed: style.success(text)
        case .failed: style.failure(text)
        case .needsAttention: style.warning(text)
        case .running: style.accent(text)
        default: style.dim(text)
        }
    }

    private func agentStatus(_ status: AgentStatus) -> String {
        let text: String = switch status {
        case .available: "○ "
        case .queued: "◌ "
        case .working: "● "
        case .waitingForApproval: "! "
        case .paused: "‖ "
        case .completed: "✓ "
        case .failed: "✗ "
        case .cancelled: "− "
        }
        let full = text + status.displayName
        return switch status {
        case .working: style.accent(full)
        case .waitingForApproval: style.warning(full)
        case .completed: style.success(full)
        case .failed: style.failure(full)
        default: style.dim(full)
        }
    }

    private func occurrenceText(_ status: AutomationOccurrenceStatus) -> String {
        switch status {
        case .queued: style.dim("◌ Queued")
        case .running: style.accent("● Running")
        case .needsAttention: style.warning("! Needs review")
        case .completed: style.success("✓ Completed")
        case .failed: style.failure("✗ Failed")
        case .cancelled: style.dim("− Cancelled")
        }
    }

    private func scopeText(_ scope: GADAgentScopeProjection, state: DashboardProjection) -> String {
        switch scope {
        case .global: "personal"
        case .union: "all projects"
        case let .project(id): "project " + safe(state.projects.first { $0.id == id }?.name ?? id.rawValue)
        }
    }

    private func instructionScope(_ scope: InstructionScope, state: DashboardProjection) -> String {
        switch scope {
        case .allProjects: "all projects"
        case let .platform(platform): platform.displayName + " projects"
        case let .projects(ids): ids.compactMap { id in state.projects.first { $0.id == id }?.name }.map(safe).sorted().joined(separator: ", ")
        }
    }

    private func endpoint(_ endpoint: GADHandoffEndpointProjection, state: DashboardProjection) -> String {
        let agent = state.agents.first { $0.id == endpoint.agentID }?.name ?? endpoint.agentID.rawValue
        let project = state.projects.first { $0.id == endpoint.projectID }?.name ?? endpoint.projectID.rawValue
        return safe(agent) + style.dim(" (\(safe(project)), \(endpoint.providerID.displayName))")
    }

    private func schedule(_ schedule: AutomationSchedule) -> String {
        let time = String(format: "%02d:%02d", schedule.cadence.hour, schedule.cadence.minute)
        switch schedule.cadence {
        case .daily: return "daily \(time)"
        case let .weekly(weekday, _, _):
            let names = Calendar.current.weekdaySymbols
            let day = (1...7).contains(weekday) ? names[weekday - 1] : "day \(weekday)"
            return "\(day)s \(time)"
        }
    }

    func relative(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        let magnitude = abs(seconds)
        let amount: String = switch magnitude {
        case ..<60: "\(magnitude)s"
        case ..<3_600: "\(magnitude / 60)m"
        case ..<86_400: "\(magnitude / 3_600)h"
        default: "\(magnitude / 86_400)d"
        }
        if magnitude < 5 { return "now" }
        return seconds < 0 ? "\(amount) ago" : "in \(amount)"
    }

    private func duration(from start: Date, to end: Date) -> String {
        GobyTerminalPresenter.format(.seconds(max(0, end.timeIntervalSince(start))))
    }

    private func heading(_ text: String) -> String { style.bold(text) }
    private func label(_ text: String) -> String { "  " + style.dim(text.padding(toLength: 10, withPad: " ", startingAt: 0)) }
    private func emptyNote(_ text: String) -> String { style.dim("  " + text) }
    private func safe(_ text: String) -> String { WorkflowTextFormatter.terminalSafe(text) }
}
