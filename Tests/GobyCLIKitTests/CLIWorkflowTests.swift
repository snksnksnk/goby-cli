import Foundation
import Synchronization
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyInfrastructure
import GobyExperience
import Testing
@testable import GobyCLIKit

@Suite("Standalone CLI workflow", .timeLimit(.minutes(1)))
struct CLIWorkflowTests {
    @Test("A fake stdio Codex bridge runs the default request through Core and the socket")
    @MainActor
    func endToEnd() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        let primary = root.appending(path: "primary")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try Data("# Test repository\n".utf8).write(to: primary.appending(path: "README.md"))
        try await GobySocketIO.offload {
            try git(["init", "-q"], root: primary)
            try git(["add", "README.md"], root: primary)
            try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "commit", "-qm", "Fixture"], root: primary)
            try git(["worktree", "add", "--detach", "-q", repo.path], root: primary)
        }
        let bridge = root.appending(path: "fake-codex")
        try Data(fakeBridge.utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let defaultsName = "com.goby.cli.spike.workflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let runtime = try GADFreshStandaloneRuntime(storeDirectory: root.appending(path: "store"),
            notifier: FixtureNotifier(), trustPolicy: FixtureTrust(executable: bridge), keychainNamespace: .spike,
            localDefaults: defaults, identifierAliasCodec: RemoteIdentifierAliasCodec(keyData: Data(repeating: 9, count: 32)),
            automationAuthenticator: UITestFileAutomationDocumentAuthenticator(directoryURL: root.appending(path: "store")),
            temporaryChatSupportDirectoryURL: root.appending(path: "chat-cache"))
        let handler = try await runtime.start(hostVersion: "fixture")
        let url = root.appending(path: "host.sock")
        let listener = GobyUnixSocketListener(socketURL: url, handler: handler)
        try await listener.start()
        let output = OutputRecorder()
        let options = try GobyCLIOptions(["Summarize the README. Do not edit files.", "--yes", "--json"])
        let workflow = GobyTerminalWorkflow(transport: GobyUnixSocketTransport(socketURL: url), options: options,
                                           directory: repo, io: output.io)
        let code = await workflow.execute()
        #expect(code == 0, Comment(rawValue: output.lines.joined(separator: "\n")))
        #expect(output.lines.contains { $0.contains("\"type\":\"plan\"") })
        #expect(output.lines.contains { $0.contains("Fixture completed the README summary.") })
        #expect(output.lines.contains { $0.contains("\"type\":\"result\"") })
        #expect(!output.lines.contains { $0.contains(root.path) })
        let cliRun = try #require(runtime.store?.runs.first)
        #expect(cliRun.status == .completed)
        let projection = try await GADHostIPCGobyClient(transport: GobyUnixSocketTransport(socketURL: url), deviceID: .init(rawValue: "cli-local-client")).snapshot()
        let id = try #require(projection.runs.first?.id.rawValue)
        let resultCode = await GobyTerminalWorkflow(transport: GobyUnixSocketTransport(socketURL: url), options: try GobyCLIOptions(["result", id]),
            directory: repo, io: output.io).execute()
        #expect(resultCode == 0)
        try Data("# Test repository\nA reviewed workspace change.\n".utf8).write(to: repo.appending(path: "README.md"))
        let diffCode = await GobyTerminalWorkflow(transport: GobyUnixSocketTransport(socketURL: url), options: try GobyCLIOptions(["diff", id, "--json"]),
            directory: repo, io: output.io).execute()
        #expect(diffCode == 0)
        #expect(output.lines.contains { $0.contains("+A reviewed workspace change.") })
        func command(_ args: [String], io: GobyTerminalIO? = nil) async throws -> Int32 {
            await GobyTerminalWorkflow(transport: GobyUnixSocketTransport(socketURL: url), options: try GobyCLIOptions(args),
                directory: repo, io: io ?? output.io).execute()
        }
        #expect(try await command(["diagnostics", "--json"]) == 0)
        #expect(output.lines.contains { $0.contains("\"type\":\"diagnostics\"") })
        #expect(try await command(["ask", "What is a README?", "--json"]) == 0)
        #expect(output.lines.contains { $0.contains("\"type\":\"answer\"") && $0.contains("Fixture completed") })
        #expect(try await command(["ask", "end", "--json"]) == 0)
        let agents = repo.appending(path: ".codex/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let native = agents.appending(path: "reviewer.toml")
        let original = Data("name = \"README reviewer\"\ndescription = \"Read-only review\"\ndeveloper_instructions = \"Summarize the README without editing files.\"\n".utf8)
        try original.write(to: native)
        let ownerChecks = Mutex(0)
        let importIO = GobyTerminalIO(interactive: false, write: output.io.write, read: { _ in nil }, authenticateOwner: {
            ownerChecks.withLock { $0 += 1 }; return "test-owner-confirmed"
        })
        #expect(try await command(["import-agents", "--yes", "--json"], io: importIO) == 0)
        #expect(ownerChecks.withLock { $0 } == 1)
        #expect(try Data(contentsOf: native) == original)
        #expect(runtime.store?.lab.agents.contains { $0.name == "README reviewer" } == true)
        #expect(try await command(["automation", "add", "Daily review", "09:00", "Summarize the README", "--yes", "--json"]) == 0, Comment(rawValue: output.lines.joined(separator: "\n")))
        let definition = try #require(runtime.store?.automations.first)
        #expect(definition.state == .paused)
        #expect(!definition.automaticallyApproveRuntimeRequests)
        #expect(try await command(["automation", "resume", definition.id.rawValue, "--yes", "--json"]) == 0)
        #expect(try await command(["automation", "pause", definition.id.rawValue, "--yes", "--json"]) == 0)
        await listener.stop()
        try await runtime.stop()
    }

    @Test("A noninteractive unregistered repository needs a decision without mutation")
    @MainActor
    func registrationDecision() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await GobySocketIO.offload { try git(["init", "-q"], root: root) }
        let defaults = try #require(UserDefaults(suiteName: "com.goby.cli.spike.registration"))
        let runtime = try GADFreshStandaloneRuntime(storeDirectory: root.appending(path: "store"), notifier: FixtureNotifier(),
            keychainNamespace: .spike, localDefaults: defaults,
            identifierAliasCodec: RemoteIdentifierAliasCodec(keyData: Data(repeating: 8, count: 32)),
            automationAuthenticator: UITestFileAutomationDocumentAuthenticator(directoryURL: root.appending(path: "store")))
        let handler = try await runtime.start(hostVersion: "fixture")
        let output = OutputRecorder()
        let code = await GobyTerminalWorkflow(transport: InProcessTransport(handler: handler), options: try GobyCLIOptions(["read the README", "--json"]),
                                              directory: root, io: output.io).execute()
        #expect(code == 2)
        #expect(runtime.store?.lab.projects.isEmpty == true)
        try await runtime.stop()
    }
}

final class OutputRecorder: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    var io: GobyTerminalIO { .init(interactive: false, write: { [self] line in storage.withLock { $0.append(line) } }, read: { _ in nil }) }
}
private struct InProcessTransport: GADHostIPCTransporting {
    let handler: any GADHostIPCRequestHandling
    func exchange(_ request: GADHostIPCRequest) async -> GADHostIPCResponse { await handler.handle(request) }
}
private actor FixtureNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {}
    func notify(for occurrence: AutomationOccurrence) async {}
}
private struct FixtureTrust: ProviderRuntimeTrustPolicy {
    let executable: URL
    func codexExecutableURL() -> URL { executable }
    func codexValidator() -> any CodexRuntimeValidating { FixtureValidator() }
    func validateProviderRuntime(bundleURL: URL, runtimeURLs: [URL]) throws { throw ProviderRuntimeIntegrityError.invalidBundle }
}
private struct FixtureValidator: CodexRuntimeValidating {
    func validate(executableURL: URL) throws {}
    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {}
}
private func git(_ args: [String], root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GobyTerminalError("Git fixture failed.") }
}

// Existing app-server JSON-RPC protocol over stdio, with no account or network.
private let fakeBridge = #"""
#!/usr/bin/python3
import json, sys, time

def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if 'id' not in request:
        continue
    result = {}
    if method == 'initialize': result = {'userAgent': 'goby-test-bridge'}
    elif method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'model/list': result = {'data': []}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'thread/list': result = {'data': []}
    elif method == 'thread/start': result = {'thread': {'id': 'fixture-thread'}}
    elif method == 'turn/start': result = {'turn': {'id': 'fixture-turn', 'status': 'inProgress'}}
    send({'id': request['id'], 'result': result})
    if method == 'turn/start':
        time.sleep(0.2)
        send({'method': 'item/agentMessage/delta', 'params': {'threadId': 'fixture-thread', 'turnId': 'fixture-turn', 'delta': 'Fixture completed the README summary.'}})
        send({'method': 'turn/completed', 'params': {'threadId': 'fixture-thread', 'turn': {'id': 'fixture-turn', 'status': 'completed'}}})
"""#
