import Foundation

/// How a run's answer and verification read in a conversation. Shared by the
/// Mac (`RunRecord`) and the phone (the run projection), which carry the same
/// facts in different shapes.
public enum ConversationAnswer {
    public struct AssignmentFacts: Sendable {
        public let id: AssignmentID
        public let status: AgentStatus
        public let statusReason: String?

        public init(id: AssignmentID, status: AgentStatus, statusReason: String?) {
            self.id = id
            self.status = status
            self.statusReason = statusReason
        }
    }

    /// Paragraphs Goby appends after an agent's answer on completion.
    private static let verifierPrefixes = [
        "Verified from ",
        "Read-only request:",
        "No automated project check was detected",
        "No file changes to commit.",
    ]

    /// The agent's answer without Goby's verification text; nil while the run
    /// is working or when no answer was produced.
    public static func answer(
        status: RunStatus,
        assignments: [AssignmentFacts],
        outcome: String?,
        activity: [RunActivityStep]
    ) -> String? {
        if let unverified = unverifiedAnswer(status: status, assignments: assignments, outcome: outcome) {
            return unverified.answer
        }
        guard status == .completed else { return nil }
        let finalMessages = answerSteps(status: status, assignments: assignments, activity: activity).map(\.title)
        if !finalMessages.isEmpty { return finalMessages.joined(separator: "\n\n---\n\n") }
        let source = assignments.compactMap(\.statusReason).first ?? outcome ?? ""
        let answer = source
            .components(separatedBy: "\n\n")
            .filter { paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty
                    && !verifierPrefixes.contains { trimmed.hasPrefix($0) }
                    && !trimmed.hasPrefix("[")  // `git commit` summary line
            }
            .joined(separator: "\n\n")
        return answer.isEmpty ? nil : answer
    }

    /// Each completed assignment's last message is its answer; step feeds hide
    /// these so the answer is not shown twice.
    public static func answerSteps(
        status: RunStatus,
        assignments: [AssignmentFacts],
        activity: [RunActivityStep]
    ) -> [RunActivityStep] {
        guard status == .completed else { return [] }
        return assignments.compactMap { assignment in
            guard assignment.status == .completed else { return nil }
            return activity.last { $0.assignmentID == assignment.id && $0.kind == .message }
        }
    }

    public static func unverifiedAnswer(
        status: RunStatus,
        assignments: [AssignmentFacts],
        outcome: String?
    ) -> (issue: String, answer: String)? {
        guard status == .failed || status == .needsAttention else { return nil }
        for text in assignments.compactMap(\.statusReason) + [outcome].compactMap({ $0 }) {
            if let split = UnverifiedAgentResult.split(text) { return split }
        }
        return nil
    }

    /// A short verification note for a result footer.
    public static func verificationNote(assignments: [AssignmentFacts], outcome: String?) -> String? {
        let text = ([outcome] + assignments.map(\.statusReason)).compactMap { $0 }.joined(separator: "\n")
        if text.contains("project checks were not required") { return "checks not required" }
        if text.contains("Verified from ") { return "checks passed" }
        if text.contains("No automated project check was detected") { return "no project checks" }
        return nil
    }
}

public extension RunRecord {
    private var answerFacts: [ConversationAnswer.AssignmentFacts] {
        assignments.map { .init(id: $0.id, status: $0.status, statusReason: $0.statusReason) }
    }

    var conversationAnswer: String? {
        ConversationAnswer.answer(status: status, assignments: answerFacts, outcome: outcome, activity: activity)
    }

    var answerSteps: [RunActivityStep] {
        ConversationAnswer.answerSteps(status: status, assignments: answerFacts, activity: activity)
    }

    var verificationNote: String? {
        ConversationAnswer.verificationNote(assignments: answerFacts, outcome: outcome)
    }
}
