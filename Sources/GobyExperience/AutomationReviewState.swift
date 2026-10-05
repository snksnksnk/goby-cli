import GobyApplication
import GobyDomain

/// Resolves a mobile review against the latest host projection. A sheet keeps
/// only the occurrence ID so an advanced or withdrawn action cannot retain an
/// executable plan from the projection that originally opened it.
public struct AutomationReviewState: Equatable, Sendable {
    public let plan: RoutingPlan
    public let binding: AutomationReviewBinding

    public static func current(
        occurrenceID: AutomationOccurrenceID,
        in projection: DashboardProjection?
    ) -> Self? {
        guard let occurrence = projection?.automations.occurrences.first(where: { $0.id == occurrenceID }),
              let plan = occurrence.currentReviewAttempt?.plan,
              let binding = occurrence.currentReviewBinding else { return nil }
        return Self(plan: plan, binding: binding)
    }
}
