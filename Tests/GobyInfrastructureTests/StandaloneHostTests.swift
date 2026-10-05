import Foundation
@testable import GobyInfrastructure
import Testing

@Suite("Standalone host integrity and repository lock")
struct StandaloneHostTests {
    @Test("Standalone Codex rejects a binary without the OpenAI Team ID")
    func wrongTeamID() throws {
        let validator = StandaloneCodexRuntimeIntegrityValidator()
        #expect(throws: CodexRuntimeIntegrityError.invalidSignature) {
            try validator.validate(executableURL: URL(fileURLWithPath: "/bin/echo"))
        }
    }

    @Test("Standalone Codex rejects a symbolic link")
    func symbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-symlink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        #expect(throws: CodexRuntimeIntegrityError.symbolicLink) {
            try StandaloneCodexRuntimeIntegrityValidator().validate(executableURL: link)
        }
    }

    @Test("A binary replaced after validation is rejected before process trust")
    func swappedBinary() throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appending(path: "goby-swap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appending(path: "codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let validator = StandaloneCodexRuntimeIntegrityValidator(assumeValidSignatureForTests: true)
        try validator.validate(executableURL: binary)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(throws: CodexRuntimeIntegrityError.changedDuringValidation) {
            try validator.validateRunningProcess(processIdentifier: getpid(), executableURL: binary)
        }
    }

    @Test("Standalone provider runtime rejects a manifest mismatch")
    func manifestMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-manifest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = root.appending(path: "node")
        try Data("node".utf8).write(to: node)
        #expect(throws: ProviderRuntimeIntegrityError.invalidBundle) {
            try StandaloneProviderRuntimeTrustPolicy(manifest: ["node": String(repeating: "0", count: 64)])
                .validateProviderRuntime(bundleURL: root, runtimeURLs: [node])
        }
    }

    @Test("App policy retains its canonical Codex location restriction")
    func appPolicyUnchanged() throws {
        #expect(throws: CodexRuntimeIntegrityError.untrustedLocation) {
            try AppProviderRuntimeTrustPolicy().codexValidator()
                .validate(executableURL: URL(fileURLWithPath: "/bin/echo"))
        }
    }

    @Test("Independent hosts coordinate through one Git common-directory lock")
    func repositoryLockAcrossHosts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-repo-lock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "--quiet"]
        git.standardOutput = Pipe()
        git.standardError = Pipe()
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)

        let firstHost = GADRepositoryAdvisoryLock()
        let secondHost = GADRepositoryAdvisoryLock()
        let first = try await firstHost.acquire(
            repositoryURL: root, ownerLabel: "first", reservationID: "same-run", maximumWait: .seconds(1)
        )
        let sameRun = try await firstHost.acquire(
            repositoryURL: root, ownerLabel: "first", reservationID: "same-run", maximumWait: .seconds(1)
        )
        #expect(first === sameRun)
        do {
            _ = try await secondHost.acquire(
                repositoryURL: root, ownerLabel: "second", maximumWait: .milliseconds(300)
            )
            Issue.record("Second host acquired a lock still owned by the first host")
        } catch let error as GADRepositoryLockError {
            guard case .held = error else { Issue.record("Unexpected lock error: \(error)"); return }
        }
        await firstHost.release(reservationID: "same-run")
        let second = try await secondHost.acquire(repositoryURL: root, ownerLabel: "second", maximumWait: .seconds(1))
        second.release()
    }

    @Test("Parallel runs in one host share the repository lock until the last run ends")
    func repositoryLockParallelRunsInOneHost() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-repo-lock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "--quiet"]
        git.standardOutput = Pipe()
        git.standardError = Pipe()
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)

        let host = GADRepositoryAdvisoryLock()
        let otherHost = GADRepositoryAdvisoryLock()
        let runA = try await host.acquire(
            repositoryURL: root, ownerLabel: "host", reservationID: "run-a", maximumWait: .milliseconds(300)
        )
        let runB = try await host.acquire(
            repositoryURL: root, ownerLabel: "host", reservationID: "run-b", maximumWait: .milliseconds(300)
        )
        #expect(runA === runB)

        await host.release(reservationID: "run-a")
        do {
            _ = try await otherHost.acquire(
                repositoryURL: root, ownerLabel: "other", maximumWait: .milliseconds(300)
            )
            Issue.record("Another host acquired the lock while run B was still active")
        } catch let error as GADRepositoryLockError {
            guard case .held = error else { Issue.record("Unexpected lock error: \(error)"); return }
        }

        await host.release(reservationID: "run-b")
        let other = try await otherHost.acquire(
            repositoryURL: root, ownerLabel: "other", maximumWait: .seconds(1)
        )
        other.release()
    }
}
