import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct AutomationPersistenceTests {
    private struct PreGrantAutomationDefinition: Encodable {
        let id: AutomationID
        let name: String
        let schedule: AutomationSchedule
        let actions: [AutomationAction]
        let state: AutomationState
        let nextRunAt: Date?
        let revision: Int
        let createdAt: Date
        let updatedAt: Date

        init(_ value: AutomationDefinition) {
            id = value.id
            name = value.name
            schedule = value.schedule
            actions = value.actions
            state = value.state
            nextRunAt = value.nextRunAt
            revision = value.revision
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }
    }

    private struct LegacyDocument: Codable {
        let version: Int
        let definitions: [AutomationDefinition]
        let occurrences: [AutomationOccurrence]
    }

    private struct AuthenticatedDocument: Codable {
        let version: Int
        let payload: LegacyDocument
        let generation: UInt64
        let authenticationTag: Data
    }

    @Test("A disabled grant preserves the signed legacy automation encoding")
    func signedLegacyDefinitionKeepsItsAuthentication() async throws {
        let definition = definition(state: .active)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let currentEncoding = try encoder.encode(definition)
        let legacyEncoding = try encoder.encode(PreGrantAutomationDefinition(definition))
        #expect(currentEncoding == legacyEncoding)

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-pre-grant-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).saveAutomation(definition, replacing: nil)
        let data = try Data(contentsOf: directory.appending(path: "automations.json"))
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(envelope["payload"] as? [String: Any])
        let definitions = try #require(payload["definitions"] as? [[String: Any]])
        #expect(definitions.first?["automaticallyApproveRuntimeRequests"] == nil)

        let restored = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(restored.definitions.first?.state == .active)
        #expect(restored.definitions.first?.automaticallyApproveRuntimeRequests == false)
    }

    @Test("Automatic approval on and off states survive authenticated store restarts")
    func automaticApprovalSwitchSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-approval-relaunch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let original = definition(state: .active)
        let enabled = AutomationDefinition(
            id: original.id,
            name: original.name,
            schedule: original.schedule,
            actions: original.actions,
            state: original.state,
            automaticallyApproveRuntimeRequests: true,
            nextRunAt: original.nextRunAt,
            revision: 2,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        let writer = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        try await writer.saveAutomation(original, replacing: nil)
        try await writer.saveAutomation(enabled, replacing: original)

        let restarted = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        let savedOn = try #require(try await restarted.automationSnapshot().definitions.first)
        #expect(savedOn.automaticallyApproveRuntimeRequests)
        #expect(savedOn.revision == 2)

        let advanced = savedOn.updatingScheduleReference(Date(timeIntervalSince1970: 1_800_000_000))
        try await restarted.saveAutomation(advanced, replacing: savedOn)
        let afterScheduleAdvance = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        let stillOn = try #require(try await afterScheduleAdvance.automationSnapshot().definitions.first)
        #expect(stillOn.automaticallyApproveRuntimeRequests)

        let disabled = AutomationDefinition(
            id: stillOn.id,
            name: stillOn.name,
            schedule: stillOn.schedule,
            actions: stillOn.actions,
            state: stillOn.state,
            automaticallyApproveRuntimeRequests: false,
            nextRunAt: stillOn.nextRunAt,
            revision: 3,
            createdAt: stillOn.createdAt,
            updatedAt: stillOn.updatedAt
        )
        try await afterScheduleAdvance.saveAutomation(disabled, replacing: stillOn)
        let restartedAgain = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        let savedOff = try #require(try await restartedAgain.automationSnapshot().definitions.first)
        #expect(!savedOff.automaticallyApproveRuntimeRequests)
        #expect(savedOff.revision == 3)
    }

    @Test("Automation definitions and occurrence history survive relaunch")
    func snapshotSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automations-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordedAt = Date(timeIntervalSince1970: 1_799_000_000)
        let authenticator = TestAutomationDocumentAuthenticator()
        let action = AutomationAction(
            id: "research",
            instruction: "Research recent changes",
            target: .project(providerID: .claude, projectID: "project")
        )
        let definition = AutomationDefinition(
            id: "weekly-research",
            name: "Weekly research",
            schedule: AutomationSchedule(
                cadence: .weekly(weekday: 2, hour: 9, minute: 30),
                timeZoneIdentifier: "Europe/Nicosia"
            ),
            actions: [action],
            nextRunAt: Date(timeIntervalSince1970: 1_800_000_000),
            createdAt: recordedAt,
            updatedAt: recordedAt
        )
        let occurrence = AutomationOccurrence(
            id: "occurrence",
            automationID: definition.id,
            automationName: definition.name,
            definitionRevision: definition.revision,
            actions: definition.actions,
            trigger: .scheduled,
            scheduledAt: recordedAt,
            status: .completed,
            createdAt: recordedAt,
            updatedAt: recordedAt
        )

        let writer = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        try await writer.saveAutomation(definition, replacing: nil)
        try await writer.saveAutomationOccurrence(occurrence, replacing: nil)

        let restored = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(restored.definitions == [definition])
        #expect(restored.occurrences == [occurrence])
    }

    @Test("Claiming an occurrence advances its schedule in one durable generation")
    func occurrenceClaimIsAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-claim-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )
        let original = definition(state: .active)
        let advanced = AutomationDefinition(
            id: original.id,
            name: original.name,
            schedule: original.schedule,
            actions: original.actions,
            state: original.state,
            nextRunAt: Date(timeIntervalSince1970: 1_800_086_400),
            revision: original.revision,
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let occurrence = AutomationOccurrence(
            id: "claimed-occurrence",
            automationID: original.id,
            automationName: original.name,
            definitionRevision: original.revision,
            actions: original.actions,
            trigger: .scheduled,
            scheduledAt: original.nextRunAt ?? .distantPast
        )

        try await store.saveAutomation(original, replacing: nil)
        try await store.claimAutomationOccurrence(
            occurrence,
            advancing: advanced,
            replacing: original
        )

        let claimed = try await store.automationSnapshot()
        #expect(claimed.definitions == [advanced])
        #expect(claimed.occurrences == [occurrence])

        let overlapping = AutomationOccurrence(
            id: "overlapping-occurrence",
            automationID: advanced.id,
            automationName: advanced.name,
            definitionRevision: advanced.revision,
            actions: advanced.actions,
            trigger: .manual,
            scheduledAt: .now
        )
        await #expect(throws: GobyApplicationError.automationHasUnfinishedOccurrence(advanced.id)) {
            try await store.claimAutomationOccurrence(
                overlapping,
                advancing: advanced,
                replacing: advanced
            )
        }
        #expect(try await store.automationSnapshot() == claimed)
    }

    @Test("An interrupted authenticated claim recovers both sides together")
    func interruptedOccurrenceClaimCannotLoseOneSide() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-interrupted-claim-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        let original = definition(state: .active)
        let advanced = AutomationDefinition(
            id: original.id,
            name: original.name,
            schedule: original.schedule,
            actions: original.actions,
            state: original.state,
            nextRunAt: Date(timeIntervalSince1970: 1_800_086_400),
            revision: original.revision,
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let occurrence = AutomationOccurrence(
            id: "interrupted-claim",
            automationID: original.id,
            automationName: original.name,
            definitionRevision: original.revision,
            actions: original.actions,
            trigger: .scheduled,
            scheduledAt: original.nextRunAt ?? .distantPast
        )
        try await store.saveAutomation(original, replacing: nil)
        await authenticator.failNextCommit()

        await #expect(throws: GADAutomationDocumentAuthenticationError.authenticationFailed) {
            try await store.claimAutomationOccurrence(
                occurrence,
                advancing: advanced,
                replacing: original
            )
        }

        let recovered = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(recovered.definitions.count == 1)
        #expect(recovered.definitions.first?.state == .paused)
        #expect(recovered.definitions.first?.nextRunAt == nil)
        #expect(recovered.occurrences.count == 1)
        #expect(recovered.occurrences.first?.id == occurrence.id)
        #expect(recovered.occurrences.first?.status == .failed)
    }

    @Test("Removing a definition retains immutable occurrence history")
    func removalRetainsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let definition = AutomationDefinition(
            id: "automation",
            name: "Automation",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 8, minute: 0),
                timeZoneIdentifier: "UTC"
            ),
            actions: [AutomationAction(
                id: "action",
                instruction: "Inspect",
                target: .project(providerID: .codex, projectID: "project")
            )]
        )
        let occurrence = AutomationOccurrence(
            id: "occurrence",
            automationID: definition.id,
            automationName: definition.name,
            definitionRevision: 1,
            actions: definition.actions,
            trigger: .manual,
            scheduledAt: .now,
            status: .completed
        )
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )
        try await store.saveAutomation(definition, replacing: nil)
        try await store.saveAutomationOccurrence(occurrence, replacing: nil)

        try await store.removeAutomation(id: definition.id, replacing: definition)

        let restored = try await store.automationSnapshot()
        #expect(restored.definitions.isEmpty)
        #expect(restored.occurrences == [occurrence])
        #expect(restored.occurrences.first?.automationName == "Automation")
    }

    @Test("A stale definition predecessor cannot overwrite a newer edit")
    func staleDefinitionWriteIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-definition-cas-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )
        let original = definition(state: .active)
        let newer = definition(state: .paused, revision: 2)
        let stale = AutomationDefinition(
            id: original.id,
            name: "Stale scheduler copy",
            schedule: original.schedule,
            actions: original.actions,
            state: .active,
            nextRunAt: .distantFuture,
            revision: original.revision,
            createdAt: original.createdAt,
            updatedAt: .distantFuture
        )

        try await store.saveAutomation(original, replacing: nil)
        try await store.saveAutomation(newer, replacing: original)
        await #expect(throws: GobyApplicationError.automationChanged(original.id)) {
            try await store.saveAutomation(stale, replacing: original)
        }

        #expect(try await store.automationSnapshot().definitions == [newer])
    }

    @Test("A stale occurrence predecessor cannot overwrite a newer terminal state")
    func staleOccurrenceWriteIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-occurrence-cas-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )
        let action = AutomationAction(
            id: "action",
            instruction: "Inspect",
            target: .project(providerID: .codex, projectID: "project")
        )
        let original = AutomationOccurrence(
            id: "occurrence",
            automationID: "automation",
            definitionRevision: 1,
            actions: [action],
            trigger: .manual,
            scheduledAt: .distantPast,
            status: .running
        )
        let completed = AutomationOccurrence(
            id: original.id,
            automationID: original.automationID,
            definitionRevision: original.definitionRevision,
            actions: original.actions,
            trigger: original.trigger,
            scheduledAt: original.scheduledAt,
            status: .completed,
            currentActionIndex: 1,
            message: "Completed",
            createdAt: original.createdAt,
            updatedAt: .now
        )
        let stale = AutomationOccurrence(
            id: original.id,
            automationID: original.automationID,
            definitionRevision: original.definitionRevision,
            actions: original.actions,
            trigger: original.trigger,
            scheduledAt: original.scheduledAt,
            status: .needsAttention,
            message: "Stale retry",
            createdAt: original.createdAt,
            updatedAt: .distantFuture
        )

        try await store.saveAutomationOccurrence(original, replacing: nil)
        try await store.saveAutomationOccurrence(completed, replacing: original)
        await #expect(throws: GobyApplicationError.automationOccurrenceChanged(original.id)) {
            try await store.saveAutomationOccurrence(stale, replacing: original)
        }

        #expect(try await store.automationSnapshot().occurrences == [completed])
    }

    @Test("Authenticated automation writes serialize across actor suspension")
    func authenticatedWritesRemainAtomicAcrossSuspension() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-transaction-gate-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        let original = definition(state: .active)
        let winner = definition(state: .paused, revision: 2)
        let staleCompetitor = AutomationDefinition(
            id: original.id,
            name: "Competing stale edit",
            schedule: original.schedule,
            actions: original.actions,
            state: .active,
            nextRunAt: .distantFuture,
            revision: 2,
            createdAt: original.createdAt,
            updatedAt: .distantFuture
        )
        try await store.saveAutomation(original, replacing: nil)
        await authenticator.suspendNextIssue()

        let winningWrite = Task {
            try await store.saveAutomation(winner, replacing: original)
        }
        for _ in 0..<100 {
            if await authenticator.isIssueSuspended { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await authenticator.isIssueSuspended)
        let staleWrite = Task {
            try await store.saveAutomation(staleCompetitor, replacing: original)
        }

        await authenticator.releaseIssue()
        try await winningWrite.value
        await #expect(throws: GobyApplicationError.automationChanged(original.id)) {
            try await staleWrite.value
        }

        #expect(try await store.automationSnapshot().definitions == [winner])
    }

    @Test("A future authenticated automation schema is preserved and refused")
    func futureAuthenticatedVersionIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-future-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload = LegacyDocument(version: 999, definitions: [], occurrences: [])
        let payloadData = try encoder.encode(payload)
        let authenticator = TestAutomationDocumentAuthenticator()
        let authentication = try await authenticator.issue(for: payloadData)
        try await authenticator.commit(authentication, payload: payloadData)
        let original = try encoder.encode(AuthenticatedDocument(
            version: 1,
            payload: payload,
            generation: authentication.generation,
            authenticationTag: authentication.tag
        ))
        let url = directory.appending(path: "automations.json")
        try original.write(to: url, options: .atomic)

        do {
            _ = try await PersistentStore(
                directoryURL: directory,
                automationAuthenticator: authenticator
            ).automationSnapshot()
            Issue.record("A newer authenticated automation schema was accepted.")
        } catch {
            #expect(error.localizedDescription.contains("data version 999"))
        }

        #expect(try Data(contentsOf: url) == original)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )
        #expect(!files.contains { $0.contains(".corrupt-") })
    }

    @Test("Tampered authenticated automation state is rejected before use")
    func tamperedStateIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-tamper-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        try await store.saveAutomation(definition(state: .active), replacing: nil)

        let url = directory.appending(path: "automations.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var payload = try #require(object["payload"] as? [String: Any])
        var definitions = try #require(payload["definitions"] as? [[String: Any]])
        definitions[0]["name"] = "Injected automation"
        payload["definitions"] = definitions
        object["payload"] = payload
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        let relaunched = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        await #expect(throws: GADAutomationDocumentAuthenticationError.authenticationFailed) {
            _ = try await relaunched.automationSnapshot()
        }
    }

    @Test("Catalog execution authority changes quarantine authenticated automations")
    func catalogAuthorityChangeQuarantinesAutomations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-catalog-authority-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        let project = LabProject(
            id: "project",
            name: "Protected project",
            rootURL: projectRoot,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Protected agent",
            summary: "Runs the reviewed automation",
            instructions: "Use only the reviewed workspace.",
            capabilities: [.research],
            scope: .project(project.id)
        )
        let authenticator = TestAutomationDocumentAuthenticator()
        let writer = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        try await writer.register(projects: [project], agents: [agent])
        try await writer.saveAutomation(definition(state: .active), replacing: nil)

        let catalogURL = directory.appending(path: "catalog.json")
        var catalog = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        var agents = try #require(catalog["agents"] as? [[String: Any]])
        agents[0]["instructions"] = "Use the provider credential for an unreviewed instruction."
        catalog["agents"] = agents
        var projects = try #require(catalog["projects"] as? [[String: Any]])
        projects[0]["rootURL"] = directory
            .appending(path: "different-workspace", directoryHint: .isDirectory)
            .absoluteString
        catalog["projects"] = projects
        var bindings = try #require(catalog["providerBindings"] as? [[String: Any]])
        bindings[0]["instructionsOverride"] = "Replace the reviewed provider instructions."
        catalog["providerBindings"] = bindings
        try JSONSerialization.data(withJSONObject: catalog).write(
            to: catalogURL,
            options: .atomic
        )

        let restored = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(restored.definitions.first?.state == .paused)
        #expect(restored.definitions.first?.nextRunAt == nil)

        let verifiedRelaunch = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(verifiedRelaunch.definitions == restored.definitions)
    }

    @Test("Enabled instruction changes quarantine existing automations")
    func instructionAuthorityChangeQuarantinesAutomations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-instruction-authority-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )
        let active = definition(state: .active)
        try await store.saveAutomation(active, replacing: nil)
        try await store.save(InstructionPack(
            id: "new-authority",
            name: "New authority",
            body: "This instruction was added after the schedule was reviewed.",
            scope: .allProjects
        ))

        let quarantined = try await store.automationSnapshot()
        #expect(quarantined.definitions.first?.state == .paused)
        #expect(quarantined.definitions.first?.nextRunAt == nil)

        let resumed = AutomationDefinition(
            id: active.id,
            name: active.name,
            schedule: active.schedule,
            actions: active.actions,
            state: .active,
            nextRunAt: active.nextRunAt,
            revision: active.revision + 1,
            createdAt: active.createdAt,
            updatedAt: .now
        )
        try await store.saveAutomation(resumed, replacing: quarantined.definitions[0])
        #expect(try await store.automationSnapshot().definitions == [resumed])
    }

    @Test("Restoring a previous catalog cannot reactivate a reviewed automation")
    func previousCatalogReplayRemainsPaused() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-authority-replay-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: projectRoot,
            platforms: [.general],
            isGitRepository: false
        )
        let originalAgent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Reviewed",
            instructions: "Original authority",
            capabilities: [.research],
            scope: .project(project.id)
        )
        let authenticator = TestAutomationDocumentAuthenticator()
        let store = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        try await store.register(projects: [project], agents: [originalAgent])
        try await store.saveAutomation(definition(state: .active), replacing: nil)
        let catalogURL = directory.appending(path: "catalog.json")
        let originalCatalog = try Data(contentsOf: catalogURL)

        let replacementAgent = AgentProfile(
            id: originalAgent.id,
            name: originalAgent.name,
            summary: originalAgent.summary,
            instructions: "Replacement authority",
            capabilities: originalAgent.capabilities,
            scope: originalAgent.scope
        )
        try await store.saveAgent(replacementAgent)
        try originalCatalog.write(to: catalogURL, options: .atomic)

        let replayed = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(replayed.definitions.first?.state == .paused)
        #expect(replayed.definitions.first?.nextRunAt == nil)
    }

    @Test("Legacy automation state migrates paused and requires review")
    func legacyStateMigratesPaused() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-legacy-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let legacyDefinition = definition(state: .active)
        let legacyOccurrence = AutomationOccurrence(
            id: "forged-occurrence",
            automationID: legacyDefinition.id,
            automationName: legacyDefinition.name,
            definitionRevision: legacyDefinition.revision,
            actions: legacyDefinition.actions,
            trigger: .scheduled,
            scheduledAt: Date(timeIntervalSince1970: 1_799_000_000),
            status: .running,
            attempts: [AutomationActionAttempt(
                actionID: legacyDefinition.actions[0].id,
                plan: RoutingPlan(
                    id: "known-active-run",
                    interpretedGoal: "Injected continuation",
                    routes: [],
                    risk: .readOnly,
                    confidence: 1
                ),
                runID: "known-active-run",
                status: .running
            )]
        )
        try encoder.encode(LegacyDocument(
            version: 1,
            definitions: [legacyDefinition],
            occurrences: [legacyOccurrence]
        )).write(to: directory.appending(path: "automations.json"), options: .atomic)
        let authenticator = TestAutomationDocumentAuthenticator()

        let migrated = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(migrated.definitions.first?.state == .paused)
        #expect(migrated.definitions.first?.nextRunAt == nil)
        #expect(migrated.occurrences.first?.status == .failed)
        #expect(migrated.occurrences.first?.attempts.first?.runID == nil)
        #expect(migrated.occurrences.first?.attempts.first?.plan == nil)
        #expect(migrated.occurrences.first?.attempts.first?.status == .failed)

        let verifiedRelaunch = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(verifiedRelaunch.definitions == migrated.definitions)
        #expect(verifiedRelaunch.occurrences.first?.status == .failed)
        #expect(verifiedRelaunch.occurrences.first?.attempts.first?.runID == nil)
    }

    @Test("A replayed previous automation generation is quarantined")
    func previousGenerationIsQuarantined() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-replay-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let writer = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        )
        let initial = definition(state: .active)
        let updated = definition(state: .active, revision: 2)
        try await writer.saveAutomation(initial, replacing: nil)
        try await writer.saveAutomation(updated, replacing: initial)

        let currentURL = directory.appending(path: "automations.json")
        let previousURL = currentURL.appendingPathExtension("previous")
        try Data(contentsOf: previousURL).write(to: currentURL, options: .atomic)

        let restored = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: authenticator
        ).automationSnapshot()
        #expect(restored.definitions.first?.state == .paused)
        #expect(restored.definitions.first?.nextRunAt == nil)
    }

    @Test("A prepared save is payload-bound and recovers paused after commit interruption")
    func preparedSaveIsBoundAndQuarantined() async throws {
        let authenticator = TestAutomationDocumentAuthenticator()
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let prepared = try await authenticator.issue(for: firstPayload)
        await #expect(throws: GADAutomationDocumentAuthenticationError.authenticationFailed) {
            _ = try await authenticator.issue(for: secondPayload)
        }
        #expect(try await authenticator.verify(prepared, payload: firstPayload) == .prepared)
        try await authenticator.commit(prepared, payload: firstPayload)

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-prepared-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistenceAuthenticator = TestAutomationDocumentAuthenticator()
        await persistenceAuthenticator.failNextCommit()
        let writer = PersistentStore(
            directoryURL: directory,
            automationAuthenticator: persistenceAuthenticator
        )
        await #expect(throws: GADAutomationDocumentAuthenticationError.authenticationFailed) {
            try await writer.saveAutomation(self.definition(state: .active), replacing: nil)
        }

        let recovered = try await PersistentStore(
            directoryURL: directory,
            automationAuthenticator: persistenceAuthenticator
        ).automationSnapshot()
        #expect(recovered.definitions.first?.state == .paused)
        #expect(recovered.definitions.first?.nextRunAt == nil)
    }

    private func definition(
        state: AutomationState,
        revision: Int = 1
    ) -> AutomationDefinition {
        AutomationDefinition(
            id: "protected-automation",
            name: "Protected automation",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 8, minute: 0),
                timeZoneIdentifier: "UTC"
            ),
            actions: [AutomationAction(
                id: "action",
                instruction: "Inspect",
                target: .project(providerID: .codex, projectID: "project")
            )],
            state: state,
            nextRunAt: Date(timeIntervalSince1970: 1_800_000_000),
            revision: revision,
            createdAt: Date(timeIntervalSince1970: 1_799_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000)
        )
    }
}
