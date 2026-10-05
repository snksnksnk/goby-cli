import Foundation
import Testing
@testable import GobyApplication
@testable import GobyDomain

@Suite("Provider approval operation binding")
struct ProviderApprovalBindingTests {
    @Test("Provider approval identities namespace native IDs")
    func approvalIdentityIncludesProviderAndAssignment() {
        let assignmentA = AssignmentID(rawValue: "assignment|1")
        let assignmentB = AssignmentID(rawValue: "assignment")
        let codex = ProviderApprovalRequest(
            id: "1|approval",
            providerID: .codex,
            assignmentID: assignmentA,
            kind: .command,
            summary: "Run"
        )
        let claude = ProviderApprovalRequest(
            id: codex.id,
            providerID: .claude,
            assignmentID: assignmentA,
            kind: .command,
            summary: "Run"
        )
        let otherAssignment = ProviderApprovalRequest(
            id: "1|approval",
            providerID: .codex,
            assignmentID: assignmentB,
            kind: .command,
            summary: "Run"
        )

        #expect(codex.identity != claude.identity)
        #expect(codex.identity != otherAssignment.identity)
        #expect(Set([codex.routingID, claude.routingID, otherAssignment.routingID]).count == 3)
        #expect(codex.routingID == codex.identity.routingID)
        #expect(codex.routingID.count == 76)
        #expect(!codex.routingID.contains(codex.id))
    }

    @Test("External providers require a complete canonical digest")
    func externalProvidersFailClosedWithoutBinding() {
        let missing = ProviderApprovalRequest(
            id: "approval",
            providerID: .claude,
            assignmentID: .init(rawValue: "assignment"),
            kind: .command,
            summary: "Run",
            details: "{}"
        )
        let valid = ProviderApprovalRequest(
            id: "approval",
            providerID: .githubCopilot,
            assignmentID: .init(rawValue: "assignment"),
            kind: .permissions,
            summary: "Use tool",
            details: "{}",
            operationDigest: String(repeating: "a", count: 64),
            disclosureComplete: true
        )

        #expect(!missing.hasCompleteOperationBinding)
        #expect(valid.hasCompleteOperationBinding)
    }

    @Test("Legacy approval payloads decode decline-only for every provider")
    func legacyDecodingFailsClosedByProvider() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        func legacyData(providerID: AgentProviderID) throws -> Data {
            let current = ProviderApprovalRequest(
                id: "approval",
                providerID: providerID,
                assignmentID: .init(rawValue: "assignment"),
                kind: .command,
                summary: "Run",
                operationDigest: String(repeating: "a", count: 64),
                disclosureComplete: true
            )
            var object = try #require(
                JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any]
            )
            object.removeValue(forKey: "operationDigest")
            object.removeValue(forKey: "disclosureComplete")
            return try JSONSerialization.data(withJSONObject: object)
        }

        let externalData = try legacyData(providerID: .claude)
        let decodedExternal = try decoder.decode(ProviderApprovalRequest.self, from: externalData)
        #expect(!decodedExternal.hasCompleteOperationBinding)

        let codexData = try legacyData(providerID: .codex)
        let decodedCodex = try decoder.decode(ProviderApprovalRequest.self, from: codexData)
        #expect(!decodedCodex.hasCompleteOperationBinding)
    }
}
