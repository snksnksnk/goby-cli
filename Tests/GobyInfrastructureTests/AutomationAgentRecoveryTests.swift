import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct AutomationAgentRecoveryTests {
    @Test("Missing specialists are persisted without replaying completed work or replacing agents")
    func createsOnlyMissingSpecialists() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await fixture.store.snapshot().agents
        let originalURL = try #require(original.first?.sourceURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let plan = try await fixture.plan()
        #expect(plan.capabilities == [.documentation, .security, .testing])
        #expect(plan.providerID == .codex)

        let created = try await fixture.create(plan)

        #expect(created.count == 3)
        #expect(created.allSatisfy { $0.scope == .project("project") && $0.isEnabled })
        #expect(created.allSatisfy { $0.toolPreset == nil })
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        let lab = try await fixture.store.snapshot()
        #expect(lab.agents.count == 4)
        #expect(lab.agents.contains(original[0]))
        #expect(AgentRoutingMatcher.missingCapabilities(
            required: [.review, .documentation, .security, .testing],
            among: AgentRoutingMatcher.eligibleAgents(for: "project", providerID: .codex, in: lab)
        ).isEmpty)
        for agent in created {
            let url = try #require(agent.sourceURL)
            #expect(url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == fixture.agentDirectory.resolvingSymlinksInPath().path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let snapshot = try await fixture.store.automationSnapshot()
        #expect(snapshot.definitions.first?.state == .paused)
        #expect(snapshot.occurrences.first?.status == .failed)
        #expect(snapshot.occurrences.first?.attempts.first == fixture.completedAttempt)
        #expect(try await fixture.store.allRuns().isEmpty)
        #expect(AutomationAgentRecoveryPolicy.plan(for: "occurrence", in: snapshot, lab: lab) == nil)
        await #expect(throws: (any Error).self) { _ = try await fixture.create(plan) }
        #expect(try await fixture.store.snapshot().agents.count == 4)
    }

    @Test("A file conflict preserves partial success and retries only the remaining specialist")
    func partialCreationCanBeRetried() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = fixture.agentDirectory.appending(path: "automation-testing-specialist.toml")
        let originalBytes = Data("# An existing, unimported user definition\n".utf8)
        try originalBytes.write(to: conflict)
        let plan = try await fixture.plan()

        do {
            _ = try await fixture.create(plan)
            Issue.record("Expected the existing definition to block creation")
        } catch {
            #expect(error.localizedDescription.contains("Added 2 of 3"))
        }
        #expect(try Data(contentsOf: conflict) == originalBytes)
        #expect(try await fixture.store.snapshot().agents.count == 3)
        let retry = try await fixture.plan()
        #expect(retry.capabilities == [.testing])
        try FileManager.default.removeItem(at: conflict)
        let created = try await fixture.create(retry)
        #expect(created.map(\.capabilities) == [[.testing]])
        #expect(try await fixture.store.snapshot().agents.count == 4)
    }

    @Test("A cancelled occurrence rejects an earlier missing-agent selection")
    func rejectsStaleRecovery() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.plan()
        let old = try #require(try await fixture.store.automationSnapshot().occurrences.first)
        let cancelled = AutomationOccurrence(
            id: old.id, automationID: old.automationID, definitionRevision: old.definitionRevision,
            actions: old.actions, trigger: old.trigger, scheduledAt: old.scheduledAt,
            status: .cancelled, currentActionIndex: old.currentActionIndex, attempts: old.attempts
        )
        try await fixture.store.saveAutomationOccurrence(cancelled, replacing: old)
        await #expect(throws: (any Error).self) { _ = try await fixture.create(plan) }
        #expect(try await fixture.store.snapshot().agents.count == 1)
    }

    @Test("Coverage respects provider, project, enabled state, and exact targets")
    func recoveryEligibility() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try await fixture.store.automationSnapshot()
        let originalLab = try await fixture.store.snapshot()
        let otherProject = LabProject(
            id: "other", name: "Other", rootURL: fixture.root.appending(path: "Other"),
            platforms: [.macOS], isGitRepository: false
        )
        let candidates = [
            AgentProfile(id: "other-project", name: "Other", summary: "Other project", capabilities: [.security], scope: .project("other")),
            AgentProfile(id: "disabled", name: "Disabled", summary: "Disabled", capabilities: [.testing], scope: .project("project"), isEnabled: false),
            AgentProfile(id: "claude-only", name: "Claude", summary: "Claude", capabilities: [.documentation], scope: .project("project"))
        ]
        let lab = LabSnapshot(
            projects: originalLab.projects + [otherProject],
            agents: originalLab.agents + candidates,
            providerBindings: originalLab.providerBindings + [
                ProviderAgentBinding(id: "other-binding", providerID: .codex, agentID: "other-project", projectID: "other", nativeID: "other", capabilities: [.security]),
                ProviderAgentBinding(id: "disabled-binding", providerID: .codex, agentID: "disabled", projectID: "project", nativeID: "disabled", capabilities: [.testing]),
                ProviderAgentBinding(id: "claude-binding", providerID: .claude, agentID: "claude-only", projectID: "project", nativeID: "claude", capabilities: [.documentation])
            ]
        )
        let plan = try #require(AutomationAgentRecoveryPolicy.plan(for: "occurrence", in: snapshot, lab: lab))
        #expect(plan.capabilities == [.documentation, .security, .testing])

        let exact = AutomationAction(
            id: "exact", instruction: "Security review",
            target: .agent(.init(agentID: originalLab.agents[0].id, projectID: "project"))
        )
        let definition = AutomationDefinition(
            id: "exact-automation", name: "Exact", schedule: fixture.schedule, actions: [exact]
        )
        let occurrence = AutomationOccurrence(
            id: "exact-occurrence", automationID: definition.id, definitionRevision: 1,
            actions: [exact], trigger: .manual, scheduledAt: .now, status: .needsAttention,
            attempts: [.init(actionID: exact.id, status: .needsAttention)]
        )
        #expect(AutomationAgentRecoveryPolicy.plan(
            for: occurrence.id, in: .init(definitions: [definition], occurrences: [occurrence]), lab: lab
        ) == nil)
    }

    private struct Fixture {
        let root: URL
        let agentDirectory: URL
        let store: PersistentStore
        let create: AddMissingAutomationAgentsUseCase
        let completedAttempt: AutomationActionAttempt
        let schedule: AutomationSchedule

        func plan() async throws -> AutomationAgentRecoveryPlan {
            try #require(AutomationAgentRecoveryPolicy.plan(
                for: "occurrence", in: try await store.automationSnapshot(), lab: try await store.snapshot()
            ))
        }

        static func make() async throws -> Fixture {
            let root = URL(fileURLWithPath: "/private/tmp/goby-agent-recovery-\(UUID().uuidString)", isDirectory: true)
            let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let store = PersistentStore(
                directoryURL: root.appending(path: "State"),
                automationAuthenticator: TestAutomationDocumentAuthenticator()
            )
            try await store.register(projects: [LabProject(
                id: "project", name: "Project", rootURL: projectRoot, platforms: [.macOS], isGitRepository: false
            )], agents: [])
            let createAgent = CreateAgentUseCase(
                repository: store, catalog: store,
                definitions: CodexAgentDefinitionStore(globalAgentsURL: root.appending(path: "Global/agents"))
            )
            _ = try await createAgent(name: "Existing Reviewer", summary: "Reviews work", capabilities: [.review], scope: .project("project"))
            let actions = [
                AutomationAction(id: "completed", instruction: "Review", target: .project(providerID: .codex, projectID: "project")),
                AutomationAction(id: "blocked", instruction: "Review security, documentation and testing", target: .project(providerID: .codex, projectID: "project"))
            ]
            let schedule = AutomationSchedule(cadence: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC")
            let definition = AutomationDefinition(id: "automation", name: "Automation", schedule: schedule, actions: actions)
            let completed = AutomationActionAttempt(actionID: "completed", runID: "completed-run", status: .completed)
            let occurrence = AutomationOccurrence(
                id: "occurrence", automationID: definition.id, definitionRevision: 1, actions: actions,
                trigger: .manual, scheduledAt: .now, status: .needsAttention, currentActionIndex: 1,
                attempts: [completed, .init(actionID: "blocked", status: .needsAttention)]
            )
            try await store.saveAutomation(definition, replacing: nil)
            try await store.saveAutomationOccurrence(occurrence, replacing: nil)
            return Fixture(
                root: root, agentDirectory: projectRoot.appending(path: ".codex/agents"), store: store,
                create: AddMissingAutomationAgentsUseCase(catalog: store, automations: store, createAgent: createAgent),
                completedAttempt: completed, schedule: schedule
            )
        }
    }
}
