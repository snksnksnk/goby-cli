import Foundation
import GobyDomain

public typealias CodexActivityRefresh = ProviderActivityFreshness

/// A presentation-only projection for Goby's global activity popover.
/// It keeps actionable work ahead of routine activity and prevents a run with
/// a pending approval from appearing twice in the same queue.
public struct OperationsCenterSnapshot: Sendable {
    public let approvalRuns: [RunRecord]
    public let attentionRuns: [RunRecord]
    public let currentRuns: [RunRecord]
    public let recentRuns: [RunRecord]
    public let codexAttentionTasks: [CodexTaskActivity]
    public let codexActiveTasks: [CodexTaskActivity]
    public let codexActivityRefresh: CodexActivityRefresh
    public let pendingApprovalCount: Int

    public init(
        runs: [RunRecord],
        codexTasks: [CodexTaskActivity],
        pendingApprovalAssignmentIDs: [AssignmentID],
        codexActivityRefresh: CodexActivityRefresh = .fresh(at: .distantPast),
        recentLimit: Int = 3,
        clearedAt: Date? = nil
    ) {
        let approvalAssignmentIDs = Set(pendingApprovalAssignmentIDs)
        // Clear hides failed and finished runs that have not changed since;
        // runs still waiting on a decision stay until they are resolved.
        let sortedRuns = runs.sorted { $0.updatedAt > $1.updatedAt }.filter { run in
            guard let clearedAt, run.updatedAt <= clearedAt else { return true }
            return ![.failed, .completed, .cancelled].contains(run.status)
        }
        let runsWithApprovals = sortedRuns.filter { run in
            run.assignments.contains { approvalAssignmentIDs.contains($0.id) }
        }
        let approvalRunIDs = Set(runsWithApprovals.map(\.id))

        approvalRuns = runsWithApprovals
        attentionRuns = sortedRuns.filter {
            RunLane($0.status) == .needsAttention && !approvalRunIDs.contains($0.id)
        }
        currentRuns = sortedRuns.filter { RunLane($0.status) == .active }
        recentRuns = Array(sortedRuns.filter {
            RunLane($0.status) == .recentlyCompleted
        }.prefix(max(0, recentLimit)))
        codexAttentionTasks = codexTasks.filter(\.status.needsAttention).sorted {
            $0.updatedAt > $1.updatedAt
        }
        codexActiveTasks = codexTasks.filter { $0.status == .active }.sorted {
            $0.updatedAt > $1.updatedAt
        }
        self.codexActivityRefresh = codexActivityRefresh
        pendingApprovalCount = pendingApprovalAssignmentIDs.count
    }

    public var actionCount: Int {
        pendingApprovalCount
            + attentionRuns.count
            + (codexActivityRefresh.isStale ? 0 : codexAttentionTasks.count)
    }

    public var currentCount: Int {
        currentRuns.count
            + (codexActivityRefresh.isStale ? 0 : codexActiveTasks.count)
    }

    public var staleCodexTasks: [CodexTaskActivity] {
        guard codexActivityRefresh.isStale else { return [] }
        return (codexAttentionTasks + codexActiveTasks).sorted { $0.updatedAt > $1.updatedAt }
    }

    public var isEmpty: Bool {
        actionCount == 0
            && currentCount == 0
            && recentRuns.isEmpty
            && staleCodexTasks.isEmpty
    }

    public func run(containing assignmentID: AssignmentID) -> RunRecord? {
        approvalRuns.first { run in
            run.assignments.contains { $0.id == assignmentID }
        }
    }
}
