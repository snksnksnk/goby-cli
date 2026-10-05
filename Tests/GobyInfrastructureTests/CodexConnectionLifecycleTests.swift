import Foundation
import Darwin
import Testing
import GobyDomain
@testable import GobyInfrastructure

@Suite("Codex connection lifecycle", .timeLimit(.minutes(1)))
struct CodexConnectionLifecycleTests {
    @Test("Overlapping refreshes share one initialize handshake")
    func concurrentGatewayConnections() async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        let gateway = CodexGateway(
            executableURL: fixture.executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let first = Task { try await gateway.connect() }
        try await fixture.waitForRequest("initialize")
        let second = Task { try await gateway.connect() }
        // Leave the first initialize outstanding while the second refresh arrives.
        try await Task.sleep(for: .milliseconds(100))
        try fixture.releaseHandshake()
        for task in [first, second] {
            do {
                #expect(try await task.value == .connected(version: "lifecycle-test"))
            } catch {
                Issue.record("A concurrent refresh failed: \(error.localizedDescription)")
            }
        }
        #expect(try await gateway.connect() == .connected(version: "lifecycle-test"))
        #expect(try fixture.requests().filter { $0 == "initialize" }.count == 1)
        #expect(try await gateway.accountSnapshot().authenticated)
        await gateway.disconnect()
    }

    @Test("Transport startup remains single-flight during signature validation")
    func concurrentTransportValidation() async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        try fixture.releaseHandshake()
        let validator = GatedConnectionValidator(phase: .beforeLaunch)
        defer { validator.release() }
        let transport = CodexAppServerTransport(
            executableURL: fixture.executable, clientVersion: "test", runtimeValidator: validator
        )
        let first = Task { try await transport.start() }
        try await waitForLifecycleCondition { validator.hasEnteredGate }
        let second = Task { try await transport.start() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(validator.validationCount == 1)
        validator.release()
        #expect(try await first.value == second.value)
        _ = try await transport.start()
        #expect(try fixture.requests().filter { $0 == "initialize" }.count == 1)
        await transport.stop()
    }

    @Test("Disconnect during validation cannot revive or overwrite the next connection",
          arguments: [GatedConnectionValidator.Phase.beforeLaunch, .running])
    fileprivate func disconnectDuringValidation(phase: GatedConnectionValidator.Phase) async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        try fixture.releaseHandshake()
        let validator = GatedConnectionValidator(phase: phase)
        defer { validator.release() }
        let gateway = CodexGateway(
            executableURL: fixture.executable, clientVersion: "test",
            runtimeValidator: validator, globalStateURL: nil
        )
        let first = Task { try await gateway.connect() }
        try await waitForLifecycleCondition { validator.hasEnteredGate }
        let oldProcessID = validator.processID
        await gateway.disconnect()
        #expect(await gateway.connectionState() == .disconnected)
        #expect(try fixture.requests().isEmpty)
        #expect(try await gateway.connect() == .connected(version: "lifecycle-test"))
        validator.release()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(await gateway.connectionState() == .connected(version: "lifecycle-test"))
        #expect(try await gateway.accountSnapshot().authenticated)
        #expect(try fixture.requests().filter { $0 == "initialize" }.count == 1)
        if let oldProcessID {
            try await waitForLifecycleCondition { kill(oldProcessID, 0) != 0 }
        }
        await gateway.disconnect()
    }

    @Test("A timed-out initialize can be retried without an already-running error")
    func retryAfterFailedHandshake() async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        let transport = CodexAppServerTransport(
            // The blocked first handshake deterministically times out. Allow a
            // normal retry enough time to launch while other build/tests run.
            executableURL: fixture.executable, clientVersion: "test", requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator()
        )
        await #expect(throws: CodexTransportError.requestTimedOut("initialize")) {
            try await transport.start()
        }
        try fixture.releaseHandshake()
        #expect(try await transport.start()["userAgent"] == .string("lifecycle-test"))
        #expect(try await transport.request(method: "account/read", params: EmptyParameters())["account"] != nil)
        await transport.stop()
    }

    @Test("Reconnection restores notifications and closes a malformed session before retry")
    func reconnectRestoresNotifications() async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        try fixture.releaseHandshake()
        let gateway = CodexGateway(
            executableURL: fixture.executable, clientVersion: "test", requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator(), globalStateURL: nil
        )
        _ = try await gateway.connect()
        await gateway.disconnect()
        _ = try await gateway.connect()
        try Data().write(to: fixture.malformedFile)
        await #expect(throws: (any Error).self) { try await gateway.accountSnapshot() }
        try await waitForLifecycleCondition {
            if case .failed = await gateway.connectionState() { return true }
            return false
        }
        #expect(try await gateway.connect() == .connected(version: "lifecycle-test"))
        #expect(try await gateway.accountSnapshot().authenticated)
        await gateway.disconnect()
    }

    @Test("Large split responses preserve byte order and complete before EOF")
    func orderedLargeResponses() async throws {
        let fixture = try ConnectionServerFixture()
        defer { fixture.remove() }
        try fixture.releaseHandshake()
        let payload = (0..<2_048).map {
            String(format: "%08d", $0) + String(repeating: "x", count: 248)
        }.joined()
        try Data(payload.utf8).write(to: fixture.largePayloadFile)
        let transport = CodexAppServerTransport(
            executableURL: fixture.executable, clientVersion: "test", requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator()
        )
        do {
            _ = try await transport.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        let response = try await transport.request(method: "test/large", params: EmptyParameters())
                        #expect(response["payload"]?.stringValue == payload)
                    }
                }
                try await group.waitForAll()
            }
            let final = try await transport.request(method: "test/large-close", params: EmptyParameters())
            #expect(final["payload"]?.stringValue == payload)
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }
}

struct LiveCodexConnectionTests {
    @Test("Installed Codex supports concurrent account/history refreshes and reconnection",
          .enabled(if: ProcessInfo.processInfo.environment["GOBY_RUN_CODEX_ACCOUNT_INTEGRATION"] == "1"),
          .timeLimit(.minutes(3)))
    func installedAccountConnection() async throws {
        let gateway = CodexGateway(
            executableURL: InstalledCodexLocator.locate(),
            clientVersion: "connection-integration-test", globalStateURL: nil
        )
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        guard case .connected = try await gateway.connect() else {
                            Issue.record("Installed Codex did not report a connected state.")
                            return
                        }
                    }
                }
                try await group.waitForAll()
            }
            for _ in 0..<2 {
                _ = try await gateway.connect()
                let account = try await gateway.accountSnapshot()
                #expect(account.authenticated)
                #expect(account.usedPercent != nil || account.secondaryUsedPercent != nil)
                guard case .connected = await gateway.connectionState() else {
                    Issue.record("The connection failed after refreshing account usage.")
                    break
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        let catalog = try await gateway.recentProjectRoots()
                        #expect(!catalog.tasks.isEmpty)
                        if case let .failed(reason) = await gateway.connectionState() {
                            Issue.record("Task history refresh closed Codex: \(reason)")
                        }
                        #expect(try await gateway.accountSnapshot().authenticated)
                    }
                }
                try await group.waitForAll()
            }
            await gateway.disconnect()
            _ = try await gateway.connect()
            #expect(try await gateway.accountSnapshot().authenticated)
            let reconnectedCatalog = try await gateway.recentProjectRoots()
            #expect(!reconnectedCatalog.tasks.isEmpty)
            guard case .connected = await gateway.connectionState() else {
                Issue.record("The reconnected gateway failed while reading task history.")
                await gateway.disconnect()
                return
            }
            await gateway.disconnect()
        } catch {
            await gateway.disconnect()
            throw error
        }
    }
}

private func waitForLifecycleCondition(_ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexTransportError.requestTimedOut("lifecycle test condition")
}

private final class GatedConnectionValidator: CodexRuntimeValidating, @unchecked Sendable {
    enum Phase: Sendable { case beforeLaunch, running }
    private let phase: Phase
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    private var validations = 0
    private var runningValidations = 0
    private var childID: Int32?

    init(phase: Phase) { self.phase = phase }
    var hasEnteredGate: Bool { lock.withLock { entered } }
    var validationCount: Int { lock.withLock { validations } }
    var processID: Int32? { lock.withLock { childID } }
    func release() { gate.signal() }

    func validate(executableURL: URL) throws {
        let shouldBlock = lock.withLock {
            validations += 1
            return phase == .beforeLaunch && validations == 1
        }
        if shouldBlock { try blockFirstValidation() }
    }

    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {
        let shouldBlock = lock.withLock {
            runningValidations += 1
            if runningValidations == 1 { childID = processIdentifier }
            return phase == .running && runningValidations == 1
        }
        if shouldBlock { try blockFirstValidation() }
    }

    private func blockFirstValidation() throws {
        lock.withLock { entered = true }
        guard gate.wait(timeout: .now() + 10) == .success else {
            throw CodexTransportError.requestTimedOut("test validation gate")
        }
    }
}

private struct ConnectionServerFixture {
    let directory: URL
    let executable: URL
    let requestLog: URL
    let releaseFile: URL
    let malformedFile: URL
    let largePayloadFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-connection-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        executable = directory.appending(path: "server")
        requestLog = directory.appending(path: "requests.log")
        releaseFile = directory.appending(path: "release")
        malformedFile = directory.appending(path: "malformed")
        largePayloadFile = directory.appending(path: "large-payload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"method":"([^"]+)"' ]]; then
            method=${match[1]}
            print -r -- "$method" >> "\#(requestLog.path)"
          else
            continue
          fi
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$method" == initialize ]]; then
            while [[ ! -f "\#(releaseFile.path)" ]]; do sleep 0.01; done
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"lifecycle-test\"}}"
          elif [[ "$method" == *account*read* ]]; then
            if [[ -f "\#(malformedFile.path)" ]]; then
              /bin/rm "\#(malformedFile.path)"
              print 'malformed-protocol-response'
            else
              print "{\"id\":${request_id},\"result\":{\"account\":{\"type\":\"chatgpt\"}}}"
            fi
          elif [[ "$method" == *test*large* ]]; then
            print -n "{\"id\":${request_id},\"result\":{\"payload\":\""
            /bin/cat "\#(largePayloadFile.path)"
            print -r -- '"}}'
            if [[ "$method" == *close* ]]; then exit 0; fi
          elif [[ "$method" == *test*close* ]]; then
            print "{\"id\":${request_id},\"result\":{}}"
            exit 0
          else
            print "{\"id\":${request_id},\"result\":{}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func releaseHandshake() throws {
        try Data().write(to: releaseFile)
    }

    func requests() throws -> [String] {
        guard FileManager.default.fileExists(atPath: requestLog.path) else { return [] }
        return try String(contentsOf: requestLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func waitForRequest(_ method: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try requests().contains(method) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CodexTransportError.requestTimedOut(method)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
