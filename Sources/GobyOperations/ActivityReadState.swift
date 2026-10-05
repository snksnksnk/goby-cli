import Foundation
import GobyDomain

/// Which Activity panel items the user has seen, as in Notification Center.
/// A run is unread when it changed after the user last saw it; running work
/// is shown live and is never unread.
public struct ActivityReadState: Equatable, Sendable {
    public private(set) var marks: [RunID: Date]
    /// Runs last changed before this are already read, so history that
    /// predates read state does not arrive as a wall of unread items.
    public let baseline: Date

    public init(marks: [RunID: Date] = [:], baseline: Date) {
        self.marks = marks
        self.baseline = baseline
    }

    public func isUnread(_ run: RunRecord) -> Bool {
        guard ![.draft, .ready, .running].contains(run.status) else { return false }
        return run.updatedAt > max(marks[run.id] ?? .distantPast, baseline)
    }

    /// Returns whether anything changed.
    @discardableResult
    public mutating func markRead(_ run: RunRecord) -> Bool {
        guard (marks[run.id] ?? .distantPast) < run.updatedAt else { return false }
        marks[run.id] = run.updatedAt
        return true
    }

    /// Forgets runs that no longer exist so the record stays small.
    public mutating func retain(_ runIDs: Set<RunID>) {
        marks = marks.filter { runIDs.contains($0.key) }
    }
}
