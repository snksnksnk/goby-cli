import Foundation
import GobyApplication
import GobyDomain

/// Something known before a run starts that will make it fail or stall,
/// with the action that fixes it.
public struct RunReadinessIssue: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openProviderSettings
        case switchToCodex
        case reauthorizeProjects

        public var title: String {
            switch self {
            case .openProviderSettings: "Provider Connections"
            case .switchToCodex: "Use Codex Instead"
            case .reauthorizeProjects: "Choose Project Folder…"
            }
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let actions: [Action]
    /// Blocking issues open review instead of starting automatically.
    public let blocksAutomaticStart: Bool
}

/// Pre-flight checks for a proposed plan. Uses only state Goby already has.
public enum RunReadiness {
    public static func issues(
        for plan: RoutingPlan,
        lab: LabSnapshot,
        providerAccounts: [ProviderAccountSnapshot],
        runs: [RunRecord],
        projectIdentitiesKnown: Bool
    ) -> [RunReadinessIssue] {
        var issues: [RunReadinessIssue] = []
        let providers = Set(plan.routes.map(\.providerID))

        for providerID in providers.sorted() {
            let alternatives: [RunReadinessIssue.Action] = providerID == .codex
                ? [.openProviderSettings]
                : [.switchToCodex, .openProviderSettings]
            if let billing = latestBillingFailure(providerID: providerID, runs: runs) {
                issues.append(RunReadinessIssue(
                    id: "billing-\(providerID.rawValue)",
                    title: "\(providerID.displayName)'s account has no credits",
                    detail: "The last \(providerID.displayName) run stopped with “\(billing)”. Fix the account, or run this request with another provider.",
                    actions: alternatives,
                    blocksAutomaticStart: true
                ))
            }
            switch providerAccounts.first(where: { $0.providerID == providerID })?.connectionState {
            case .needsAuthentication:
                issues.append(RunReadinessIssue(
                    id: "auth-\(providerID.rawValue)",
                    title: "\(providerID.displayName) needs you to sign in",
                    detail: "Runs with \(providerID.displayName) cannot start until its account is connected.",
                    actions: alternatives,
                    blocksAutomaticStart: true
                ))
            case let .unavailable(reason):
                issues.append(RunReadinessIssue(
                    id: "unavailable-\(providerID.rawValue)",
                    title: "\(providerID.displayName) is unavailable",
                    detail: reason,
                    actions: alternatives,
                    blocksAutomaticStart: true
                ))
            case let .failed(message):
                issues.append(RunReadinessIssue(
                    id: "status-\(providerID.rawValue)",
                    title: "\(providerID.displayName)'s last status check failed",
                    detail: message,
                    actions: alternatives,
                    blocksAutomaticStart: false
                ))
            default:
                break
            }
        }

        if projectIdentitiesKnown {
            for route in plan.routes {
                guard let project = lab.projects.first(where: { $0.id == route.projectID }),
                      project.fileSystemIdentity?.kind != .directory else { continue }
                let required = route.providerID != .codex
                issues.append(RunReadinessIssue(
                    id: "identity-\(project.id.rawValue)-\(route.providerID.rawValue)",
                    title: "Goby can't confirm \(project.name)'s folder",
                    detail: required
                        ? "\(route.providerID.displayName) only works in folders Goby has verified. Choose \(project.name)'s folder again."
                        : "Choose \(project.name)'s folder again so Goby can verify it.",
                    actions: [.reauthorizeProjects],
                    blocksAutomaticStart: required
                ))
            }
        }
        return issues
    }

    /// The provider's newest finished assignment failed for lack of credits.
    static func latestBillingFailure(providerID: AgentProviderID, runs: [RunRecord]) -> String? {
        let latest = runs
            .filter(\.status.isFinished)
            .flatMap { run in
                run.assignments
                    .filter { $0.providerID == providerID && ($0.status == .completed || $0.status == .failed) }
                    .map { (run.updatedAt, $0) }
            }
            .max { $0.0 < $1.0 }?.1
        guard let latest, latest.status == .failed,
              let reason = latest.statusReason,
              reason.localizedCaseInsensitiveContains("credit balance is too low") else { return nil }
        return "Credit balance is too low"
    }
}
