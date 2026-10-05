import GobyDomain

public extension RunRecord {
    /// Keeps exact run-review metadata for the signed local UI while excluding
    /// attachment bodies and file bytes. Reuse is a semantic host command, so
    /// the authoritative copy retains those sources without sending them over IPC.
    var localPresentationCopy: RunRecord {
        let presentationPlan = RoutingPlan(
            id: plan.id,
            interpretedGoal: plan.interpretedGoal,
            attachments: plan.attachments.map { $0.redactedReference() },
            routes: plan.routes,
            risk: plan.risk,
            confidence: plan.confidence,
            gitOperations: plan.gitOperations,
            warnings: plan.warnings,
            createdAt: plan.createdAt
        )
        let presentationAssignments = assignments.map { assignment in
            AgentAssignment(
                id: assignment.id,
                runID: assignment.runID,
                projectID: assignment.projectID,
                agentID: assignment.agentID,
                status: assignment.status,
                currentTask: assignment.currentTask,
                attachments: assignment.attachments.map { $0.redactedReference() },
                progress: assignment.progress,
                startedAt: assignment.startedAt,
                statusReason: assignment.statusReason,
                workingDirectory: assignment.workingDirectory,
                workingDirectoryIdentity: assignment.workingDirectoryIdentity,
                codexThreadID: assignment.codexThreadID,
                codexTurnID: assignment.codexTurnID,
                providerID: assignment.providerID,
                providerBindingID: assignment.providerBindingID,
                model: assignment.model,
                providerTaskID: assignment.providerTaskID,
                providerTurnID: assignment.providerTurnID,
                handoffID: assignment.handoffID,
                deliveryStageID: assignment.deliveryStageID
            )
        }
        return RunRecord(
            id: id,
            plan: presentationPlan,
            status: status,
            assignments: presentationAssignments,
            helperTasks: helperTasks,
            outcome: outcome,
            approvalReceipts: approvalReceipts,
            instructionSnapshot: instructionSnapshot,
            agentSnapshot: agentSnapshot,
            providerBindingSnapshot: providerBindingSnapshot,
            projectSnapshot: projectSnapshot,
            automationExecutionAuthorityDigest: automationExecutionAuthorityDigest,
            automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests,
            journal: journal,
            resourceSnapshot: resourceSnapshot,
            activity: activity,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
