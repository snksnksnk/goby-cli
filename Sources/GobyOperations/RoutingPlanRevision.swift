import Foundation
import GobyDomain

/// Rebuilds every user-visible plan fact after scope editing so the plan remains
/// one consistent authorization boundary.
public enum RoutingPlanRevision {
    public static func make(
        from plan: RoutingPlan,
        routes: [ProjectRoute],
        gitOperations: [PlannedGitOperation],
        projects: [LabProject]
    ) -> RoutingPlan {
        let sortedRoutes = routes.sorted { $0.projectID.rawValue < $1.projectID.rawValue }
        let routedProjectIDs = Set(sortedRoutes.map(\.projectID))
        let revisedWarnings = plan.warnings.filter { warning in
            guard let project = projects.first(where: {
                warning.range(
                    of: $0.name + " ",
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) != nil
            }) else { return true }
            return routedProjectIDs.contains(project.id)
        }
        let warningDifference = plan.warnings.count - revisedWarnings.count
        let confidence: Double
        if sortedRoutes.isEmpty {
            confidence = 0.2
        } else {
            confidence = min(max(plan.confidence + Double(warningDifference) * 0.08, 0), 1)
        }
        let risk: PlanRisk = switch plan.risk {
        case .readOnly: .readOnly
        case .low: .low
        case .medium, .high: sortedRoutes.count > 5 ? .high : .medium
        }

        return RoutingPlan(
            id: plan.id,
            interpretedGoal: plan.interpretedGoal,
            attachments: plan.attachments,
            routes: sortedRoutes,
            risk: risk,
            confidence: confidence,
            gitOperations: gitOperations,
            warnings: revisedWarnings,
            createdAt: plan.createdAt,
            deliveryPipeline: plan.deliveryPipeline?.restricted(to: sortedRoutes)
        )
    }
}
