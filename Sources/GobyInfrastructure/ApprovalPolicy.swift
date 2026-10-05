import GobyApplication
import GobyDomain

public actor ApprovalPolicy: ApprovalChecking {
    public init() {}

    public func validate(plan: RoutingPlan, receipt: ApprovalReceipt?) throws {
        guard plan.requiresApproval else { return }
        guard let receipt else { throw GobyApplicationError.approvalRequired }
        guard receipt.runID == plan.id, receipt.decision == .approved else {
            throw GobyApplicationError.approvalRequired
        }
        let required = Set(plan.gitOperations.map(\.id))
        guard required.isSubset(of: receipt.operationIDs) else {
            throw GobyApplicationError.incompleteApproval
        }
    }
}
