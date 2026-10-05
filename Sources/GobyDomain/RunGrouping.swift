import Foundation

/// The three Home lanes both the Mac and iOS use to group runs. A draft has
/// not started and belongs to no lane.
public enum RunLane: String, CaseIterable, Hashable, Sendable {
    case needsAttention
    case active
    case recentlyCompleted

    public init?(_ status: RunStatus) {
        switch status {
        case .needsAttention, .failed: self = .needsAttention
        case .ready, .running: self = .active
        case .completed, .cancelled: self = .recentlyCompleted
        case .draft: return nil
        }
    }
}

/// A run record that can say which projects it touched, so "conversations in
/// this project" means the same thing on every platform.
public protocol ProjectScopedRun {
    var id: RunID { get }
    var updatedAt: Date { get }
    /// Every project the run was planned for, snapshotted, or assigned in.
    var scopedProjectIDs: Set<ProjectID> { get }
}

public extension Sequence where Element: ProjectScopedRun {
    /// Runs that touched the project, newest first with a stable tie order.
    func touching(_ projectID: ProjectID) -> [Element] {
        filter { $0.scopedProjectIDs.contains(projectID) }
            .sorted {
                $0.updatedAt != $1.updatedAt
                    ? $0.updatedAt > $1.updatedAt
                    : $0.id.rawValue < $1.id.rawValue
            }
    }
}

extension RunRecord: ProjectScopedRun {
    public var scopedProjectIDs: Set<ProjectID> {
        Set(projectSnapshot.map(\.id))
            .union(assignments.map(\.projectID))
            .union(plan.routes.map(\.projectID))
    }
}
