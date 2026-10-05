import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

@Suite("Working-copy commit and push")
struct WorkingCopyCommitTests {
    @Test("A commit-only request plans a commit in the folder and a push step, without a worktree")
    func routerPlansWorkingCopyCommit() async throws {
        #expect(RouteMutationIntent.isCommitOnly("commit and push"))
        #expect(RouteMutationIntent.isCommitOnly("Commit my changes"))
        #expect(!RouteMutationIntent.isCommitOnly("fix the login screen and commit"))
        #expect(RouteMutationIntent.isCommitOnly("push to git"))
        #expect(!RouteMutationIntent.isCommitOnly("fix the build and push"))
        #expect(!RouteMutationIntent.isCommitOnly("merge and push"))

        let siry = LabProject(
            id: "siry", name: "Siry", rootURL: FileManager.default.temporaryDirectory.appending(path: "siry"),
            platforms: [.iOS], isGitRepository: true
        )
        let lab = LabSnapshot(projects: [siry], agents: [
            AgentProfile(id: "ios", name: "iOS Agent", summary: "iOS", capabilities: [.iOS, .routing], scope: .project(siry.id)),
        ])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "commit and push", scope: .projects([siry.id])), in: lab
        )
        #expect(plan.gitOperations.map(\.kind) == [.commit, .push])
        #expect(plan.commitsWorkingCopy)
        #expect(!plan.warnings.contains { $0.contains("never push") })
        #expect(plan.removingPushOperations().gitOperations.map(\.kind) == [.commit])
        #expect(plan.deliveryPipeline == nil)

        let edit = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "fix the login screen and commit", scope: .projects([siry.id])), in: lab
        )
        #expect(edit.gitOperations.contains { $0.kind == .createWorktree })
        #expect(!edit.commitsWorkingCopy)
    }

    @Test("Goby commits the user's changes on the reviewed branch and pushes only when approved")
    func commitsAndPushesInPlace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "--bare", "remote.git"], in: root)
        try git(["init", "-q", "-b", "develop", "work"], in: root)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try git(["config", "user.name", "Test"], in: work)
        try git(["config", "user.email", "test@example.com"], in: work)
        try "one".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: work)
        try git(["commit", "-q", "-m", "Initial"], in: work)
        try git(["remote", "add", "origin", root.appending(path: "remote.git").path(percentEncoded: false)], in: work)
        try git(["push", "-q", "origin", "develop"], in: work)

        let project = LabProject(
            id: "project", name: "Project", rootURL: work, platforms: [.macOS],
            isGitRepository: true, fileSystemIdentity: GADFileSystemIdentity.capture(work)
        )
        let manager = GitWorkspaceManager(worktreesRoot: root.appending(path: "Worktrees"), approvals: ApprovalPolicy())
        let operations = [
            PlannedGitOperation(projectID: project.id, kind: .commit, branch: "develop"),
            PlannedGitOperation(projectID: project.id, kind: .push, branch: "develop", remote: "origin"),
        ]
        func run(_ plan: RoutingPlan) -> RunRecord {
            RunRecord(
                id: plan.id, plan: plan, status: .running, assignments: [],
                approvalReceipts: [ApprovalReceipt(
                    runID: plan.id, decision: .approved, operationIDs: Set(plan.gitOperations.map(\.id))
                )]
            )
        }
        let plan = RoutingPlan(
            id: "run", interpretedGoal: "commit and push",
            routes: [ProjectRoute(projectID: project.id, agentIDs: ["agent"], reason: "Matched")],
            risk: .medium, confidence: 1, gitOperations: operations
        )

        let placement = try await manager.prepare(project: project, for: run(plan))
        #expect(placement.rootURL.standardizedFileURL == work.standardizedFileURL)

        try "two".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        try "new".write(to: work.appending(path: "NOTES"), atomically: true, encoding: .utf8)
        // Goby reads the changes for the commit-message agent itself.
        let changes = try #require(GitWorkspaceManager.workingCopyChanges(in: work))
        #expect(changes.contains("?? NOTES"))
        #expect(changes.contains("README"))
        #expect(changes.contains("+two"))
        let task = CodexRunOrchestrator.commitMessageTask(request: "push to git", pushes: true, changes: changes)
        #expect(task.contains("Do not run any commands"))
        #expect(task.contains("+two"))
        let pushed = try await manager.finalize(
            project: project, workingDirectory: work, for: run(plan),
            commitMessage: "```\nUpdate the readme\n\nSay two.\n```"
        )
        #expect(pushed?.contains("Committed 2 files on develop") == true)
        #expect(pushed?.contains("Pushed develop to origin.") == true)
        #expect(try output(["log", "-1", "--format=%s"], in: work) == "Update the readme")
        let head = try output(["rev-parse", "HEAD"], in: work)
        #expect(try output(["rev-parse", "develop"], in: root.appending(path: "remote.git")) == head)

        // Without the separate push approval the commit stays local.
        let commitOnly = plan.removingPushOperations()
        try "three".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        let committed = try await manager.finalize(
            project: project, workingDirectory: work, for: run(commitOnly), commitMessage: "Say three"
        )
        #expect(committed?.contains("Pushed") == false)
        #expect(try output(["rev-parse", "develop"], in: root.appending(path: "remote.git")) == head)

        // A different branch than reviewed commits nothing.
        try git(["switch", "-q", "-c", "other"], in: work)
        try "four".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        await #expect(throws: WorkspaceError.self) {
            _ = try await manager.finalize(project: project, workingDirectory: work, for: run(plan), commitMessage: "Nope")
        }
        #expect(try output(["status", "--porcelain"], in: work).isEmpty == false)

        // A push follow-up pushes the branch an earlier run committed,
        // without checking it out or touching the folder's changes.
        try git(["switch", "-q", "develop"], in: work)
        try git(["branch", "codex/goby-earlier", "other"], in: work)
        try git(["switch", "-q", "other"], in: work)
        try git(["add", "-A"], in: work)
        try git(["commit", "-q", "-m", "Earlier run"], in: work)
        try git(["branch", "-f", "codex/goby-earlier", "other"], in: work)
        try git(["switch", "-q", "develop"], in: work)
        try "five".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        let pushOnly = RoutingPlan(
            id: "push-run", interpretedGoal: "push to git",
            routes: [ProjectRoute(projectID: project.id, agentIDs: ["agent"], reason: "Matched")],
            risk: .medium, confidence: 1,
            gitOperations: [PlannedGitOperation(projectID: project.id, kind: .push, branch: "codex/goby-earlier", remote: "origin")]
        )
        #expect(pushOnly.runsInProjectFolder && pushOnly.pushesOnly && !pushOnly.commitsWorkingCopy)
        let pushPlacement = try await manager.prepare(project: project, for: run(pushOnly))
        #expect(pushPlacement.rootURL.standardizedFileURL == work.standardizedFileURL)
        let pushedEarlier = try await manager.finalize(project: project, workingDirectory: work, for: run(pushOnly), commitMessage: nil)
        #expect(pushedEarlier == "Pushed codex/goby-earlier to origin.")
        #expect(try output(["rev-parse", "codex/goby-earlier"], in: root.appending(path: "remote.git"))
            == output(["rev-parse", "codex/goby-earlier"], in: work))
        #expect(try output(["symbolic-ref", "--short", "HEAD"], in: work) == "develop")
        #expect(try output(["status", "--porcelain"], in: work).isEmpty == false)
    }

    @Test("A commit message falls back when the agent gave none")
    func commitMessageFallback() {
        #expect(GitWorkspaceManager.commitMessage(nil, projectName: "Siry") == "Update Siry")
        #expect(GitWorkspaceManager.commitMessage("```text\n```", projectName: "Siry") == "Update Siry")
        #expect(!GitWorkspaceManager.isSafeRefOperand("--upload-pack=x"))
        #expect(GitWorkspaceManager.isSafeRefOperand("codex/feature-1"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(
            path: "goby-working-copy-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkspaceError.commandFailed(command: arguments.joined(separator: " "), status: process.terminationStatus, output: "")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func output(_ arguments: [String], in directory: URL) throws -> String {
        try git(arguments, in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
