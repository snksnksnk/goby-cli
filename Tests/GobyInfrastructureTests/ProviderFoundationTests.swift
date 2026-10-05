import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct ProviderFoundationTests {
    @Test("Provider helpers inherit no ambient credential variables")
    func providerEnvironmentIsCredentialMinimal() {
        let source = [
            "PATH": "/usr/bin",
            "LANG": "en_US.UTF-8",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "claude-token",
            "GITHUB_TOKEN": "github-token",
            "GOBY_COPILOT_GITHUB_TOKEN": "copilot-token",
            "AWS_ACCESS_KEY_ID": "aws-id",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "GOOGLE_APPLICATION_CREDENTIALS": "/private/credentials.json",
            "DATABASE_PASSWORD": "database-secret",
            "SSH_AUTH_SOCK": "/private/ssh-agent.sock",
            "NODE_OPTIONS": "--require=/private/injected.js",
            "DYLD_INSERT_LIBRARIES": "/private/injected.dylib",
            "DATABASE_URL": "postgres://example.invalid",
        ]

        let sanitized = ProviderProcessEnvironment.sanitized(source)

        #expect(sanitized == ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"])

        let selected = ProviderProcessEnvironment.sanitized(
            source,
            allowing: ["GOBY_COPILOT_GITHUB_TOKEN"]
        )
        #expect(selected["GOBY_COPILOT_GITHUB_TOKEN"] == "copilot-token")
        #expect(selected["ANTHROPIC_API_KEY"] == nil)
        #expect(selected["GITHUB_TOKEN"] == nil)
        #expect(selected["NODE_OPTIONS"] == nil)
        #expect(selected["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(selected["DATABASE_URL"] == nil)
    }

    @Test("Provider filesystem identities preserve full-width integers as decimal strings")
    func providerFilesystemIdentityEncoding() throws {
        let payload = ProviderFileSystemIdentityPayload(GADFileSystemIdentity(
            device: UInt64.max,
            inode: 9_007_199_254_740_993,
            kind: .directory
        ))
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object["device"] == "18446744073709551615")
        #expect(object["inode"] == "9007199254740993")
        #expect(object["kind"] == "directory")
    }

    @Test("Provider helpers require the exact identity-aware bridge protocol")
    func providerBridgeProtocolIsExact() {
        #expect(ProviderBridgeProtocol.accepts("1.1"))
        #expect(!ProviderBridgeProtocol.accepts("1.0"))
        #expect(!ProviderBridgeProtocol.accepts("1.2"))
        #expect(!ProviderBridgeProtocol.accepts("2.0"))
    }

    @Test("Release provider bridge lookup ignores ambient Node overrides and system fallbacks")
    func releaseBridgeLookupRequiresBundledNode() {
        let environment = ["GOBY_NODE_EXECUTABLE": "/bin/sh"]

        #expect(InstalledClaudeAgentSDKBridgeLocator.locateNode(
            environment: environment,
            bundle: .main,
            fileManager: .default,
            allowDevelopmentOverrides: false
        ) == nil)
        #expect(InstalledCopilotSDKBridgeLocator.locateNode(
            environment: environment,
            bundle: .main,
            fileManager: .default,
            allowDevelopmentOverrides: false
        ) == nil)
    }

    @Test("Provider bindings and collaboration membership survive relaunch")
    func providerConfigurationSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-provider-foundation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.web],
            isGitRepository: true
        )
        let role = AgentProfile(
            id: "builder",
            name: "Builder",
            summary: "Builds the project",
            capabilities: [.web, .testing],
            scope: .project(project.id),
            codexRegistrationKey: "builder"
        )
        let writer = PersistentStore(directoryURL: directory)
        try await writer.register(projects: [project], agents: [role])
        let projectProviders = ProjectProviderConfiguration(
            projectID: project.id,
            providerIDs: [.codex, .claude],
            configuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await writer.saveProjectProviderConfiguration(projectProviders)
        let codex = try #require(try await writer.snapshot().providerBindings.first)
        let claude = ProviderAgentBinding(
            providerID: .claude,
            agentID: role.id,
            projectID: project.id,
            nativeID: "agent_claude_builder",
            capabilities: role.capabilities
        )
        try await writer.saveProviderBinding(claude)
        let collaboration = ProviderCollaborationSet(
            id: "collaboration",
            projectID: project.id,
            members: [
                ProviderCollaborationMember(providerID: .codex, bindingID: codex.id),
                ProviderCollaborationMember(providerID: .claude, bindingID: claude.id),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await writer.saveProviderCollaborationSet(collaboration)

        let restored = try await PersistentStore(directoryURL: directory).snapshot()

        #expect(Set(restored.providerBindings.map(\.providerID)) == [.codex, .claude])
        #expect(restored.projectProviderConfigurations == [projectProviders])
        #expect(restored.providerCollaborationSets == [collaboration])
    }

    @Test("Provider instruction overrides can be edited without changing the logical role")
    func providerInstructionOverridesCanBeEdited() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-provider-instructions-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let role = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            summary: "Shared review role",
            instructions: "Use the shared review checklist.",
            capabilities: [.review],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [role])
        let claude = ProviderAgentBinding(
            providerID: .claude,
            agentID: role.id,
            projectID: project.id,
            nativeID: "claude-reviewer",
            capabilities: role.capabilities
        )
        try await store.saveProviderBinding(claude)
        let update = UpdateProviderBindingInstructionsUseCase(
            catalog: store,
            providerConfigurations: store
        )

        let updated = try await update(
            bindingID: claude.id,
            instructions: "  Focus on concurrency and recovery.  "
        )
        #expect(updated.instructionsOverride == "Focus on concurrency and recovery.")
        let restored = try #require(try await PersistentStore(directoryURL: directory)
            .snapshot()
            .providerBindings
            .first(where: { $0.id == claude.id }))
        #expect(restored.instructionsOverride == "Focus on concurrency and recovery.")
        #expect(try await store.snapshot().agents.first?.instructions == role.instructions)

        let fallback = try await update(bindingID: claude.id, instructions: "   ")
        #expect(fallback.instructionsOverride == nil)
        await #expect(throws: GobyApplicationError.unknownProviderBinding("missing")) {
            try await update(bindingID: "missing", instructions: "No target")
        }
    }

    @Test("Collaboration membership rejects mismatched provider endpoints")
    func collaborationRejectsMismatchedEndpoints() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-provider-invalid-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let role = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Works",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [role])
        let binding = try #require(try await store.snapshot().providerBindings.first)
        let invalid = ProviderCollaborationSet(
            projectID: project.id,
            members: [
                ProviderCollaborationMember(providerID: .claude, bindingID: binding.id),
                ProviderCollaborationMember(providerID: .githubCopilot, bindingID: binding.id),
            ]
        )

        await #expect(throws: GobyApplicationError.invalidProviderCollaborationSet) {
            try await store.saveProviderCollaborationSet(invalid)
        }
    }

    @Test("Runtime registry resolves exact providers and reports unavailable providers honestly")
    func runtimeRegistryResolution() async {
        let codex = RuntimeStub(providerID: .codex)
        let claude = RuntimeStub(providerID: .claude)
        let registry = AgentRuntimeRegistry(runtimes: [codex])

        #expect(await registry.providerIDs() == [.codex])
        #expect(await registry.runtime(for: .claude) == nil)

        await registry.register(claude)
        #expect(await registry.providerIDs() == [.claude, .codex])
        let runtime = await registry.runtime(for: .claude)
        #expect(runtime?.providerID == .claude)
    }

    @Test("Claude assignments use the shared runtime, verification, journal, and task identity path")
    func claudeUsesSharedOrchestrationPath() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            summary: "Reviews the project",
            capabilities: [.review],
            scope: .project(project.id)
        )
        let binding = ProviderAgentBinding(
            providerID: .claude,
            agentID: agent.id,
            projectID: project.id,
            nativeID: "reviewer",
            capabilities: agent.capabilities
        )
        let plan = RoutingPlan(
            id: "claude-run",
            interpretedGoal: "Review the project",
            routes: [ProjectRoute(
                projectID: project.id,
                providerID: .claude,
                agentIDs: [agent.id],
                reason: "Claude reviewer selected"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "claude-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal,
            providerID: .claude
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [binding],
            projectSnapshot: [project]
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(
                projects: [project],
                agents: [agent],
                projectProviderConfigurations: [ProjectProviderConfiguration(
                    projectID: project.id,
                    providerIDs: [.claude]
                )],
                providerBindings: [binding]
            ),
            runs: [run]
        )
        let claude = CompletingProviderRuntime(providerID: .claude)
        let registry = AgentRuntimeRegistry(runtimes: [claude])
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: registry,
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        try await orchestrator.execute(runID: run.id)

        let completed = try #require(await repository.records.first)
        let completedAssignment = try #require(completed.assignments.first)
        #expect(completed.status == .completed)
        #expect(completedAssignment.status == .completed)
        #expect(completedAssignment.providerID == .claude)
        #expect(completedAssignment.providerTaskID == "claude-task")
        #expect(completedAssignment.codexThreadID == nil)
        #expect(completedAssignment.workingDirectoryIdentity == project.fileSystemIdentity)
        #expect(completed.helperTasks.first?.title == "Review Helper")
        #expect(completed.helperTasks.first?.summary == "Helper review completed")
        #expect(completed.helperTasks.first?.status == .completed)
        #expect(completed.journal.contains { $0.message.contains("Completed") })
    }

    @Test("A workspace pathname replacement cannot be recaptured as provider authority")
    func workspaceReplacementBeforeProviderStartIsRejected() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "goby-provider-workspace-race-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "Project", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = LabProject(
            id: "raced-project",
            name: "Raced Project",
            rootURL: root,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "raced-agent",
            name: "Raced Agent",
            summary: "Must not receive a replaced root",
            capabilities: [.review],
            scope: .project(project.id)
        )
        let binding = ProviderAgentBinding(
            providerID: .claude,
            agentID: agent.id,
            projectID: project.id,
            nativeID: "raced-agent",
            capabilities: agent.capabilities
        )
        let plan = RoutingPlan(
            id: "raced-run",
            interpretedGoal: "Inspect the reviewed root",
            routes: [ProjectRoute(
                projectID: project.id,
                providerID: .claude,
                agentIDs: [agent.id],
                reason: "Reviewed route"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [AgentAssignment(
                id: "raced-assignment",
                runID: plan.id,
                projectID: project.id,
                agentID: agent.id,
                status: .queued,
                currentTask: plan.interpretedGoal,
                providerID: .claude,
                providerBindingID: binding.id
            )],
            agentSnapshot: [agent],
            providerBindingSnapshot: [binding],
            projectSnapshot: [project]
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent], providerBindings: [binding]),
            runs: [run]
        )
        let runtime = RecoveringProviderRuntime(providerID: .claude)
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: ReplacingProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        try await orchestrator.execute(runID: run.id)

        #expect(await runtime.startCount == 0)
        #expect(await repository.records.first?.status == .failed)
        #expect(await repository.records.first?.assignments.first?.status == .failed)
    }

    @Test("Relaunch reattaches a surviving provider task and preserves progress without replaying it")
    func providerTaskRecoveryAfterRelaunch() async throws {
        let project = LabProject(
            id: "recovery-project",
            name: "Recovery Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "recovery-agent",
            name: "Recovery Agent",
            summary: "Continues surviving provider work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "recovery-run",
            interpretedGoal: "Continue the existing task",
            routes: [ProjectRoute(
                projectID: project.id,
                providerID: .codex,
                agentIDs: [agent.id],
                reason: "Previously reviewed route"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "recovery-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .working,
            currentTask: "Provider is working",
            progress: 0.47,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            workingDirectory: project.rootURL,
            workingDirectoryIdentity: project.fileSystemIdentity,
            providerID: .codex,
            providerTaskID: "surviving-task",
            providerTurnID: "surviving-turn"
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .running,
            assignments: [assignment],
            agentSnapshot: [agent],
            projectSnapshot: [project]
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [run]
        )
        let runtime = RecoveringProviderRuntime(providerID: .codex)
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        let recovered = try await orchestrator.recoverInterruptedRuns()
        let active = try #require(recovered.first)
        #expect(active.status == .running)
        #expect(active.assignments.first?.status == .working)
        #expect(active.assignments.first?.progress == 0.47)
        #expect(active.assignments.first?.statusReason?.contains("existing Codex task") == true)
        #expect(await runtime.startCount == 0)
        #expect(await runtime.recoveryCount == 1)

        await runtime.complete(assignmentID: assignment.id)
        for _ in 0..<100 {
            if await repository.records.first?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try #require(await repository.records.first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
        #expect(completed.assignments.first?.progress == 1)
    }

    @Test("An indeterminate Codex start is persisted and cannot be retried")
    func indeterminateCodexStartCannotReplay() async throws {
        let project = LabProject(
            id: "indeterminate-project",
            name: "Indeterminate Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "indeterminate-agent",
            name: "Indeterminate Agent",
            summary: "Must not replay uncertain work",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "indeterminate-run",
            interpretedGoal: "Run exactly once",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "indeterminate-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .paused,
            currentTask: "Codex start needs reconciliation",
            workingDirectory: project.rootURL,
            providerID: .codex,
            providerTaskID: "thread-indeterminate",
            providerTurnID: nil
        )
        #expect(assignment.hasIndeterminateProviderStart)
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .needsAttention,
            assignments: [assignment],
            agentSnapshot: [agent]
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [run]
        )
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: []),
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        do {
            try await orchestrator.execute(runID: run.id)
            Issue.record("The orchestrator replayed an indeterminate provider start")
        } catch let error as OrchestratorError {
            guard case let .indeterminateProviderStart(providerID, assignmentID) = error else {
                Issue.record("Unexpected orchestrator error: \(error.localizedDescription)")
                return
            }
            #expect(providerID == .codex)
            #expect(assignmentID == assignment.id)
        }

        #expect(await repository.records.first == run)
    }

    @Test("An older read-only improvement plan must be replanned before retry")
    func oldReadOnlyImprovementPlanRequiresReview() async throws {
        let plan = RoutingPlan(
            id: "old-improvement-run",
            interpretedGoal: "Cycle 1: Do not change code during this phase. Cycle 2: Edit project files to improve UI clarity.",
            routes: [], risk: .readOnly, confidence: 1
        )
        let run = RunRecord(
            id: plan.id, plan: plan, status: .needsAttention, assignments: []
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [], agents: []), runs: [run]
        )
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository, runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: []),
            workspaces: ProviderTestWorkspace(), verifier: ProjectVerifier()
        )

        do {
            try await orchestrator.execute(runID: run.id)
            Issue.record("The old read-only plan started")
        } catch OrchestratorError.savedPlanNeedsChangeReview {
            // A fresh reviewed plan is required.
        } catch {
            Issue.record("Unexpected execution error: \(error.localizedDescription)")
        }
        do {
            try await orchestrator.resume(runID: run.id)
            Issue.record("The old read-only plan resumed")
        } catch OrchestratorError.savedPlanNeedsChangeReview {
            // A fresh reviewed plan is required.
        } catch {
            Issue.record("Unexpected retry error: \(error.localizedDescription)")
        }
        #expect(await repository.records.first == run)
    }

    @Test("Relaunch pauses an assignment when its provider cannot confirm a live task")
    func unavailableProviderRecoveryDoesNotReplay() async throws {
        let project = LabProject(
            id: "unconfirmed-project",
            name: "Unconfirmed Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let plan = RoutingPlan(
            id: "unconfirmed-run",
            interpretedGoal: "Do not replay this task",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "unconfirmed-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: "unconfirmed-agent",
            status: .working,
            currentTask: plan.interpretedGoal,
            progress: 0.63,
            workingDirectory: project.rootURL,
            providerID: .claude,
            providerTaskID: "unknown-task"
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [project], agents: []),
            runs: [RunRecord(id: plan.id, plan: plan, status: .running, assignments: [assignment])]
        )
        let runtime = RuntimeStub(providerID: .claude)
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        let recovered = try await orchestrator.recoverInterruptedRuns()
        #expect(recovered.first?.status == .needsAttention)
        #expect(recovered.first?.assignments.first?.status == .paused)
        #expect(recovered.first?.assignments.first?.progress == 0.63)
    }

    @Test("Relaunch reconciles approval work already marked as needing attention")
    func needsAttentionApprovalRecoveryDoesNotRemainPermanentlyInFlight() async throws {
        let project = LabProject(
            id: "stale-approval-project",
            name: "Stale Approval Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let plan = RoutingPlan(
            id: "stale-approval-run",
            interpretedGoal: "Recover without replaying the approval",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "stale-approval-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: "stale-approval-agent",
            status: .waitingForApproval,
            currentTask: "Waiting for an approval from the prior process",
            progress: 0.41,
            workingDirectory: project.rootURL,
            providerID: .claude,
            providerTaskID: "stale-provider-task"
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(projects: [project], agents: []),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .needsAttention,
                assignments: [assignment]
            )]
        )
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [RuntimeStub(providerID: .claude)]),
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        let recovered = try await orchestrator.recoverInterruptedRuns()

        #expect(recovered.count == 1)
        #expect(recovered.first?.status == .needsAttention)
        #expect(recovered.first?.assignments.first?.status == .paused)
        #expect(recovered.first?.assignments.first?.progress == 0.41)
        #expect(recovered.first?.outcome?.contains("paused") == true)
    }

    @Test("Installed Claude bridge negotiates the pinned provider protocol without making an API request")
    func installedClaudeBridgeHandshake() async throws {
        guard let installation = InstalledClaudeAgentSDKBridgeLocator.locate() else {
            return
        }
        let runtime = ClaudeAgentSDKRuntimeAdapter(
            nodeExecutableURL: installation.nodeExecutableURL,
            bridgeEntryURL: installation.bridgeEntryURL,
            requestTimeout: 30
        )

        let state = try await runtime.connect()
        let account = try await runtime.accountSnapshot()
        let capabilities = await runtime.capabilities()
        await runtime.shutdown()

        guard case let .connected(version) = state else {
            Issue.record("Claude bridge did not reach its connected transport state.")
            return
        }
        #expect(version == "0.2.0-beta.1")
        #expect(account.providerID == .claude)
        #expect(capabilities.supports(.execution))
        #expect(capabilities.supports(.approvals))
        #expect(capabilities.supports(.quotaReporting))
    }

    @Test("Installed GitHub Copilot bridge negotiates without reusing ambient authentication")
    func installedCopilotBridgeHandshake() async throws {
        guard let installation = InstalledCopilotSDKBridgeLocator.locate() else {
            return
        }
        let runtime = CopilotSDKRuntimeAdapter(
            nodeExecutableURL: installation.nodeExecutableURL,
            bridgeEntryURL: installation.bridgeEntryURL,
            requestTimeout: 15
        )

        let state = try await runtime.connect()
        let account = try await runtime.accountSnapshot()
        let capabilities = await runtime.capabilities()
        await runtime.shutdown()

        guard case let .connected(version) = state else {
            Issue.record("GitHub Copilot bridge did not reach its connected transport state.")
            return
        }
        #expect(version == "0.2.0-beta.1")
        #expect(account.providerID == .githubCopilot)
        #expect(account.connectionState == .needsAuthentication)
        #expect(capabilities.supports(.execution))
        #expect(capabilities.supports(.approvals))
        #expect(!capabilities.supports(.quotaReporting))
    }

    @Test("Provider planes share project coordinates and show only their exact bindings")
    func providerPlaneProjection() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.web],
            isGitRepository: false
        )
        let codexAgent = AgentProfile(
            id: "codex-agent",
            name: "Codex Builder",
            summary: "Builds",
            capabilities: [.web],
            scope: .project(project.id),
            codexRegistrationKey: "codex-builder"
        )
        let claudeAgent = AgentProfile(
            id: "claude-agent",
            name: "Claude Reviewer",
            summary: "Reviews",
            capabilities: [.review],
            scope: .project(project.id)
        )
        let codexBinding = ProviderAgentBinding.migratedCodexBinding(for: codexAgent)
        let claudeBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: claudeAgent.id,
            projectID: project.id,
            nativeID: "claude-reviewer",
            capabilities: claudeAgent.capabilities
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(
                projects: [project],
                agents: [codexAgent, claudeAgent],
                providerBindings: [codexBinding, claudeBinding]
            ),
            runs: []
        )
        let build = BuildGraphUseCase(catalog: repository, layout: RadialGraphLayout())

        let codex = try await build(assignments: [], providerID: .codex)
        let claude = try await build(assignments: [], providerID: .claude)
        let codexAgentIDs = codex.nodes.compactMap { node -> AgentID? in
            guard case let .agent(agent, _) = node.kind else { return nil }
            return agent.id
        }
        let claudeAgentIDs = claude.nodes.compactMap { node -> AgentID? in
            guard case let .agent(agent, _) = node.kind else { return nil }
            return agent.id
        }
        let codexProjectPoint = try #require(codex.nodes.first(where: { $0.id == .project(project.id) })?.position)
        let claudeProjectPoint = try #require(claude.nodes.first(where: { $0.id == .project(project.id) })?.position)

        #expect(codexAgentIDs == [codexAgent.id])
        #expect(claudeAgentIDs == [claudeAgent.id])
        #expect(codexProjectPoint == claudeProjectPoint)
    }

    @Test("Active follow-up reaches every steerable assignment and is journalled without storing its text")
    func activeFollowUpUsesExactProviderRuntime() async throws {
        let project = LabProject(
            id: "steering-project",
            name: "Steering Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "steering-agent",
            name: "Steering Agent",
            summary: "Accepts active context",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let binding = ProviderAgentBinding.migratedCodexBinding(for: agent)
        let plan = RoutingPlan(
            id: "steering-run",
            interpretedGoal: "Investigate the reconnect failure",
            routes: [.init(
                projectID: project.id,
                providerID: .codex,
                agentIDs: [agent.id],
                reason: "Exact active Codex target"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "steering-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .working,
            currentTask: plan.interpretedGoal,
            providerID: .codex,
            providerTaskID: "thread-1",
            providerTurnID: "turn-2"
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .running,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [binding]
        )
        let repository = ProviderTestRepository(
            lab: LabSnapshot(
                projects: [project],
                agents: [agent],
                providerBindings: [binding]
            ),
            runs: [run]
        )
        let runtime = SteerableProviderRuntime(providerID: .codex)
        let orchestrator = ProviderRunOrchestrator(
            catalog: repository,
            runs: repository,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: ProviderTestWorkspace(),
            verifier: ProjectVerifier()
        )

        try await orchestrator.followUp(
            runID: run.id,
            text: "  Focus on the reconnect failure.  "
        )

        #expect(await runtime.received == [
            .init(assignmentID: assignment.id, text: "Focus on the reconnect failure.")
        ])
        let saved = try #require(await repository.records.first)
        #expect(saved.journal.last?.message == "Follow-up delivered to Codex.")
        #expect(saved.journal.allSatisfy { !$0.message.contains("reconnect failure") })
    }
}

private actor RuntimeStub: AgentRuntimeServing {
    nonisolated let providerID: AgentProviderID

    init(providerID: AgentProviderID) {
        self.providerID = providerID
    }

    func capabilities() -> ProviderCapabilities { .unavailable }
    func connectionState() -> ProviderConnectionState { .notChecked }
    func connect() -> ProviderConnectionState { .connected(version: nil) }
    func accountSnapshot() -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(providerID: providerID, connectionState: .connected(version: nil))
    }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> ProviderExecutionHandle {
        ProviderExecutionHandle(providerID: providerID, taskID: "task")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { AsyncStream { $0.finish() } }
}

private actor CompletingProviderRuntime: AgentRuntimeServing {
    nonisolated let providerID: AgentProviderID
    private let eventStream: AsyncStream<ProviderRunEvent>
    private let eventContinuation: AsyncStream<ProviderRunEvent>.Continuation

    init(providerID: AgentProviderID) {
        self.providerID = providerID
        let pair = AsyncStream<ProviderRunEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities([.execution, .interruption, .approvals])
    }

    func connectionState() -> ProviderConnectionState { .connected(version: "test") }
    func connect() -> ProviderConnectionState { .connected(version: "test") }
    func accountSnapshot() -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(providerID: providerID, connectionState: .connected(version: "test"))
    }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }

    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> ProviderExecutionHandle {
        eventContinuation.yield(.assignmentStarted(providerID, assignment.id))
        eventContinuation.yield(.helperUpdated(
            assignment.id,
            activity: ProviderTaskActivity(
                identity: ProviderTaskIdentity(providerID: providerID, nativeID: "claude-helper"),
                projectID: project.id,
                title: "Review Helper",
                summary: "Helper review completed",
                status: .completed,
                updatedAt: .now,
                parentTaskIdentity: ProviderTaskIdentity(providerID: providerID, nativeID: "claude-task"),
                agentRole: "review_helper"
            )
        ))
        eventContinuation.yield(.assignmentCompleted(
            providerID,
            assignment.id,
            outcome: "Provider completed the review"
        ))
        return ProviderExecutionHandle(providerID: providerID, taskID: "claude-task")
    }

    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { eventStream }
}

private actor RecoveringProviderRuntime: AgentRuntimeServing {
    nonisolated let providerID: AgentProviderID
    private let eventStream: AsyncStream<ProviderRunEvent>
    private let eventContinuation: AsyncStream<ProviderRunEvent>.Continuation
    private(set) var startCount = 0
    private(set) var recoveryCount = 0

    init(providerID: AgentProviderID) {
        self.providerID = providerID
        let pair = AsyncStream<ProviderRunEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities([.execution, .interruption, .resume])
    }

    func connectionState() -> ProviderConnectionState { .connected(version: "test") }
    func connect() -> ProviderConnectionState { .connected(version: "test") }
    func accountSnapshot() -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(providerID: providerID, connectionState: .connected(version: "test"))
    }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }
    func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) -> ProviderExecutionRecovery? {
        recoveryCount += 1
        return ProviderExecutionRecovery(
            handle: ProviderExecutionHandle(
                providerID: providerID,
                taskID: assignment.providerTaskID ?? "",
                turnID: assignment.providerTurnID
            ),
            status: .working,
            message: "Rejoined existing provider task"
        )
    }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> ProviderExecutionHandle {
        startCount += 1
        return ProviderExecutionHandle(providerID: providerID, taskID: "replacement-task")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { eventStream }

    func complete(assignmentID: AssignmentID) {
        eventContinuation.yield(.assignmentCompleted(
            providerID,
            assignmentID,
            outcome: "Recovered provider task completed"
        ))
    }
}

private actor SteerableProviderRuntime: AgentRuntimeServing {
    struct Received: Equatable, Sendable {
        let assignmentID: AssignmentID
        let text: String
    }

    nonisolated let providerID: AgentProviderID
    private(set) var received: [Received] = []

    init(providerID: AgentProviderID) {
        self.providerID = providerID
    }

    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities([.execution, .activeSteering])
    }

    func connectionState() -> ProviderConnectionState { .connected(version: "test") }
    func connect() -> ProviderConnectionState { .connected(version: "test") }
    func accountSnapshot() -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(providerID: providerID, connectionState: .connected(version: "test"))
    }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> ProviderExecutionHandle {
        ProviderExecutionHandle(providerID: providerID, taskID: "task", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func steer(assignmentID: AssignmentID, text: String) {
        received.append(.init(assignmentID: assignmentID, text: text))
    }
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { AsyncStream { $0.finish() } }
}

private actor ProviderTestRepository: LabCatalogRepository, RunRepository {
    let lab: LabSnapshot
    var records: [RunRecord]

    init(lab: LabSnapshot, runs: [RunRecord]) {
        self.lab = lab
        records = runs
    }

    func snapshot() -> LabSnapshot { lab }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func allRuns() -> [RunRecord] { records }
    func save(_ run: RunRecord) {
        records.removeAll { $0.id == run.id }
        records.append(run)
    }
}

private actor ProviderTestWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) -> String? { nil }
}

private actor ReplacingProviderTestWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        let retained = project.rootURL.deletingLastPathComponent().appending(
            path: "retained-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: project.rootURL, to: retained)
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: false)
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }

    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) -> String? { nil }
}
