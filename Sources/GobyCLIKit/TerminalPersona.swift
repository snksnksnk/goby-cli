import Darwin
import Foundation
import GobyApplication
import GobyDomain
import GobyExperience
import Synchronization

/// Goby's terminal character: a goby fish keeps watch at the burrow while its
/// partner shrimp digs. The provider digs; Goby scouts, plans, and stops to
/// check with you before anything risky. Idle moments may be playful. Plans,
/// approvals and errors stay plain and exact.
///
/// Decoration applies only to an interactive, colour-capable terminal. JSON,
/// pipes, NO_COLOR and TERM=dumb keep the plain contract output. Provider text
/// is sanitized before any styling is added, so it can never inject escapes.
public struct GobyTerminalStyle: Sendable {
    public let enabled: Bool
    public let reduceMotion: Bool

    public init(enabled: Bool, reduceMotion: Bool = false) {
        self.enabled = enabled
        self.reduceMotion = reduceMotion
    }

    public static let plain = GobyTerminalStyle(enabled: false)

    /// Decorates only a colour-capable interactive terminal.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> GobyTerminalStyle {
        let tty = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0
        let noColor = environment["NO_COLOR"].map { !$0.isEmpty } ?? false
        let dumb = environment["TERM"] == nil || environment["TERM"] == "dumb"
        let motion = environment["GOBY_NO_ANIMATION"] != nil
            || UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "reduceMotion") == true
        return GobyTerminalStyle(enabled: tty && !noColor && !dumb, reduceMotion: motion)
    }

    private func paint(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
    public func accent(_ text: String) -> String { paint("38;5;80", text) }
    public func fish(_ text: String) -> String { paint("1;38;5;209", text) }
    public func bold(_ text: String) -> String { paint("1", text) }
    public func dim(_ text: String) -> String { paint("2", text) }
    public func success(_ text: String) -> String { paint("38;5;114", text) }
    public func warning(_ text: String) -> String { paint("38;5;221", text) }
    public func failure(_ text: String) -> String { paint("38;5;203", text) }
}

public enum GobyPersona {
    public static let mascot = "><(((º>"

    public static func greeting(hour: Int = Calendar.current.component(.hour, from: .now)) -> String {
        switch hour {
        case 5..<12: "Morning! The water's clear."
        case 12..<18: "Afternoon! Good currents today."
        case 18..<23: "Evening! Let's get something done."
        default: "Late swim? I'm awake."
        }
    }

    public static func introduction(provider: String) -> [String] {
        ["I keep watch while \(provider) digs. I'll scout",
         "your repo, plan the work, and check with you",
         "before anything risky."]
    }

    public static let planning = ["Scouting the reef", "Reading the currents", "Charting a plan", "Sizing up the scope"]

    public static func working(provider: String) -> [String] {
        ["Keeping watch while \(provider) digs", "Swimming through files", "Nibbling at the problem",
         "Checking the burrow", "Watching the currents", "Tidying the reef"]
    }

    public static let farewells = ["See you around the reef.", "Swimming off. Call me anytime.", "Back to the burrow. Bye!"]

    static func pick(_ lines: [String]) -> String { lines.randomElement() ?? lines[0] }
}

/// Renders workflow events for a decorated terminal. Every caller passes
/// already sanitized text; this type only adds layout and colour.
public struct GobyTerminalPresenter: Sendable {
    public let style: GobyTerminalStyle
    public let width: Int

    public init(style: GobyTerminalStyle, width: Int = GobyTerminalPresenter.terminalWidth()) {
        self.style = style
        self.width = max(40, min(width, 100))
    }

    public static func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    public func banner(version: String, repository rawRepository: String, provider: String) -> String {
        let repository = safe(rawRepository)
        let inner = min(width - 4, 56)
        func row(_ plain: String, _ styled: String? = nil) -> String {
            let pad = max(0, inner - plain.count)
            return style.dim("│ ") + (styled ?? plain) + String(repeating: " ", count: pad) + style.dim(" │")
        }
        let titlePlain = "\(GobyPersona.mascot)  Goby"
        let versionText = "v\(version)"
        let titleGap = max(1, inner - titlePlain.count - versionText.count)
        var lines = [style.dim("╭" + String(repeating: "─", count: inner + 2) + "╮")]
        lines.append(style.dim("│ ") + style.fish(GobyPersona.mascot) + "  " + style.bold("Goby")
            + String(repeating: " ", count: titleGap) + style.dim(versionText) + style.dim(" │"))
        lines.append(row(""))
        let greeting = GobyPersona.greeting()
        lines.append(row(greeting, style.accent(greeting)))
        for line in GobyPersona.introduction(provider: provider) { lines.append(row(line)) }
        lines.append(row(""))
        let repo = "repo      \(repository)"
        lines.append(row(repo, style.dim("repo      ") + repository))
        let agent = "provider  \(provider)"
        lines.append(row(agent, style.dim("provider  ") + provider))
        lines.append(style.dim("╰" + String(repeating: "─", count: inner + 2) + "╯"))
        lines.append(style.dim("  Ask for a change, or try /help · /status · /exit"))
        return lines.joined(separator: "\n")
    }

    public func header(repository: String, provider: String) -> String {
        let repository = safe(repository)
        return style.fish(GobyPersona.mascot) + " " + style.bold("goby") + style.dim(" · \(repository) · \(provider)")
    }

    public var promptMarker: String { style.accent("› ") }

    public func question(_ prompt: String) -> String {
        let trimmed = prompt.replacingOccurrences(of: " [y/N] ", with: "")
        return style.accent("? ") + style.bold(trimmed) + style.dim(" (y/N) ")
    }

    public func plan(_ plan: GADPlanProjection, projects: [GADProjectProjection]) -> String {
        let bar = style.dim("  │ ")
        var lines = [style.accent("●") + " " + style.bold("Here's my plan")]
        lines.append(bar + safe(plan.goal))
        let riskText = WorkflowTextFormatter.riskLabel(plan.risk)
        let risk: String = switch plan.risk {
        case .readOnly, .low: style.success(riskText)
        case .medium: style.warning(riskText)
        case .high: style.failure(riskText)
        }
        lines.append(bar + style.dim("risk     ") + risk)
        for (index, route) in plan.routes.enumerated() {
            let name = safe(projects.first { $0.id == route.projectID }?.name ?? route.projectID.rawValue)
            let label = index == 0 ? "scope    " : "         "
            lines.append(bar + style.dim(label) + "\(name) · \(route.providerID.displayName) · \(route.agentIDs.count) agent(s)")
            lines.append(bar + "         " + style.dim(safe(route.reason)))
        }
        for operation in plan.gitOperations {
            var line = operation.kind.rawValue
            if let branch = operation.branch { line += " · branch \(branch)" }
            if let remote = operation.remote { line += " · remote \(remote)" }
            lines.append(bar + style.dim("git      ") + safe(line))
        }
        if !plan.selectedResourceIDs.isEmpty {
            lines.append(bar + style.dim("shared   ") + safe(plan.selectedResourceIDs.map(\.rawValue).joined(separator: ", ")))
        }
        for warning in plan.warnings { lines.append(bar + style.warning("! ") + safe(warning)) }
        lines.append(bar + style.dim("plan     \(plan.id.rawValue)"))
        return lines.joined(separator: "\n")
    }

    /// A one-line peek at streamed activity. The full text arrives in the result.
    public func step(_ title: String) -> String {
        let first = safe(title).split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let room = max(10, width - 6)
        let shown = first.count > room ? String(first.prefix(room - 1)) + "…" : first
        return style.dim("  ⎿ " + shown)
    }

    public func running(_ runID: RunID, provider: String) -> String {
        style.accent("▶") + " " + style.bold("On it") + style.dim(" · \(provider) is digging · \(runID.rawValue)")
    }

    public func result(_ run: GADRunProjection, elapsed: Duration?) -> String {
        let time = elapsed.map { " · \(Self.format($0))" } ?? ""
        let heading: String = switch run.status {
        case .completed: style.success("✓ ") + style.bold("All done") + style.dim(time)
        case .failed: style.failure("✗ ") + style.bold("That didn't work") + style.dim(time)
        case .cancelled: style.dim("− ") + style.bold("Cancelled") + style.dim(time)
        default: WorkflowTextFormatter.status(run.status)
        }
        let body = safe(WorkflowTextFormatter.result(run))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }
            .joined(separator: "\n")
        var lines = [heading, "", body, ""]
        if run.status == .completed, run.risk != .readOnly {
            lines.append(style.dim("  next: goby diff \(run.id.rawValue) · goby commit \(run.id.rawValue) · goby result \(run.id.rawValue)"))
        }
        return lines.joined(separator: "\n")
    }

    public func approval(_ disclosure: String) -> String {
        let bar = style.warning("  ┃ ")
        let body = safe(disclosure).split(separator: "\n", omittingEmptySubsequences: false).map { bar + $0 }
        return ([style.warning("!") + " " + style.bold("Hold on, this needs your OK")] + body).joined(separator: "\n")
    }

    public func approvalNeeded(_ text: String) -> String { style.warning("! ") + safe(text) }
    public func success(_ text: String) -> String { style.success("✓ ") + safe(text) }
    public func note(_ text: String) -> String { style.accent("◆ ") + safe(text) }
    public func error(_ text: String) -> String { style.failure("✗ ") + safe(text) }
    public func farewell() -> String { style.dim(GobyPersona.mascot + " " + GobyPersona.pick(GobyPersona.farewells)) }

    public func sessionHelp(_ commands: [(usage: String, summary: String)]) -> String {
        let width = (commands.map(\.usage.count).max() ?? 10) + 2
        var lines = [style.bold("What I can do")]
        for command in commands {
            lines.append("  " + style.accent(command.usage.padding(toLength: width, withPad: " ", startingAt: 0)) + style.dim(command.summary))
        }
        lines.append("")
        lines.append(style.dim("Anything that isn't a /command is a request. Ctrl-C detaches from a run without cancelling it."))
        return lines.joined(separator: "\n")
    }

    public var help: String {
        [style.bold("In this session"),
         "  " + style.accent("/status") + style.dim("   runs, plans and approvals"),
         "  " + style.accent("/help") + style.dim("     this list"),
         "  " + style.accent("/exit") + style.dim("     leave (the host keeps running)"),
         "  " + style.dim("anything else is a request for Goby"),
         "",
         style.dim("Ctrl-C detaches from a run without cancelling it. Run goby help for every command.")
        ].joined(separator: "\n")
    }

    /// Provider and repository text never reaches the terminal unsanitized.
    private func safe(_ text: String) -> String { WorkflowTextFormatter.terminalSafe(text) }

    static func format(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// A single transient status line on standard error. Output written through
/// `interleave` clears the line first so results never mix with a frame.
public final class GobySpinner: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var lines: [String] = []
        var started = ContinuousClock.now
        var lineVisible = false
    }
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let state = Mutex(State())
    private let style: GobyTerminalStyle
    private let width: Int

    public init(style: GobyTerminalStyle, width: Int = GobyTerminalPresenter.terminalWidth()) {
        self.style = style
        self.width = width
    }

    /// Starts or retargets the line. Lines rotate every few seconds.
    public func start(_ lines: [String]) {
        guard style.enabled, !lines.isEmpty else { return }
        let alreadyRunning = state.withLock { state -> Bool in
            state.lines = lines.shuffled()
            if state.task == nil { state.started = .now }
            return state.task != nil
        }
        guard !alreadyRunning else { return }
        let task = Task.detached { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.draw(tick: tick)
                tick += 1
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
        state.withLock { $0.task = task }
    }

    public var elapsed: Duration? {
        state.withLock { $0.task == nil ? nil : ContinuousClock.now - $0.started }
    }

    public func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            defer { state.task = nil }
            if state.lineVisible { Self.clearLine(); state.lineVisible = false }
            return state.task
        }
        task?.cancel()
    }

    /// Clears the status line, then writes, so the next frame redraws below.
    public func interleave(_ write: () -> Void) {
        state.withLock { state in
            if state.lineVisible { Self.clearLine(); state.lineVisible = false }
            write()
        }
    }

    private func draw(tick: Int) {
        state.withLock { state in
            guard state.task != nil, !state.lines.isEmpty else { return }
            let elapsed = ContinuousClock.now - state.started
            let seconds = Int(elapsed.components.seconds)
            let text = state.lines[(seconds / 4) % state.lines.count] + "…"
            let frame = style.reduceMotion ? "◦" : Self.frames[tick % Self.frames.count]
            let meta = " (\(GobyTerminalPresenter.format(elapsed)) · ctrl-c detaches)"
            let available = max(10, width - 2 - meta.count)
            let shown = text.count > available ? String(text.prefix(available - 1)) + "…" : text
            let line = "\r\u{1B}[2K" + style.accent(frame) + " " + style.fish(shown) + style.dim(meta)
            FileHandle.standardError.write(Data(line.utf8))
            state.lineVisible = true
        }
    }

    private static func clearLine() {
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}
