import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

@Suite(.serialized)
struct HandoffTests {
    @Test("Provider helper diagnostics redact common credential forms")
    func transportDiagnosticRedaction() {
        let secret = "sk-ant-supersecret123"
        let output = JSONRPCProcessTransport.redactedDiagnostic(
            "Bearer abcdefghijklmnop token=\(secret) github_pat_abcdefghijklmnop"
        )
        #expect(!output.contains(secret))
        #expect(!output.contains("abcdefghijklmnop"))
        #expect(output.contains("[redacted]"))
    }

    @Test("A reviewed Codex handoff dispatches Claude once and survives relaunch")
    func manualCodexToClaudeContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-handoff-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let projectRoot = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: projectRoot,
            platforms: [.backend],
            isGitRepository: false
        )
        let builder = AgentProfile(
            id: "builder",
            name: "Builder",
            summary: "Builds the service",
            instructions: "Use the shared implementation policy.",
            capabilities: [.backend, .testing],
            scope: .project(project.id),
            codexRegistrationKey: "builder"
        )
        let reviewer = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            summary: "Reviews the service",
            instructions: "Use the shared review policy.",
            capabilities: [.review, .security],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [builder, reviewer])
        let initial = try await store.snapshot()
        let sourceBinding = try #require(initial.providerBindings.first(where: {
            $0.providerID == .codex && $0.agentID == builder.id
        }))
        let destinationBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: reviewer.id,
            projectID: project.id,
            nativeID: "goby-agent:reviewer",
            capabilities: reviewer.capabilities,
            instructionsOverride: "Apply the Claude-specific review policy."
        )
        try await store.saveProviderBinding(destinationBinding)
        let link = AgentHandoffLink(
            source: endpoint(sourceBinding, projectID: project.id),
            destination: endpoint(destinationBinding, projectID: project.id),
            purpose: "Continue implementation with an independent review.",
            conditions: "After the builder reaches a reviewed success checkpoint.",
            acceptedArtifacts: [.summary, .changedFileList, .patch, .verificationEvidence],
            maximumDepth: 2,
            triggers: [.success]
        )
        try await SaveHandoffLinkUseCase(catalog: store)(link)

        let sourceAttachment = PromptAttachment(
            kind: .snippet,
            displayName: "Source-only context",
            source: .text("private source context")
        )
        let plan = RoutingPlan(
            id: "run",
            interpretedGoal: "Implement and review the service",
            attachments: [sourceAttachment],
            routes: [ProjectRoute(
                projectID: project.id,
                providerID: .codex,
                agentIDs: [builder.id],
                reason: "Implementation"
            )],
            risk: .readOnly,
            confidence: 1
        )
        let sourceAssignment = AgentAssignment(
            id: "source",
            runID: plan.id,
            projectID: project.id,
            agentID: builder.id,
            status: .completed,
            currentTask: "Original source task",
            attachments: [sourceAttachment],
            progress: 1,
            statusReason: "Implementation completed",
            providerID: .codex,
            providerTaskID: "codex-task"
        )
        let sourceReceipt = ApprovalReceipt(
            runID: plan.id,
            decision: .approved,
            operationIDs: []
        )
        let sourceResource = SharedResource(
            name: "Source-only resource",
            url: projectRoot
        )
        try await store.save(RunRecord(
            id: plan.id,
            plan: plan,
            status: .completed,
            assignments: [sourceAssignment],
            outcome: "Implementation completed",
            approvalReceipts: [sourceReceipt],
            agentSnapshot: [builder],
            providerBindingSnapshot: [sourceBinding],
            resourceSnapshot: [sourceResource]
        ))

        let secret = "sk-ant-secretvalue123"
        let awsSecret = "AWS_SECRET_ACCESS_KEY=verySecretMaterial123"
        let databaseSecret = "postgres://alice:correct-horse@example.com/private"
        let jwt = "eyJabcdefghijk.eyJlmnopqrstuvwxyz.abcdefghijklmnopqrstuvwxyz"
        let opaqueStoredCredential = "opaque-provider-material-271828"
        let privatePath = "/Users/alice/SecretProject/.env"
        let privateKey = "-----BEGIN PRIVATE KEY-----\nvery-private-material\n-----END PRIVATE KEY-----"
        let preparer = PrepareManualHandoffUseCase(
            catalog: store,
            runs: store,
            handoffs: store,
            credentials: HandoffCredentialRepository(credential: opaqueStoredCredential)
        )
        let handoffRequest = PrepareManualHandoffRequest(
            runID: plan.id,
            linkID: link.id,
            sourceAssignmentID: sourceAssignment.id,
            trigger: .success,
            sourceOutcomeSummary: "Completed the API at \(privatePath) with token=\(secret) \(awsSecret) \(databaseSecret) \(jwt) \(privateKey) \(opaqueStoredCredential)",
            completedSteps: ["Implemented endpoints"],
            unresolvedWork: ["Review authentication"],
            knownRisks: ["Bearer abcdefghijklmnop must not leave the source"],
            requestedNextAction: "Review the authentication boundary",
            artifacts: [
                HandoffArtifactReference(
                    id: "local",
                    kind: .summary,
                    name: "Local report",
                    url: URL(fileURLWithPath: privatePath)
                ),
                HandoffArtifactReference(
                    id: "remote",
                    kind: .summary,
                    name: "Remote report",
                    url: URL(string: "https://alice:password@example.com/report?token=hidden#private")
                ),
                HandoffArtifactReference(
                    id: "remote-secret-path",
                    kind: .summary,
                    name: "Unsafe remote report",
                    url: URL(string: "https://example.com/password=hidden")
                ),
            ],
            changedFiles: ["Sources/API.swift", privatePath, "../Secrets.txt", "file:///private/tmp/key"],
            patchOrCommitReference: "Patch generated at \(privatePath)",
            workingCopyIdentity: privatePath,
            verificationEvidence: [HandoffVerificationEvidence(
                id: "tests",
                command: "API_KEY=\(secret) swift test",
                status: "passed",
                exitCode: 0,
                source: "source"
            )]
        )
        let prepared = try await preparer(handoffRequest)
        let duplicatePreparation = try await preparer(handoffRequest)

        #expect(prepared.state == .ready)
        #expect(duplicatePreparation.id == prepared.id)
        #expect(HandoffBundleIntegrity.isValid(prepared.bundle))
        #expect(!String(describing: prepared.bundle).contains(secret))
        #expect(!String(describing: prepared.bundle).contains("/Users/alice"))
        #expect(!String(describing: prepared.bundle).contains("very-private-material"))
        #expect(!String(describing: prepared.bundle).contains("verySecretMaterial123"))
        #expect(!String(describing: prepared.bundle).contains("correct-horse"))
        #expect(!String(describing: prepared.bundle).contains(jwt))
        #expect(!String(describing: prepared.bundle).contains(opaqueStoredCredential))
        #expect(prepared.bundle.sourceTaskIdentity == nil)
        #expect(prepared.bundle.changedFiles == ["Sources/API.swift"])
        #expect(prepared.bundle.workingCopyIdentity == nil)
        #expect(prepared.bundle.artifacts.first(where: { $0.id == "local" })?.url == nil)
        #expect(
            prepared.bundle.artifacts.first(where: { $0.id == "remote" })?.url?.absoluteString
                == "https://example.com/report"
        )
        #expect(prepared.bundle.artifacts.first(where: { $0.id == "remote-secret-path" })?.url == nil)

        let dispatcher = DispatchManualHandoffUseCase(catalog: store, runs: store, handoffs: store)
        let firstDispatch = try await dispatcher(handoffID: prepared.id)
        let secondDispatch = try await dispatcher(handoffID: prepared.id)
        #expect(firstDispatch.run.id != plan.id)
        #expect(secondDispatch.run.id == firstDispatch.run.id)
        #expect(firstDispatch.run.assignments.count == 1)
        #expect(secondDispatch.run.assignments.count == 1)
        #expect(firstDispatch.handoff.destinationRunID == firstDispatch.run.id)
        #expect(firstDispatch.run.plan.risk == .readOnly)
        #expect(firstDispatch.run.plan.attachments.isEmpty)
        #expect(firstDispatch.run.plan.gitOperations.isEmpty)
        #expect(firstDispatch.run.approvalReceipts.isEmpty)
        #expect(firstDispatch.run.instructionSnapshot.isEmpty)
        #expect(firstDispatch.run.resourceSnapshot.isEmpty)
        let destinationAssignment = try #require(firstDispatch.run.assignments.first(where: {
            $0.handoffID == prepared.id
        }))
        #expect(destinationAssignment.providerID == .claude)
        #expect(destinationAssignment.attachments.isEmpty)
        #expect(destinationAssignment.currentTask.contains("Review the authentication boundary"))

        let unchangedSource = try #require(try await store.allRuns().first(where: { $0.id == plan.id }))
        #expect(unchangedSource.assignments == [sourceAssignment])
        #expect(unchangedSource.approvalReceipts == [sourceReceipt])
        #expect(unchangedSource.resourceSnapshot == [sourceResource])

        let restored = try await PersistentStore(directoryURL: directory).snapshot()
        #expect(restored.agentHandoffLinks.map(\.id) == [link.id])
        #expect(restored.agentHandoffLinks.first?.source == link.source)
        #expect(restored.agentHandoffLinks.first?.destination == link.destination)
        #expect(restored.handoffs.first?.state == .queued)

        let runtime = HandoffCompletingRuntime()
        let orchestrator = ProviderRunOrchestrator(
            catalog: store,
            runs: store,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: HandoffWorkspace(),
            verifier: ProjectVerifier(),
            handoffCatalog: store
        )
        try await orchestrator.execute(runID: firstDispatch.run.id)

        let finalSourceRun = try #require(try await store.allRuns().first(where: { $0.id == plan.id }))
        let finalRun = try #require(try await store.allRuns().first(where: { $0.id == firstDispatch.run.id }))
        let finalHandoff = try #require(try await store.snapshot().handoffs.first(where: { $0.id == prepared.id }))
        #expect(finalSourceRun.status == .completed)
        #expect(finalSourceRun.assignments == [sourceAssignment])
        #expect(finalRun.status == .completed)
        #expect(finalRun.assignments.first(where: { $0.handoffID == prepared.id })?.status == .completed)
        #expect(finalHandoff.state == .completed)
        #expect(finalHandoff.destinationTaskIdentity?.providerID == .claude)
        #expect(await runtime.startCount == 1)
        #expect(await runtime.receivedInstructions == "Apply the Claude-specific review policy.")

        let reverseLink = AgentHandoffLink(
            source: endpoint(destinationBinding, projectID: project.id),
            destination: endpoint(sourceBinding, projectID: project.id),
            purpose: "Return to the original builder.",
            conditions: "After review completes.",
            maximumDepth: 3,
            triggers: [.success]
        )
        try await SaveHandoffLinkUseCase(catalog: store)(reverseLink)
        let completedDestination = try #require(finalRun.assignments.first)
        await #expect(throws: GobyApplicationError.invalidHandoffLink(
            "the continuation would return to an earlier endpoint"
        )) {
            try await preparer(PrepareManualHandoffRequest(
                runID: finalRun.id,
                linkID: reverseLink.id,
                sourceAssignmentID: completedDestination.id,
                trigger: .success,
                sourceOutcomeSummary: "Review completed.",
                requestedNextAction: reverseLink.purpose
            ))
        }
    }

    @Test("Automatic and mismatched handoff paths fail closed")
    func invalidPathsFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-handoff-invalid-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let projectRoot = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: projectRoot,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Works",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [agent])
        let binding = try #require(try await store.snapshot().providerBindings.first)
        let endpoint = endpoint(binding, projectID: project.id)
        let automatic = AgentHandoffLink(
            source: endpoint,
            destination: AgentHandoffEndpoint(
                providerID: .claude,
                bindingID: binding.id,
                agentID: agent.id,
                projectID: project.id
            ),
            purpose: "Continue",
            conditions: "After review",
            mode: .automaticWhenApproved
        )

        await #expect(throws: GobyApplicationError.automaticHandoffsUnavailable) {
            try await SaveHandoffLinkUseCase(catalog: store)(automatic)
        }

        let mismatched = AgentHandoffLink(
            source: endpoint,
            destination: AgentHandoffEndpoint(
                providerID: .claude,
                bindingID: binding.id,
                agentID: agent.id,
                projectID: project.id
            ),
            purpose: "Continue",
            conditions: "After review"
        )
        await #expect(throws: GobyApplicationError.invalidHandoffLink(
            "an endpoint no longer matches its exact provider binding"
        )) {
            try await store.saveHandoffLink(mismatched)
        }
    }

    @Test("A failed source assignment is never restarted by its destination handoff")
    func failedSourceIsNotRestarted() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-handoff-failed-source-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let projectRoot = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: projectRoot,
            platforms: [.general],
            isGitRepository: false
        )
        let sourceAgent = AgentProfile(
            id: "source-agent",
            name: "Source",
            summary: "Attempts work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let destinationAgent = AgentProfile(
            id: "destination-agent",
            name: "Destination",
            summary: "Diagnoses failures",
            capabilities: [.review],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [sourceAgent, destinationAgent])
        let sourceBinding = try #require(try await store.snapshot().providerBindings.first(where: {
            $0.providerID == .codex && $0.agentID == sourceAgent.id
        }))
        let destinationBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: destinationAgent.id,
            projectID: project.id,
            nativeID: "goby-agent:destination-agent",
            capabilities: destinationAgent.capabilities
        )
        try await store.saveProviderBinding(destinationBinding)
        let link = AgentHandoffLink(
            source: endpoint(sourceBinding, projectID: project.id),
            destination: endpoint(destinationBinding, projectID: project.id),
            purpose: "Diagnose the source failure",
            conditions: "After the source fails",
            triggers: [.failure]
        )
        try await SaveHandoffLinkUseCase(catalog: store)(link)

        let sourceRunID: RunID = "failed-source-run"
        let sourceAssignment = AgentAssignment(
            id: "failed-source-assignment",
            runID: sourceRunID,
            projectID: project.id,
            agentID: sourceAgent.id,
            status: .failed,
            currentTask: "Original failed task",
            statusReason: "Source failed",
            providerID: .codex
        )
        try await store.save(RunRecord(
            id: sourceRunID,
            plan: RoutingPlan(
                id: sourceRunID,
                interpretedGoal: "Attempt then diagnose",
                routes: [ProjectRoute(
                    projectID: project.id,
                    providerID: .codex,
                    agentIDs: [sourceAgent.id],
                    reason: "Source attempt"
                )],
                risk: .readOnly,
                confidence: 1
            ),
            status: .failed,
            assignments: [sourceAssignment],
            agentSnapshot: [sourceAgent],
            providerBindingSnapshot: [sourceBinding]
        ))

        let prepared = try await PrepareManualHandoffUseCase(
            catalog: store,
            runs: store,
            handoffs: store
        )(PrepareManualHandoffRequest(
            runID: sourceRunID,
            linkID: link.id,
            sourceAssignmentID: sourceAssignment.id,
            trigger: .failure,
            sourceOutcomeSummary: "The source attempt failed.",
            requestedNextAction: "Diagnose without restarting the source."
        ))
        let destination = try await DispatchManualHandoffUseCase(
            catalog: store,
            runs: store,
            handoffs: store
        )(handoffID: prepared.id)

        let runtime = HandoffCompletingRuntime()
        let orchestrator = ProviderRunOrchestrator(
            catalog: store,
            runs: store,
            runtimes: AgentRuntimeRegistry(runtimes: [runtime]),
            workspaces: HandoffWorkspace(),
            verifier: ProjectVerifier(),
            handoffCatalog: store
        )
        try await orchestrator.execute(runID: destination.run.id)

        let sourceAfter = try #require(try await store.allRuns().first(where: { $0.id == sourceRunID }))
        let destinationAfter = try #require(try await store.allRuns().first(where: {
            $0.id == destination.run.id
        }))
        #expect(sourceAfter.status == .failed)
        #expect(sourceAfter.assignments == [sourceAssignment])
        #expect(
            destinationAfter.status == .completed,
            "Destination outcome: \(destinationAfter.outcome ?? destinationAfter.assignments.first?.statusReason ?? "none")"
        )
        #expect(await runtime.startCount == 1)
    }

    private func endpoint(
        _ binding: ProviderAgentBinding,
        projectID: ProjectID
    ) -> AgentHandoffEndpoint {
        AgentHandoffEndpoint(
            providerID: binding.providerID,
            bindingID: binding.id,
            agentID: binding.agentID,
            projectID: projectID
        )
    }
}

private actor HandoffCompletingRuntime: AgentRuntimeServing {
    nonisolated let providerID: AgentProviderID = .claude
    private let stream: AsyncStream<ProviderRunEvent>
    private let continuation: AsyncStream<ProviderRunEvent>.Continuation
    private(set) var startCount = 0
    private(set) var receivedInstructions: String?

    init() {
        let pair = AsyncStream<ProviderRunEvent>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func capabilities() -> ProviderCapabilities { ProviderCapabilities([.execution]) }
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
        startCount += 1
        receivedInstructions = agent.instructions
        continuation.yield(.assignmentStarted(providerID, assignment.id))
        continuation.yield(.assignmentCompleted(
            providerID,
            assignment.id,
            outcome: "Claude completed the handoff"
        ))
        return ProviderExecutionHandle(providerID: providerID, taskID: "claude-handoff-task")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) {}
    func events() -> AsyncStream<ProviderRunEvent> { stream }
}

private actor HandoffWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) -> String? { nil }
}

private actor HandoffCredentialRepository: ProviderCredentialRepository {
    private let credential: String

    init(credential: String) {
        self.credential = credential
    }

    func credential(for providerID: AgentProviderID, kind: ProviderCredentialKind) -> String? {
        providerID == .claude && kind == .apiKey ? credential : nil
    }

    func saveCredential(_ credential: String, for providerID: AgentProviderID, kind: ProviderCredentialKind) {}
    func removeCredential(for providerID: AgentProviderID, kind: ProviderCredentialKind) {}
}
