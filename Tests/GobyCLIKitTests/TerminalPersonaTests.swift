import Foundation
import GobyApplication
import GobyCLIKit
import GobyDomain
import Testing

@Suite("Goby terminal persona")
struct TerminalPersonaTests {
    private let escape = "\u{1B}["

    @Test("Plain style adds no escape sequences")
    func plainStyleIsPlain() {
        let presenter = GobyTerminalPresenter(style: .plain, width: 80)
        let rendered = [
            presenter.banner(version: "1.0", repository: "demo", provider: "Codex"),
            presenter.note("First time in demo."),
            presenter.error("Something failed."),
            presenter.help,
        ].joined(separator: "\n")
        #expect(!rendered.contains(escape))
    }

    @Test("Provider text cannot inject terminal escapes into styled output")
    func providerTextIsSanitizedBeforeStyling() {
        let presenter = GobyTerminalPresenter(style: GobyTerminalStyle(enabled: true), width: 80)
        let hostile = "done\u{1B}]52;c;ZXZpbA==\u{07}\u{1B}[2J"
        let outputs = [presenter.step(hostile), presenter.approval(hostile), presenter.error(hostile), presenter.note(hostile)]
        for output in outputs {
            #expect(!output.contains("\u{1B}]"))
            #expect(!output.contains("\u{07}"))
            #expect(!output.contains("\u{1B}[2J"))
            #expect(output.contains(escape)) // Goby's own styling remains.
        }
    }

    @Test("Banner rows line up at a fixed width")
    func bannerRowsAlign() {
        let presenter = GobyTerminalPresenter(style: .plain, width: 80)
        let rows = presenter.banner(version: "0.2.0", repository: "my-project", provider: "Claude")
            .split(separator: "\n")
            .filter { $0.hasPrefix("│") || $0.hasPrefix("╭") || $0.hasPrefix("╰") }
        #expect(rows.count >= 8)
        #expect(Set(rows.map(\.count)).count == 1)
    }

    @Test("NO_COLOR, dumb terminals and missing TERM disable decoration")
    func environmentDisablesDecoration() {
        #expect(!GobyTerminalStyle.detect(environment: ["NO_COLOR": "1", "TERM": "xterm-256color"]).enabled)
        #expect(!GobyTerminalStyle.detect(environment: ["TERM": "dumb"]).enabled)
        #expect(!GobyTerminalStyle.detect(environment: [:]).enabled)
        #expect(GobyTerminalStyle.detect(environment: ["GOBY_NO_ANIMATION": "1"]).reduceMotion)
    }

    @Test("Streamed activity is a single truncated line")
    func stepIsOneLine() {
        let presenter = GobyTerminalPresenter(style: .plain, width: 40)
        let step = presenter.step("First line of a long thought that keeps going past the edge\nsecond line")
        #expect(!step.contains("\n"))
        #expect(!step.contains("second line"))
        #expect(step.count <= 40)
        #expect(step.hasSuffix("…"))
    }

    @Test("Answers render light Markdown when decorated, and stay untouched when plain")
    func markdownRendering() {
        let source = "## Handoff notes\n- Read **README.md** with `cat`\n```\nswift test\n```\nSee [docs](https://example.com)."
        #expect(GobyTerminalPresenter(style: .plain, width: 80).markdown(source) == source)
        let styled = GobyTerminalPresenter(style: GobyTerminalStyle(enabled: true), width: 80).markdown(source)
        let visible = styled.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(visible == "Handoff notes\n• Read README.md with cat\n│ swift test\nSee docs (https://example.com).", Comment(rawValue: visible.debugDescription))
        #expect(styled.contains("\u{1B}[1m"))
    }

    @Test("A non-interactive terminal never decorates")
    func nonInteractiveIOIsPlain() {
        let io = GobyTerminalIO(interactive: false, write: { _ in }, read: { _ in nil },
                                style: GobyTerminalStyle(enabled: true))
        #expect(!io.style.enabled)
    }
}
