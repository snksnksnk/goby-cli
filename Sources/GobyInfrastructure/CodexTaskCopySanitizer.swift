import Foundation

enum CodexTaskCopySanitizer {
    struct Copy: Equatable, Sendable {
        let title: String
        let summary: String?
    }

    static func copy(
        id: String,
        name: String?,
        preview: String?,
        isSubagent: Bool
    ) -> Copy {
        let safeName = sanitized(name, maximumLength: 180)
        let safePreview = sanitized(preview, maximumLength: 240)
        let title = safeName
            ?? safePreview
            ?? "Imported Codex \(isSubagent ? "subagent" : "task") · \(String(id.prefix(8)))"
        let summary = safePreview.flatMap { $0 == title ? nil : $0 }
        return Copy(title: title, summary: summary)
    }

    private static func sanitized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, collapsed.count <= maximumLength else { return nil }
        let lowered = collapsed.lowercased()
        let internalMarkers = [
            ">>> transcript", "codex agent history", "[tool]", "tool call",
            "assistant to=", "recipient=", "<developer", "<system",
            "analysis channel", "commentary channel", "custom_tool_call"
        ]
        guard !internalMarkers.contains(where: lowered.contains) else { return nil }
        return collapsed
    }
}
