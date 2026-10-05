import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

@Suite("Project Git branch manager")
struct ProjectGitBranchManagerTests {
    @Test("Lists local branches and switches only the approved clean working copy")
    func switchesApprovedBranch() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = LocalProjectGitBranchManager()

        let before = try await manager.inspect(project: fixture.project)
        #expect(before.currentBranch == "main")
        #expect(before.localBranches == ["feature", "main"])
        #expect(!before.hasUncommittedChanges)

        let after = try await manager.switchBranch(
            project: fixture.project,
            approval: ProjectGitBranchSwitchApproval(
                projectID: fixture.project.id,
                expectedCurrentBranch: "main",
                destinationBranch: "feature"
            )
        )

        #expect(after.currentBranch == "feature")
        #expect(try runGit(["branch", "--show-current"], in: fixture.root) == "feature")
    }

    @Test("Refuses to switch a dirty working copy without stashing or discarding it")
    func refusesDirtyWorkingCopy() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let untracked = fixture.root.appending(path: "keep-me.txt")
        try Data("user work".utf8).write(to: untracked)
        let manager = LocalProjectGitBranchManager()

        let inspected = try await manager.inspect(project: fixture.project)
        #expect(inspected.hasUncommittedChanges)
        do {
            _ = try await manager.switchBranch(
                project: fixture.project,
                approval: ProjectGitBranchSwitchApproval(
                    projectID: fixture.project.id,
                    expectedCurrentBranch: "main",
                    destinationBranch: "feature"
                )
            )
            Issue.record("Expected dirty working copy rejection")
        } catch {
            #expect(error as? ProjectGitBranchError == .dirtyWorkingCopy)
        }

        #expect(try runGit(["branch", "--show-current"], in: fixture.root) == "main")
        #expect(try String(contentsOf: untracked, encoding: .utf8) == "user work")
    }

    @Test("Refuses a stale approval after the current branch changes")
    func refusesStaleApproval() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = LocalProjectGitBranchManager()
        _ = try runGit(["switch", "--quiet", "feature"], in: fixture.root)

        do {
            _ = try await manager.switchBranch(
                project: fixture.project,
                approval: ProjectGitBranchSwitchApproval(
                    projectID: fixture.project.id,
                    expectedCurrentBranch: "main",
                    destinationBranch: "feature"
                )
            )
            Issue.record("Expected stale approval rejection")
        } catch {
            #expect(
                error as? ProjectGitBranchError
                    == .currentBranchChanged(expected: "main", actual: "feature")
            )
        }
    }

    @Test("Option-like low-level refs are never offered or passed to Git")
    func rejectsOptionLikeBranches() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let head = try runGit(["rev-parse", "HEAD"], in: fixture.root)
        _ = try runGit(["update-ref", "refs/heads/--detach", head], in: fixture.root)
        let manager = LocalProjectGitBranchManager()

        let snapshot = try await manager.inspect(project: fixture.project)
        #expect(!snapshot.localBranches.contains("--detach"))
        await #expect(throws: ProjectGitBranchError.self) {
            try await manager.switchBranch(
                project: fixture.project,
                approval: .init(
                    projectID: fixture.project.id,
                    expectedCurrentBranch: "main",
                    destinationBranch: "--detach"
                )
            )
        }
        #expect(try runGit(["branch", "--show-current"], in: fixture.root) == "main")
    }

    @Test("A replaced registered repository root cannot redirect Git operations")
    func rejectsReplacedRepositoryRoot() async throws {
        let original = try makeRepository()
        let outside = try makeRepository()
        let retained = original.root.appendingPathExtension("retained")
        defer {
            try? FileManager.default.removeItem(at: original.root)
            try? FileManager.default.removeItem(at: retained)
            try? FileManager.default.removeItem(at: outside.root)
        }
        try FileManager.default.moveItem(at: original.root, to: retained)
        try FileManager.default.createSymbolicLink(at: original.root, withDestinationURL: outside.root)
        let outsideBranch = try runGit(["branch", "--show-current"], in: outside.root)

        await #expect(throws: ProjectGitBranchError.self) {
            _ = try await LocalProjectGitBranchManager().inspect(project: original.project)
        }

        #expect(try runGit(["branch", "--show-current"], in: outside.root) == outsideBranch)
    }

    @Test("A standard linked worktree remains discoverable and supports branch inspection")
    func supportsLinkedWorktrees() async throws {
        let fixture = try makeRepository()
        let worktree = fixture.root.appendingPathExtension("linked")
        defer {
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        _ = try runGit(
            ["worktree", "add", "--quiet", "-b", "linked-review", worktree.path(percentEncoded: false)],
            in: fixture.root
        )
        let project = LabProject(
            id: ProjectID.derived(fromProjectRoot: worktree),
            name: "Linked Fixture",
            rootURL: worktree,
            platforms: [.general],
            isGitRepository: true
        )

        let discovered = try #require(
            try await FileSystemProjectDiscovery().discover(selectedRoots: [worktree]).first
        )
        let snapshot = try await LocalProjectGitBranchManager().inspect(project: project)

        #expect(discovered.project.isGitRepository)
        #expect(snapshot.currentBranch == "linked-review")
        #expect(snapshot.localBranches.contains("main"))
    }

    private func makeRepository() throws -> (root: URL, project: LabProject) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-branch-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init", "--quiet", "--initial-branch=main"], in: root)
        try Data("# Fixture\n".utf8).write(to: root.appending(path: "README.md"))
        _ = try runGit(["add", "README.md"], in: root)
        _ = try runGit([
            "-c", "user.name=Goby Tests",
            "-c", "user.email=goby-tests@example.invalid",
            "commit", "--quiet", "-m", "Initial",
        ], in: root)
        _ = try runGit(["branch", "feature"], in: root)
        let project = LabProject(
            id: ProjectID.derived(fromProjectRoot: root),
            name: "Branch Fixture",
            rootURL: root,
            platforms: [.general],
            isGitRepository: true
        )
        return (root, project)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
            "-C", directory.path(percentEncoded: false),
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
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ProjectGitBranchError.commandFailed(output)
        }
        return output
    }
}
