import Foundation

/// One typed thing an agent did during a run: a message, a command, a file
/// change, a search or a tool call. Stored on the Mac for the run thread; the
/// remote projection keeps using the journal.
public struct RunActivityStep: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case message
        case command
        /// Reading, searching or listing files: exploration, shown compactly.
        case read
        case search
        case list
        case fileChange
        case webSearch
        case tool
        case plan
    }

    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
    }

    public static let titleLimit = 300
    public static let detailLimit = 2_000
    /// Agent narration is the conversation itself, so it keeps more text.
    public static let messageLimit = 8_000

    public let id: String
    public let assignmentID: AssignmentID
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let status: Status
    public let exitCode: Int?
    public let startedAt: Date
    public let finishedAt: Date?

    public init(
        id: String,
        assignmentID: AssignmentID,
        kind: Kind,
        title: String,
        detail: String? = nil,
        status: Status,
        exitCode: Int? = nil,
        startedAt: Date = .now,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.assignmentID = assignmentID
        self.kind = kind
        let titleLimit = kind == .message ? Self.messageLimit : Self.titleLimit
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLimit))
        self.detail = detail
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(Self.detailLimit)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Merges a later report for the same step, keeping its original start.
    public func updated(with later: RunActivityStep) -> RunActivityStep {
        RunActivityStep(
            id: id,
            assignmentID: assignmentID,
            kind: later.kind,
            title: later.title.isEmpty ? title : later.title,
            detail: later.detail ?? detail,
            status: later.status,
            exitCode: later.exitCode ?? exitCode,
            startedAt: startedAt,
            finishedAt: later.finishedAt ?? finishedAt
        )
    }
}

public enum RunActivityLog {
    /// Newest steps kept per run.
    public static let limit = 300

    /// Inserts or updates a step by id, keeping order of first appearance.
    public static func upserting(_ step: RunActivityStep, into steps: [RunActivityStep]) -> [RunActivityStep] {
        var result = steps
        if let index = result.firstIndex(where: { $0.id == step.id && $0.assignmentID == step.assignmentID }) {
            result[index] = result[index].updated(with: step)
        } else {
            result.append(step)
        }
        return result.count > limit ? Array(result.suffix(limit)) : result
    }
}

public extension Collection where Element == RunActivityStep {
    /// Every file a run reported changing, in first-seen order, without
    /// duplicates. Built only from completed file-change steps, so it reflects
    /// what the agent did rather than what it attempted.
    var changedFilePaths: [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for step in self where step.kind == .fileChange && step.status == .succeeded {
            for line in (step.detail ?? "").split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        return paths
    }
}
