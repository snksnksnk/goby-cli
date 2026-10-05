import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct CatalogSyncUseCaseTests {
    @Test("Codex refresh returns only new or changed projects and agents")
    func refreshFiltersUnchangedCatalogEntries() async throws {
        let existingProject = LabProject(
            id: "existing-project",
            name: "Existing",
            rootURL: URL(fileURLWithPath: "/tmp/existing"),
            platforms: [.web],
            frameworks: ["React"],
            isGitRepository: true,
            registeredAt: .distantPast
        )
        let unchangedAgent = AgentProfile(
            id: "existing-agent",
            name: "Web Agent",
            summary: "Builds websites",
            capabilities: [.web],
            scope: .project(existingProject.id),
            sourceURL: existingProject.rootURL.appending(path: ".codex/agents/web.toml"),
            isEnabled: false
        )
        let newProject = LabProject(
            id: "new-project",
            name: "New Project",
            rootURL: URL(fileURLWithPath: "/tmp/new"),
            platforms: [.iOS],
            isGitRepository: true
        )
        let refreshedExistingProject = LabProject(
            id: existingProject.id,
            name: existingProject.name,
            rootURL: existingProject.rootURL,
            platforms: existingProject.platforms,
            frameworks: existingProject.frameworks,
            isGitRepository: existingProject.isGitRepository
        )
        let rediscoveredAgent = AgentProfile(
            id: unchangedAgent.id,
            name: unchangedAgent.name,
            summary: unchangedAgent.summary,
            capabilities: unchangedAgent.capabilities,
            scope: unchangedAgent.scope,
            sourceURL: unchangedAgent.sourceURL,
            isEnabled: true
        )
        let newAgent = AgentProfile(
            id: "new-agent",
            name: "iOS Agent",
            summary: "Builds Apple apps",
            capabilities: [.iOS],
            scope: .project(newProject.id),
            sourceURL: newProject.rootURL.appending(path: ".codex/agents/ios.toml")
        )
        let catalog = SyncCatalogStub(snapshot: LabSnapshot(
            projects: [existingProject],
            agents: [unchangedAgent]
        ))
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: catalog,
            codex: SyncCodexStub(roots: [existingProject.rootURL, newProject.rootURL]),
            projectDiscovery: SyncProjectDiscoveryStub(candidates: [
                ProjectCandidate(project: refreshedExistingProject),
                ProjectCandidate(project: newProject, detectedAgents: [newAgent])
            ]),
            agentDiscovery: SyncAgentDiscoveryStub(plan: AgentImportPlan(
                candidates: [
                    AgentImportCandidate(profile: rediscoveredAgent, configurationPreview: "existing", evidence: []),
                    AgentImportCandidate(profile: newAgent, configurationPreview: "new", evidence: [])
                ],
                suggestions: []
            ))
        )

        let plan = try await useCase()

        #expect(plan.scannedProjectCount == 2)
        #expect(plan.scannedAgentCount == 2)
        #expect(plan.projects.map(\.id) == [newProject.id])
        #expect(plan.agents.candidates.map(\.id) == [newAgent.id])
    }

    @Test("Codex sync never registers an agent for an unregistered project")
    func syncRejectsOrphanedProjectAgent() async throws {
        let catalog = SyncCatalogStub(snapshot: .empty)
        let orphan = AgentImportCandidate(
            profile: AgentProfile(
                id: "orphan",
                name: "Orphan",
                summary: "Should not be imported",
                capabilities: [.routing],
                scope: .project("not-selected")
            ),
            configurationPreview: "",
            evidence: []
        )

        try await SyncCodexCatalogUseCase(catalog: catalog)(projects: [], agents: [orphan])

        #expect(await catalog.snapshot().agents.isEmpty)
    }

    @Test("Direct folder import registers projects without implicitly trusting detected agents")
    func directImportRequiresSeparateAgentReview() async throws {
        let project = LabProject(
            id: "reviewed-project",
            name: "Reviewed Project",
            rootURL: URL(fileURLWithPath: "/tmp/reviewed-project"),
            platforms: [.web],
            isGitRepository: true
        )
        let detectedAgent = AgentProfile(
            id: "unreviewed-agent",
            name: "Repository Agent",
            summary: "Instructions still need review",
            capabilities: [.web],
            scope: .project(project.id),
            sourceURL: project.rootURL.appending(path: ".codex/agents/web.toml")
        )
        let catalog = SyncCatalogStub(snapshot: .empty)

        try await RegisterProjectsUseCase(catalog: catalog)(candidates: [
            ProjectCandidate(project: project, detectedAgents: [detectedAgent])
        ])

        let snapshot = await catalog.snapshot()
        #expect(snapshot.projects.map(\.id) == [project.id])
        #expect(snapshot.agents.isEmpty)
    }

    @Test("File-backed imports require the exact complete definition shown in review")
    func fileBackedImportBindsExactReviewedContent() async throws {
        let source = URL(fileURLWithPath: "/tmp/reviewed-agent.toml")
        let completeDefinition = """
        name = "Reviewed Agent"
        developer_instructions = "Review code."
        [mcp_servers.hidden]
        command = "/tmp/executable"
        """
        let profile = AgentProfile(
            id: "reviewed-agent",
            name: "Reviewed Agent",
            summary: "Reviews code",
            instructions: "Review code.",
            capabilities: [.review],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(completeDefinition)
        )
        let catalog = SyncCatalogStub(snapshot: .empty)
        let useCase = RegisterAgentsUseCase(catalog: catalog)

        await #expect(throws: GobyApplicationError.incompleteAgentDefinitionReview) {
            try await useCase(candidates: [AgentImportCandidate(
                profile: profile,
                configurationPreview: profile.instructions ?? "",
                evidence: []
            )])
        }
        #expect(await catalog.snapshot().agents.isEmpty)

        try await useCase(candidates: [AgentImportCandidate(
            profile: profile,
            configurationPreview: completeDefinition,
            evidence: []
        )])
        let imported = try #require(await catalog.snapshot().agents.first)
        #expect(imported.definitionReviewProvenance == .fullContent)
        #expect(imported.sourceURL == source)
    }

    @Test("Semantic imports persist as source-detached instruction-only agents")
    func semanticImportHasNoExecutableAuthority() async throws {
        let catalog = SyncCatalogStub(snapshot: .empty)
        let profile = AgentProfile(
            id: "semantic-agent",
            name: "Semantic Agent",
            summary: "Reviews code",
            instructions: "Review code.",
            capabilities: [.review],
            scope: .global,
            toolPreset: .iconComposer,
            reviewedDefinitionDigest: String(repeating: "a", count: 64),
            codexRegistrationKey: "unreviewed_registration"
        )

        try await RegisterAgentsUseCase(catalog: catalog)(candidates: [
            AgentImportCandidate(profile: profile, configurationPreview: "Review code.", evidence: [])
        ])

        let imported = try #require(await catalog.snapshot().agents.first)
        #expect(imported.definitionReviewProvenance == .semanticOnly)
        #expect(imported.sourceURL == nil)
        #expect(imported.toolPreset == nil)
        #expect(imported.reviewedDefinitionDigest == nil)
        #expect(imported.codexRegistrationKey == nil)
    }

    @Test("Codex catalog sync cannot bypass complete definition review")
    func codexSyncUsesTheSameCompleteReviewBoundary() async throws {
        let source = URL(fileURLWithPath: "/tmp/codex-sync-agent.toml")
        let completeDefinition = "name = \"Sync Agent\"\n[mcp_servers.hidden]\ncommand = \"/tmp/tool\"\n"
        let profile = AgentProfile(
            id: "sync-agent",
            name: "Sync Agent",
            summary: "Synced role",
            instructions: "Do the work.",
            capabilities: [.routing],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(completeDefinition)
        )
        let catalog = SyncCatalogStub(snapshot: .empty)
        let useCase = SyncCodexCatalogUseCase(catalog: catalog)

        await #expect(throws: GobyApplicationError.incompleteAgentDefinitionReview) {
            try await useCase(projects: [], agents: [
                AgentImportCandidate(profile: profile, configurationPreview: "Do the work.", evidence: [])
            ])
        }
        #expect(await catalog.snapshot().agents.isEmpty)

        try await useCase(projects: [], agents: [
            AgentImportCandidate(profile: profile, configurationPreview: completeDefinition, evidence: [])
        ])
        #expect(await catalog.snapshot().agents.first?.definitionReviewProvenance == .fullContent)
    }

    @Test("A project without definitions receives one reviewed platform agent suggestion")
    func projectWithoutAgentGetsSuggestion() async throws {
        let project = LabProject(
            id: "android-project",
            name: "Pocket App",
            rootURL: URL(fileURLWithPath: "/tmp/pocket-app"),
            platforms: [.android],
            frameworks: ["Gradle"],
            isGitRepository: true
        )
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: SyncCatalogStub(snapshot: .empty),
            codex: SyncCodexStub(roots: [project.rootURL]),
            projectDiscovery: SyncProjectDiscoveryStub(candidates: [ProjectCandidate(project: project)]),
            agentDiscovery: SyncAgentDiscoveryStub(plan: .empty)
        )

        let plan = try await useCase()
        let suggestion = try #require(plan.agents.candidates.first)

        #expect(plan.projects.map(\.id) == [project.id])
        #expect(plan.scannedAgentCount == 1)
        #expect(suggestion.profile.name == "Android Agent")
        #expect(suggestion.profile.capabilities == [.android])
        #expect(suggestion.profile.scope == .project(project.id))
        #expect(suggestion.profile.sourceURL == nil)
        #expect(suggestion.configurationPreview.contains("inferred from Android"))
    }

    @Test("A multi-platform project receives one focused agent suggestion per missing capability")
    func multiPlatformProjectGetsFocusedSuggestions() async throws {
        let project = LabProject(
            id: "pharmacies",
            name: "Pharmacies",
            rootURL: URL(fileURLWithPath: "/tmp/pharmacies"),
            platforms: [.android, .backend, .iOS, .web],
            isGitRepository: true
        )
        let existingWebAgent = AgentProfile(
            id: "existing-web",
            name: "Web Agent",
            summary: "Owns the website",
            capabilities: [.web],
            scope: .project(project.id)
        )
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: SyncCatalogStub(snapshot: LabSnapshot(projects: [], agents: [existingWebAgent])),
            codex: SyncCodexStub(roots: [project.rootURL]),
            projectDiscovery: SyncProjectDiscoveryStub(candidates: [ProjectCandidate(project: project)]),
            agentDiscovery: SyncAgentDiscoveryStub(plan: .empty)
        )

        let plan = try await useCase()

        #expect(plan.agents.candidates.map(\.profile.name) == ["Android Agent", "Backend Agent", "iOS Agent"])
        #expect(plan.agents.candidates.allSatisfy { $0.profile.scope == .project(project.id) })
        #expect(plan.agents.candidates.allSatisfy { $0.profile.sourceURL == nil })
        #expect(!plan.agents.candidates.contains { $0.profile.capabilities.contains(.web) })
    }

    @Test("An inaccessible saved Codex project remains available as reviewed metadata")
    func savedProjectMetadataFallback() async throws {
        let root = URL(fileURLWithPath: "/tmp/inaccessible-saved-project", isDirectory: true)
        let reference = CodexSavedProjectReference(name: "Saved Project", rootURL: root)
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: SyncCatalogStub(snapshot: .empty),
            codex: SyncCodexStub(roots: [root], savedProjects: [reference]),
            projectDiscovery: SyncProjectDiscoveryStub(candidates: []),
            agentDiscovery: SyncAgentDiscoveryStub(plan: .empty)
        )

        let plan = try await useCase()
        let candidate = try #require(plan.projects.first)
        let suggestion = try #require(plan.agents.candidates.first)

        #expect(candidate.project.id == ProjectID.derived(fromProjectRoot: root))
        #expect(candidate.project.name == "Saved Project")
        #expect(candidate.project.platforms == [.general])
        #expect(candidate.inspectionLevel == .metadataOnly)
        #expect(candidate.evidence.contains { $0.hasPrefix("Folder access required") })
        #expect(plan.limitedProjectAccessCount == 1)
        #expect(suggestion.profile.name == "Project Agent")
        #expect(suggestion.profile.scope == .project(candidate.id))
    }

    @Test("A limited Codex scan preserves reviewed project structure and suggests missing platform agents")
    func limitedRefreshPreservesReviewedProjectStructure() async throws {
        let root = URL(fileURLWithPath: "/tmp/reviewed-pharmacies", isDirectory: true)
        let project = LabProject(
            id: ProjectID.derived(fromProjectRoot: root),
            name: "Pharmacies",
            rootURL: root,
            platforms: [.android, .backend, .iOS, .web],
            frameworks: ["Gradle", "React", "Swift Package", "Xcode"],
            testCommands: ["npm --prefix web test"],
            isGitRepository: true
        )
        let existingRoutingAgent = AgentProfile(
            id: "legacy-project-agent",
            name: "Project Agent",
            summary: "Routes work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: SyncCatalogStub(snapshot: LabSnapshot(
                projects: [project],
                agents: [existingRoutingAgent]
            )),
            codex: SyncCodexStub(
                roots: [root],
                savedProjects: [CodexSavedProjectReference(name: project.name, rootURL: root)]
            ),
            projectDiscovery: SyncProjectDiscoveryStub(candidates: []),
            agentDiscovery: SyncAgentDiscoveryStub(plan: .empty)
        )

        let plan = try await useCase()

        #expect(plan.projects.isEmpty)
        #expect(plan.limitedProjectAccessCount == 1)
        #expect(plan.agents.candidates.map(\.profile.name) == [
            "Android Agent", "Backend Agent", "iOS Agent", "Web Agent"
        ])
        #expect(plan.agents.candidates.allSatisfy { $0.profile.scope == .project(project.id) })
    }
}

private actor SyncCatalogStub: LabCatalogRepository {
    private var value: LabSnapshot

    init(snapshot: LabSnapshot) {
        value = snapshot
    }

    func snapshot() -> LabSnapshot { value }

    func register(projects: [LabProject], agents: [AgentProfile]) {
        var projectMap = Dictionary(uniqueKeysWithValues: value.projects.map { ($0.id, $0) })
        var agentMap = Dictionary(uniqueKeysWithValues: value.agents.map { ($0.id, $0) })
        for project in projects { projectMap[project.id] = project }
        for agent in agents { agentMap[agent.id] = agent }
        value = LabSnapshot(projects: Array(projectMap.values), agents: Array(agentMap.values))
    }
}

private struct SyncProjectDiscoveryStub: ProjectDiscovering {
    let candidates: [ProjectCandidate]
    func discover(selectedRoots: [URL]) -> [ProjectCandidate] { candidates }
}

private struct SyncAgentDiscoveryStub: AgentDiscovering {
    let plan: AgentImportPlan
    func discover(projects: [LabProject]) -> AgentImportPlan { plan }
}

private actor SyncCodexStub: CodexServing {
    let roots: [URL]
    let savedProjects: [CodexSavedProjectReference]

    init(roots: [URL], savedProjects: [CodexSavedProjectReference] = []) {
        self.roots = roots
        self.savedProjects = savedProjects
    }

    func connectionState() -> CodexConnectionState { .connected(version: "test") }
    func connect() -> CodexConnectionState { .connected(version: "test") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot {
        .init(roots: roots, savedProjects: savedProjects)
    }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) throws -> CodexExecutionHandle {
        throw GobyApplicationError.noRoute
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { AsyncStream { $0.finish() } }
}
