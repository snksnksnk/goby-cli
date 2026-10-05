import Foundation
import GobyDomain

/// Advisory only: never changes models or authorizes a provider operation.
/// Uses the blocked assignment's current report, never executable approval text
/// or historical journal messages. Model IDs are not capability rankings.
public struct ApprovalModelGuidance: Equatable, Sendable {
    public let title: String
    public let explanation: String
    public let evidence: String
    public let suggestedModel: String?

    public static func evaluate(
        run: RunRecord,
        approval: ProviderApprovalRequest,
        availableModels: [String]
    ) -> Self? {
        guard !run.status.isFinished,
              let assignment = run.assignments.first(where: {
                  $0.id == approval.assignmentID && $0.providerID == approval.providerID
              }),
              [.waitingForApproval, .failed, .paused].contains(assignment.status) else { return nil }
        let latest = run.journal.last {
            ($0.kind == .recovery && ($0.assignmentID == nil || $0.assignmentID == assignment.id))
                || ($0.kind == .assignmentChanged && $0.assignmentID == assignment.id)
        }
        // currentTask is replaced by the executable command when approval arrives.
        // Use only the latest progress report in this attempt, plus the status reason.
        let reports = [assignment.statusReason, latest?.kind == .assignmentChanged ? latest?.message : nil]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for report in reports where !report.isEmpty {
            // Inspect individual report lines, ignoring common negated or quoted command text.
            for line in report.components(separatedBy: .newlines) {
                let text = line.lowercased()
                guard !["do not", "don't", "no need", "not necessary", "does not require", "doesn't require", "not exceed", "```", "echo ", "printf "]
                    .contains(where: text.contains) else { continue }
                let suggested = availableModels.first { model in
                    guard model != assignment.model else { return false }
                    let escaped = NSRegularExpression.escapedPattern(for: model.lowercased())
                    return text.range(
                        of: #"\b(?:switch to|use|retry with|try)\s+"# + escaped + #"(?=$|[^a-z0-9_.-])"#,
                        options: .regularExpression
                    ) != nil
                }
                let evidence = ApprovalDisplayPolicy.exactVisibleText(String(line.prefix(600)))
                if let suggested {
                    return Self(
                        title: "Model change suggested by the agent",
                        explanation: "The current report names an available model. Review its suitability and cost before retrying.",
                        evidence: evidence, suggestedModel: suggested
                    )
                }
                if ["requires a stronger model", "needs a stronger model", "switch to a stronger model",
                    "requires a more capable model", "needs a more capable model", "switch to a more capable model"]
                    .contains(where: text.contains) {
                    return Self(
                        title: "Agent requests a more capable model",
                        explanation: "Choose an appropriate model from this provider. Goby cannot rank capability from model names alone.",
                        evidence: evidence, suggestedModel: nil
                    )
                }
                if (text.contains("context window") || text.contains("context length"))
                    && ["exceed", "too small", "too long", "maximum", "limit reached"].contains(where: text.contains) {
                    return Self(
                        title: "Agent reports a context limit",
                        explanation: "A model with a larger context window may help. Check the selected model's capacity before retrying.",
                        evidence: evidence, suggestedModel: nil
                    )
                }
                if ["model does not support", "model doesn't support", "model is unavailable", "model not found", "model_not_found", "unsupported model"]
                    .contains(where: text.contains) {
                    return Self(
                        title: "Agent reports a model limitation",
                        explanation: "Review an available model that supports this task. A model change does not grant permissions.",
                        evidence: evidence, suggestedModel: nil
                    )
                }
            }
        }
        return nil
    }
}
