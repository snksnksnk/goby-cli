import Foundation

/// A commit-only request commits the user's own changes on their current
/// branch, in the project folder, instead of an isolated worktree. A push is
/// a separate, explicitly approved step that Goby performs itself.
extension RoutingPlan {
    public func commitsWorkingCopy(of projectID: ProjectID) -> Bool {
        gitOperations.contains { $0.projectID == projectID && $0.kind == .commit }
            && !gitOperations.contains { $0.projectID == projectID && $0.kind == .createWorktree }
    }

    public var commitsWorkingCopy: Bool {
        routes.contains { commitsWorkingCopy(of: $0.projectID) }
    }

    /// Git work Goby does in the project folder itself: committing the
    /// user's changes, or pushing a branch an earlier run committed.
    public func runsInProjectFolder(of projectID: ProjectID) -> Bool {
        let operations = gitOperations.filter { $0.projectID == projectID }
        return !operations.isEmpty
            && !operations.contains { $0.kind == .createWorktree }
            && operations.allSatisfy { $0.kind == .commit || $0.kind == .push }
    }

    public var runsInProjectFolder: Bool {
        routes.contains { runsInProjectFolder(of: $0.projectID) }
    }

    /// Pushing is all this plan does, so it has nothing to run without the
    /// push approval.
    public var pushesOnly: Bool {
        !gitOperations.isEmpty && gitOperations.allSatisfy { $0.kind == .push }
    }

    public var pushOperations: [PlannedGitOperation] {
        gitOperations.filter { $0.kind == .push }
    }

    /// The same plan without its push steps, for an approval that did not
    /// switch pushing on.
    public func removingPushOperations() -> RoutingPlan {
        replacingGitOperations(gitOperations.filter { $0.kind != .push })
    }

    public func replacingGitOperations(
        _ operations: [PlannedGitOperation],
        warnings: [String]? = nil
    ) -> RoutingPlan {
        RoutingPlan(
            id: id,
            interpretedGoal: interpretedGoal,
            attachments: attachments,
            routes: routes,
            risk: risk,
            confidence: confidence,
            gitOperations: operations,
            warnings: warnings ?? self.warnings,
            createdAt: createdAt,
            deliveryPipeline: deliveryPipeline
        )
    }
}
