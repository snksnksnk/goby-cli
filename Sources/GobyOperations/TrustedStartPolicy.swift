import GobyDomain

/// Decides whether a plan may start without a review click because the user
/// trusts every project it touches.
///
/// Trust is a standing, local, revocable opt-in per project. It never widens
/// what a plan discloses: the start is still an ordinary approved start, and
/// the host still binds the disclosed worktree, branch and commit operations.
/// Everything that needs its own decision stays out of reach.
public enum TrustedStartPolicy {
    public static func allows(
        plan: RoutingPlan,
        trustedProjectIDs: Set<ProjectID>,
        lab: LabSnapshot,
        hasSelectedResources: Bool,
        hasBlockingReadinessIssue: Bool
    ) -> Bool {
        guard !trustedProjectIDs.isEmpty,
              !hasSelectedResources,
              !hasBlockingReadinessIssue,
              !plan.routes.isEmpty,
              plan.routes.allSatisfy({ !$0.agentIDs.isEmpty }),
              plan.risk <= .medium,
              plan.confidence >= 0.8,
              plan.warnings.isEmpty,
              !plan.hasMultiStagePipeline,
              plan.deliveryPipeline?.includesRelease != true else { return false }

        // Pushes, merges, history rewrites, tags and deletions always ask.
        guard !plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval }) else {
            return false
        }

        for route in plan.routes {
            guard trustedProjectIDs.contains(route.projectID),
                  let project = lab.projects.first(where: { $0.id == route.projectID }),
                  project.isGitRepository else { return false }
            // Edits must be isolated: the plan has to disclose a worktree for
            // this project, so a non-isolated change can never skip review.
            let hasWorktree = plan.gitOperations.contains {
                $0.projectID == route.projectID && $0.kind == .createWorktree
            }
            guard hasWorktree else { return false }
        }
        // Operations on a project the plan does not route to are unexpected.
        let routed = Set(plan.routes.map(\.projectID))
        return plan.gitOperations.allSatisfy { routed.contains($0.projectID) }
    }
}
