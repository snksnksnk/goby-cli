import Darwin
import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyExperience
import Testing
@testable import GobyCLIKit

@Suite("Standalone CLI transport")
struct CLITransportTests {
    @Test("Socket round trips the shared codec and rejects version skew")
    func roundTrip() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "host.sock")
        let listener = GobyUnixSocketListener(socketURL: url, handler: PingHandler(version: "test"))
        try await listener.start()
        let transport = GobyUnixSocketTransport(socketURL: url)
        let request = GADHostIPCRequest(operation: .ping)
        let response = try await transport.exchange(request)
        #expect(response.requestID == request.requestID)
        #expect(response.hostVersion == "test")
        let skewed = try await transport.exchange(.init(protocolVersion: 0, operation: .ping))
        #expect(skewed.error != nil)
        let delayed = try GobySocketIO.connect(url)
        defer { close(delayed) }
        try await Task.sleep(for: .milliseconds(100))
        let payload = try GADHostIPCCodec.encode(request)
        let delayedResponse = try await GobySocketIO.offload {
            try GobySocketIO.writeFrame(delayed, data: payload, maximum: GADHostIPCCodec.maximumRequestBytes)
            return try GobySocketIO.readFrame(delayed, maximum: GADHostIPCCodec.maximumResponseBytes)
        }
        #expect(try GADHostIPCCodec.decodeResponse(GADHostIPCResponse.self, from: delayedResponse).requestID == request.requestID)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        await listener.stop()
    }
    @Test("Peer UID is enforced in both directions")
    func foreignPeer() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        #expect(throws: GobySocketError.self) {
            try GobySocketIO.peer(pair[0], expectedUID: geteuid() + 1)
        }
    }
    @Test("Oversize frames and a half-written client do not poison the listener")
    func badClients() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "host.sock")
        let listener = GobyUnixSocketListener(socketURL: url, handler: PingHandler(version: "test"))
        try await listener.start()
        try await GobySocketIO.offload {
            let oversized = try GobySocketIO.connect(url)
            var bytes: [UInt8] = [255, 255, 255, 255]
            #expect(write(oversized, &bytes, 4) == 4)
            close(oversized)
            let partial = try GobySocketIO.connect(url)
            bytes = [0, 0, 0, 20, 123]
            #expect(write(partial, &bytes, 5) == 5)
            close(partial)
        }
        let response = try await GobyUnixSocketTransport(socketURL: url).exchange(.init(operation: .ping))
        #expect(response.error == nil)
        await listener.stop()
    }
    @Test("Symlinked endpoints and nonprivate directories are rejected")
    func unsafePaths() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "host.sock")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appending(path: "outside"))
        let listener = GobyUnixSocketListener(socketURL: url, handler: PingHandler(version: "test"))
        await #expect(throws: GobySocketError.self) { try await listener.start() }
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: GobySocketError.self) { try GobySocketIO.secureDirectory(root) }
    }
    @Test("Two lazy clients launch only one host")
    func lazyRace() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: URL(fileURLWithPath: "/unused"), hostVersion: "test")
        let launcher = TestLauncher()
        let one = GobyLazyHostConnection(configuration: config, launcher: launcher)
        let two = GobyLazyHostConnection(configuration: config, launcher: launcher)
        async let first = one.connect()
        async let second = two.connect()
        _ = try await (first, second)
        #expect(await launcher.launchCount == 1)
        await launcher.stop()
    }
    @Test("Drain blocks new work while preserving approvals and controls")
    func draining() async throws {
        let router = GobyCLIHostRouter(handler: PingHandler(version: "old"), version: "old")
        let drained = await router.handle(.init(protocolVersion: 0, operation: .localAdministration(.preparePermanentHostShutdown)))
        #expect(drained.error == nil)
        let newWork = await router.handle(.init(operation: .send(command(.preparePlan))))
        #expect(newWork.isReadOnly)
        let control = await router.handle(.init(operation: .send(command(.controlRun(.init(runID: .init(rawValue: "run"), action: .cancel))))))
        #expect(control.error == nil)
        #expect(await router.shouldExit(now: .now, idleTimeout: 0, busy: true) == false)
        #expect(await router.shouldExit(now: .now, idleTimeout: 0, busy: false))
    }
    @Test("Active runs and approvals inhibit idle exit")
    func idle() {
        #expect(GobyStandaloneIdlePolicy.preventsExit(runStatuses: [.running], pendingApprovalCount: 0, automations: .empty, isBusy: false))
        #expect(GobyStandaloneIdlePolicy.preventsExit(runStatuses: [], pendingApprovalCount: 1, automations: .empty, isBusy: false))
        #expect(!GobyStandaloneIdlePolicy.preventsExit(runStatuses: [.completed], pendingApprovalCount: 0, automations: .empty, isBusy: false))
    }
    @Test("Stable exit codes distinguish decisions, policy and host failures")
    func exitCodes() {
        #expect(GobyCLIExitCode.forRun(.completed) == 0)
        #expect(GobyCLIExitCode.forRun(.failed) == 1)
        #expect(GobyCLIExitCode.forRun(.needsAttention) == 2)
        #expect(GobyCLIExitCode.forError(GobySocketError.unavailable) == 3)
        #expect(GobyCLIExitCode.forError(GADCommandFailure(.rejectedPolicy, "denied")) == 4)
    }
    @Test("Text and JSON have stable content and no ANSI colour")
    func goldenOutput() throws {
        let disclosure = GADApprovalDisclosure(approvalID: "approval", summary: "Run the test", details: "swift test", expiresAt: Date(timeIntervalSince1970: 0))
        #expect(WorkflowTextFormatter.disclosure(disclosure) == "Run the test\n\nswift test")
        #expect(WorkflowTextFormatter.status(.needsAttention) == "! Needs Attention")
        #expect(WorkflowTextFormatter.terminalSafe("text\u{1b}\u{7}") == "text")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(GobyCLIOutput(type: "result", data: "Completed."))
        #expect(String(decoding: data, as: UTF8.self) == "{\"data\":\"Completed.\",\"schemaVersion\":1,\"type\":\"result\"}")
    }
}

func socketRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp/gcli-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}
private func command(_ payload: GADCommandPayload) -> GADCommand {
    .init(idempotencyKey: UUID().uuidString, hostEpoch: .make(), deviceID: .init(rawValue: "cli-local-client"),
          baseRevision: .zero, issuedAt: .now, expiresAt: .now.addingTimeInterval(30), payload: payload)
}
actor PingHandler: GADHostIPCRequestHandling {
    let version: String
    init(version: String) { self.version = version }
    func handle(_ request: GADHostIPCRequest) -> GADHostIPCResponse {
        .init(requestID: request.requestID, hostVersion: version, generatedAt: .now, isReadOnly: false,
              error: request.protocolVersion == GADHostIPCRequest.currentProtocolVersion ? nil : "Protocol version mismatch")
    }
}
private actor TestLauncher: GobyHostLaunching {
    private var listener: GobyUnixSocketListener?
    private(set) var launchCount = 0
    func launch(configuration: GobyCLIConfiguration) async throws {
        launchCount += 1
        let listener = GobyUnixSocketListener(socketURL: configuration.socketURL, handler: PingHandler(version: configuration.hostVersion))
        try await listener.start()
        self.listener = listener
    }
    func stop() async { await listener?.stop() }
}

@Suite("CLI namespace boundaries")
struct CLINamespaceTests {
    @Test("An alternate store gets independent CLI Keychain service names")
    func namespace() {
        let scoped = GADHostKeychainNamespace.isolatedCLI(scopeDigest: String(repeating: "a", count: 64))
        #expect(scoped.identifierAlias.hasPrefix("com.goby.cli.store."))
        #expect(scoped.identifierAlias != GADHostKeychainNamespace.cli.identifierAlias)
        #expect(scoped.automation != GADHostKeychainNamespace.app.automation)
    }
    @Test("The CLI refuses the app store and its descendants")
    func appStoreBoundary() {
        let app = URL(fileURLWithPath: "/private/tmp/Goby-app-store")
        #expect(throws: GobyTerminalError.self) { try GobyCLIEntrypoint.validateStoreNamespace(app, appStore: app) }
        #expect(throws: GobyTerminalError.self) { try GobyCLIEntrypoint.validateStoreNamespace(app.appending(path: "nested"), appStore: app) }
    }
    @Test("A repository subfolder resolves to the enclosing repository")
    func nestedScope() throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "Sources/Module", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        #expect(GobyCLIEntrypoint.repositoryDirectory(from: child).path == root.path)
    }
}

@Suite("CLI host version replacement")
struct CLIVersionReplacementTests {
    @Test("An older idle host drains before one replacement is launched")
    func replaceIdleHost() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: URL(fileURLWithPath: "/unused"), hostVersion: "new")
        let old = OldVersionHandler(stopsOnDrain: true)
        let listener = GobyUnixSocketListener(socketURL: config.socketURL, handler: old)
        await old.attach(listener)
        try await listener.start()
        let launcher = TestLauncher()
        let transport = try await GobyLazyHostConnection(configuration: config, launcher: launcher).connect()
        #expect(try await transport.exchange(.init(operation: .ping)).hostVersion == "new")
        #expect(await old.drainCount == 1)
        #expect(await launcher.launchCount == 1)
        await launcher.stop()
    }
    @Test("A busy older host is never killed or replaced")
    func preserveBusyHost() async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: URL(fileURLWithPath: "/unused"), hostVersion: "new")
        let old = OldVersionHandler(stopsOnDrain: false)
        let listener = GobyUnixSocketListener(socketURL: config.socketURL, handler: old)
        await old.attach(listener)
        try await listener.start()
        let launcher = TestLauncher()
        do {
            _ = try await GobyLazyHostConnection(configuration: config, launcher: launcher).connect()
            Issue.record("A busy host must remain authoritative.")
        } catch GobySocketError.incompatibleVersion {}
        #expect(await launcher.launchCount == 0)
        #expect(await old.drainCount == 1)
        #expect(try await GobyUnixSocketTransport(socketURL: config.socketURL).exchange(.init(operation: .ping)).hostVersion == "old")
        await listener.stop()
    }
}
private actor OldVersionHandler: GADHostIPCRequestHandling {
    let stopsOnDrain: Bool
    private var listener: GobyUnixSocketListener?
    private(set) var drainCount = 0
    init(stopsOnDrain: Bool) { self.stopsOnDrain = stopsOnDrain }
    func attach(_ listener: GobyUnixSocketListener) { self.listener = listener }
    func handle(_ request: GADHostIPCRequest) -> GADHostIPCResponse {
        if request.operation == .localAdministration(.preparePermanentHostShutdown) {
            drainCount += 1
            if stopsOnDrain {
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await listener?.stop()
                }
            }
        }
        return .init(protocolVersion: 11, requestID: request.requestID, hostVersion: "old", generatedAt: .now, isReadOnly: false)
    }
}
