import Foundation
import Darwin
import GobyApplication
import GobyCLIKit
import GobyHostCore
import GobyDomain
import GobyInfrastructure
import Testing

@Suite("CLI host process signals", .timeLimit(.minutes(1)))
struct CLISignalTests {
    @Test("SIGTERM and SIGINT seal a checkpoint and release the writer lease", arguments: [SIGTERM, SIGINT])
    @MainActor
    func terminationCheckpoint(signal: Int32) async throws {
        let root = try socketRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let argument = try #require(CommandLine.arguments.first { $0.contains(".xctest") })
        var bundle = URL(fileURLWithPath: argument)
        while bundle.pathExtension != "xctest", bundle.path != "/" { bundle.deleteLastPathComponent() }
        let executable = bundle.deletingLastPathComponent().appending(path: "GobyCLIHostFixture")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = [root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let configuration = GobyCLIConfiguration(storeDirectory: root, executableURL: executable, hostVersion: "signal-fixture")
        let transport = GobyUnixSocketTransport(socketURL: configuration.socketURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var connected = false
        while ContinuousClock.now < deadline {
            if (try? await transport.exchange(.init(operation: .ping))) != nil { connected = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(connected)
        #expect(kill(process.processIdentifier, signal) == 0)
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while process.isRunning && ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "operational-continuity.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "coordinator-checkpoint.json").path))
        #expect(!FileManager.default.fileExists(atPath: configuration.socketURL.path))
        let defaults = try #require(UserDefaults(suiteName: "com.goby.cli.spike.signal.verify"))
        let restarted = try GADFreshStandaloneRuntime(storeDirectory: root, notifier: SignalNotifier(),
            keychainNamespace: .spike, localDefaults: defaults,
            identifierAliasCodec: RemoteIdentifierAliasCodec(keyData: Data(repeating: 3, count: 32)),
            automationAuthenticator: UITestFileAutomationDocumentAuthenticator(directoryURL: root))
        _ = try await restarted.start(hostVersion: "signal-fixture")
        #expect(restarted.store != nil)
        try await restarted.stop()
    }
}
private actor SignalNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {}
    func notify(for occurrence: AutomationOccurrence) async {}
}
