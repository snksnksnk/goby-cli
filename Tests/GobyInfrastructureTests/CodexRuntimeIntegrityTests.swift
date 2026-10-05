import Foundation
import Testing
@testable import GobyInfrastructure

struct AllowingCodexRuntimeValidator: CodexRuntimeValidating {
    func validate(executableURL: URL) throws {}
}

private enum TestCodexRuntimeValidationError: Error {
    case rejected
    case rejectedRunningProcess
}

private final class RejectingCodexRuntimeValidator: CodexRuntimeValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func validate(executableURL: URL) throws {
        lock.withLock { count += 1 }
        throw TestCodexRuntimeValidationError.rejected
    }

    func validationCount() -> Int {
        lock.withLock { count }
    }
}

private final class RejectingRunningCodexRuntimeValidator: CodexRuntimeValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var beforeLaunchCount = 0
    private var runningProcessCount = 0

    func validate(executableURL: URL) throws {
        lock.withLock { beforeLaunchCount += 1 }
    }

    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {
        lock.withLock { runningProcessCount += 1 }
        throw TestCodexRuntimeValidationError.rejectedRunningProcess
    }

    func counts() -> (beforeLaunch: Int, runningProcess: Int) {
        lock.withLock { (beforeLaunchCount, runningProcessCount) }
    }
}

private final class ThreadRecordingCodexRuntimeValidator: CodexRuntimeValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var ranOnMainThread: Bool?

    func validate(executableURL: URL) throws {
        lock.withLock { ranOnMainThread = Thread.isMainThread }
        throw TestCodexRuntimeValidationError.rejected
    }

    func validationRanOnMainThread() -> Bool? {
        lock.withLock { ranOnMainThread }
    }
}

@Suite("Codex runtime integrity")
struct CodexRuntimeIntegrityTests {
    @Test("Default locator never auto-selects a mutable Homebrew runtime")
    func locatorUsesCanonicalOpenAIRuntime() {
        let located = InstalledCodexLocator.locate(
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin"]
        )

        #expect(InstalledCodexLocator.approvedExecutableURLs.contains(located))
        #expect(located == InstalledCodexLocator.locate(environment: [:]))
    }

#if DEBUG
    @Test("DEBUG locator accepts only an explicit absolute development runtime")
    func locatorAcceptsExplicitDevelopmentRuntime() {
        let explicit = "/private/tmp/goby-development-codex"
        #expect(InstalledCodexLocator.locate(environment: [
            InstalledCodexLocator.developmentExecutableEnvironmentKey: explicit,
        ]) == URL(fileURLWithPath: explicit))
        #expect(InstalledCodexLocator.locate(environment: [
            InstalledCodexLocator.developmentExecutableEnvironmentKey: "relative/codex",
        ]) == InstalledCodexLocator.canonicalExecutableURL)
    }
#endif

    @Test("Production validator rejects a Homebrew Codex path")
    func rejectsHomebrewRuntime() {
        let validator = CodexRuntimeIntegrityValidator(environment: [:])

        #expect(throws: CodexRuntimeIntegrityError.untrustedLocation) {
            try validator.validate(
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            )
        }
    }

    @Test(
        "Installed canonical runtime has the expected OpenAI signature and seal",
        .enabled(if: FileManager.default.isExecutableFile(
            atPath: InstalledCodexLocator.canonicalExecutableURL.path(percentEncoded: false)
        ))
    )
    func acceptsInstalledCanonicalRuntime() throws {
        try CodexRuntimeIntegrityValidator(environment: [:]).validate(
            executableURL: InstalledCodexLocator.canonicalExecutableURL
        )
    }

    @Test(
        "Locator selects the signature-validated Codex CLI inside the current ChatGPT bundle",
        .enabled(if: FileManager.default.isExecutableFile(
            atPath: InstalledCodexLocator.canonicalExecutableURL.path(percentEncoded: false)
        ))
    )
    func selectsCurrentInstalledRuntime() throws {
        #expect(InstalledCodexLocator.locate(environment: [:]) == InstalledCodexLocator.canonicalExecutableURL)
        try CodexRuntimeIntegrityValidator(environment: [:]).validate(
            executableURL: InstalledCodexLocator.locate(environment: [:])
        )
    }

    @Test("Executable path policy rejects symbolic-link substitution")
    func rejectsSymbolicLinkSubstitution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-codex-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "target")
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: target.path(percentEncoded: false)
        )
        let link = directory.appending(path: "codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: CodexRuntimeIntegrityError.symbolicLink) {
            _ = try CodexRuntimePathPolicy.validateExecutable(link)
        }
    }

    @Test("App-server transport validates before process launch")
    func transportRejectsBeforeLaunch() async throws {
        let fixture = try launchMarkerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validator = RejectingCodexRuntimeValidator()
        let transport = CodexAppServerTransport(
            executableURL: fixture.executable,
            clientVersion: "test",
            runtimeValidator: validator
        )

        await #expect(throws: TestCodexRuntimeValidationError.rejected) {
            _ = try await transport.start()
        }
        #expect(validator.validationCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path(percentEncoded: false)))
    }

    @Test("App-server transport keeps signature validation off the main thread")
    @MainActor
    func transportValidatesOffMainThread() async throws {
        let fixture = try launchMarkerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validator = ThreadRecordingCodexRuntimeValidator()
        let transport = CodexAppServerTransport(
            executableURL: fixture.executable,
            clientVersion: "test",
            runtimeValidator: validator
        )

        await #expect(throws: TestCodexRuntimeValidationError.rejected) {
            _ = try await transport.start()
        }
        #expect(validator.validationRanOnMainThread() == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path(percentEncoded: false)))
    }

    @Test("App-server transport attests the running process before protocol initialization")
    func transportRejectsUnattestedRunningProcess() async throws {
        let fixture = try launchMarkerFixture(keepsRunning: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validator = RejectingRunningCodexRuntimeValidator()
        let transport = CodexAppServerTransport(
            executableURL: fixture.executable,
            clientVersion: "test",
            runtimeValidator: validator
        )

        await #expect(throws: TestCodexRuntimeValidationError.rejectedRunningProcess) {
            _ = try await transport.start()
        }
        let counts = validator.counts()
        #expect(counts.beforeLaunch == 1)
        #expect(counts.runningProcess == 1)
    }

    @Test("Every Codex preflight process validates before launch")
    func preflightRejectsBeforeLaunch() async throws {
        let fixture = try launchMarkerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validator = RejectingCodexRuntimeValidator()
        let health = await SystemPreflight(
            codexURL: fixture.executable,
            storageURL: fixture.directory,
            codexRuntimeValidator: validator
        ).check(projects: [])

        #expect(validator.validationCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path(percentEncoded: false)))
        #expect(health.checks.first { $0.kind == .codex }?.status == .failed)
        #expect(health.checks.first { $0.kind == .appServerProtocol }?.status == .failed)
    }

    @Test("System preflight keeps runtime validation off the main thread")
    @MainActor
    func preflightValidatesOffMainThread() async throws {
        let fixture = try launchMarkerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validator = ThreadRecordingCodexRuntimeValidator()

        let health = await SystemPreflight(
            codexURL: fixture.executable,
            storageURL: fixture.directory,
            codexRuntimeValidator: validator
        ).check(projects: [])

        #expect(validator.validationRanOnMainThread() == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path(percentEncoded: false)))
        #expect(health.checks.first { $0.kind == .codex }?.status == .failed)
    }

    @Test("System preflight bounds a stalled runtime command")
    func preflightBoundsStalledRuntime() async throws {
        let fixture = try launchMarkerFixture(keepsRunning: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let startedAt = Date()

        let health = await SystemPreflight(
            codexURL: fixture.executable,
            storageURL: fixture.directory,
            codexRuntimeValidator: AllowingCodexRuntimeValidator(),
            commandTimeout: 0.1
        ).check(projects: [])

        #expect(Date().timeIntervalSince(startedAt) < 5)
        #expect(health.checks.first { $0.kind == .codex }?.status == .failed)
        #expect(health.checks.first { $0.kind == .codex }?.summary == "The command timed out.")
    }

    @Test("System preflight drains and caps noisy command output")
    func preflightBoundsNoisyRuntimeOutput() async throws {
        let fixture = try noisyRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let startedAt = Date()

        let health = await SystemPreflight(
            codexURL: fixture.executable,
            storageURL: fixture.directory,
            codexRuntimeValidator: AllowingCodexRuntimeValidator(),
            commandTimeout: 2,
            maximumCommandOutputBytes: 1_024
        ).check(projects: [])

        #expect(Date().timeIntervalSince(startedAt) < 5)
        #expect(health.checks.first { $0.kind == .codex }?.status == .failed)
        #expect(health.checks.first { $0.kind == .codex }?.summary == "The command returned too much output.")
    }

    private func launchMarkerFixture(
        keepsRunning: Bool = false
    ) throws -> (directory: URL, executable: URL, marker: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-codex-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "launched")
        let executable = directory.appending(path: "codex")
        let wait = keepsRunning ? "exec /bin/sleep 10\n" : ""
        let script = "#!/bin/zsh\n/usr/bin/touch \"\(marker.path(percentEncoded: false))\"\n\(wait)exit 0\n"
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (directory, executable, marker)
    }

    private func noisyRuntimeFixture() throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-codex-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "codex")
        let script = "#!/bin/zsh\n/usr/bin/yes x | /usr/bin/head -c 1048576\n"
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (directory, executable)
    }
}
