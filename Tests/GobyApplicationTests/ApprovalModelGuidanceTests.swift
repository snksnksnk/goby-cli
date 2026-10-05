import Foundation
import GobyDomain
import GobyApplication
import Testing

struct ApprovalModelGuidanceTests {
    @Test("A reported model choice is advisory and limited to the approval's provider", arguments: [AgentProviderID.codex, .claude, .githubCopilot])
    func explicitSuggestion(provider: AgentProviderID) throws {
        let (run, approval) = fixture(provider: provider, report: "Working: Please switch to capable-model for this task.")
        let advice = try #require(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["capable-model"]))
        #expect(advice.suggestedModel == "capable-model")
        #expect(advice.evidence.contains("Please switch"))
        #expect(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["other-provider-model"]) == nil)
    }

    @Test("Explicit capability and context reports offer a review without guessing a model ranking", arguments: [
        "This task requires a more capable model.",
        "Maximum context length exceeded.",
        "The current model does not support images.",
        "model_not_found"
    ])
    func limitations(report: String) throws {
        let (run, approval) = fixture(report: report)
        let advice = try #require(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["unknown-model"]))
        #expect(advice.suggestedModel == nil)
    }

    @Test("Permissions and executable approval contents are not evidence that a model upgrade is needed", arguments: [
        "Approval required", "Network permission required", "This task does not require a stronger model.",
        "Do not switch to capable-model.", "No need to switch to capable-model.",
        "The context length does not exceed the limit.", "The model does not require a retry.",
        "Switch to capable-model-other.", "echo 'switch to capable-model'"
    ])
    func avoidsFalseSuggestions(report: String) {
        let (run, approval) = fixture(report: report)
        #expect(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["capable-model"]) == nil)
    }

    @Test("Old reports, other assignments and previous attempts cannot suggest a model change")
    func scopesEvidence() {
        for tail in [
            RunJournalEntry(kind: .assignmentChanged, message: "Working: Verification progressing normally", assignmentID: "assignment"),
            RunJournalEntry(kind: .recovery, message: "Retry started", assignmentID: nil)
        ] {
            let (run, approval) = fixture(report: "Switch to capable-model", tail: [tail])
            #expect(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["capable-model"]) == nil)
        }
        let (run, approval) = fixture(report: "Work is in progress", tail: [
            RunJournalEntry(kind: .assignmentChanged, message: "Switch to capable-model", assignmentID: "other-assignment")
        ])
        #expect(ApprovalModelGuidance.evaluate(run: run, approval: approval, availableModels: ["capable-model"]) == nil)
        let wrongProvider = ProviderApprovalRequest(id: approval.id, providerID: .claude, assignmentID: approval.assignmentID, kind: .command, summary: "Switch to capable-model")
        #expect(ApprovalModelGuidance.evaluate(run: run, approval: wrongProvider, availableModels: ["capable-model"]) == nil)
    }

    private func fixture(
        provider: AgentProviderID = .codex, report: String, tail: [RunJournalEntry] = []
    ) -> (RunRecord, ProviderApprovalRequest) {
        let approval = ProviderApprovalRequest(
            id: "approval", providerID: provider, assignmentID: "assignment", kind: .command,
            summary: "echo 'switch to capable-model'", details: "Switch to capable-model"
        )
        let run = RunRecord(
            id: "run", plan: RoutingPlan(id: "run", interpretedGoal: "Switch to capable-model", routes: [], risk: .readOnly, confidence: 1),
            status: .needsAttention,
            assignments: [AgentAssignment(
                id: "assignment", runID: "run", projectID: "project", agentID: "agent",
                status: .waitingForApproval, currentTask: approval.summary,
                statusReason: "Approval required", providerID: provider, model: "current-model"
            )],
            journal: [RunJournalEntry(kind: .assignmentChanged, message: report, assignmentID: "assignment")] + tail
        )
        return (run, approval)
    }
}
