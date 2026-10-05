import Foundation
import GobyDomain

/// Counts tasks, rather than runs: one run can contain both working and blocked agents.
public struct DockStatusSnapshot: Equatable, Sendable {
    public let workingCount: Int
    public let attentionCount: Int
    public let isLive: Bool

    public init(
        runs: [RunRecord],
        providerTasks: [ProviderTaskActivity],
        pendingApprovalAssignmentIDs: [AssignmentID],
        freshProviderIDs: Set<AgentProviderID>,
        isLive: Bool
    ) {
        self.isLive = isLive
        guard isLive else {
            workingCount = 0
            attentionCount = 0
            return
        }
        let approvals = Set(pendingApprovalAssignmentIDs)
        var seenAssignments = Set<AssignmentID>()
        var seenTasks = Set<ProviderTaskIdentity>()
        var working = 0
        var attention = 0

        for run in runs.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard run.status == .running || run.status == .needsAttention || run.status == .failed else { continue }
            var hasAttentionTask = false
            for assignment in run.assignments {
                let needsAttention = approvals.contains(assignment.id)
                    || [.waitingForApproval, .paused, .failed].contains(assignment.status)
                hasAttentionTask = hasAttentionTask || needsAttention
                guard seenAssignments.insert(assignment.id).inserted else { continue }
                if let taskID = assignment.providerTaskID {
                    guard seenTasks.insert(.init(providerID: assignment.providerID, nativeID: taskID)).inserted else { continue }
                }
                if needsAttention {
                    attention += 1
                } else if assignment.status == .working, run.status != .failed {
                    working += 1
                }
            }
            for task in run.helperTasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                hasAttentionTask = hasAttentionTask || task.status.needsAttention
                guard seenTasks.insert(task.identity).inserted else { continue }
                if task.status.needsAttention {
                    attention += 1
                } else if task.status == .working, run.status != .failed {
                    working += 1
                }
            }
            // Preparation and recovery can require action before an agent exists.
            if (run.status == .needsAttention || run.status == .failed), !hasAttentionTask {
                attention += 1
            }
        }
        attention += approvals.subtracting(seenAssignments).count

        for task in providerTasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard freshProviderIDs.contains(task.providerID),
                  seenTasks.insert(task.identity).inserted else { continue }
            if task.status.needsAttention {
                attention += 1
            } else if task.status == .working {
                working += 1
            }
        }
        workingCount = working
        attentionCount = attention
    }

    public var accessibilitySummary: String {
        guard isLive else { return "Goby — live status unavailable" }
        guard workingCount > 0 || attentionCount > 0 else { return "Goby — no active work" }
        return "Goby — \(workingCount) working, \(attentionCount) \(attentionCount == 1 ? "needs" : "need") attention"
    }
}
