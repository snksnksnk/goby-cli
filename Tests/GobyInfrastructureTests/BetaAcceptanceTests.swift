import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct BetaAcceptanceTests {
    @Test(
        "Disposable lab completes import, review, approval, isolated execution, verification, and consolidation",
        .timeLimit(.minutes(1))
    )
    func completeBetaWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-beta-acceptance-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWebProject(named: "Atlas Web", under: root)
        try makeWebProject(named: "Beacon Web", under: root)

        let discovered = try await FileSystemProjectDiscovery().discover(selectedRoots: [root])
        #expect(discovered.count == 2)
        #expect(discovered.allSatisfy { $0.project.platforms.contains(.web) })
        #expect(discovered.allSatisfy { $0.project.isGitRepository })
        #expect(discovered.allSatisfy { $0.detectedAgents.count == 1 })

        let reviewed = discovered.map { candidate in
            ProjectCandidate(
                project: LabProject(
                    id: candidate.project.id,
                    name: candidate.project.name,
                    rootURL: candidate.project.rootURL,
                    platforms: candidate.project.platforms,
                    frameworks: candidate.project.frameworks,
                    testCommands: ["/bin/test -f agent-output.txt"],
                    instructionFiles: candidate.project.instructionFiles,
                    isGitRepository: candidate.project.isGitRepository,
                    registeredAt: candidate.project.registeredAt
                ),
                detectedAgents: candidate.detectedAgents,
                evidence: candidate.evidence
            )
        }

        let stateDirectory = root.appending(path: "State", directoryHint: .isDirectory)
        let repository = PersistentStore(directoryURL: stateDirectory)
        try await RegisterProjectsUseCase(catalog: repository)(candidates: reviewed)
        let projectOnlyLab = try await repository.snapshot()
        #expect(projectOnlyLab.projects.count == 2)
        #expect(projectOnlyLab.agents.isEmpty)

        let emptyGlobalAgents = root.appending(path: "GlobalAgents", directoryHint: .isDirectory)
        let agentReview = try await CodexAgentDiscovery(globalAgentsURL: emptyGlobalAgents)
            .discover(projects: projectOnlyLab.projects)
        #expect(agentReview.candidates.count == 2)
        #expect(agentReview.candidates.allSatisfy { $0.profile.instructions?.contains("preferred-source") == true })
        try await RegisterAgentsUseCase(catalog: repository)(candidates: agentReview.candidates)
        let lab = try await repository.snapshot()
        #expect(lab.agents.count == 2)
        let restructurePreview = try await AgentDefinitionRestructurer()
            .preview(candidates: agentReview.candidates)
        #expect(restructurePreview.count == 2)
        #expect(restructurePreview.allSatisfy { !$0.proposedContents.isEmpty })

        let request = RouteRequest(
            prompt: "Update all websites with Google preferred sources and verify the result",
            scope: .all
        )
        let plan = try await PrepareRoutingPlanUseCase(
            catalog: repository,
            router: DeterministicRouter()
        )(request)
        #expect(plan.routes.count == 2)
        #expect(plan.routes.allSatisfy { $0.agentIDs.count == 1 })
        #expect(plan.gitOperations.count == 6)
        #expect(plan.requiresApproval)
        #expect(plan.routes.allSatisfy { $0.reason.contains("assigned") })

        let receipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(plan.gitOperations.map(\.id))
        )
        let approvalPolicy = ApprovalPolicy()
        let staged = try await StageRunUseCase(
            repository: repository,
            catalog: repository,
            instructions: repository,
            resources: repository,
            approvals: approvalPolicy
        )(plan: plan, receipt: receipt)
        #expect(staged.status == .ready)
        #expect(staged.assignments.count == 2)
        #expect(staged.agentSnapshot.count == 2)
        #expect(staged.approvalReceipts == [receipt])

        let codex = AcceptanceCodex()
        let worktrees = GitWorkspaceManager(
            worktreesRoot: stateDirectory.appending(path: "Worktrees", directoryHint: .isDirectory),
            approvals: approvalPolicy
        )
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: worktrees,
            verifier: ProjectVerifier(),
            maximumConcurrentAssignments: 2
        )
        try await orchestrator.execute(runID: staged.id)

        let completed = try #require(try await repository.allRuns().first(where: { $0.id == staged.id }))
        #expect(
            completed.status == .completed,
            "Outcome: \(completed.outcome ?? "none"); assignments: \(completed.assignments.map { $0.statusReason ?? "none" })"
        )
        #expect(completed.assignments.count == 2)
        #expect(completed.assignments.allSatisfy { $0.status == .completed })
        #expect(completed.assignments.allSatisfy { $0.workingDirectory != nil })
        #expect(completed.outcome?.contains("preferred-source update complete") == true)
        #expect(completed.outcome?.contains("Verified from Codex App Server execution evidence") == true)

        for assignment in completed.assignments {
            let workingDirectory = try #require(assignment.workingDirectory)
            #expect(FileManager.default.fileExists(
                atPath: workingDirectory.appending(path: "agent-output.txt").path(percentEncoded: false)
            ))
            #expect(try runGit(["status", "--porcelain"], in: workingDirectory).isEmpty)
            #expect(try runGit(["log", "-1", "--pretty=%s"], in: workingDirectory).hasPrefix("Goby run "))
        }

        let graph = await RadialGraphLayout().layout(lab: lab, assignments: completed.assignments)
        let completedAgentNodes = graph.nodes.filter { node in
            if case let .agent(_, assignment) = node.kind {
                return assignment?.status == .completed
            }
            return false
        }
        #expect(completedAgentNodes.count == 2)
        #expect(graph.edges.filter { $0.kind == .assignment }.count == 2)
    }

    @Test("Approved workspace preparation rejects a pre-existing symlinked worktree")
    func workspacePreparationRejectsSymlink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-worktree-boundary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWebProject(named: "Repository", under: root)
        let repositoryRoot = root.appending(path: "Repository", directoryHint: .isDirectory)
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        let worktreesRoot = root.appending(path: "Worktrees", directoryHint: .isDirectory)
        let project = LabProject(
            id: "worktree-project",
            name: "Repository",
            rootURL: repositoryRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let operations = [
            PlannedGitOperation(projectID: project.id, kind: .createWorktree),
            PlannedGitOperation(projectID: project.id, kind: .createBranch, branch: "goby/symlink-test"),
            PlannedGitOperation(projectID: project.id, kind: .commit)
        ]
        let plan = RoutingPlan(
            id: "worktree-symlink-run",
            interpretedGoal: "Exercise workspace safety",
            routes: [],
            risk: .low,
            confidence: 1,
            gitOperations: operations
        )
        let receipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(operations.map(\.id))
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [],
            approvalReceipts: [receipt]
        )
        let runDirectory = worktreesRoot.appending(path: run.id.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runDirectory.appending(path: project.id.rawValue),
            withDestinationURL: outside
        )
        let manager = GitWorkspaceManager(worktreesRoot: worktreesRoot, approvals: ApprovalPolicy())

        await #expect(throws: WorkspaceError.self) {
            _ = try await manager.prepare(project: project, for: run)
        }
    }

    @Test("Workspace preparation resumes an approved branch left by a failed checkout")
    func workspacePreparationResumesExistingBranch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-worktree-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWebProject(named: "Repository", under: root)
        let repositoryRoot = root.appending(path: "Repository", directoryHint: .isDirectory)
        let worktreesRoot = root.appending(path: "Worktrees", directoryHint: .isDirectory)
        let project = LabProject(
            id: "retry-project",
            name: "Repository",
            rootURL: repositoryRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let branch = "goby/retry-existing-branch"
        let operations = [
            PlannedGitOperation(projectID: project.id, kind: .createWorktree),
            PlannedGitOperation(projectID: project.id, kind: .createBranch, branch: branch),
            PlannedGitOperation(projectID: project.id, kind: .commit),
        ]
        let plan = RoutingPlan(
            id: "worktree-retry-run",
            interpretedGoal: "Retry an interrupted checkout",
            routes: [],
            risk: .low,
            confidence: 1,
            gitOperations: operations
        )
        let receipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(operations.map(\.id))
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [],
            approvalReceipts: [receipt]
        )
        _ = try runGit(["branch", branch], in: repositoryRoot)

        let manager = GitWorkspaceManager(worktreesRoot: worktreesRoot, approvals: ApprovalPolicy())
        let prepared = try await manager.prepare(project: project, for: run)

        #expect(prepared.matchesCurrentObject())
        #expect(FileManager.default.fileExists(atPath: prepared.rootURL.path(percentEncoded: false)))
        #expect(try runGit(["branch", "--show-current"], in: prepared.rootURL) == branch)
    }

    @Test("Workspace retry preserves tracked changes in an unclaimed registered worktree")
    func workspacePreparationPreservesInterruptedCheckoutChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-worktree-incomplete-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWebProject(named: "Repository", under: root)
        let repositoryRoot = root.appending(path: "Repository", directoryHint: .isDirectory)
        let worktreesRoot = root.appending(path: "Worktrees", directoryHint: .isDirectory)
        let project = LabProject(
            id: "incomplete-project",
            name: "Repository",
            rootURL: repositoryRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let branch = "goby/retry-incomplete-checkout"
        let operations = [
            PlannedGitOperation(projectID: project.id, kind: .createWorktree),
            PlannedGitOperation(projectID: project.id, kind: .createBranch, branch: branch),
            PlannedGitOperation(projectID: project.id, kind: .commit),
        ]
        let plan = RoutingPlan(
            id: "worktree-incomplete-run",
            interpretedGoal: "Complete an interrupted checkout",
            routes: [],
            risk: .low,
            confidence: 1,
            gitOperations: operations
        )
        let receipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(operations.map(\.id))
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [],
            approvalReceipts: [receipt]
        )
        let worktree = worktreesRoot
            .appending(path: run.id.rawValue, directoryHint: .isDirectory)
            .appending(path: project.id.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(["worktree", "add", "-b", branch, worktree.path(percentEncoded: false)], in: repositoryRoot)
        try FileManager.default.removeItem(at: worktree.appending(path: "package.json"))

        let manager = GitWorkspaceManager(worktreesRoot: worktreesRoot, approvals: ApprovalPolicy())
        await #expect(throws: WorkspaceError.self) {
            _ = try await manager.prepare(project: project, for: run)
        }

        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "package.json").path(percentEncoded: false)))
        let status = try runGit(["status", "--porcelain", "--untracked-files=no"], in: worktree)
        #expect(!status.isEmpty)
    }

    @Test("A claimed worktree cannot be resumed without its exact persisted identity")
    func workspacePreparationRejectsLegacyAndReplacedClaimedWorktrees() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-worktree-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWebProject(named: "Repository", under: root)
        let repositoryRoot = root.appending(path: "Repository", directoryHint: .isDirectory)
        let worktreesRoot = root.appending(path: "Worktrees", directoryHint: .isDirectory)
        let project = LabProject(
            id: "identity-project",
            name: "Repository",
            rootURL: repositoryRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let branch = "goby/identity-resume"
        let operations = [
            PlannedGitOperation(projectID: project.id, kind: .createWorktree),
            PlannedGitOperation(projectID: project.id, kind: .createBranch, branch: branch),
            PlannedGitOperation(projectID: project.id, kind: .commit),
        ]
        let plan = RoutingPlan(
            id: "worktree-identity-run",
            interpretedGoal: "Resume only the reviewed worktree object",
            routes: [],
            risk: .low,
            confidence: 1,
            gitOperations: operations
        )
        let receipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: Set(operations.map(\.id))
        )
        let unclaimedRun = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [],
            approvalReceipts: [receipt]
        )
        let manager = GitWorkspaceManager(worktreesRoot: worktreesRoot, approvals: ApprovalPolicy())
        let prepared = try await manager.prepare(project: project, for: unclaimedRun)
        let legacyAssignment = AgentAssignment(
            runID: plan.id,
            projectID: project.id,
            agentID: "identity-agent",
            status: .failed,
            currentTask: "Resume",
            workingDirectory: prepared.rootURL
        )
        let legacyRun = RunRecord(
            id: plan.id,
            plan: plan,
            status: .failed,
            assignments: [legacyAssignment],
            approvalReceipts: [receipt]
        )

        await #expect(throws: WorkspaceError.self) {
            _ = try await manager.prepare(project: project, for: legacyRun)
        }

        let claimedAssignment = AgentAssignment(
            id: legacyAssignment.id,
            runID: plan.id,
            projectID: project.id,
            agentID: legacyAssignment.agentID,
            status: .failed,
            currentTask: "Resume",
            workingDirectory: prepared.rootURL,
            workingDirectoryIdentity: prepared.fileSystemIdentity
        )
        let claimedRun = RunRecord(
            id: plan.id,
            plan: plan,
            status: .failed,
            assignments: [claimedAssignment],
            approvalReceipts: [receipt]
        )
        let displaced = root.appending(path: "DisplacedWorktree", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: prepared.rootURL, to: displaced)
        try FileManager.default.copyItem(at: displaced, to: prepared.rootURL)
        #expect(GADFileSystemIdentity.capture(prepared.rootURL) != prepared.fileSystemIdentity)
        #expect(try runGit(["branch", "--show-current"], in: prepared.rootURL) == branch)

        await #expect(throws: WorkspaceError.self) {
            _ = try await manager.prepare(project: project, for: claimedRun)
        }
    }

    @Test("Worktree filesystem timeouts and mmap cancellations are eligible for bounded recovery")
    func workspacePreparationClassifiesTransientFilesystemFailures() {
        let timeout = WorkspaceError.commandFailed(
            command: "/usr/bin/git worktree add",
            status: 128,
            output: "fatal: mmap failed: Operation timed out"
        )
        let cancellation = WorkspaceError.commandFailed(
            command: "/usr/bin/git worktree add",
            status: 128,
            output: "Updating files: 71% (147/206)\nfatal: mmap failed: Operation canceled"
        )

        #expect(GitWorkspaceManager.isTransientWorktreeFailure(timeout))
        #expect(GitWorkspaceManager.isTransientWorktreeFailure(cancellation))
    }

    @Test("Worktree recovery applies conservative Git object mapping only to fallback commands")
    func workspacePreparationBuildsConservativeGitArguments() {
        let base = ["-C", "/project", "worktree", "add", "/worktree", "topic"]

        #expect(GitWorkspaceManager.gitArguments(base, conservativeObjectReads: false) == base)
        #expect(
            GitWorkspaceManager.gitArguments(base, conservativeObjectReads: true) == [
                "-c", "core.packedGitWindowSize=1m",
                "-c", "core.packedGitLimit=64m",
            ] + base
        )
    }

    @Test("Worktree preparation warms Git pack metadata before checkout")
    func workspacePreparationSelectsGitPackFilesForWarming() {
        let root = URL(fileURLWithPath: "/repository/.git/objects/pack", isDirectory: true)
        let urls = [
            root.appending(path: "pack-a.pack"),
            root.appending(path: "pack-a.idx"),
            root.appending(path: "pack-a.rev"),
            root.appending(path: "multi-pack-index"),
            root.appending(path: "temporary.lock"),
        ]

        #expect(
            GitWorkspaceManager.orderedGitPackFiles(from: urls).map(\.lastPathComponent) == [
                "multi-pack-index",
                "pack-a.idx",
                "pack-a.rev",
                "pack-a.pack",
            ]
        )
    }

    @Test("Worktree preparation distinguishes unavailable cloud objects from local files")
    func workspacePreparationClassifiesCloudObjectAvailability() {
        #expect(
            GitWorkspaceManager.needsCloudDownload(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded
            )
        )
        #expect(
            !GitWorkspaceManager.needsCloudDownload(
                isUbiquitous: true,
                downloadingStatus: .current
            )
        )
        #expect(
            !GitWorkspaceManager.needsCloudDownload(
                isUbiquitous: false,
                downloadingStatus: nil
            )
        )
    }

    @Test("Worktree preparation verifies every byte of a cloud object")
    func workspacePreparationReadsObjectFilesFully() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "goby-object-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = Data(repeating: 0xA5, count: 2_500_000)
        try contents.write(to: file, options: .atomic)

        #expect(try GitWorkspaceManager.readFileFully(at: file) == Int64(contents.count))
    }

    private func makeWebProject(named name: String, under root: URL) throws {
        let project = root.appending(path: name, directoryHint: .isDirectory)
        let agents = project.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(#"{"name":"fixture","scripts":{"test":"test -f agent-output.txt"}}"#.utf8)
            .write(to: project.appending(path: "package.json"), options: .atomic)
        try Data("Only make reviewed changes and verify them.\n".utf8)
            .write(to: project.appending(path: "AGENTS.md"), options: .atomic)
        let definition = #"""
        name = "Web Research Verifier"
        description = "Implements and tests web research changes"
        developer_instructions = "Apply only the assigned preferred-source change, then verify it."
        """#
        try Data(definition.utf8)
            .write(to: agents.appending(path: "web-agent.toml"), options: .atomic)
        _ = try runGit(["init", "-b", "main"], in: project)
        _ = try runGit(["config", "user.name", "Goby Acceptance"], in: project)
        _ = try runGit(["config", "user.email", "goby-acceptance@example.invalid"], in: project)
        _ = try runGit(["add", "-A"], in: project)
        _ = try runGit(["commit", "-m", "Initial fixture"], in: project)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
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
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw AcceptanceError.gitFailed(arguments.joined(separator: " "), text)
        }
        return text
    }
}

private enum AcceptanceError: Error {
    case gitFailed(String, String)
}

private actor AcceptanceCodex: CodexServing {
    private let stream: AsyncStream<CodexRunEvent>
    private let continuation: AsyncStream<CodexRunEvent>.Continuation

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "acceptance-fixture") }
    func connect() -> CodexConnectionState { .connected(version: "acceptance-fixture") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "fixture", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }

    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) throws -> CodexExecutionHandle {
        try Data("preferred-source update complete\n".utf8)
            .write(to: project.rootURL.appending(path: "agent-output.txt"), options: .atomic)
        continuation.yield(.assignmentStarted(assignment.id))
        continuation.yield(.commandExecutionCompleted(
            assignment.id,
            evidence: CodexCommandExecutionEvidence(
                id: "verification-\(assignment.id.rawValue)",
                command: "/bin/test -f agent-output.txt",
                workingDirectory: project.rootURL,
                status: .completed,
                exitCode: 0,
                durationMilliseconds: 1
            )
        ))
        continuation.yield(.assignmentCompleted(
            assignment.id,
            outcome: "\(agent.name): preferred-source update complete"
        ))
        return CodexExecutionHandle(
            threadID: "thread-\(assignment.id.rawValue)",
            turnID: "turn-\(assignment.id.rawValue)"
        )
    }

    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}
