import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct AutomationUseCaseTests {
    @Test("Saving an automation normalizes its content and calculates its next run")
    func saveNormalizesAndSchedules() async throws {
        let repository = AutomationRepositoryStub()
        let catalog = AutomationCatalogStub(snapshot: automationLab)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = AutomationDefinition(
            id: "daily-research",
            name: "  Daily research  ",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "Europe/Nicosia"
            ),
            actions: [AutomationAction(
                id: "research",
                instruction: "  Review the latest evidence  ",
                target: .agent(AgentRouteTarget(
                    providerID: .codex,
                    agentID: "research-agent",
                    projectID: "project"
                ))
            )]
        )

        let saved = try await SaveAutomationUseCase(
            repository: repository,
            catalog: catalog
        )(draft, expectedRevision: nil, now: now)

        #expect(saved.name == "Daily research")
        #expect(saved.actions.first?.instruction == "Review the latest evidence")
        #expect(saved.nextRunAt == saved.schedule.nextDate(after: now))
        #expect(await repository.automationSnapshot().definitions == [saved])
    }

    @Test("An exact target must still have a configured provider binding")
    func rejectsStaleAgentBinding() async {
        let repository = AutomationRepositoryStub()
        let lab = LabSnapshot(
            projects: automationLab.projects,
            agents: automationLab.agents,
            providerBindings: []
        )
        let draft = validDraft()

        await #expect(throws: GobyApplicationError.missingProviderBinding(
            agentID: "research-agent",
            providerID: .codex,
            projectID: "project"
        )) {
            _ = try await SaveAutomationUseCase(
                repository: repository,
                catalog: AutomationCatalogStub(snapshot: lab)
            )(draft, expectedRevision: nil)
        }
    }

    @Test("An all-approval automation cannot silently include a provider without that grant")
    func rejectsNonCodexAutomaticApproval() async {
        let draft = AutomationDefinition(
            id: "mixed-provider",
            name: "Mixed provider",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "UTC"
            ),
            actions: [AutomationAction(
                id: "action",
                instruction: "Improve the project",
                target: .project(providerID: .claude, projectID: "project")
            )],
            automaticallyApproveRuntimeRequests: true
        )
        await #expect(throws: GobyApplicationError.invalidAutomation(
            "automatic approvals currently require Codex for every action"
        )) {
            _ = try await SaveAutomationUseCase(
                repository: AutomationRepositoryStub(),
                catalog: AutomationCatalogStub(snapshot: automationLab)
            )(draft, expectedRevision: nil)
        }
    }

    @Test("Saving rejects an editor revision that is no longer current")
    func rejectsStaleEditorRevision() async {
        let draft = validDraft()
        let newer = AutomationDefinition(
            id: draft.id,
            name: "Newer edit",
            schedule: draft.schedule,
            actions: draft.actions,
            state: .paused,
            revision: draft.revision + 1,
            createdAt: draft.createdAt,
            updatedAt: .now
        )
        let repository = AutomationRepositoryStub(snapshot: AutomationSnapshot(
            definitions: [newer]
        ))

        await #expect(throws: GobyApplicationError.automationChanged(draft.id)) {
            _ = try await SaveAutomationUseCase(
                repository: repository,
                catalog: AutomationCatalogStub(snapshot: automationLab)
            )(draft, expectedRevision: draft.revision)
        }

        #expect(await repository.automationSnapshot().definitions == [newer])
    }

    @Test("Deleting an automation preserves safety while an occurrence is unfinished")
    func rejectsDeleteDuringOccurrence() async throws {
        let draft = validDraft()
        let occurrence = AutomationOccurrence(
            automationID: draft.id,
            definitionRevision: draft.revision,
            actions: draft.actions,
            trigger: .manual,
            scheduledAt: .now,
            status: .running
        )
        let repository = AutomationRepositoryStub(
            snapshot: AutomationSnapshot(definitions: [draft], occurrences: [occurrence])
        )

        await #expect(throws: GobyApplicationError.automationHasUnfinishedOccurrence(draft.id)) {
            try await DeleteAutomationUseCase(repository: repository)(
                id: draft.id,
                expectedRevision: draft.revision
            )
        }
    }

    private func validDraft() -> AutomationDefinition {
        AutomationDefinition(
            id: "daily-research",
            name: "Daily research",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "Europe/Nicosia"
            ),
            actions: [AutomationAction(
                id: "research",
                instruction: "Review the latest evidence",
                target: .agent(AgentRouteTarget(
                    providerID: .codex,
                    agentID: "research-agent",
                    projectID: "project"
                ))
            )]
        )
    }

    private var automationLab: LabSnapshot {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: URL(fileURLWithPath: "/tmp/project"),
            platforms: [.web],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "research-agent",
            name: "Research",
            summary: "Researches changes",
            capabilities: [.research],
            scope: .project(project.id)
        )
        return LabSnapshot(projects: [project], agents: [agent])
    }
}

private actor AutomationRepositoryStub: AutomationRepository {
    private var value: AutomationSnapshot

    init(snapshot: AutomationSnapshot = .empty) {
        value = snapshot
    }

    func automationSnapshot() -> AutomationSnapshot { value }

    func saveAutomation(
        _ automation: AutomationDefinition,
        replacing expected: AutomationDefinition?
    ) throws {
        guard value.definitions.first(where: { $0.id == automation.id }) == expected else {
            throw GobyApplicationError.automationChanged(automation.id)
        }
        var definitions = value.definitions.filter { $0.id != automation.id }
        definitions.append(automation)
        value = AutomationSnapshot(definitions: definitions, occurrences: value.occurrences)
    }

    func removeAutomation(
        id: AutomationID,
        replacing expected: AutomationDefinition
    ) throws {
        guard value.definitions.first(where: { $0.id == id }) == expected else {
            throw GobyApplicationError.automationChanged(id)
        }
        value = AutomationSnapshot(
            definitions: value.definitions.filter { $0.id != id },
            occurrences: value.occurrences
        )
    }

    func saveAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        replacing expected: AutomationOccurrence?
    ) throws {
        guard value.occurrences.first(where: { $0.id == occurrence.id }) == expected else {
            throw GobyApplicationError.automationOccurrenceChanged(occurrence.id)
        }
        var occurrences = value.occurrences.filter { $0.id != occurrence.id }
        occurrences.append(occurrence)
        value = AutomationSnapshot(definitions: value.definitions, occurrences: occurrences)
    }

    func claimAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        advancing automation: AutomationDefinition,
        replacing expectedAutomation: AutomationDefinition
    ) throws {
        guard value.definitions.first(where: { $0.id == expectedAutomation.id })
                == expectedAutomation else {
            throw GobyApplicationError.automationChanged(expectedAutomation.id)
        }
        guard !value.occurrences.contains(where: {
            $0.automationID == expectedAutomation.id && !$0.status.isFinished
        }) else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(expectedAutomation.id)
        }
        var definitions = value.definitions.filter { $0.id != automation.id }
        definitions.append(automation)
        var occurrences = value.occurrences
        occurrences.append(occurrence)
        value = AutomationSnapshot(definitions: definitions, occurrences: occurrences)
    }
}

private actor AutomationCatalogStub: LabCatalogRepository {
    let value: LabSnapshot

    init(snapshot: LabSnapshot) {
        value = snapshot
    }

    func snapshot() -> LabSnapshot { value }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
}
