import Foundation
import GobyApplication
import Testing

struct RememberedApprovalCompatibilityTests {
    @Test("Existing remembered manual rules decode without an automation label")
    func legacyManualRule() throws {
        let rule = RememberedCommandApproval(providerID: .codex, projectID: "project", projectName: "Project",
            scope: .init(command: "swift test", workingDirectory: "/tmp/project", contextDigest: "scope"),
            authorizationDigest: "manual-authority")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        object.removeValue(forKey: "automationName")
        object.removeValue(forKey: "isEnabled")
        let decoded = try JSONDecoder().decode(RememberedCommandApproval.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.automationName == nil)
        #expect(decoded.isEnabled)
        #expect(decoded.covers(rule))
    }

    @Test("Old hosts and disclosures never imply support for persistent approval")
    func legacyDefaultsFailClosed() throws {
        let session = ClientSession(hostID: .make(), hostEpoch: .make(), protocolVersion: .current,
                                    revision: .zero, capabilities: [.runtimeApprovalOnce])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "supportsRememberedCommandApprovals")
        let decoded = try JSONDecoder().decode(ClientSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.supportsRememberedCommandApprovals)
        let disclosure = GADApprovalDisclosure(approvalID: "a", summary: "command", details: "exact", expiresAt: .distantFuture)
        let roundTrip = try JSONDecoder().decode(GADApprovalDisclosure.self, from: JSONEncoder().encode(disclosure))
        #expect(roundTrip.rememberedCommandScope == nil)
        #expect(roundTrip.rememberedFileChangeScope == nil)
        let once = GADApprovalResponse(approvalID: "a", runID: "run", assignmentID: "assignment", action: .allowOnce)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(once)) as? [String: Any])
        #expect(wire["rememberCommand"] == nil)
    }
}
