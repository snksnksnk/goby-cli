import Darwin
import Foundation
import Synchronization

/// What one prompt read produced.
public enum GobyLineInput: Equatable, Sendable {
    case line(String)
    /// Ctrl-D on an empty line, or the input closed.
    case endOfInput
    /// Ctrl-C on an empty line.
    case interrupt
}

/// A small line editor for Goby's interactive session. Typing `/` opens a
/// live list of matching commands under the prompt: Tab or → accepts, ↑ ↓
/// move through it, Esc closes it. Without a list, ↑ ↓ walk the history.
///
/// It runs only on an interactive, decorated terminal. Everything else keeps
/// line-buffered input, so pipes, scripts and tests are unchanged.
public final class GobyLineEditor: Sendable {
    public struct Command: Sendable {
        public let name: String
        public let usage: String
        public let summary: String
        public init(name: String, usage: String, summary: String) {
            self.name = name; self.usage = usage; self.summary = summary
        }
        /// Commands whose usage names an argument wait for it after completion.
        var takesArguments: Bool { usage.contains("<") || usage.contains("[") }
    }

    private struct State {
        var history: [String] = []
    }

    public static let menuLimit = 8
    private let style: GobyTerminalStyle
    private let commands: [Command]
    private let state = Mutex(State())

    public init(style: GobyTerminalStyle, commands: [Command]) {
        self.style = style
        self.commands = commands
    }

    // MARK: Pure editing model (tested without a terminal)

    /// Commands matching the typed `/word`, best first: prefix, then contains.
    public func suggestions(for buffer: String) -> [Command] {
        guard buffer.hasPrefix("/"), !buffer.contains(" ") else { return [] }
        let typed = buffer.dropFirst().lowercased()
        let prefix = commands.filter { $0.name.hasPrefix(typed) }
        let contains = typed.isEmpty ? [] : commands.filter { !$0.name.hasPrefix(typed) && $0.name.contains(typed) }
        return Array((prefix + contains).prefix(Self.menuLimit))
    }

    /// The buffer after accepting a suggestion.
    public static func completion(for command: Command) -> String {
        "/" + command.name + (command.takesArguments ? " " : "")
    }

    // MARK: Terminal loop

    /// Blocking; call off the main actor. Restores the terminal before returning.
    public func readLine(prompt: String) -> GobyLineInput {
        guard let original = Self.enterRawMode() else {
            FileHandle.standardError.write(Data(prompt.utf8))
            return Swift.readLine().map { .line($0) } ?? .endOfInput
        }
        defer { Self.restore(original) }

        let history = state.withLock { $0.history }
        var buffer: [Character] = []
        var cursor = 0
        var selection = 0
        var menuDismissed = false
        var historyIndex = history.count
        var draftBeforeHistory = ""
        var cursorRow = 0
        let width = max(20, GobyTerminalPresenter.terminalWidth())
        let promptWidth = Self.visibleWidth(prompt)

        func currentText() -> String { String(buffer) }
        func menu() -> [Command] { menuDismissed ? [] : suggestions(for: currentText()) }

        func render() {
            var out = ""
            // Back to the first row of the prompt, then clear everything below.
            if cursorRow > 0 { out += "\u{1B}[\(cursorRow)A" }
            out += "\r\u{1B}[J"
            out += prompt + WorkflowSafe.text(currentText())
            let items = menu()
            if selection >= items.count { selection = max(0, items.count - 1) }
            let endColumn = promptWidth + buffer.count
            let endRow = endColumn / width
            var below = 0
            if !items.isEmpty {
                let nameWidth = (items.map(\.usage.count).max() ?? 0) + 2
                for (index, item) in items.enumerated() {
                    let selected = index == selection
                    let usage = item.usage.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let room = max(0, width - 4 - nameWidth)
                    let summary = item.summary.count > room ? String(item.summary.prefix(max(0, room - 1))) + "…" : item.summary
                    let marker = selected ? style.accent("› ") : "  "
                    let text = selected ? style.bold(usage) + style.dim(summary) : style.dim(usage + summary)
                    out += "\r\n" + marker + text
                    below += 1
                }
            }
            // Move from the end of the menu back to the cursor position.
            let cursorColumn = promptWidth + cursor
            let targetRow = cursorColumn / width
            let rowsUp = below + (endRow - targetRow)
            if rowsUp > 0 { out += "\u{1B}[\(rowsUp)A" }
            out += "\r"
            let column = cursorColumn % width
            if column > 0 { out += "\u{1B}[\(column)C" }
            cursorRow = targetRow
            FileHandle.standardError.write(Data(out.utf8))
        }

        func finish() {
            // Leave the cursor after the line, with the menu cleared.
            let endRow = (promptWidth + buffer.count) / width
            var out = ""
            if endRow > cursorRow { out += "\u{1B}[\(endRow - cursorRow)B" }
            out += "\r\n\u{1B}[J"
            FileHandle.standardError.write(Data(out.utf8))
        }

        func accept(_ command: Command) {
            buffer = Array(Self.completion(for: command))
            cursor = buffer.count
            selection = 0
            menuDismissed = false
        }

        func setText(_ text: String) {
            buffer = Array(text); cursor = buffer.count; selection = 0; menuDismissed = false
        }

        render()
        var pending: [UInt8] = []
        while true {
            guard let byte = Self.readByte() else { finish(); return .endOfInput }
            switch byte {
            case 3: // Ctrl-C clears the line, or leaves on an empty one.
                if buffer.isEmpty { finish(); return .interrupt }
                setText("")
            case 4: // Ctrl-D
                if buffer.isEmpty { finish(); return .endOfInput }
                if cursor < buffer.count { buffer.remove(at: cursor) }
            case 13, 10: // Enter
                let items = menu()
                if !items.isEmpty, selection < items.count {
                    let chosen = items[selection]
                    let typed = String(currentText().dropFirst())
                    if typed != chosen.name {
                        accept(chosen)
                        if chosen.takesArguments { break }
                    }
                }
                let line = currentText()
                finish()
                remember(line)
                return .line(line)
            case 9: // Tab accepts the highlighted suggestion.
                let items = menu()
                if !items.isEmpty { accept(items[selection]) }
            case 127, 8: // Backspace
                if cursor > 0 { buffer.remove(at: cursor - 1); cursor -= 1; menuDismissed = false }
            case 1: cursor = 0 // Ctrl-A
            case 5: cursor = buffer.count // Ctrl-E
            case 21: buffer.removeFirst(cursor); cursor = 0; menuDismissed = false // Ctrl-U
            case 11: buffer.removeLast(buffer.count - cursor) // Ctrl-K
            case 23: // Ctrl-W deletes the previous word.
                var start = cursor
                while start > 0, buffer[start - 1] == " " { start -= 1 }
                while start > 0, buffer[start - 1] != " " { start -= 1 }
                buffer.removeSubrange(start..<cursor); cursor = start; menuDismissed = false
            case 27: // Escape sequences: arrows, Home/End, or a bare Esc.
                guard Self.byteIsReady(), let next = Self.readByte() else {
                    menuDismissed = true
                    break
                }
                guard next == 91 || next == 79, let code = Self.readByte() else { break }
                let items = menu()
                switch code {
                case 65: // Up
                    if !items.isEmpty { selection = (selection - 1 + items.count) % items.count }
                    else if historyIndex > 0 {
                        if historyIndex == history.count { draftBeforeHistory = currentText() }
                        historyIndex -= 1; setText(history[historyIndex]); menuDismissed = true
                    }
                case 66: // Down
                    if !items.isEmpty { selection = (selection + 1) % items.count }
                    else if historyIndex < history.count {
                        historyIndex += 1
                        setText(historyIndex == history.count ? draftBeforeHistory : history[historyIndex])
                        menuDismissed = true
                    }
                case 67: // Right accepts at the end of the line, otherwise moves.
                    if cursor == buffer.count, !items.isEmpty { accept(items[selection]) }
                    else if cursor < buffer.count { cursor += 1 }
                case 68: if cursor > 0 { cursor -= 1 } // Left
                case 72: cursor = 0 // Home
                case 70: cursor = buffer.count // End
                case 51: // Delete is ESC [ 3 ~
                    if Self.readByte() == 126, cursor < buffer.count { buffer.remove(at: cursor) }
                case 50: // Bracketed paste markers (ESC [ 200~ / 201~): ignore.
                    while let b = Self.readByte(), b != 126 {}
                default: break
                }
            default:
                guard byte >= 32 else { break }
                pending.append(byte)
                // Collect a whole UTF-8 scalar before inserting it.
                let expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                while pending.count < expected, let more = Self.readByte() { pending.append(more) }
                for character in String(decoding: pending, as: UTF8.self) {
                    buffer.insert(character, at: cursor); cursor += 1
                }
                pending.removeAll()
                menuDismissed = false
            }
            render()
        }
    }

    private func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.withLock { state in
            if state.history.last != trimmed { state.history.append(trimmed) }
            if state.history.count > 200 { state.history.removeFirst(state.history.count - 200) }
        }
    }

    // MARK: Raw terminal mode

    private static let saved = Mutex<termios?>(nil)

    private static func enterRawMode() -> termios? {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        // Keystrokes arrive one by one, unechoed; Ctrl-C arrives as a byte.
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        saved.withLock { $0 = original }
        registerExitRestore()
        return original
    }

    private static func restore(_ original: termios) {
        var original = original
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        saved.withLock { $0 = nil }
    }

    /// If the process exits while editing, give the terminal back.
    private static let exitHook: Void = {
        atexit {
            if var original = GobyLineEditor.saved.withLock({ $0 }) {
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            }
        }
    }()

    private static func registerExitRestore() { _ = exitHook }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 { return byte }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// True when another byte follows within a few milliseconds, which tells
    /// an arrow key's escape sequence apart from a bare Esc press.
    private static func byteIsReady() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 30) > 0
    }

    static func visibleWidth(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }
}

private enum WorkflowSafe {
    /// Typed text is echoed as data; control characters never reach the terminal.
    static func text(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
    }
}
