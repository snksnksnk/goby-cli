import Foundation
import GobyApplication
import GobyDomain

/// Shared semantic wording. Terminals add presentation symbols without changing
/// plan scope, approval disclosure or consolidated-result content.
public enum WorkflowTextFormatter {
    public static func riskLabel(_ risk: PlanRisk) -> String {
        switch risk {
        case .readOnly: "Read only"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
    public static func planActionTitle(risk: PlanRisk) -> String {
        risk == .readOnly ? "Run Read-Only" : "Run"
    }
    public static func approvalSummary(_ request: ProviderApprovalRequest) -> String { request.visibleSummary }
    public static func result(_ run: RunRecord, fallback: String) -> String {
        RunOutcomeSummary.display(for: run) ?? fallback
    }
    public static func plan(_ plan: GADPlanProjection, projects: [GADProjectProjection]) -> String {
        var lines = [plan.goal, "Risk: \(riskLabel(plan.risk))", "Scope:"]
        for route in plan.routes {
            let name = projects.first { $0.id == route.projectID }?.name ?? route.projectID.rawValue
            lines.append("  \(name) · \(route.providerID.displayName) · \(route.agentIDs.count) agent(s)")
            lines.append("  \(route.reason)")
        }
        for operation in plan.gitOperations {
            var line = "Git: \(operation.kind.rawValue)"
            if let branch = operation.branch { line += " · branch \(branch)" }
            if let remote = operation.remote { line += " · remote \(remote)" }
            lines.append(line)
        }
        if !plan.selectedResourceIDs.isEmpty { lines.append("Shared resources: \(plan.selectedResourceIDs.map(\.rawValue).joined(separator: ", "))") }
        for warning in plan.warnings { lines.append("Warning: \(warning)") }
        lines.append("Plan: \(plan.id.rawValue)")
        return lines.joined(separator: "\n")
    }
    public static func plan(_ plan: RoutingPlan, projects: [GADProjectProjection]) -> String {
        self.plan(.init(id: plan.id, goal: plan.interpretedGoal,
            routes: plan.routes.map { .init(projectID: $0.projectID, providerID: $0.providerID, model: $0.model,
                agentIDs: $0.agentIDs, providerBindings: $0.providerBindings, reason: $0.reason) },
            risk: plan.risk, confidence: plan.confidence,
            gitOperations: plan.gitOperations.map { .init(id: $0.id, projectID: $0.projectID, kind: $0.kind, branch: $0.branch, remote: $0.remote) },
            warnings: plan.warnings, selectedResourceIDs: [], createdAt: plan.createdAt), projects: projects)
    }
    public static func disclosure(_ disclosure: GADApprovalDisclosure) -> String {
        [disclosure.summary, disclosure.details].compactMap { $0 }.joined(separator: "\n\n")
    }
    public static func result(_ run: GADRunProjection) -> String {
        run.outcome ?? "No consolidated result is available yet."
    }
    public static func status(_ status: RunStatus) -> String {
        let symbol: String = switch status {
        case .completed: "✓"
        case .failed: "✗"
        case .cancelled: "−"
        case .needsAttention: "!"
        case .running: "▶"
        case .ready: "○"
        case .draft: "·"
        }
        return "\(symbol) \(status.displayName)"
    }
    /// ANSI/OSC and other terminal control bytes in provider content are data,
    /// never instructions for the user's terminal. NO_COLOR needs no special
    /// handling because the CLI emits no colour sequences at all.
    public static func terminalSafe(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value == 10 || $0.value == 9 || ($0.value >= 32 && $0.value != 127 && !((128...159).contains($0.value))) })
    }
}
