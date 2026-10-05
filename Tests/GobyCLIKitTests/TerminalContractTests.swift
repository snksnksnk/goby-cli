import Foundation
import GobyApplication
import GobyDomain
import GobyExperience
import Testing
@testable import GobyCLIKit

@Suite("Terminal workflow contracts")
struct TerminalContractTests {
    @Test("An approval prints full disclosure and binds the decision to its digest")
    func approval() async throws {
        let host = TerminalFixture()
        let output = OutputRecorder()
        let code = try await workflow(host, output, ["approve", "approval", "--yes"]).execute()
        #expect(code == 0)
        #expect(output.lines.first == "Run the disclosed test\n\nswift test\nRead-only tool operation.")
        let payloads = await host.payloads
        #expect(payloads.count == 2)
        guard case let .respondToApproval(response) = payloads.last else { Issue.record("Missing decision"); return }
        #expect(response.disclosureDigest == "exact-request-digest")
        #expect(response.action == .allowOnce)
    }
    @Test("Incomplete disclosure cannot authorize an operation")
    func incompleteApproval() async throws {
        let host = TerminalFixture(completeDisclosure: false)
        let code = try await workflow(host, OutputRecorder(), ["approve", "approval", "--yes", "--json"]).execute()
        #expect(code == 4)
        #expect(await host.payloads.count == 1)
    }
    @Test("Deny still presents full disclosure")
    func deny() async throws {
        let host = TerminalFixture()
        let output = OutputRecorder()
        #expect(try await workflow(host, output, ["deny", "approval"]).execute() == 0)
        #expect(output.lines.first?.contains("swift test") == true)
        guard case let .respondToApproval(response) = await host.payloads.last else { Issue.record("Missing decision"); return }
        #expect(response.action == .decline)
    }
    @Test("Plan --yes never authorizes runtime requests while watching")
    func watchDecision() async throws {
        let host = TerminalFixture()
        let output = OutputRecorder()
        #expect(try await workflow(host, output, ["watch", "run", "--yes", "--json"]).execute() == 2)
        #expect(output.lines.contains { $0.contains("approval-needed") })
        #expect(await host.payloads.isEmpty)
    }
    @Test("Plan confirmation is required and never enables blanket runtime approval")
    func planConfirmation() async throws {
        let host = TerminalFixture(pendingApproval: false, hasPlan: true)
        let output = OutputRecorder()
        #expect(try await workflow(host, output, ["run", "plan", "--json"]).execute() == 2)
        #expect(await host.payloads.isEmpty)
        #expect(try await workflow(host, output, ["run", "plan", "--yes", "--json"]).execute() == 0)
        guard case let .startRun(approval) = await host.payloads.last else { Issue.record("Missing plan approval"); return }
        #expect(!approval.automaticallyApproveRuntimeRequests)
        #expect(approval.allowsPush != true)
    }
    @Test("Pause, resume and cancel target exactly the chosen run", arguments: ["pause", "resume", "cancel"])
    func controls(action: String) async throws {
        let host = TerminalFixture()
        #expect(try await workflow(host, OutputRecorder(), [action, "run", "--json"]).execute() == 0)
        guard case let .controlRun(control) = await host.payloads.last else { Issue.record("Missing control"); return }
        #expect(control.runID.rawValue == "run")
        #expect(control.action.rawValue == action)
    }
    @Test("Follow-up uses the host's existing bounded active-run command")
    func followUp() async throws {
        let host = TerminalFixture()
        #expect(try await workflow(host, OutputRecorder(), ["follow-up", "run", "Explain the result.", "--json"]).execute() == 0)
        guard case let .followUp(followUp) = await host.payloads.last else { Issue.record("Missing follow-up"); return }
        #expect(followUp.text == "Explain the result.")
        #expect(followUp.runID.rawValue == "run")
    }
    @Test("Results omit raw journals, and log exposes them explicitly")
    func progressiveDisclosure() async throws {
        let host = TerminalFixture(pendingApproval: false)
        let output = OutputRecorder()
        #expect(try await workflow(host, output, ["result", "run", "--json"]).execute() == 2)
        #expect(!output.lines.contains { $0.contains("journal") })
    }
    private func workflow(_ host: TerminalFixture, _ output: OutputRecorder, _ arguments: [String]) throws -> GobyTerminalWorkflow {
        GobyTerminalWorkflow(transport: host, options: try GobyCLIOptions(arguments),
                             directory: URL(fileURLWithPath: "/private/tmp"), io: output.io)
    }
}

private actor TerminalFixture: GADHostIPCTransporting {
    private let epoch = HostEpoch.make()
    private let completeDisclosure: Bool
    private var pendingApproval: Bool
    private var hasPlan: Bool
    private var completed = false
    private(set) var payloads: [GADCommandPayload] = []
    init(completeDisclosure: Bool = true, pendingApproval: Bool = true, hasPlan: Bool = false) {
        self.completeDisclosure = completeDisclosure; self.pendingApproval = pendingApproval; self.hasPlan = hasPlan
    }
    func exchange(_ request: GADHostIPCRequest) -> GADHostIPCResponse {
        let artifact: GADHostIPCArtifact?
        switch request.operation {
        case .connect:
            artifact = .session(.init(hostID: .init(rawValue: "host"), hostEpoch: epoch, protocolVersion: .current,
                                      revision: .zero, capabilities: Array(GADCapability.productionHost)))
        case .snapshot:
            artifact = .snapshot(projection())
        case let .send(command):
            payloads.append(command.payload)
            var value: GADCommandArtifact?
            if case .requestApprovalDisclosure = command.payload {
                value = .approvalDisclosure(.init(approvalID: "approval", requestDigest: completeDisclosure ? "exact-request-digest" : nil,
                    summary: "Run the disclosed test", details: "swift test\nRead-only tool operation.", expiresAt: .now.addingTimeInterval(30)))
            }
            if case .respondToApproval = command.payload { pendingApproval = false }
            if case .startRun = command.payload { hasPlan = false; completed = true }
            artifact = .acknowledgement(.init(commandID: command.id, disposition: .accepted, revision: .zero, artifact: value))
        default: artifact = nil
        }
        return .init(requestID: request.requestID, hostVersion: "fixture", generatedAt: .now, isReadOnly: false, artifact: artifact)
    }
    private func projection() -> DashboardProjection {
        let run = GADRunProjection(id: .init(rawValue: completed ? "plan" : "run"), goal: "Run the test", risk: .readOnly,
            status: completed ? .completed : .needsAttention, assignments: [], outcome: completed ? "Completed." : nil,
            journal: [], createdAt: .now, updatedAt: .now)
        let approval = GADApprovalProjection(id: "approval", runID: .init(rawValue: "run"), assignmentID: .init(rawValue: "assignment"),
            kind: .command, summary: "Run the test", details: nil, actions: [.allowOnce, .decline], approvalSessionID: nil,
            expiresAt: .now.addingTimeInterval(30))
        let plan = GADPlanProjection(id: .init(rawValue: "plan"), goal: "Make the change", routes: [
            .init(projectID: .init(rawValue: "project"), agentIDs: [.init(rawValue: "agent")], reason: "Handles this project.")
        ], risk: .high, confidence: 1, gitOperations: [], warnings: [], selectedResourceIDs: [], createdAt: .now)
        return .init(generatedAt: .now, host: .init(id: .init(rawValue: "host"), displayName: "Fixture", reachability: .online, lastUpdatedAt: .now),
                     plan: hasPlan ? plan : nil, runs: [run], approvals: pendingApproval ? [approval] : [])
    }
}
