import Foundation

public enum RunOutcomeSummary {
    /// Preserve assignment order and individual results, but report identical
    /// failures once with the number of affected assignments.
    public static func consolidate(_ assignments: [AgentAssignment]) -> String? {
        var failureCounts: [String: Int] = [:]
        for assignment in assignments where assignment.status == .failed {
            guard let reason = assignment.statusReason, !reason.isEmpty else { continue }
            failureCounts[reason, default: 0] += 1
        }
        var reportedFailures = Set<String>()
        let summaries = assignments.compactMap { assignment -> String? in
            guard let reason = assignment.statusReason else { return nil }
            guard assignment.status == .failed, let count = failureCounts[reason], count > 1 else {
                return reason
            }
            guard reportedFailures.insert(reason).inserted else { return nil }
            return "\(count) assignments failed with the same error:\n\n\(reason)"
        }
        return summaries.isEmpty ? nil : summaries.joined(separator: "\n\n")
    }

    /// Older runs stored the raw concatenation. Compact that known format for
    /// display without rewriting history or replacing a custom/provider outcome.
    public static func display(for run: RunRecord) -> String? {
        guard run.status == .failed,
              run.outcome == run.assignments.compactMap(\.statusReason).joined(separator: "\n\n") else {
            return run.outcome
        }
        return consolidate(run.assignments) ?? run.outcome
    }
}
