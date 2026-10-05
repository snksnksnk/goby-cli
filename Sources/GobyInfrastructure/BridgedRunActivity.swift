import Foundation
import GobyApplication
import GobyDomain

/// Builds run-thread steps from the Claude and GitHub Copilot bridges' existing
/// notifications: whole assistant messages and completed tool calls. No bridge
/// protocol change is needed; steps appear when each tool call finishes.
enum BridgedRunActivity {
    static func messageStep(
        assignmentID: AssignmentID,
        text: String,
        sequence: Int,
        now: Date = .now
    ) -> RunActivityStep? {
        let cleaned = SensitiveTextRedactor.redactCredentials(text, limit: RunActivityStep.messageLimit)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RunActivityStep(
            id: "message-\(sequence)", assignmentID: assignmentID, kind: .message,
            title: cleaned, status: .succeeded, startedAt: now, finishedAt: now
        )
    }

    /// `command` is the shell command for shell tools, otherwise
    /// `ToolName {json input}` (see `commandFor` in the bridges).
    static func toolStep(
        assignmentID: AssignmentID,
        evidenceID: String,
        command: String,
        actionCommands: [String],
        succeeded: Bool,
        exitCode: Int?,
        output: String?,
        now: Date = .now
    ) -> RunActivityStep {
        let status: RunActivityStep.Status = succeeded ? .succeeded : .failed
        let redactedOutput = output.map { SensitiveTextRedactor.redactCredentials($0, limit: 64_000) }
        func step(_ kind: RunActivityStep.Kind, _ title: String, detail: String? = redactedOutput) -> RunActivityStep {
            RunActivityStep(
                id: evidenceID, assignmentID: assignmentID, kind: kind,
                title: SensitiveTextRedactor.redactCredentials(title, limit: RunActivityStep.titleLimit),
                detail: detail, status: status, exitCode: exitCode, startedAt: now, finishedAt: now
            )
        }
        guard let tool = actionCommands.first else {
            return step(.command, command)
        }
        let input = toolInput(command: command, tool: tool)
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
        }
        func fileName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

        switch tool.lowercased() {
        case "edit", "multiedit", "write", "notebookedit", "create", "str_replace_editor", "apply_patch":
            let path = string("file_path", "notebook_path", "path", "fileName")
            return step(.fileChange, path.map { "Edited \(fileName($0))" } ?? "Edited files", detail: path)
        case "read", "view":
            let path = string("file_path", "path")
            return step(.read, path.map { "Read \(fileName($0))" } ?? "Read a file", detail: nil)
        case "glob", "grep", "search", "ls":
            let pattern = string("pattern", "query", "path")
            return step(.search, pattern.map { "Searched “\($0)”" } ?? "Searched files", detail: nil)
        case "webfetch", "web_fetch", "fetch":
            return step(.webSearch, string("url").map { "Opened \($0)" } ?? "Opened a web page", detail: nil)
        case "websearch", "web_search":
            return step(.webSearch, string("query").map { "Searched “\($0)”" } ?? "Searched the web", detail: nil)
        case "todowrite", "update_todo":
            return step(.plan, "Updated the task list", detail: nil)
        default:
            return step(.tool, "Used \(tool)")
        }
    }

    private static func toolInput(command: String, tool: String) -> [String: Any] {
        guard command.hasPrefix(tool) else { return [:] }
        let json = command.dropFirst(tool.count).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
