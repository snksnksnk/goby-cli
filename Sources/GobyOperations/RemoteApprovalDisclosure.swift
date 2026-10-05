import Foundation
import GobyApplication

/// Exact display bytes stay memory-only, paired with their originating projection.
struct RemoteApprovalDisclosure {
    let source: GADApprovalProjection
    let request: ProviderApprovalRequest

    func accepts(_ candidate: ProviderApprovalRequest) -> Bool {
        candidate == request || candidate == ProviderApprovalRequest(
            id: source.id, providerID: source.providerID, assignmentID: source.assignmentID,
            kind: source.kind, summary: source.summary, details: source.details,
            canAccept: source.actions.contains(.allowOnce), approvalSessionID: source.approvalSessionID,
            operationDigest: source.operationDigest, disclosureComplete: source.disclosureComplete
        )
    }

    func matches(_ current: GADApprovalProjection) -> Bool {
        // expiresAt in routine projections is a rolling history-window timestamp,
        // not the host's one-use disclosure receipt expiry.
        source.id == current.id && source.runID == current.runID
            && source.assignmentID == current.assignmentID && source.providerID == current.providerID
            && source.kind == current.kind && source.summary == current.summary
            && source.details == current.details && source.actions == current.actions
            && source.approvalSessionID == current.approvalSessionID
            && source.operationDigest == current.operationDigest
            && source.disclosureComplete == current.disclosureComplete
    }
}
