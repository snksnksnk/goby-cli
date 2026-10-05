import GobyDomain

/// Keeps the primary automation-row action identical across Mac and iPhone.
/// The policy intentionally exposes only the next useful action; it never
/// presents a disabled Run Now control while an occurrence owns the schedule.
public enum AutomationRowPrimaryAction: Equatable, Sendable {
    case review(AutomationOccurrenceID)
    case openRun(RunID)
    case resolve(AutomationOccurrenceID)
    case runNow
    case progress
}

public enum AutomationRowActionPolicy {
    public static func primaryAction(
        for occurrence: AutomationOccurrence?
    ) -> AutomationRowPrimaryAction {
        guard let occurrence else { return .runNow }
        guard !occurrence.status.isFinished else { return .runNow }

        let attempt = currentAttempt(in: occurrence)
        if occurrence.status == .needsAttention {
            if attempt?.status == .waitingForReview, attempt?.plan != nil {
                return .review(occurrence.id)
            }
            if let runID = attempt?.runID {
                return .openRun(runID)
            }
            return .resolve(occurrence.id)
        }

        if let runID = attempt?.runID {
            return .openRun(runID)
        }
        return .progress
    }

    private static func currentAttempt(
        in occurrence: AutomationOccurrence
    ) -> AutomationActionAttempt? {
        guard occurrence.actions.indices.contains(occurrence.currentActionIndex) else {
            return occurrence.attempts.last
        }
        let actionID = occurrence.actions[occurrence.currentActionIndex].id
        return occurrence.attempts.last(where: { $0.actionID == actionID })
    }
}
