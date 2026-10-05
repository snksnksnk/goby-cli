import Foundation
import GobyDomain

public struct LoadAutomationsUseCase: Sendable {
    private let repository: any AutomationRepository

    public init(repository: any AutomationRepository) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> AutomationSnapshot {
        try await repository.automationSnapshot()
    }
}

public struct SaveAutomationUseCase: Sendable {
    private let repository: any AutomationRepository
    private let catalog: any LabCatalogRepository

    public init(
        repository: any AutomationRepository,
        catalog: any LabCatalogRepository
    ) {
        self.repository = repository
        self.catalog = catalog
    }

    @discardableResult
    public func callAsFunction(
        _ draft: AutomationDefinition,
        expectedRevision: Int?,
        now: Date = .now
    ) async throws -> AutomationDefinition {
        let lab = try await catalog.snapshot()
        try validate(draft, against: lab)

        let snapshot = try await repository.automationSnapshot()
        let previous = snapshot.definitions.first { $0.id == draft.id }
        guard previous?.revision == expectedRevision else {
            throw GobyApplicationError.automationChanged(draft.id)
        }
        let normalized = AutomationDefinition(
            id: draft.id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: draft.schedule,
            actions: draft.actions.map {
                AutomationAction(
                    id: $0.id,
                    instruction: $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                    target: $0.target
                )
            },
            state: draft.state,
            automaticallyApproveRuntimeRequests: draft.automaticallyApproveRuntimeRequests,
            nextRunAt: draft.state == .active ? draft.schedule.nextDate(after: now) : nil,
            revision: previous.map { $0.revision + 1 } ?? 1,
            createdAt: previous?.createdAt ?? draft.createdAt,
            updatedAt: now
        )
        try await repository.saveAutomation(normalized, replacing: previous)
        return normalized
    }

    private func validate(
        _ automation: AutomationDefinition,
        against lab: LabSnapshot
    ) throws {
        let name = automation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            throw GobyApplicationError.invalidAutomation("enter a name up to 120 characters")
        }
        guard (1...8).contains(automation.actions.count) else {
            throw GobyApplicationError.invalidAutomation("add between 1 and 8 ordered actions")
        }
        guard !automation.automaticallyApproveRuntimeRequests
                || automation.actions.allSatisfy({ $0.target.providerID == .codex }) else {
            throw GobyApplicationError.invalidAutomation(
                "automatic approvals currently require Codex for every action"
            )
        }
        guard Set(automation.actions.map(\.id)).count == automation.actions.count else {
            throw GobyApplicationError.invalidAutomation("each action must have a unique identity")
        }
        guard TimeZone(identifier: automation.schedule.timeZoneIdentifier) != nil else {
            throw GobyApplicationError.invalidAutomation("choose a valid time zone")
        }
        guard (0...23).contains(automation.schedule.cadence.hour),
              (0...59).contains(automation.schedule.cadence.minute) else {
            throw GobyApplicationError.invalidAutomation("choose a valid time")
        }
        if let weekday = automation.schedule.cadence.weekday,
           !(1...7).contains(weekday) {
            throw GobyApplicationError.invalidAutomation("choose a valid weekday")
        }
        guard automation.schedule.nextDate(after: .now) != nil else {
            throw GobyApplicationError.invalidAutomation("the schedule cannot produce a future run")
        }

        let projects = Dictionary(uniqueKeysWithValues: lab.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: lab.agents.map { ($0.id, $0) })
        let providerConfigurations = Dictionary(
            uniqueKeysWithValues: lab.projectProviderConfigurations.map { ($0.projectID, $0) }
        )

        for (offset, action) in automation.actions.enumerated() {
            let instruction = action.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty, instruction.count <= 32_000 else {
                throw GobyApplicationError.invalidAutomation(
                    "action \(offset + 1) needs an instruction up to 32,000 characters"
                )
            }
            guard projects[action.target.projectID] != nil else {
                throw GobyApplicationError.unknownProject(action.target.projectID)
            }
            guard providerConfigurations[action.target.projectID]?.providerIDs.contains(
                action.target.providerID
            ) == true else {
                throw GobyApplicationError.invalidAutomation(
                    "action \(offset + 1) uses a provider that is not linked to its project"
                )
            }

            switch action.target {
            case let .project(providerID, projectID):
                guard !AgentRoutingMatcher.eligibleAgents(
                    for: projectID,
                    providerID: providerID,
                    in: lab
                ).isEmpty else {
                    throw GobyApplicationError.invalidAutomation(
                        "action \(offset + 1) has no available \(providerID.displayName) agent"
                    )
                }
            case let .agent(target):
                guard let agent = agents[target.agentID] else {
                    throw GobyApplicationError.unknownAgent(target.agentID)
                }
                guard agent.isEnabled else {
                    throw GobyApplicationError.agentUnavailable(target.agentID)
                }
                guard AgentRoutingMatcher.agentCanWork(agent, in: target.projectID) else {
                    throw GobyApplicationError.agentOutsideProject(target.agentID, target.projectID)
                }
                guard lab.providerBindings.contains(where: {
                    $0.providerID == target.providerID
                        && $0.agentID == target.agentID
                        && ($0.projectID == nil || $0.projectID == target.projectID)
                        && $0.state == .configured
                }) else {
                    throw GobyApplicationError.missingProviderBinding(
                        agentID: target.agentID,
                        providerID: target.providerID,
                        projectID: target.projectID
                    )
                }
            }
        }
    }
}

public struct SetAutomationStateUseCase: Sendable {
    private let repository: any AutomationRepository

    public init(repository: any AutomationRepository) {
        self.repository = repository
    }

    @discardableResult
    public func callAsFunction(
        id: AutomationID,
        state: AutomationState,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> AutomationDefinition {
        let snapshot = try await repository.automationSnapshot()
        guard let current = snapshot.definitions.first(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAutomation(id)
        }
        guard current.revision == expectedRevision else {
            throw GobyApplicationError.automationChanged(id)
        }
        let updated = AutomationDefinition(
            id: current.id,
            name: current.name,
            schedule: current.schedule,
            actions: current.actions,
            state: state,
            automaticallyApproveRuntimeRequests: current.automaticallyApproveRuntimeRequests,
            nextRunAt: state == .active ? current.schedule.nextDate(after: now) : nil,
            revision: current.revision + 1,
            createdAt: current.createdAt,
            updatedAt: now
        )
        try await repository.saveAutomation(updated, replacing: current)
        return updated
    }
}

public struct DeleteAutomationUseCase: Sendable {
    private let repository: any AutomationRepository

    public init(repository: any AutomationRepository) {
        self.repository = repository
    }

    public func callAsFunction(
        id: AutomationID,
        expectedRevision: Int
    ) async throws {
        let snapshot = try await repository.automationSnapshot()
        guard let current = snapshot.definitions.first(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAutomation(id)
        }
        guard current.revision == expectedRevision else {
            throw GobyApplicationError.automationChanged(id)
        }
        guard !snapshot.occurrences.contains(where: {
            $0.automationID == id && !$0.status.isFinished
        }) else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(id)
        }
        try await repository.removeAutomation(id: id, replacing: current)
    }
}
