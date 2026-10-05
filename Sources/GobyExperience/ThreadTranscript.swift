import Foundation
import GobyDomain

/// An agent's work as a conversation: its own sentences, with the tool calls
/// between two sentences folded into one line, as Claude and Codex show it.
public enum ThreadTranscriptItem: Identifiable, Equatable, Sendable {
    case message(RunActivityStep)
    case activity(ThreadToolGroup)

    public var id: String {
        switch self {
        case let .message(step): "message-\(step.id)"
        case let .activity(group): "group-\(group.id)"
        }
    }
}

/// Consecutive tool calls, with identical repeats merged.
public struct ThreadToolGroup: Identifiable, Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let step: RunActivityStep
        public let count: Int
        public var id: String { step.id }
    }

    public let id: String
    public let entries: [Entry]

    public var steps: [RunActivityStep] { entries.map(\.step) }
    public var running: RunActivityStep? { entries.last(where: { $0.step.status == .running })?.step }
    public var failureCount: Int { entries.filter { $0.step.status == .failed }.reduce(0) { $0 + $1.count } }

    /// "Read 9 files, 2 searches, ran 3 commands".
    public var summary: String {
        func count(_ kind: RunActivityStep.Kind) -> Int {
            entries.filter { $0.step.kind == kind }.reduce(0) { $0 + $1.count }
        }
        func plural(_ value: Int, _ one: String, _ many: String) -> String { value == 1 ? one : "\(value) \(many)" }
        var parts: [String] = []
        let reads = count(.read)
        if reads > 0 { parts.append("read " + plural(reads, "a file", "files")) }
        let searches = count(.search)
        if searches > 0 { parts.append(plural(searches, "1 search", "searches")) }
        let lists = count(.list)
        if lists > 0 { parts.append("listed " + plural(lists, "a folder", "folders")) }
        let commands = count(.command)
        if commands > 0 { parts.append("ran " + plural(commands, "a command", "commands")) }
        let edits = count(.fileChange)
        if edits > 0 { parts.append("edited " + plural(edits, "a file", "files")) }
        let web = count(.webSearch)
        if web > 0 { parts.append(plural(web, "1 web lookup", "web lookups")) }
        let tools = entries.filter { $0.step.kind == .tool }
        if !tools.isEmpty {
            let names = tools.map(\.step.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let total = tools.reduce(0) { $0 + $1.count }
            if names.count == 1 {
                let name = names[0].hasPrefix("Used ") ? String(names[0].dropFirst(5)) : names[0]
                parts.append("used \(name)" + (total > 1 ? " ×\(total)" : ""))
            } else {
                parts.append("used \(total) tools")
            }
        }
        if count(.plan) > 0 { parts.append("updated the plan") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

public enum ThreadTranscript {
    public static func items(_ steps: [RunActivityStep]) -> [ThreadTranscriptItem] {
        var items: [ThreadTranscriptItem] = []
        var pending: [ThreadToolGroup.Entry] = []

        func flush() {
            guard let first = pending.first else { return }
            items.append(.activity(ThreadToolGroup(id: first.step.id, entries: pending)))
            pending.removeAll()
        }

        for step in steps {
            if step.kind == .message || (step.kind == .plan && step.title.count > 80) {
                flush()
                items.append(.message(step))
                continue
            }
            if let last = pending.last,
               last.step.kind == step.kind, last.step.title == step.title,
               last.step.status == step.status, step.status != .running {
                pending[pending.count - 1] = .init(step: step, count: last.count + 1)
            } else {
                pending.append(.init(step: step, count: 1))
            }
        }
        flush()
        return items
    }
}
