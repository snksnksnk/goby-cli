import Foundation

/// A provider finished and answered, but Goby could not verify the work, so
/// the assignment is failed. The answer is kept in the failure reason after a
/// fixed label so presentation can show the answer first and the reason second.
public enum UnverifiedAgentResult {
    public static let label = "Agent result (not verified):"

    /// Composes a failure reason that keeps the provider's answer.
    public static func reason(verificationIssue: String, answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return verificationIssue }
        return "\(verificationIssue)\n\n\(label)\n\(trimmed)"
    }

    /// Splits a failure reason into the verification issue and the answer.
    public static func split(_ text: String) -> (issue: String, answer: String)? {
        guard let range = text.range(of: label) else { return nil }
        let issue = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }
        return (issue, answer)
    }
}

public extension RunRecord {
    /// The provider's answer when the run failed only because its work could
    /// not be verified.
    var unverifiedAnswer: (issue: String, answer: String)? {
        guard status == .failed || status == .needsAttention else { return nil }
        for text in assignments.compactMap(\.statusReason) + [outcome].compactMap({ $0 }) {
            if let split = UnverifiedAgentResult.split(text) { return split }
        }
        return nil
    }
}
