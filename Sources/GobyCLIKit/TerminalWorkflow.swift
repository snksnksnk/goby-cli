import Darwin
import Foundation
import GobyApplication
import GobyDomain
import GobyExperience

public enum GobyCLIExitCode {
    public static func forError(_ error: any Error) -> Int32 {
        if let failure = error as? GADCommandFailure {
            return switch failure.disposition {
            case .rejectedStale, .rejectedExpired: 2
            case .rejectedPolicy, .rejectedCapability, .rejectedRevoked: 4
            case .failedRecoverable, .failedIndeterminate: 1
            case .accepted: 0
            }
        }
        if error is GobySocketError || error is GADHostIPCClientError { return 3 }
        if let error = error as? GobyTerminalError { return error.code }
        return 1
    }
    public static func forRun(_ status: RunStatus) -> Int32 {
        switch status {
        case .completed: 0
        case .failed, .cancelled: 1
        case .needsAttention, .draft, .ready, .running: 2
        }
    }
}

public struct GobyTerminalError: LocalizedError, Sendable {
    public let message: String
    public let code: Int32
    public init(_ message: String, code: Int32 = 2) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}

public struct GobyCLIOptions: Sendable {
    public let arguments: [String]
    public let json: Bool
    public let verbose: Bool
    public let yes: Bool
    public let storePath: String?
    public let providerID: AgentProviderID
    public let hasExplicitProvider: Bool
    public let stayAlive: Bool
    public init(_ input: [String]) throws {
        var args: [String] = []
        var json = false, verbose = false, yes = false
        var store: String?
        var provider = AgentProviderID.codex
        var explicitProvider = false
        var stayAlive = false
        var index = 0
        while index < input.count {
            let value = input[index]
            switch value {
            case "--": args += input.dropFirst(index + 1); index = input.count; continue
            case "--json": json = true
            case "--verbose": verbose = true
            case "--yes": yes = true
            case "--stay-alive": stayAlive = true
            case "--version": args = ["version"]
            case "--store", "--provider":
                index += 1
                guard index < input.count else { throw GobyTerminalError("\(value) needs a value.") }
                if value == "--store" { store = input[index] }
                else {
                    let selected = input[index] == "copilot" ? AgentProviderID.githubCopilot : AgentProviderID(rawValue: input[index])
                    guard AgentProviderID.builtIn.contains(selected) else {
                        throw GobyTerminalError("Choose codex, claude or copilot.", code: 4)
                    }
                    provider = selected; explicitProvider = true
                }
            case "--help", "-h": args = ["help"]
            default:
                guard !value.hasPrefix("--") else { throw GobyTerminalError("Unknown option \(value).") }
                args.append(value)
            }
            index += 1
        }
        arguments = args; self.json = json; self.verbose = verbose; self.yes = yes
        storePath = store; providerID = provider; hasExplicitProvider = explicitProvider; self.stayAlive = stayAlive
        guard !stayAlive || args == ["host", "run"] else { throw GobyTerminalError("--stay-alive is only valid with goby host run.", code: 4) }
    }
}

public struct GobyCLIOutput<Value: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let type: String
    public let data: Value
    public init(type: String, data: Value) { schemaVersion = 1; self.type = type; self.data = data }
}

/// Terminal I/O is injected so the same workflow runs in contract tests over
/// the real socket. JSON is newline-delimited, with a stable typed envelope.
public struct GobyTerminalIO: Sendable {
    public let interactive: Bool
    public let write: @Sendable (String) -> Void
    public let read: @Sendable (String) async -> String?
    public let readSecret: @Sendable (String) async -> String?
    public let authenticateOwner: @Sendable () async throws -> String
    /// Goby's terminal character. Plain unless an interactive colour terminal is detected.
    public let style: GobyTerminalStyle
    public init(interactive: Bool, write: @escaping @Sendable (String) -> Void,
                read: @escaping @Sendable (String) async -> String?,
                readSecret: @escaping @Sendable (String) async -> String? = { _ in nil },
                authenticateOwner: @escaping @Sendable () async throws -> String = { throw GobyTerminalError("Device-owner authentication is required.", code: 4) },
                style: GobyTerminalStyle = .plain) {
        self.interactive = interactive; self.write = write; self.read = read
        self.readSecret = readSecret; self.authenticateOwner = authenticateOwner
        self.style = interactive ? style : .plain
    }
    public static func standard() -> Self {
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        return .init(interactive: interactive,
              write: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
              read: { prompt in
                  FileHandle.standardError.write(Data(prompt.utf8))
                  return try? await GobySocketIO.offload { readLine() }
              }, readSecret: { prompt in
                  try? await GobySocketIO.offload {
                      guard let value = getpass(prompt) else { return nil }
                      defer { _ = memset(value, 0, strlen(value)) }
                      return String(cString: value)
                  }
              }, authenticateOwner: { try await GobyCLIEnvironment.authenticateOwner() },
              style: interactive ? .detect() : .plain)
    }
}

public actor GobyTerminalWorkflow {
    private let transport: any GADHostIPCTransporting
    private let options: GobyCLIOptions
    private let io: GobyTerminalIO
    private let directory: URL
    private let deviceID = DeviceID(rawValue: "cli-local-client")
    private let client: GADHostIPCGobyClient
    private var session: ClientSession?
    private let preferences: GobyCLIProjectPreferences?
    private let presenter: GobyTerminalPresenter
    private let spinner: GobySpinner
    private var providerName = "your agent"
    /// Session choices made with /provider and /model; they apply to new requests.
    private var sessionProvider: AgentProviderID?
    private var sessionModel: String?
    private var views: GobySessionViews { GobySessionViews(style: io.style) }
    /// Goby's character appears only in an interactive, colour-capable terminal.
    private var decorated: Bool { io.style.enabled && !options.json }

    public init(transport: any GADHostIPCTransporting, options: GobyCLIOptions,
                directory: URL, io: GobyTerminalIO, preferences: GobyCLIProjectPreferences? = nil) {
        self.transport = transport; self.options = options; self.directory = directory
        self.io = io; self.preferences = preferences
        client = GADHostIPCGobyClient(transport: transport, deviceID: deviceID)
        presenter = GobyTerminalPresenter(style: io.style)
        spinner = GobySpinner(style: io.style)
    }
    public func execute() async -> Int32 {
        do {
            session = try await client.connect()
            let code = try await perform(options.arguments)
            await client.disconnect()
            return code
        } catch {
            spinner.stop()
            await client.disconnect()
            let code = GobyCLIExitCode.forError(error)
            try? emit("error", data: CLIErrorOutput(message: error.localizedDescription, exitCode: code), text: error.localizedDescription,
                      styled: presenter.error(error.localizedDescription))
            return code
        }
    }
    private func perform(_ args: [String]) async throws -> Int32 {
        if let command = args.first {
            let bounds: ClosedRange<Int>?
            switch command {
            case "status", "projects", "diagnostics", "import-agents", "automations", "home", "map", "tree",
                 "providers", "instructions", "resources", "groups", "handoffs", "health": bounds = 1...1
            case "agents", "runs", "models", "branches", "show": bounds = 1...2
            case "automation": bounds = 3...Int.max
            case "run", "approve", "deny", "result", "diff", "log", "host", "commit", "push": bounds = 2...2
            case "use": bounds = 2...17
            case "watch", "pause", "resume", "cancel", "add": bounds = 1...2
            case "follow-up": bounds = 3...Int.max
            case "ask": bounds = 2...Int.max
            case "doctor", "login", "logout":
                throw GobyTerminalError("The \(command) subcommand belongs to a later CLI phase. Use goby help for implemented commands.", code: 4)
            default: bounds = nil
            }
            if let bounds, !bounds.contains(args.count) { throw GobyTerminalError("Check goby help for the \(command) command's arguments.") }
        }
        switch args.first {
        case "automations":
            let state = try await client.snapshot()
            let snapshot = state.automations
            let plainList = snapshot.definitions.map { "\($0.id.rawValue) · \($0.state.displayName) · \($0.name)" }.joined(separator: "\n")
            try emit("automations", data: snapshot, text: plainList.isEmpty ? GobySessionViews(style: .plain).automations(state) : plainList,
                     styled: views.automations(state))
            return 0
        case "home":
            let state = try await client.snapshot()
            try emit("home", data: CLIStatusOutput(plan: state.plan, runs: state.runs.map(CLIRunOutput.init), approvals: state.approvals),
                     text: GobySessionViews(style: .plain).overview(state), styled: views.overview(state))
            return 0
        case "map", "tree":
            let state = try await client.snapshot()
            try emit("map", data: CLIMapOutput(state), text: GobySessionViews(style: .plain).map(state), styled: views.map(state))
            return 0
        case "agents":
            let state = try await client.snapshot()
            let project = try args.count > 1 ? projectID(args[1], in: state) : nil
            let agents = project.map { views.agents(in: $0, state: state) } ?? state.agents
            try emit("agents", data: agents, text: GobySessionViews(style: .plain).agents(state, project: project), styled: views.agents(state, project: project))
            return 0
        case "runs":
            let state = try await client.snapshot()
            let project = try args.count > 1 ? projectID(args[1], in: state) : nil
            try emit("runs", data: state.runs.map(CLIRunOutput.init), text: GobySessionViews(style: .plain).runs(state, project: project), styled: views.runs(state, project: project))
            return 0
        case "show":
            let run = try await findRun(args.dropFirst().first)
            let state = try await client.snapshot()
            try emit("conversation", data: CLIRunOutput(run), text: GobySessionViews(style: .plain).conversation(run, state: state), styled: views.conversation(run, state: state))
            return 0
        case "providers":
            let state = try await providerSnapshot()
            let provider = try? await selectedProvider(in: state)
            try emit("providers", data: state.providerAccounts, text: GobySessionViews(style: .plain).providers(state, selectedProvider: provider, model: sessionModel),
                     styled: views.providers(state, selectedProvider: provider, model: sessionModel))
            return 0
        case "models":
            let state = try await providerSnapshot()
            let provider = try args.count > 1 ? Self.provider(named: args[1]) : try await selectedProvider(in: state)
            let models = state.providerAccounts.first { $0.providerID == provider }?.availableModels ?? []
            try emit("models", data: models, text: GobySessionViews(style: .plain).models(state, provider: provider, selected: sessionModel),
                     styled: views.models(state, provider: provider, selected: sessionModel))
            return 0
        case "instructions":
            let state = try await client.snapshot()
            try emit("instructions", data: state.instructions, text: GobySessionViews(style: .plain).instructions(state), styled: views.instructions(state))
            return 0
        case "resources":
            let state = try await client.snapshot()
            try emit("resources", data: state.resources, text: GobySessionViews(style: .plain).resources(state), styled: views.resources(state))
            return 0
        case "groups":
            let state = try await client.snapshot()
            try emit("groups", data: state.projectGroups, text: GobySessionViews(style: .plain).groups(state), styled: views.groups(state))
            return 0
        case "handoffs":
            let state = try await client.snapshot()
            try emit("handoffs", data: state.handoffLinks, text: GobySessionViews(style: .plain).handoffs(state), styled: views.handoffs(state))
            return 0
        case "health":
            let state = try await client.snapshot()
            try emit("health", data: state.health, text: GobySessionViews(style: .plain).health(state), styled: views.health(state))
            return 0
        case "branches":
            let state = try await client.snapshot()
            let project: ProjectID
            if args.count > 1 { project = try projectID(args[1], in: state) }
            else { project = try await repository(at: directory, requiringConfirmation: false).id }
            guard case let .projectGitBranches(snapshot) = try await local(.inspectProjectGitBranches(project)) else { throw GobySocketError.invalidResponse }
            let name = state.projects.first { $0.id == project }?.name ?? project.rawValue
            try emit("branches", data: snapshot, text: Self.branchesText(snapshot, name: name, style: .plain), styled: Self.branchesText(snapshot, name: name, style: io.style))
            return 0
        case "automation":
            return try await automation(args)
        case "diagnostics":
            let ack = try await administration(.exportRedactedDiagnostics, needsConfirmation: false)
            guard case let .redactedDiagnostics(data) = ack.artifact, let report = String(data: data, encoding: .utf8) else { throw GobySocketError.invalidResponse }
            try emit("diagnostics", data: report, text: report)
            return 0
        case "ask":
            if args == ["ask", "end"] {
                if let chat = try await client.snapshot().host.temporaryChat { _ = try await send(.endTemporaryChat(chat.id)) }
                try emit("chat-ended", data: "cleared", text: "Temporary chat ended and cleared.")
                return 0
            }
            let text = args.dropFirst().joined(separator: " ")
            let state = try await client.snapshot()
            let provider = try await selectedProvider(in: state)
            guard state.host.temporaryChat == nil || state.host.temporaryChat?.providerID == provider else {
                throw GobyTerminalError("End the other provider's temporary chat with goby ask end first.")
            }
            _ = try await send(.askTemporaryChat(.init(chatID: state.host.temporaryChat?.id, text: text, providerID: provider)))
            while !Task.isCancelled {
                guard let chat = try await client.snapshot().host.temporaryChat else { throw GobyTerminalError("Temporary chat ended before an answer was available.", code: 1) }
                if chat.status != .answering {
                    if chat.status == .failed { throw GobyTerminalError(chat.failureMessage ?? "The temporary answer failed.", code: 1) }
                    let answer = chat.messages.last(where: { $0.role == .assistant })?.text ?? "No answer is available."
                    try emit("answer", data: answer, text: answer)
                    return 0
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            return 0
        case "commit", "push":
            let id = try await runID(args[1])
            guard let kind = GADRunDeliveryKind(rawValue: args[0]),
                  case let .runDeliveryPreview(preview) = try await local(.previewRunDelivery(runID: id, kind: kind)) else { throw GobySocketError.invalidResponse }
            try emit("delivery-review", data: preview, text: "\(preview.kind.rawValue.capitalized) · \(preview.projectName) · branch \(preview.branch)\n\(preview.summary)")
            guard await confirmed("Approve this separate \(args[0]) operation? [y/N] ") else { throw GobyTerminalError("Git delivery needs a separate decision. Review it and rerun this command with --yes.") }
            let receipt = try await local(.executeRunDelivery(previewID: preview.id, digest: preview.digest))
            try emit("delivery", data: receipt, text: "Git delivery completed. Review the receipt with --json.")
            return 0
        case "import-agents":
            let project = try await repository(at: directory, requiringConfirmation: true)
            try await importAgents(project: project)
            return 0
        case "use":
            guard let preferences else { throw GobyTerminalError("CLI scope preferences are unavailable.", code: 3) }
            if args == ["use", "cwd"] {
                await preferences.select([])
                try emit("scope", data: [String](), text: "Default requests use their current Git repository.")
                return 0
            }
            let state = try await client.snapshot()
            // Names or IDs from goby projects both work.
            let ids = try args.dropFirst().map { try projectID($0, in: state) }
            guard Set(ids).count == ids.count, state.plan == nil, state.draft.text.isEmpty else {
                throw GobyTerminalError("Choose each registered project once, while no draft or plan is pending.")
            }
            await preferences.select(ids)
            let names = ids.compactMap { id in state.projects.first { $0.id == id }?.name }.joined(separator: ", ")
            try emit("scope", data: ids, text: "Explicit project scope saved for future requests. Use goby use cwd to return to the current repository.",
                     styled: presenter.success("New requests go to \(names). /use cwd switches back to the current repository."))
            return 0
        case "status":
            try await status()
            return 0
        case "projects":
            let artifact = try await local(.inspectLocalCatalog)
            guard case let .localCatalog(catalog) = artifact else { throw GobySocketError.invalidResponse }
            let projectsState = decorated ? try await client.snapshot() : nil
            try emit("projects", data: catalog.projects.map { CLIProjectOutput(id: $0.id, name: $0.name) },
                     text: catalog.projects.map { "\($0.id.rawValue) · \($0.name)" }.joined(separator: "\n"),
                     styled: projectsState.map { views.projects($0) })
            return 0
        case "add":
            let root = args.count > 1 ? URL(fileURLWithPath: args[1], relativeTo: directory).standardizedFileURL : directory
            _ = try await repository(at: root, requiringConfirmation: true)
            return 0
        case "run":
            guard args.count == 2 else { throw GobyTerminalError("Usage: goby run <plan> [--yes]") }
            let state = try await client.snapshot()
            guard let plan = state.plan, plan.id.rawValue == args[1] else { throw GobyTerminalError("This plan is no longer pending. Prepare a new request.") }
            return try await start(plan, state: state)
        case "watch":
            return try await watch(try await runID(args.dropFirst().first))
        case "result":
            let run = try await findRun(args.dropFirst().first)
            try emit("result", data: CLIRunOutput(run), text: "\(WorkflowTextFormatter.status(run.status)) \(run.id.rawValue)\n\n\(WorkflowTextFormatter.result(run))")
            return GobyCLIExitCode.forRun(run.status)
        case "diff":
            let id = try await runID(args.dropFirst().first)
            guard case let .localRunDiff(diff) = try await local(.inspectLocalRunDiff(id)) else { throw GobySocketError.invalidResponse }
            try emit("diff", data: diff, text: diff)
            return 0
        case "log":
            let run = try await findRun(args.dropFirst().first)
            try emit("log", data: run.journal, text: run.journal.map { $0.message }.joined(separator: "\n"))
            return 0
        case "pause", "resume", "cancel":
            let id = try await runID(args.dropFirst().first)
            guard let action = GADRunControlAction(rawValue: args[0]) else { throw GobySocketError.invalidResponse }
            let ack = try await send(.controlRun(.init(runID: id, action: action)))
            try emit("control", data: ack, text: "Requested \(args[0]) for \(id.rawValue).")
            return 0
        case "approve", "deny":
            guard args.count == 2 else { throw GobyTerminalError("Usage: goby \(args[0]) <approval> [--yes]") }
            let state = try await client.snapshot()
            guard let approval = state.approvals.first(where: { $0.id == args[1] }) else { throw GobyTerminalError("This approval is no longer pending.") }
            return try await decide(approval, allow: args[0] == "approve")
        case "follow-up":
            guard args.count >= 3 else { throw GobyTerminalError("Usage: goby follow-up <run> <text>") }
            let id = try await runID(args[1])
            let ack = try await send(.followUp(.init(runID: id, text: args.dropFirst(2).joined(separator: " "))))
            try emit("follow-up", data: ack, text: ack.message ?? "Delivered the follow-up within the active run's approved scope.")
            return 0
        case "host":
            guard args.count == 2 else { throw GobyTerminalError("Usage: goby host status | stop | run") }
            if args[1] == "status" {
                let response = try await transport.exchange(.init(operation: .ping))
                try emit("host", data: response.hostVersion, text: "CLI host available · \(response.hostVersion)")
                return 0
            }
            guard args[1] == "stop" else { throw GobyTerminalError("Usage: goby host status | stop | run") }
            let receipt = try await local(.preparePermanentHostShutdown)
            try emit("host-stop", data: receipt, text: "The CLI host will checkpoint and stop after active work and approvals finish.")
            return 0
        default:
            var text = args.joined(separator: " ")
            if text.isEmpty {
                if decorated { return try await session() }
                guard io.interactive, !options.json, let entered = await io.read("Request: ") else {
                    throw GobyTerminalError("Enter a request: goby \"<request>\". Use goby help for commands.")
                }
                text = entered
            } else if decorated {
                let provider = (try? await selectedProvider(in: try await client.snapshot()))?.displayName ?? providerName
                io.write(presenter.header(repository: directory.lastPathComponent, provider: provider))
            }
            return try await request(text)
        }
    }

    /// The interactive session: Goby greets once, then keeps taking requests
    /// until /exit or end of input, like a conversation.
    private func session() async throws -> Int32 {
        let provider = (try? await selectedProvider(in: try await client.snapshot()))?.displayName ?? providerName
        io.write(presenter.banner(version: GobyCLIEnvironment.version, repository: directory.lastPathComponent, provider: provider))
        while true {
            guard let line = await io.read("\n" + presenter.promptMarker) else {
                io.write("\n" + presenter.farewell())
                return 0
            }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if ["exit", "quit", "/exit", "/quit", ":q"].contains(text.lowercased()) {
                io.write(presenter.farewell())
                return 0
            }
            if Self.isSlashCommand(text) {
                do { try await slash(text) } catch {
                    spinner.stop()
                    try? emit("error", data: CLIErrorOutput(message: error.localizedDescription, exitCode: GobyCLIExitCode.forError(error)),
                              text: error.localizedDescription, styled: presenter.error(error.localizedDescription))
                }
                continue
            }
            do {
                _ = try await request(text)
            } catch {
                spinner.stop()
                let code = GobyCLIExitCode.forError(error)
                try? emit("error", data: CLIErrorOutput(message: error.localizedDescription, exitCode: code), text: error.localizedDescription,
                          styled: presenter.error(error.localizedDescription))
            }
        }
    }

    private func status() async throws {
        let state = try await client.snapshot()
        let text = (["CLI host is available."] + state.runs.map {
            "\(WorkflowTextFormatter.status($0.status)) \($0.id.rawValue) · \($0.goal)"
        } + state.approvals.map { "! Approval needed: \($0.id) · \($0.summary)" }
            + (state.plan.map { ["! Plan awaiting review: \($0.id.rawValue) · \($0.goal)"] } ?? [])).joined(separator: "\n")
        try emit("status", data: CLIStatusOutput(plan: state.plan, runs: state.runs.map(CLIRunOutput.init), approvals: state.approvals),
                 text: text, styled: views.overview(state))
    }

    /// Session commands mirror the app's screens and the CLI subcommands.
    static let sessionCommands: [(name: String, usage: String, summary: String)] = [
        ("status", "/status", "home: providers, active work, approvals, next automation"),
        ("map", "/map", "groups → projects → agents, with live status"),
        ("projects", "/projects", "registered projects"),
        ("agents", "/agents [project]", "agents, their scope, capabilities and bindings"),
        ("runs", "/runs [project]", "conversation history"),
        ("show", "/show [run]", "open a conversation"),
        ("diff", "/diff [run]", "changes in a run's working tree"),
        ("branches", "/branches [project]", "Git branches and uncommitted changes"),
        ("automations", "/automations", "schedules and recent occurrences"),
        ("providers", "/providers", "connections, plans and models"),
        ("provider", "/provider <codex|claude|copilot>", "use a provider for this session"),
        ("model", "/model [name|default]", "list models or choose one for this session"),
        ("instructions", "/instructions", "instruction packs"),
        ("resources", "/resources", "shared folders"),
        ("groups", "/groups", "project groups"),
        ("handoffs", "/handoffs", "cross-agent handoff links"),
        ("health", "/health", "system checks"),
        ("approve", "/approve <id>", "review and allow a pending operation once"),
        ("deny", "/deny <id>", "decline a pending operation"),
        ("pause", "/pause [run]", "pause a run"),
        ("resume", "/resume [run]", "resume a run"),
        ("cancel", "/cancel [run]", "cancel a run"),
        ("follow-up", "/follow-up <run> <text>", "steer an active run"),
        ("commit", "/commit <run>", "review and commit a finished run"),
        ("push", "/push <run>", "review and push, separately"),
        ("ask", "/ask <question>", "temporary chat, no project access"),
        ("use", "/use <project…> | cwd", "set the default project scope"),
        ("clear", "/clear", "clear the screen"),
        ("help", "/help", "this list"),
        ("exit", "/exit", "leave; the host keeps running"),
    ]

    static func isSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/"), let first = text.split(separator: " ").first else { return false }
        // "/Users/me/file" is a path in a request, not a command.
        return !first.dropFirst().contains("/") && first.count > 1
    }

    private func slash(_ text: String) async throws {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let name = String(parts[0].dropFirst()).lowercased()
        let rest = Array(parts.dropFirst())
        switch name {
        case "help", "?":
            io.write(presenter.sessionHelp(Self.sessionCommands.map { ($0.usage, $0.summary) }))
        case "clear":
            io.write("\u{1B}[2J\u{1B}[H")
        case "status", "home":
            try await status()
        case "provider":
            guard let value = rest.first else {
                _ = try await perform(["providers"])
                return
            }
            let provider = try Self.provider(named: value)
            sessionProvider = provider
            sessionModel = nil
            providerName = provider.displayName
            io.write(presenter.success("Using \(provider.displayName) for this session. I'll keep watch while it digs."))
        case "model":
            let state = try await client.snapshot()
            let provider = try await selectedProvider(in: state)
            guard let value = rest.first else {
                _ = try await perform(["models"])
                return
            }
            if value.lowercased() == "default" {
                sessionModel = nil
                io.write(presenter.success("\(provider.displayName) will use its default model."))
                return
            }
            let models = state.providerAccounts.first { $0.providerID == provider }?.availableModels ?? []
            guard models.isEmpty || models.contains(value) else {
                throw GobyTerminalError("\(provider.displayName) doesn't offer \(value). Type /model to see its models.")
            }
            sessionModel = value
            io.write(presenter.success("New requests use \(value) on \(provider.displayName)."))
        default:
            guard Self.sessionCommands.contains(where: { $0.name == name }) || ["tree", "result", "log", "watch", "diagnostics", "import-agents", "run", "automation", "models"].contains(name) else {
                throw GobyTerminalError("Unknown command /\(name). Type /help to see what I can do.")
            }
            _ = try await perform([name == "status" ? "home" : name] + rest)
        }
    }

    /// Provider accounts appear after the host's first connection check.
    private func providerSnapshot() async throws -> DashboardProjection {
        var state = try await client.snapshot()
        let unchecked = state.providerAccounts.isEmpty || state.providerAccounts.allSatisfy {
            if case .notChecked = $0.connectionState { true } else { false }
        }
        if unchecked {
            _ = try await send(.refreshProviders(Array(AgentProviderID.builtIn)))
            state = try await client.snapshot()
        }
        return state
    }

    private func projectID(_ text: String, in state: DashboardProjection) throws -> ProjectID {
        if let exact = state.projects.first(where: { $0.id.rawValue == text }) { return exact.id }
        let matches = state.projects.filter { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
        guard matches.count == 1, let match = matches.first else {
            throw GobyTerminalError("No single project matches \(text). Use a name or ID from /projects.")
        }
        return match.id
    }

    static func provider(named text: String) throws -> AgentProviderID {
        let provider = text.lowercased() == "copilot" ? AgentProviderID.githubCopilot : AgentProviderID(rawValue: text.lowercased())
        guard AgentProviderID.builtIn.contains(provider) else { throw GobyTerminalError("Choose codex, claude or copilot.", code: 4) }
        return provider
    }

    static func branchesText(_ snapshot: ProjectGitBranchSnapshot, name: String, style: GobyTerminalStyle) -> String {
        var lines = [style.bold("Branches") + style.dim(" · " + WorkflowTextFormatter.terminalSafe(name))]
        for branch in snapshot.localBranches {
            let current = branch == snapshot.currentBranch
            lines.append("  " + (current ? style.accent("● ") : style.dim("○ ")) + WorkflowTextFormatter.terminalSafe(branch) + (current ? style.dim(" · current") : ""))
        }
        if snapshot.hasUncommittedChanges {
            lines.append("  " + style.warning("! ") + "Uncommitted changes" + (snapshot.changedFileCount.map { style.dim(" · \($0) file(s)") } ?? ""))
        } else {
            lines.append("  " + style.success("✓ ") + "Working tree clean")
        }
        if let remote = snapshot.pushRemote { lines.append("  " + style.dim("push remote " + WorkflowTextFormatter.terminalSafe(remote))) }
        return lines.joined(separator: "\n")
    }

    private func request(_ text: String) async throws -> Int32 {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GobyTerminalError("Enter a nonempty request.") }
            let selected = await preferences?.selected ?? []
            let projectIDs: [ProjectID]
            if selected.isEmpty { projectIDs = [try await repository(at: directory, requiringConfirmation: true).id] }
            else { projectIDs = selected }
            let current = try await client.snapshot()
            if !selected.isEmpty {
                guard case let .localCatalog(catalog) = try await local(.inspectLocalCatalog), projectIDs.allSatisfy({ id in catalog.projects.contains(where: { $0.id == id }) }) else { throw GobyTerminalError("A selected project is no longer available. Use goby use cwd or select registered project IDs again.") }
            }
            // Do not overwrite another terminal's outstanding plan or draft.
            guard current.plan == nil, current.draft.text.isEmpty else {
                throw GobyTerminalError("A saved draft or plan already needs review. Use goby status and goby run <plan>, or finish that request first.")
            }
            let provider = try await selectedProvider(in: current)
            providerName = provider.displayName
            _ = try await send(.replaceDraft(.init(expectedRevision: current.draft.revision, text: text,
                                                   providerID: provider, model: sessionModel, projectIDs: projectIDs, agentTargets: [], groupID: nil)))
            if decorated { spinner.start(GobyPersona.planning) }
            _ = try await send(.preparePlan)
            let state = try await client.snapshot()
            spinner.stop()
            guard let plan = state.plan else { throw GobyTerminalError("The host could not prepare a plan.", code: 1) }
            return try await start(plan, state: state)
    }

    private func repository(at root: URL, requiringConfirmation: Bool) async throws -> LabProject {
        guard case let .localCatalog(catalog) = try await local(.inspectLocalCatalog) else { throw GobySocketError.invalidResponse }
        if let existing = catalog.projects.first(where: { $0.fileSystemIdentity?.matchesCurrentObject(at: root) == true }) { return existing }
        let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard case let .localProjectCandidates(candidates) = try await local(.inspectProjectBookmarks([bookmark])),
              let candidate = candidates.first(where: { $0.rootURL.map { GADFileSystemIdentity.capture($0)?.matchesCurrentObject(at: root) == true } == true }), candidate.isGitRepository else {
            throw GobyTerminalError("Run goby from a Git repository, or use goby add <path>.", code: 4)
        }
        try emit("project-review", data: CLIProjectOutput(id: candidate.id, name: candidate.name),
                 text: "Register \(candidate.name) as this request's repository? Existing agent definitions are preserved.",
                 styled: presenter.note("First time in \(candidate.name). I'll register it so I can work here; existing agent definitions stay untouched."))
        if requiringConfirmation, !(await confirmed("Register this repository? [y/N] ")) {
            throw GobyTerminalError("Repository registration needs a decision. Review it and rerun with --yes.")
        }
        _ = try await local(.registerProjectBookmarks(bookmarks: [bookmark], selectedProjectIDs: [candidate.id]))
        guard case let .localCatalog(updated) = try await local(.inspectLocalCatalog),
              let project = updated.projects.first(where: { $0.id == candidate.id }) else { throw GobySocketError.invalidResponse }
        try emit("project-registered", data: CLIProjectOutput(id: project.id, name: project.name), text: "Registered \(project.name).",
                 styled: presenter.success("Registered \(project.name)."))
        if FileManager.default.fileExists(atPath: root.appending(path: ".codex").path) {
            try emit("agent-import-available", data: "goby import-agents", text: "Native agent definitions are available. Review instruction-only copies with goby import-agents.")
            if io.interactive, !options.json, options.arguments.first != "import-agents", await confirmed("Review agent definitions now? [y/N] ", useYes: false) {
                try await importAgents(project: project)
            }
        }
        return project
    }
    private func automation(_ args: [String]) async throws -> Int32 {
        if args[1] == "add" {
            guard args.count >= 5 else { throw GobyTerminalError("Usage: goby automation add <name> <HH:MM> <request> [--yes]") }
            let time = args[3].split(separator: ":")
            guard time.count == 2, let hour = Int(time[0]), let minute = Int(time[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw GobyTerminalError("Choose a daily time as HH:MM.", code: 4) }
            let project = try await repository(at: directory, requiringConfirmation: true)
            let provider = try await selectedProvider(in: try await client.snapshot())
            let definition = AutomationDefinition(name: args[2], schedule: .init(cadence: .daily(hour: hour, minute: minute), timeZoneIdentifier: TimeZone.current.identifier),
                actions: [.init(instruction: args.dropFirst(4).joined(separator: " "), target: .project(providerID: provider, projectID: project.id))], state: .paused)
            try emit("automation-review", data: definition, text: "Daily \(args[3]) (\(TimeZone.current.identifier)) · \(definition.name)\n\(definition.actions.map(\.instruction).joined(separator: "\n"))\nScope: \(project.name) · \(provider.displayName). Initially paused; runtime approvals remain manual.")
            guard await confirmed("Save this paused automation? [y/N] ") else { throw GobyTerminalError("Automation creation needs a decision.") }
            let ack = try await send(.saveAutomation(.init(automation: definition, expectedRevision: nil)))
            try emit("automation", data: ack, text: "Saved a paused automation. Use goby automations for its ID, then automation resume <id>. For continuous scheduling: brew services start goby.")
            return 0
        }
        guard args.count == 3 else { throw GobyTerminalError("Usage: goby automation pause|resume|run|delete|review|cancel <id>") }
        let state = try await client.snapshot()
        if args[1] == "review" || args[1] == "cancel" {
            guard let occurrence = state.automations.occurrences.first(where: { $0.id.rawValue == args[2] }) else { throw GobyTerminalError("This automation occurrence is unavailable.") }
            if args[1] == "cancel" { let ack = try await send(.cancelAutomationOccurrence(occurrence.id)); try emit("automation", data: ack, text: "Requested cancellation of this occurrence."); return 0 }
            guard let plan = occurrence.currentReviewAttempt?.plan, let binding = occurrence.currentReviewBinding else { throw GobyTerminalError("This occurrence has no current review.") }
            try emit("automation-plan", data: plan, text: WorkflowTextFormatter.plan(plan, projects: state.projects))
            guard !plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval }), await confirmed("Approve this exact automation plan? [y/N] ") else { throw GobyTerminalError("This occurrence needs a separate review; push and history-changing work cannot be authorized here.") }
            let assertion = plan.risk >= .medium || !plan.gitOperations.isEmpty ? try await io.authenticateOwner() : nil
            let ack = try await send(.reviewAndRunAutomationOccurrence(.init(id: occurrence.id, reviewBinding: binding, authorizationAssertion: assertion)))
            try emit("automation", data: ack, text: "Reviewed the current automation action. Runtime approvals remain manual.")
            return 0
        }
        guard let definition = state.automations.definitions.first(where: { $0.id.rawValue == args[2] }) else { throw GobyTerminalError("This automation definition is unavailable.") }
        try emit("automation-review", data: definition, text: "\(args[1].capitalized) · \(definition.name) · revision \(definition.revision)")
        guard await confirmed("Approve this automation change? [y/N] ") else { throw GobyTerminalError("This automation change needs a decision.") }
        let payload: GADCommandPayload
        switch args[1] {
        case "pause", "resume": payload = .setAutomationState(.init(id: definition.id, expectedRevision: definition.revision, state: args[1] == "pause" ? .paused : .active))
        case "run": payload = .runAutomationNowChecked(.init(id: definition.id, expectedRevision: definition.revision))
        case "delete": payload = .deleteAutomation(definition.id, expectedRevision: definition.revision)
        default: throw GobyTerminalError("Choose add, pause, resume, run, delete, review or cancel.")
        }
        let ack = try await send(payload)
        try emit("automation", data: ack, text: "Automation change accepted.")
        return 0
    }
    private func selectedProvider(in state: DashboardProjection) async throws -> AgentProviderID {
        if options.hasExplicitProvider { return options.providerID }
        if let sessionProvider { return sessionProvider }
        var state = state
        if !state.providerAccounts.isEmpty, state.providerAccounts.allSatisfy({ if case .notChecked = $0.connectionState { true } else { false } }) {
            _ = try await send(.refreshProviders(state.providerAccounts.map(\.providerID)))
            state = try await client.snapshot()
        }
        let connected = state.providerAccounts.filter { if case .connected = $0.connectionState { true } else { false } }.map(\.providerID)
        if connected.contains(.codex) { return .codex }
        if connected.count == 1, let only = connected.first { return only }
        // Older hosts and test bridges may not project account records.
        if connected.isEmpty { return .codex }
        throw GobyTerminalError("Several providers are signed in. Choose --provider codex|claude|copilot.")
    }
    private func administration(_ request: GADHostAdminRequest, needsConfirmation: Bool = true) async throws -> GADCommandAcknowledgement {
        let ack = try await send(.requestHostAdminPreview(request))
        guard case let .hostAdminPreview(preview) = ack.artifact else { throw GobySocketError.invalidResponse }
        try emit("administration-review", data: preview, text: preview.effects.map { "\($0.title)\n\($0.detail)" }.joined(separator: "\n\n"))
        if needsConfirmation, !(await confirmed("Approve these exact effects? [y/N] ")) { throw GobyTerminalError("This change needs a decision after its preview.") }
        let assertion = preview.requiresLocalAuthentication ? try await io.authenticateOwner() : nil
        return try await send(.commitHostAdmin(.init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: assertion)))
    }
    private func importAgents(project: LabProject) async throws {
        var offset = 0
        var candidates: [GADAgentImportCandidateProjection] = []
        repeat {
            let ack = try await send(.requestAgentCatalogDiscovery(offset: offset))
            guard case let .agentCatalogDiscovery(page) = ack.artifact, page.expiresAt > .now else { throw GobySocketError.invalidResponse }
            candidates += page.candidates.filter { $0.scope == .project(project.id) }
            guard let next = page.nextOffset else { break }
            guard next > offset, next <= 1_024 else { throw GobyTerminalError("The definition catalog exceeds the bounded review size.", code: 4) }
            offset = next
        } while true
        guard !candidates.isEmpty else {
            try emit("agent-import", data: "none", text: "No importable definitions were discovered for this repository.")
            return
        }
        for candidate in candidates {
            try emit("agent-review", data: candidate, text: "\(candidate.name)\n\(candidate.summary)\n\(candidate.instructions ?? "No instruction body.")\n\(candidate.evidence.joined(separator: "\n"))")
        }
        guard candidates.allSatisfy({ !$0.requiresMacReview && !$0.reviewHash.isEmpty }) else {
            throw GobyTerminalError("A definition cannot be completely reviewed in this terminal. No definitions were imported.", code: 4)
        }
        let receipt = try await administration(.importAgents(candidates.map { .init(agentID: $0.id, reviewHash: $0.reviewHash) }))
        try emit("agent-import", data: receipt, text: "Imported the reviewed instruction copies. Native definitions remain unchanged.")
    }
    private func start(_ plan: GADPlanProjection, state: DashboardProjection) async throws -> Int32 {
        try emit("plan", data: plan, text: WorkflowTextFormatter.plan(plan, projects: state.projects),
                 styled: presenter.plan(plan, projects: state.projects))
        guard !plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval }) else {
            throw GobyTerminalError("This plan includes Git work requiring separate approval. Review completed-workspace delivery with goby commit or goby push; other Git mutations are unavailable here.", code: 4)
        }
        if plan.startsWithoutReview != true && !plan.canStartAutomatically,
           !(await confirmed("Approve this exact plan and run? [y/N] ")) {
            throw GobyTerminalError("Plan needs a decision. Review it and use goby run \(plan.id.rawValue) --yes.")
        }
        _ = try await send(.startRun(.init(planID: plan.id)))
        return try await watch(plan.id)
    }
    private func watch(_ id: RunID) async throws -> Int32 {
        var lastStatus: RunStatus?
        var seen = Set<String>()
        while !Task.isCancelled {
            let state = try await client.snapshot()
            guard let run = state.runs.first(where: { $0.id == id }) else { throw GobyTerminalError("This run is no longer available.") }
            if lastStatus != run.status {
                if !decorated {
                    try emit("activity", data: CLIActivityOutput(runID: id, status: run.status), text: "\(WorkflowTextFormatter.status(run.status)) \(id.rawValue)")
                } else if run.status == .running {
                    try emit("activity", data: CLIActivityOutput(runID: id, status: run.status), text: "",
                             styled: presenter.running(id, provider: providerName))
                    spinner.start(GobyPersona.working(provider: providerName))
                }
                lastStatus = run.status
            }
            for step in run.activity {
                // Status transitions update a step in place.
                let key = "\(step.id):\(step.status)"
                if seen.insert(key).inserted, options.verbose || step.kind == "message" {
                    try emit("activity-step", data: step, text: "\(step.status) · \(step.title)", styled: presenter.step(step.title))
                }
            }
            if run.status.isFinished {
                let elapsed = spinner.elapsed
                spinner.stop()
                try emit("result", data: CLIRunOutput(run), text: WorkflowTextFormatter.result(run),
                         styled: presenter.result(run, elapsed: elapsed))
                return GobyCLIExitCode.forRun(run.status)
            }
            if let approval = state.approvals.first(where: { $0.runID == id }) {
                spinner.stop()
                if !io.interactive || options.json {
                    try emit("approval-needed", data: approval, text: "! Approval needed. Review with goby approve \(approval.id) or goby deny \(approval.id).",
                             styled: presenter.approvalNeeded("Approval needed. Review with goby approve \(approval.id) or goby deny \(approval.id)."))
                    return 2
                }
                let code = try await decide(approval, allow: true)
                if code != 0 { return code }
                if decorated { spinner.start(GobyPersona.working(provider: providerName)) }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return 0
    }
    private func decide(_ approval: GADApprovalProjection, allow: Bool) async throws -> Int32 {
        let ack = try await send(.requestApprovalDisclosure(approval.id))
        guard case let .approvalDisclosure(disclosure) = ack.artifact else { throw GobySocketError.invalidResponse }
        try emit("approval-disclosure", data: disclosure, text: WorkflowTextFormatter.disclosure(disclosure),
                 styled: presenter.approval(WorkflowTextFormatter.disclosure(disclosure)))
        if allow {
            guard disclosure.requestDigest != nil, disclosure.expiresAt > .now,
                  approval.actions.contains(.allowOnce) else { throw GobyTerminalError("This request cannot be completely reviewed or allowed.", code: 4) }
            guard await confirmed("Allow this exact operation once? [y/N] ", useYes: options.arguments.first == "approve") else {
                throw GobyTerminalError("Approval needs a decision. Use goby deny \(approval.id) to decline it.")
            }
        }
        let decision = GADApprovalResponse(approvalID: approval.id, runID: approval.runID, assignmentID: approval.assignmentID,
                                           action: allow ? .allowOnce : .decline, approvalSessionID: approval.approvalSessionID,
                                           disclosureDigest: disclosure.requestDigest)
        let result = try await send(.respondToApproval(decision))
        try emit("approval-decided", data: result, text: allow ? "Allowed once." : "Declined.",
                 styled: allow ? presenter.success("Allowed once. Back to it.") : presenter.note("Declined. I'll let the run know."))
        return 0
    }
    private func confirmed(_ prompt: String, useYes: Bool = true) async -> Bool {
        if useYes && options.yes { return true }
        spinner.stop()
        guard io.interactive, !options.json, let answer = await io.read(decorated ? presenter.question(prompt) : prompt) else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    private func send(_ payload: GADCommandPayload) async throws -> GADCommandAcknowledgement {
        guard let session else { throw GobySocketError.invalidResponse }
        let state = try await client.snapshot()
        let command = GADCommand(idempotencyKey: UUID().uuidString, hostEpoch: session.hostEpoch, deviceID: deviceID,
                                 baseRevision: state.revision, issuedAt: .now, expiresAt: Date.now.addingTimeInterval(30), payload: payload)
        let ack = try await client.send(command)
        guard ack.disposition == .accepted else { throw GADCommandFailure(ack.disposition, ack.message ?? "The host rejected this action.") }
        return ack
    }
    private func local(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        let response = try await transport.exchange(.init(operation: .localAdministration(command)))
        if let error = response.error { throw GADCommandFailure(response.failureDisposition ?? .failedRecoverable, error) }
        guard !response.isReadOnly, let artifact = response.artifact else { throw GobySocketError.invalidResponse }
        return artifact
    }
    private func runID(_ text: String?) async throws -> RunID {
        let state = try await client.snapshot()
        if let text {
            if let exact = state.runs.first(where: { $0.id.rawValue == text }) { return exact.id }
            // The short IDs shown in /runs work too, when they are unambiguous.
            let matches = state.runs.filter { $0.id.rawValue.hasPrefix(text) }
            guard text.count >= 4, matches.count == 1, let match = matches.first else {
                throw GobyTerminalError(matches.count > 1 ? "Several runs start with \(text). Use more of the ID." : "No run matches that ID.")
            }
            return match.id
        }
        let active = state.runs.filter { !$0.status.isFinished }
        if active.count == 1, let run = active.first { return run.id }
        if active.isEmpty, let latest = state.runs.max(by: { $0.createdAt < $1.createdAt }) { return latest.id }
        throw GobyTerminalError(active.isEmpty ? "No runs yet." : "Several runs are active. Choose one from goby status.")
    }
    private func findRun(_ text: String?) async throws -> GADRunProjection {
        let id = try await runID(text)
        guard let run = try await client.snapshot().runs.first(where: { $0.id == id }) else { throw GobySocketError.invalidResponse }
        return run
    }
    /// `styled` is Goby's decorated rendering. The presenter sanitizes every
    /// provider string before adding colour; plain and JSON output are unchanged.
    private func emit<T: Codable & Sendable>(_ kind: String, data: T, text: String, styled: String? = nil) throws {
        if options.json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            io.write(String(decoding: try encoder.encode(GobyCLIOutput(type: kind, data: data)), as: UTF8.self))
        } else if decorated {
            let display = (styled ?? WorkflowTextFormatter.terminalSafe(text))
                .replacingOccurrences(of: directory.path, with: "<repository>")
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            spinner.interleave { io.write(display) }
        } else {
            let display = text.replacingOccurrences(of: directory.path, with: "<repository>")
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            io.write(WorkflowTextFormatter.terminalSafe(display))
        }
    }
}

private struct CLIErrorOutput: Codable, Sendable { let message: String; let exitCode: Int32 }
private struct CLIProjectOutput: Codable, Sendable { let id: ProjectID; let name: String }
private struct CLIActivityOutput: Codable, Sendable { let runID: RunID; let status: RunStatus }
private struct CLIRunOutput: Codable, Sendable {
    let id: RunID
    let goal: String
    let status: RunStatus
    let outcome: String?
    init(_ run: GADRunProjection) { id = run.id; goal = run.goal; status = run.status; outcome = run.outcome }
}
private struct CLIMapOutput: Codable, Sendable {
    let groups: [GADProjectGroupProjection]
    let projects: [GADProjectProjection]
    let agents: [GADAgentProjection]
    let bindings: [GADProviderBindingProjection]
    let handoffLinks: [GADHandoffLinkProjection]
    init(_ state: DashboardProjection) {
        groups = state.projectGroups; projects = state.projects; agents = state.agents
        bindings = state.providerBindings; handoffLinks = state.handoffLinks
    }
}
private struct CLIStatusOutput: Codable, Sendable {
    let plan: GADPlanProjection?
    let runs: [CLIRunOutput]
    let approvals: [GADApprovalProjection]
}
