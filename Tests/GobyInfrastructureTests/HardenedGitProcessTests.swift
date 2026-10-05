import Darwin
import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Hardened host Git boundary", .serialized)
struct HardenedGitProcessTests {
    @Test("GitHub CLI credentials are scoped to the exact GitHub HTTPS host")
    func gitHubCredentialScope() throws {
        #expect(LocalProjectDirectoryCreator.isGitHubHTTPSRepository(
            "https://github.com/example/private.git"
        ))
        #expect(!LocalProjectDirectoryCreator.isGitHubHTTPSRepository(
            "https://github.com.evil.example/example/private.git"
        ))
        #expect(!LocalProjectDirectoryCreator.isGitHubHTTPSRepository(
            "https://user@github.com/example/private.git"
        ))

        let arguments = try HardenedGitProcess.credentialHelperArguments(
            for: URL(fileURLWithPath: "/usr/bin/false")
        )
        #expect(arguments == [
            "-c", "credential.helper=",
            "-c", "credential.https://github.com.helper=!/usr/bin/false auth git-credential",
        ])
        #expect(!arguments.joined(separator: " ").contains("token"))
        #expect(!arguments.joined(separator: " ").contains("password"))
    }

    @Test("Clone authentication failures are actionable and hide staging paths")
    func cloneAuthenticationFailureIsActionable() {
        let staging = URL(fileURLWithPath: "/private/tmp/goby-project-clone-secret")
        let message = LocalProjectDirectoryCreator.cloneFailureMessage(
            "Cloning into '/private/tmp/goby-project-clone-secret/repository'...\nfatal: could not read Username for 'https://github.com': terminal prompts disabled",
            source: "https://github.com/example/private.git",
            stagingParent: staging,
            usedGitHubCredentialHelper: false
        )

        #expect(message.contains("authenticated GitHub CLI"))
        #expect(!message.contains("/private/tmp"))
        #expect(!message.contains("Git could not clone the repository. Git could not clone"))
    }

    @Test("Executable repository Git configuration is rejected before an operation")
    func rejectsExecutableConfiguration() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try rawGit(["-C", repository.path(), "config", "filter.hostile.clean", "/usr/bin/false"])

        #expect(throws: HardenedGitProcessError.self) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
        let configured = try rawGit([
            "-C", repository.path(), "config", "--local", "--get", "filter.hostile.clean",
        ])
        #expect(configured.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/bin/false")
    }

    @Test("A clean repository still supports ordinary inspected operations")
    func cleanRepositoryWorks() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let result = try HardenedGitProcess.run(
            arguments: ["-C", repository.path(), "status", "--porcelain"],
            currentDirectory: repository
        )
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test("Read-only host status cannot execute a worktree-scoped clean filter")
    func worktreeConfigCannotExecuteDuringStatus() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let tracked = repository.appending(path: "tracked.txt")
        let sentinel = repository.appending(path: "filter-executed")
        try Data("before\n".utf8).write(to: tracked)
        try rawGit(["-C", repository.path(), "add", "tracked.txt"])
        try rawGit(["-C", repository.path(), "config", "extensions.worktreeConfig", "true"])
        try rawGit(["-C", repository.path(), "config", "--worktree", "filter.hostile.clean",
                    "/usr/bin/touch filter-executed; /bin/cat"])
        try Data("*.txt filter=hostile\n".utf8).write(to: repository.appending(path: ".gitattributes"))
        try Data("after!\n".utf8).write(to: tracked)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: tracked.path)

        #expect(throws: HardenedGitProcessError.self) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
        let filterExecuted = FileManager.default.fileExists(atPath: sentinel.path)
        #expect(!filterExecuted,
                "Read-only status must reject the repository before its filter can run.")
    }

    @Test("Executable direct and included worktree settings are rejected in main and linked worktrees",
          arguments: ["clean", "smudge", "process"], [false, true])
    func rejectsWorktreeExecutableScopes(filterKind: String, linked: Bool) throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try rawGit(["-C", repository.path(), "-c", "user.name=Goby Test", "-c", "user.email=goby@example.invalid",
                    "commit", "--quiet", "--allow-empty", "-m", "fixture"])
        try rawGit(["-C", repository.path(), "config", "extensions.worktreeConfig", "true"])
        let directory: URL
        let common: URL?
        if linked {
            directory = repository.appending(path: "linked", directoryHint: .isDirectory)
            try rawGit(["-C", repository.path(), "worktree", "add", "--quiet", "-b", "fixture", directory.path()])
            common = repository.appending(path: ".git", directoryHint: .isDirectory)
        } else {
            directory = repository
            common = nil
        }
        try rawGit(["-C", directory.path(), "config", "--worktree", "core.abbrev", "10"])
        #expect(try HardenedGitProcess.run(
            arguments: ["-C", directory.path(), "status", "--porcelain"],
            currentDirectory: directory, allowedLinkedWorktreeCommonDirectory: common
        ).status == 0)
        let key = "filter.hostile.\(filterKind)"
        let sentinel = directory.appending(path: "filter-executed")
        try rawGit(["-C", directory.path(), "config", "--worktree", key, "/usr/bin/touch filter-executed; /bin/cat"])
        #expect(throws: HardenedGitProcessError.self) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", directory.path(), "status", "--porcelain"],
                currentDirectory: directory, allowedLinkedWorktreeCommonDirectory: common
            )
        }
        try rawGit(["-C", directory.path(), "config", "--worktree", "--unset", key])
        let included = repository.appending(path: ".git/filter-settings")
        try rawGit(["config", "--file", included.path(), key, "/usr/bin/touch filter-executed; /bin/cat"])
        try rawGit(["-C", directory.path(), "config", "--worktree", "include.path", included.path()])
        #expect(throws: HardenedGitProcessError.self) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", directory.path(), "status", "--porcelain"],
                currentDirectory: directory, allowedLinkedWorktreeCommonDirectory: common
            )
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try rawGit(["-C", directory.path(), "config", "--worktree", "--includes", "--get", key])
            .contains("touch filter-executed"), "Rejection must preserve repository configuration.")
    }

    @Test("Git output is rejected while the configured byte budget is being read")
    func outputIsBoundedOnline() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("fixture\n".utf8).write(to: repository.appending(path: "README.md"))
        try rawGit(["-C", repository.path(), "add", "README.md"])

        #expect(throws: HardenedGitProcessError.outputTooLarge) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository,
                maximumOutputBytes: 4
            )
        }

        let followUp = try HardenedGitProcess.run(
            arguments: ["-C", repository.path(), "rev-parse", "--is-inside-work-tree"],
            currentDirectory: repository
        )
        #expect(followUp.status == 0)
        #expect(followUp.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test("Git directory growth is rejected at the configured online budget")
    func directoryGrowthIsBoundedOnline() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-git-directory-budget-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let target = container.appending(path: "target", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        #expect(throws: HardenedGitProcessError.directoryBudgetExceeded) {
            _ = try HardenedGitProcess.run(
                arguments: ["init", "target"],
                currentDirectory: container,
                timeout: 5,
                maximumOutputBytes: 64 * 1_024,
                directoryBudget: .init(
                    rootURL: target,
                    maximumBytes: 1,
                    maximumEntries: 1
                ),
                preflightRepository: false
            )
        }
    }

    @Test("Git timeout returns even when a descendant retains the output pipe")
    func timeoutDoesNotWaitForInheritedPipeEOF() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let startedAt = ContinuousClock.now

        #expect(throws: HardenedGitProcessError.commandTimedOut) {
            _ = try HardenedGitProcess.run(
                arguments: [
                    "-c",
                    "alias.goby-hang=!trap '' TERM; while :; do printf x; /bin/sleep 0.02; done",
                    "goby-hang",
                ],
                currentDirectory: repository,
                timeout: 0.1,
                maximumOutputBytes: 64 * 1_024,
                preflightRepository: false
            )
        }
        #expect(startedAt.duration(to: .now) < .seconds(3))
    }

    @Test("A repository cannot redirect Git metadata outside its reviewed root")
    func rejectsExternalGitDirectory() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-external-git-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let workTree = container.appending(path: "work-tree", directoryHint: .isDirectory)
        let gitDirectory = container.appending(path: "external-metadata", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: workTree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try rawGit([
            "-C", workTree.path(), "init", "--quiet", "--separate-git-dir", gitDirectory.path(),
        ])

        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", workTree.path(), "status", "--porcelain"],
                currentDirectory: workTree
            )
        }
    }

    @Test("Nested Git metadata symlinks are rejected before Git runs")
    func rejectsNestedMetadataSymlink() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-nested-git-symlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        let externalRefs = container.appending(path: "external-refs", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRefs, withIntermediateDirectories: true)
        try rawGit(["-C", container.path(), "init", "--quiet", repository.path()])
        let heads = repository.appending(path: ".git/refs/heads", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: heads)
        try FileManager.default.createSymbolicLink(at: heads, withDestinationURL: externalRefs)

        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
    }

    @Test("Unlisted Git metadata root symlinks are rejected before Git runs")
    func rejectsMetadataRootSymlink() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-root-git-symlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        let external = container.appending(path: "external-message.txt")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try rawGit(["-C", container.path(), "init", "--quiet", repository.path()])
        try Data("preserve-me".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: repository.appending(path: ".git/COMMIT_EDITMSG"),
            withDestinationURL: external
        )

        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "commit", "--allow-empty", "-m", "blocked"],
                currentDirectory: repository
            )
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "preserve-me")
    }

    @Test("Git metadata root hard links are rejected before Git runs")
    func rejectsMetadataRootHardLink() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-root-git-hardlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        let external = container.appending(path: "external-message.txt")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try rawGit(["-C", container.path(), "init", "--quiet", repository.path()])
        try Data("preserve-me".utf8).write(to: external)
        try FileManager.default.linkItem(
            at: external,
            to: repository.appending(path: ".git/COMMIT_EDITMSG")
        )

        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "commit", "--allow-empty", "-m", "blocked"],
                currentDirectory: repository
            )
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "preserve-me")
    }

    @Test("Loose Git object symlinks are rejected before Git runs")
    func rejectsLooseObjectSymlink() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-loose-object-symlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        let external = container.appending(path: "external-object")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try rawGit(["-C", container.path(), "init", "--quiet", repository.path()])
        try Data("external".utf8).write(to: external)
        let fanout = repository.appending(path: ".git/objects/aa", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fanout, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fanout.appending(path: String(repeating: "b", count: 38)),
            withDestinationURL: external
        )

        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
    }

    @Test("Loose Git object FIFOs are rejected without blocking")
    func rejectsLooseObjectFIFO() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-loose-object-fifo-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try rawGit(["-C", container.path(), "init", "--quiet", repository.path()])
        let fanout = repository.appending(path: ".git/objects/cc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fanout, withIntermediateDirectories: true)
        let fifo = fanout.appending(path: String(repeating: "d", count: 38))
        let status = fifo.path().withCString { mkfifo($0, S_IRUSR | S_IWUSR) }
        #expect(status == 0)

        let startedAt = ContinuousClock.now
        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
        #expect(startedAt.duration(to: .now) < .seconds(1))
    }

    @Test("Git's own fsmonitor socket is accepted only by name at the Git-directory root",
          arguments: [
            ("fsmonitor--daemon.ipc", "", true),
            ("other.ipc", "", false),
            ("fsmonitor--daemon.ipc", "refs/", false),
          ])
    func gitOwnedSocketBoundary(name: String, subdirectory: String, accepted: Bool) throws {
        // Unix socket paths are limited to 104 bytes, so keep the root short.
        let repository = URL(fileURLWithPath: "/private/tmp/gfsm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try rawGit(["-C", repository.path(), "init", "--quiet"])
        let socketDescriptor = try bindSocket(
            at: repository.appending(path: ".git/" + subdirectory + name).path(percentEncoded: false)
        )
        defer { close(socketDescriptor) }

        let attempt = {
            try HardenedGitProcess.run(
                arguments: ["-C", repository.path(), "status", "--porcelain"],
                currentDirectory: repository
            )
        }
        if accepted {
            #expect(try attempt().status == 0)
        } else {
            #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) { _ = try attempt() }
        }
    }

    private func bindSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
        return descriptor
    }

    @Test("An explicitly approved linked worktree keeps its Git metadata boundary")
    func allowsApprovedLinkedWorktree() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-linked-git-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let repository = container.appending(path: "repository", directoryHint: .isDirectory)
        let worktree = container.appending(path: "worktree", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try rawGit(["-C", repository.path(), "init", "--quiet"])
        try rawGit(["-C", repository.path(), "config", "user.email", "goby@example.invalid"])
        try rawGit(["-C", repository.path(), "config", "user.name", "Goby Test"])
        try Data("fixture\n".utf8).write(to: repository.appending(path: "README.md"))
        try rawGit(["-C", repository.path(), "add", "README.md"])
        try rawGit(["-C", repository.path(), "commit", "--quiet", "-m", "fixture"])
        try rawGit([
            "-C", repository.path(), "worktree", "add", "--quiet", "-b", "goby/test", worktree.path(),
        ])
        let commonPath = try rawGit([
            "-C", repository.path(), "rev-parse", "--path-format=absolute", "--git-common-dir",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try HardenedGitProcess.run(
            arguments: ["-C", worktree.path(), "status", "--porcelain"],
            currentDirectory: worktree,
            allowedLinkedWorktreeCommonDirectory: URL(fileURLWithPath: commonPath, isDirectory: true)
        )

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(throws: HardenedGitProcessError.unsafeRepositoryMetadata) {
            _ = try HardenedGitProcess.run(
                arguments: ["-C", worktree.path(), "status", "--porcelain"],
                currentDirectory: worktree
            )
        }
    }

    private func makeRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory.appending(
            path: "goby-safe-git-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try rawGit(["-C", repository.path(), "init", "--quiet"])
        return repository
    }

    @discardableResult
    private func rawGit(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
        ] + arguments
        process.environment = [
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "HOME": "/var/empty",
            "LANG": "C",
            "LC_ALL": "C",
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
            "XDG_CONFIG_HOME": "/var/empty",
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }
}
