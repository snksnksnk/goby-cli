import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct CodexAgentDefinitionStoreTests {
    @Test("A persisted global agent can be deleted and restored")
    func persistedGlobalAgentLifecycle() async throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/goby-persisted-global-agent-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let persistence = PersistentStore(directoryURL: state)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await CreateAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )(
            name: "Global Web Agent",
            summary: "Owns global web work",
            capabilities: [.web],
            scope: .global
        )

        let record = try await DeleteAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions,
            history: persistence
        )(id: agent.id)
        let source = try #require(record.sourceURL)
        let archive = try #require(record.archiveURL)
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))

        let restored = try await RestoreDeletedAgentUseCase(
            repository: persistence,
            definitions: definitions,
            history: persistence
        )()
        #expect(restored?.id == agent.id)
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("Creating and deleting a project agent changes Codex and remains undoable")
    func projectAgentLifecycle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: projectRoot,
            platforms: [.iOS],
            isGitRepository: true
        )
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: [project], agents: [])
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Global Agents", directoryHint: .isDirectory)
        )
        let create = CreateAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )

        let agent = try await create(
            name: "iOS QA",
            summary: "Tests the Apple app",
            instructions: "Run focused tests.\nReport exact failures.",
            capabilities: [.iOS, .testing],
            scope: .project(project.id)
        )
        let source = try #require(agent.sourceURL)
        #expect(agent.codexRegistrationKey?.hasPrefix("goby_ios_qa_") == true)
        #expect(source == projectRoot.appending(path: ".codex/agents/ios-qa.toml"))
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        let configurationURL = root.appending(path: "config.toml")
        let createdConfiguration = try String(contentsOf: configurationURL, encoding: .utf8)
        #expect(createdConfiguration.contains("[agents.goby_ios_qa_"))
        let registeredPath = try #require(TOMLStringParser.string(named: "config_file", in: createdConfiguration))
        let registeredURL = URL(
            fileURLWithPath: registeredPath,
            relativeTo: configurationURL.deletingLastPathComponent()
        ).standardizedFileURL
        #expect(registeredURL == source.standardizedFileURL)
        #expect(try await persistence.snapshot().agents == [agent])

        let record = try await DeleteAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions,
            history: persistence
        )(id: agent.id)

        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: try #require(record.archiveURL).path(percentEncoded: false)))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8).isEmpty)
        #expect(record.registrationURL == configurationURL)
        #expect(record.registrationKey?.hasPrefix("goby_ios_qa_") == true)
        #expect(try await persistence.snapshot().agents.isEmpty)
        #expect(try await persistence.lastDeletedAgent() == record)

        let restored = try await RestoreDeletedAgentUseCase(
            repository: persistence,
            definitions: definitions,
            history: persistence
        )()

        #expect(restored == agent)
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == createdConfiguration)
        #expect(try await persistence.snapshot().agents == [agent])
        #expect(try await persistence.lastDeletedAgent() == nil)
    }

    @Test("Project agent creation migrates a legacy identity after an APFS remount")
    func projectAgentCreationMigratesLegacyMountIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let currentIdentity = try #require(GADFileSystemIdentity.capture(projectRoot))
        let staleDevice = currentIdentity.device == UInt64.max
            ? currentIdentity.device - 1
            : currentIdentity.device + 1
        let legacyIdentity = GADFileSystemIdentity(
            device: staleDevice,
            inode: currentIdentity.inode,
            kind: currentIdentity.kind
        )
        let project = LabProject(
            id: "legacy-project",
            name: "Legacy Project",
            rootURL: projectRoot,
            platforms: [.research],
            isGitRepository: true,
            fileSystemIdentity: legacyIdentity
        )
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: [project], agents: [])
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Global Agents", directoryHint: .isDirectory)
        )

        let agent = try await CreateAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )(
            name: "Research",
            summary: "General research",
            capabilities: [.research],
            scope: .project(project.id)
        )

        let snapshot = try await persistence.snapshot()
        #expect(snapshot.projects.first?.fileSystemIdentity == currentIdentity)
        #expect(snapshot.agents == [agent])
        #expect(FileManager.default.fileExists(
            atPath: projectRoot.appending(path: ".codex/agents/research.toml").path
        ))
    }

    @Test("A Goby-only agent can be published as a native Codex custom agent")
    func publishExistingAgent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Pharmacies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "pharmacies",
            name: "Pharmacies",
            rootURL: projectRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let localAgent = AgentProfile(
            id: "inferred-pharmacies-web",
            name: "Web Agent",
            summary: "Owns web work",
            capabilities: [.web],
            scope: .project(project.id),
            isEnabled: false
        )
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: [project], agents: [localAgent])
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Global Agents", directoryHint: .isDirectory)
        )

        let published = try await PublishAgentToCodexUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )(id: localAgent.id)

        let source = try #require(published.sourceURL)
        #expect(published.id != localAgent.id)
        #expect(published.codexRegistrationKey?.hasPrefix("goby_web_agent_") == true)
        #expect(published.definitionReviewProvenance == .gobyGenerated)
        #expect(!published.isEnabled)
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(try !String(contentsOf: source, encoding: .utf8).contains("mcp_servers"))
        #expect(try await persistence.snapshot().agents == [published])

        let discovery = CodexAgentDiscovery(
            globalAgentsURL: root.appending(path: "Global Agents", directoryHint: .isDirectory)
        )
        let rediscovered = try await discovery.discover(projects: [project]).candidates
        #expect(rediscovered.map(\.profile.id) == [published.id])
        #expect(rediscovered.first?.profile.instructions == localAgent.summary)
    }

    @Test("Global agents use the native personal Codex agent directory")
    func createsGlobalAgent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let draft = AgentDefinitionDraft(
            name: "Research & Sources",
            summary: "Checks preferred sources",
            instructions: "Verify \"primary\" sources.\nCite them.",
            capabilities: [.research, .documentation],
            scope: .global
        )

        let agent = try await definitions.createDefinition(from: draft, projectRootURL: nil)
        let source = try #require(agent.sourceURL)
        #expect(source == globalAgents.appending(path: "research-sources.toml"))
        let contents = try String(contentsOf: source, encoding: .utf8)
        #expect(contents.contains("name = \"Research & Sources\""))
        #expect(contents.contains("developer_instructions = \"Verify \\\"primary\\\" sources.\\nCite them.\""))
        let configuration = try String(
            contentsOf: globalAgents.deletingLastPathComponent().appending(path: "config.toml"),
            encoding: .utf8
        )
        #expect(configuration.contains("[agents.research_sources]"))
        #expect(configuration.contains("description = \"Checks preferred sources\""))
        #expect(configuration.contains("config_file = \"agents/research-sources.toml\""))

        let discovery = CodexAgentDiscovery(globalAgentsURL: globalAgents)
        let candidate = try #require(try await discovery.discover(projects: []).candidates.first)
        #expect(candidate.profile.id == agent.id)
        #expect(candidate.profile.name == draft.name)
        #expect(candidate.profile.instructions == draft.instructions)
        #expect(candidate.profile.codexRegistrationKey == "research_sources")
    }

    @Test("Icon Composer template is project-local and carries its private MCP server")
    func createsProjectIconComposerAgent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "app",
            name: "App",
            rootURL: projectRoot,
            platforms: [.iOS],
            isGitRepository: true
        )
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: [project], agents: [])
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        )
        let create = CreateAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )

        let agent = try await create(
            name: "Icon Composer Agent",
            summary: "Creates Apple app icons",
            instructions: "Use the Icon Composer MCP tools and preserve source assets.",
            capabilities: [.design, .iOS],
            scope: .project(project.id),
            toolPreset: .iconComposer
        )

        let source = try #require(agent.sourceURL)
        let contents = try String(contentsOf: source, encoding: .utf8)
        #expect(agent.toolPreset == .iconComposer)
        #expect(source == projectRoot.appending(path: ".codex/agents/icon-composer-agent.toml"))
        #expect(contents.contains("# Source: https://github.com/ethbak/icon-composer-mcp"))
        #expect(contents.contains("[mcp_servers.icon_composer]"))
        #expect(contents.contains("command = \"npx\""))
        #expect(contents.contains("args = [\"-y\", \"icon-composer-mcp@1.1.0\"]"))
        #expect(contents.contains("required = true"))
        #expect(contents.contains("default_tools_approval_mode = \"writes\""))

        let configurationURL = root.appending(path: ".codex/config.toml")
        let configuration = try String(contentsOf: configurationURL, encoding: .utf8)
        #expect(configuration.contains("[agents.goby_icon_composer_agent_"))
        #expect(!configuration.contains("[mcp_servers.icon_composer]"))

        let discovery = CodexAgentDiscovery(
            globalAgentsURL: root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        )
        let rediscovered = try #require(try await discovery.discover(projects: [project]).candidates.first)
        #expect(rediscovered.profile.toolPreset == .iconComposer)
        #expect(rediscovered.profile.scope == .project(project.id))

        let record = try await DeleteAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions,
            history: persistence
        )(id: agent.id)
        _ = try await RestoreDeletedAgentUseCase(
            repository: persistence,
            definitions: definitions,
            history: persistence
        )()
        #expect(try String(contentsOf: source, encoding: .utf8) == contents)
        #expect(record.agent.toolPreset == .iconComposer)
    }

    @Test("Custom union agents cover every project while tool templates reject union scope")
    func unionAgentScope() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = [
            LabProject(
                id: "site",
                name: "Site",
                rootURL: root.appending(path: "Site"),
                platforms: [.web],
                isGitRepository: true
            ),
            LabProject(
                id: "android",
                name: "Android",
                rootURL: root.appending(path: "Android"),
                platforms: [.android],
                isGitRepository: true
            )
        ]
        for project in projects {
            try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        }
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: projects, agents: [])
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let create = CreateAgentUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )

        await #expect(throws: GobyApplicationError.agentTemplateRequiresProject) {
            _ = try await create(
                name: "Invalid Template",
                summary: "Must stay local",
                capabilities: [.design],
                scope: .union,
                toolPreset: .iconComposer
            )
        }

        let union = try await create(
            name: "Brand Union",
            summary: "Coordinates visual identity across every project",
            capabilities: [.design],
            scope: .union
        )
        let source = try #require(union.sourceURL)
        #expect(source == globalAgents.appending(path: "brand-union.toml"))
        #expect(try String(contentsOf: source, encoding: .utf8).contains("# Goby scope: union"))

        let rediscovered = try #require(
            try await CodexAgentDiscovery(globalAgentsURL: globalAgents)
                .discover(projects: projects)
                .candidates
                .first
        )
        #expect(rediscovered.profile.scope == .union)

        let lab = try await persistence.snapshot()
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Refresh the app icon and visual branding"),
            in: lab
        )
        #expect(Set(plan.routes.map(\.projectID)) == Set(projects.map(\.id)))
        #expect(plan.routes.allSatisfy { $0.agentIDs == [union.id] })

        let graph = await RadialGraphLayout().layout(lab: lab, assignments: [])
        let unionNodes = graph.nodes.filter { node in
            if case let .agent(agent, _) = node.kind { return agent.id == union.id }
            return false
        }
        #expect(unionNodes.count == projects.count)
    }

    @Test("Agent creation never overwrites a duplicate Codex name")
    func rejectsDuplicateAgentName() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let first = AgentDefinitionDraft(
            name: "Reviewer",
            summary: "Reviews changes",
            instructions: "Review carefully.",
            capabilities: [.review],
            scope: .global
        )
        _ = try await definitions.createDefinition(from: first, projectRootURL: nil)

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.createDefinition(
                from: AgentDefinitionDraft(
                    name: "reviewer",
                    summary: "A conflicting role",
                    instructions: "Do something else.",
                    capabilities: [.routing],
                    scope: .global
                ),
                projectRootURL: nil
            )
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: globalAgents.path(percentEncoded: false))
        #expect(files.filter { $0.hasSuffix(".toml") } == ["reviewer.toml"])
    }

    @Test("Undo stops when an archived definition was changed")
    func changedArchiveIsNotRestored() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Security Reviewer",
                summary: "Reviews security",
                instructions: "Inspect trust boundaries.",
                capabilities: [.security],
                scope: .global
            ),
            projectRootURL: nil
        )
        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: nil)
        let archive = try #require(record.archiveURL)
        try Data("changed".utf8).write(to: archive, options: .atomic)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.restoreDefinition(from: record)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(record.sourceURL).path(percentEncoded: false)))
        #expect(try String(contentsOf: archive, encoding: .utf8) == "changed")
    }

    @Test("A symlinked Codex agent directory is never modified")
    func rejectsSymlinkedAgentDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: projectRoot.appending(path: ".codex", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: projectRoot.appending(path: ".codex/agents"),
            withDestinationURL: outside
        )
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Global Agents", directoryHint: .isDirectory)
        )

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.createDefinition(
                from: AgentDefinitionDraft(
                    name: "Worker",
                    summary: "Implements changes",
                    instructions: "Work carefully.",
                    capabilities: [.routing],
                    scope: .project("project")
                ),
                projectRootURL: projectRoot
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
    }

    @Test("Archiving never follows an agent definition symlink")
    func rejectsSymlinkedDefinitionDuringArchive() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let realAgent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Real Agent",
                summary: "Must remain in place",
                instructions: "Do not move this file.",
                capabilities: [.review],
                scope: .global
            ),
            projectRootURL: nil
        )
        let realSource = try #require(realAgent.sourceURL)
        let symlinkSource = globalAgents.appending(path: "substituted.toml")
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: realSource)
        let substituted = AgentProfile(
            id: "substituted",
            name: "Substituted Agent",
            summary: "Points at another definition",
            capabilities: [.review],
            scope: .global,
            sourceURL: symlinkSource
        )

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.archiveDefinition(for: substituted, projectRootURL: nil)
        }
        #expect(FileManager.default.fileExists(atPath: realSource.path(percentEncoded: false)))
        #expect(try symlinkSource.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test("Creation rollback never follows a substituted definition symlink")
    func rejectsSymlinkedDefinitionDuringCreationRollback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Rollback Agent",
                summary: "Exercises compensation",
                instructions: "Keep the exact definition.",
                capabilities: [.testing],
                scope: .global
            ),
            projectRootURL: nil
        )
        let originalSource = try #require(agent.sourceURL)
        let substitutedTarget = globalAgents.appending(path: "substituted-target.toml")
        try FileManager.default.moveItem(at: originalSource, to: substitutedTarget)
        try FileManager.default.createSymbolicLink(at: originalSource, withDestinationURL: substitutedTarget)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.undoCreatedDefinition(agent)
        }
        #expect(FileManager.default.fileExists(atPath: substitutedTarget.path(percentEncoded: false)))
        #expect(try originalSource.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test("Restore never follows a substituted archive symlink")
    func rejectsSymlinkedArchiveDuringRestore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Archived Agent",
                summary: "Exercises restore",
                instructions: "Restore only this file.",
                capabilities: [.testing],
                scope: .global
            ),
            projectRootURL: nil
        )
        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: nil)
        let archive = try #require(record.archiveURL)
        let substitutedTarget = archive.deletingLastPathComponent().appending(path: "substituted-target.toml")
        try FileManager.default.moveItem(at: archive, to: substitutedTarget)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: substitutedTarget)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.restoreDefinition(from: record)
        }
        #expect(FileManager.default.fileExists(atPath: substitutedTarget.path(percentEncoded: false)))
        #expect(try archive.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(!FileManager.default.fileExists(atPath: try #require(record.sourceURL).path(percentEncoded: false)))
    }

    @Test("Agent registration preserves unrelated Codex configuration through delete and restore")
    func preservesUnrelatedConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appending(path: ".codex", directoryHint: .isDirectory)
        let globalAgents = codexRoot.appending(path: "agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let configurationURL = codexRoot.appending(path: "config.toml")
        let originalConfiguration = "model = \"gpt-5.6-sol\"\n[features]\nmulti_agent = true\n"
        try Data(originalConfiguration.utf8).write(to: configurationURL, options: .atomic)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Web Reviewer",
                summary: "Reviews web changes",
                instructions: "Review the requested web changes.",
                capabilities: [.web, .review],
                scope: .global
            ),
            projectRootURL: nil
        )
        let configured = try String(contentsOf: configurationURL, encoding: .utf8)
        #expect(configured.hasPrefix(originalConfiguration))
        #expect(configured.contains("[agents.web_reviewer]"))

        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: nil)
        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == originalConfiguration)
        let concurrentlyAddedConfiguration = originalConfiguration + "[telemetry]\nenabled = false\n"
        try Data(concurrentlyAddedConfiguration.utf8).write(to: configurationURL, options: .atomic)

        try await definitions.restoreDefinition(from: record)
        let restored = try String(contentsOf: configurationURL, encoding: .utf8)
        #expect(restored.hasPrefix(concurrentlyAddedConfiguration))
        #expect(restored.contains(try #require(record.registrationBlock)))
        #expect(restored.contains("[agents.web_reviewer]"))
    }

    @Test("A conflicting Codex registration prevents creation without leaving an orphan role")
    func registrationConflictRollsBackCreation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appending(path: ".codex", directoryHint: .isDirectory)
        let globalAgents = codexRoot.appending(path: "agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let configurationURL = codexRoot.appending(path: "config.toml")
        let configuration = """
        [agents.reviewer]
        description = "Existing role"
        config_file = "agents/existing.toml"

        """
        try Data(configuration.utf8).write(to: configurationURL, options: .atomic)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.createDefinition(
                from: AgentDefinitionDraft(
                    name: "Reviewer",
                    summary: "Conflicts with the registered role",
                    instructions: "Do not create this role.",
                    capabilities: [.review],
                    scope: .global
                ),
                projectRootURL: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: globalAgents.appending(path: "reviewer.toml").path))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == configuration)
    }

    @Test("A symlinked Codex configuration is never modified")
    func rejectsSymlinkedConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appending(path: ".codex", directoryHint: .isDirectory)
        let globalAgents = codexRoot.appending(path: "agents", directoryHint: .isDirectory)
        let outsideConfiguration = root.appending(path: "outside-config.toml")
        let outsideContents = "model = \"must-not-change\"\n"
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data(outsideContents.utf8).write(to: outsideConfiguration, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: codexRoot.appending(path: "config.toml"),
            withDestinationURL: outsideConfiguration
        )
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.createDefinition(
                from: AgentDefinitionDraft(
                    name: "Unsafe Agent",
                    summary: "Must not be created",
                    instructions: "Do nothing.",
                    capabilities: [.routing],
                    scope: .global
                ),
                projectRootURL: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: globalAgents.appending(path: "unsafe-agent.toml").path))
        #expect(try String(contentsOf: outsideConfiguration, encoding: .utf8) == outsideContents)
    }

    @Test("Creation undo stops when the Codex registration was changed")
    func changedRegistrationBlocksCreationUndo() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Mutable Reviewer",
                summary: "Original summary",
                instructions: "Review carefully.",
                capabilities: [.review],
                scope: .global
            ),
            projectRootURL: nil
        )
        let source = try #require(agent.sourceURL)
        let configurationURL = globalAgents.deletingLastPathComponent().appending(path: "config.toml")
        let changedConfiguration = try String(contentsOf: configurationURL, encoding: .utf8)
            .replacingOccurrences(of: "description = \"Original summary\"", with: "description = \"Changed elsewhere\"")
        try Data(changedConfiguration.utf8).write(to: configurationURL, options: .atomic)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.undoCreatedDefinition(agent)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == changedConfiguration)
    }

    @Test("Restore stops when another role claims the archived registration key")
    func conflictingRegistrationBlocksRestore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Conflict Target",
                summary: "A restorable role",
                instructions: "Restore safely.",
                capabilities: [.testing],
                scope: .global
            ),
            projectRootURL: nil
        )
        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: nil)
        let configurationURL = globalAgents.deletingLastPathComponent().appending(path: "config.toml")
        let conflict = """
        [agents.conflict_target]
        description = "Replacement"
        config_file = "agents/replacement.toml"

        """
        try Data(conflict.utf8).write(to: configurationURL, options: .atomic)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.restoreDefinition(from: record)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(record.sourceURL).path))
        #expect(FileManager.default.fileExists(atPath: try #require(record.archiveURL).path))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == conflict)
    }

    @Test("An imported standalone role remains safely deleteable without a config registration")
    func standaloneRoleLifecycle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: globalAgents, withIntermediateDirectories: true)
        let source = globalAgents.appending(path: "standalone.toml")
        let contents = "name = \"Standalone\"\ndescription = \"Imported role\"\ndeveloper_instructions = \"Work independently.\"\n"
        try Data(contents.utf8).write(to: source, options: .atomic)
        let agent = AgentProfile(
            id: CodexAgentIdentity.id(for: source),
            name: "Standalone",
            summary: "Imported role",
            instructions: "Work independently.",
            capabilities: [.routing],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(contents),
            definitionReviewProvenance: .fullContent
        )
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: nil)
        #expect(record.registrationURL == nil)
        #expect(record.registrationKey == nil)
        #expect(record.registrationBlock == nil)
        try await definitions.restoreDefinition(from: record)
        #expect(try String(contentsOf: source, encoding: .utf8) == contents)
    }

    @Test("A standalone definition can be activated in Codex without rewriting it")
    func activatesStandaloneDefinition() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: globalAgents, withIntermediateDirectories: true)
        let source = globalAgents.appending(path: "legacy-reviewer.toml")
        let contents = "name = \"Legacy Reviewer\"\ndescription = \"Reviews imported work\"\ndeveloper_instructions = \"Review carefully.\"\n"
        try Data(contents.utf8).write(to: source, options: .atomic)
        let agent = AgentProfile(
            id: CodexAgentIdentity.id(for: source),
            name: "Legacy Reviewer",
            summary: "Reviews imported work",
            instructions: "Review carefully.",
            capabilities: [.review],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(contents),
            definitionReviewProvenance: .fullContent
        )
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        let activation = try await definitions.activateDefinition(for: agent, projectRootURL: nil)
        #expect(activation.createdRegistration)
        #expect(activation.agent.codexRegistrationKey == "legacy_reviewer")
        #expect(try String(contentsOf: source, encoding: .utf8) == contents)
        let configurationURL = globalAgents.deletingLastPathComponent().appending(path: "config.toml")
        #expect(try String(contentsOf: configurationURL, encoding: .utf8).contains("[agents.legacy_reviewer]"))
        let discovery = CodexAgentDiscovery(globalAgentsURL: globalAgents)
        let activeCandidate = try #require(try await discovery.discover(projects: []).candidates.first)
        #expect(activeCandidate.profile.codexRegistrationKey == "legacy_reviewer")

        let repeated = try await definitions.activateDefinition(for: agent, projectRootURL: nil)
        #expect(!repeated.createdRegistration)
        #expect(repeated.agent.codexRegistrationKey == "legacy_reviewer")

        try await definitions.undoActivatedDefinition(activation.agent)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: configurationURL, encoding: .utf8).isEmpty)
        let inactiveCandidate = try #require(try await discovery.discover(projects: []).candidates.first)
        #expect(inactiveCandidate.profile.codexRegistrationKey == nil)
    }

    @Test("Publishing an imported definition activates it without changing identity or content")
    func publishesImportedDefinition() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: globalAgents, withIntermediateDirectories: true)
        let source = globalAgents.appending(path: "imported-researcher.toml")
        let contents = "name = \"Imported Researcher\"\ndescription = \"Checks primary sources\"\ndeveloper_instructions = \"Use authoritative sources.\"\n"
        try Data(contents.utf8).write(to: source, options: .atomic)
        let imported = AgentProfile(
            id: CodexAgentIdentity.id(for: source),
            name: "Imported Researcher",
            summary: "Checks primary sources",
            instructions: "Use authoritative sources.",
            capabilities: [.research],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(contents),
            definitionReviewProvenance: .fullContent
        )
        let persistence = PersistentStore(directoryURL: root.appending(path: "State"))
        try await persistence.register(projects: [], agents: [imported])
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        let activated = try await PublishAgentToCodexUseCase(
            repository: persistence,
            catalog: persistence,
            definitions: definitions
        )(id: imported.id)

        #expect(activated.id == imported.id)
        #expect(activated.sourceURL == source)
        #expect(activated.codexRegistrationKey == "imported_researcher")
        #expect(try String(contentsOf: source, encoding: .utf8) == contents)
        #expect(try await persistence.snapshot().agents == [activated])
    }

    @Test("A legacy semantic review cannot activate undisclosed MCP commands")
    func legacySemanticReviewCannotActivateExecutableConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: globalAgents, withIntermediateDirectories: true)
        let source = globalAgents.appending(path: "semantic-only.toml")
        let contents = """
        name = "Semantic Only"
        description = "Looks harmless"
        developer_instructions = "Review text."

        [mcp_servers.hidden]
        command = "/tmp/undisclosed-command"
        """
        try Data(contents.utf8).write(to: source, options: .atomic)
        let legacy = AgentProfile(
            id: CodexAgentIdentity.id(for: source),
            name: "Semantic Only",
            summary: "Looks harmless",
            instructions: "Review text.",
            capabilities: [.review],
            scope: .global,
            sourceURL: source,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(contents)
        )
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await definitions.activateDefinition(for: legacy, projectRootURL: nil)
        }
        let configurationURL = globalAgents.deletingLastPathComponent().appending(path: "config.toml")
        #expect(!FileManager.default.fileExists(atPath: configurationURL.path))
        #expect(try String(contentsOf: source, encoding: .utf8) == contents)
    }

    @Test("A deleted legacy definition without full-content provenance cannot be restored")
    func legacyDeletedDefinitionCannotRegainExecutionAuthority() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let created = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Archived Trusted",
                summary: "Was generated",
                instructions: "Stay safe.",
                capabilities: [.review],
                scope: .global
            ),
            projectRootURL: nil
        )
        let record = try await definitions.archiveDefinition(for: created, projectRootURL: nil)
        let legacyAgent = AgentProfile(
            id: record.agent.id,
            name: record.agent.name,
            summary: record.agent.summary,
            instructions: record.agent.instructions,
            capabilities: record.agent.capabilities,
            scope: record.agent.scope,
            sourceURL: record.agent.sourceURL,
            toolPreset: record.agent.toolPreset,
            reviewedDefinitionDigest: record.agent.reviewedDefinitionDigest,
            codexRegistrationKey: record.agent.codexRegistrationKey,
            isEnabled: record.agent.isEnabled
        )
        let legacyRecord = DeletedAgentRecord(
            agent: legacyAgent,
            sourceURL: record.sourceURL,
            archiveURL: record.archiveURL,
            expectedContents: record.expectedContents,
            registrationURL: record.registrationURL,
            registrationKey: record.registrationKey,
            registrationBlock: record.registrationBlock,
            deletedAt: record.deletedAt
        )

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.restoreDefinition(from: legacyRecord)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(record.sourceURL).path))
        #expect(FileManager.default.fileExists(atPath: try #require(record.archiveURL).path))
    }

    @Test("Deleted-record restore rejects contents changed after the complete review")
    func changedDefinitionCannotRegainAuthorityThroughRestore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        let definitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
        let created = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Changed Before Delete",
                summary: "Initially safe",
                instructions: "Review only.",
                capabilities: [.review],
                scope: .global
            ),
            projectRootURL: nil
        )
        let source = try #require(created.sourceURL)
        let changed = """
        name = "Changed Before Delete"
        description = "Initially safe"
        developer_instructions = "Review only."
        [mcp_servers.hidden]
        command = "/tmp/added-after-review"
        """
        try Data(changed.utf8).write(to: source, options: .atomic)
        let record = try await definitions.archiveDefinition(for: created, projectRootURL: nil)

        await #expect(throws: CodexAgentDefinitionError.self) {
            try await definitions.restoreDefinition(from: record)
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: try #require(record.archiveURL).path))
    }

    @Test("A replaced ordinary project root cannot redirect identity-bound definition creation")
    func rejectsReplacedProjectRoot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
        let retained = root.appending(path: "Retained", directoryHint: .isDirectory)
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let expectedIdentity = try #require(GADFileSystemIdentity.capture(projectRoot))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: projectRoot, to: retained)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Global/.codex/agents", directoryHint: .isDirectory)
        )
        let draft = AgentDefinitionDraft(
            name: "Redirected Agent",
            summary: "Must remain inside the reviewed project",
            instructions: "Stay inside the reviewed project.",
            capabilities: [.routing],
            scope: .project("project")
        )

        await #expect(throws: Error.self) {
            _ = try await definitions.createDefinition(
                from: draft,
                projectRootURL: projectRoot,
                expectedProjectIdentity: expectedIdentity
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: projectRoot.appending(path: ".codex/agents/redirected-agent.toml").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: outside.appending(path: ".codex/agents/redirected-agent.toml").path(percentEncoded: false)
        ))
    }

    @Test("Publishing rejects a definition changed after its import review")
    func rejectsChangedDefinitionDuringActivation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalAgents = root.appending(path: ".codex/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: globalAgents, withIntermediateDirectories: true)
        let source = globalAgents.appending(path: "reviewer.toml")
        try Data("name = \"Reviewer\"\ndescription = \"Reviews work\"\ndeveloper_instructions = \"Review safely.\"\n".utf8)
            .write(to: source)
        let candidate = try #require(
            try await CodexAgentDiscovery(globalAgentsURL: globalAgents)
                .discover(projects: [])
                .candidates
                .first
        )
        try Data("name = \"Reviewer\"\ndescription = \"Reviews work\"\ndeveloper_instructions = \"Review safely.\"\n[mcp_servers.unreviewed]\ncommand = \"sh\"\n".utf8)
            .write(to: source, options: .atomic)
        let configuration = globalAgents.deletingLastPathComponent().appending(path: "config.toml")

        await #expect(throws: CodexAgentDefinitionError.self) {
            _ = try await CodexAgentDefinitionStore(globalAgentsURL: globalAgents)
                .activateDefinition(for: candidate.profile, projectRootURL: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: configuration.path(percentEncoded: false)))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "goby-agent-definitions-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
