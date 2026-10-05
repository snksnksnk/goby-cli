import Foundation
import GobyDomain

/// Binds agent creation to the blocked action the user actually saw.
public struct AutomationAgentRecoveryPlan: Codable, Equatable, Sendable {
    public let occurrenceID: AutomationOccurrenceID
    public let actionID: AutomationActionID
    public let definitionRevision: Int
    public let projectID: ProjectID
    public let providerID: AgentProviderID
    public let capabilities: [AgentCapability]

    public var capabilitySummary: String {
        capabilities.map(\.displayName).joined(separator: ", ")
    }
}

public enum AutomationAgentRecoveryPolicy {
    public static func plan(
        for occurrenceID: AutomationOccurrenceID,
        in automations: AutomationSnapshot,
        lab: LabSnapshot
    ) -> AutomationAgentRecoveryPlan? {
        guard let occurrence = automations.occurrences.first(where: { $0.id == occurrenceID }),
              occurrence.status == .needsAttention || occurrence.status == .failed,
              occurrence.actions.indices.contains(occurrence.currentActionIndex),
              let definition = automations.definitions.first(where: { $0.id == occurrence.automationID }),
              definition.revision == occurrence.definitionRevision,
              definition.actions == occurrence.actions else { return nil }
        let action = occurrence.actions[occurrence.currentActionIndex]
        guard case let .project(providerID, projectID) = action.target,
              lab.projects.contains(where: { $0.id == projectID }),
              lab.projectProviderConfigurations.contains(where: {
                  $0.projectID == projectID && $0.providerIDs.contains(providerID)
              }),
              let attempt = occurrence.attempts.last(where: { $0.actionID == action.id }),
              attempt.runID == nil, attempt.plan == nil,
              attempt.status == .needsAttention || attempt.status == .failed else { return nil }
        let missing = AgentRoutingMatcher.missingCapabilities(
            required: AgentRoutingMatcher.inferredCapabilities(from: action.instruction),
            among: AgentRoutingMatcher.eligibleAgents(for: projectID, providerID: providerID, in: lab)
        )
        guard !missing.isEmpty else { return nil }
        return AutomationAgentRecoveryPlan(
            occurrenceID: occurrence.id,
            actionID: action.id,
            definitionRevision: definition.revision,
            projectID: projectID,
            providerID: providerID,
            capabilities: missing.sorted { $0.rawValue < $1.rawValue }
        )
    }
}

/// Serializes the batch, rechecks current authority, and uses the existing
/// recoverable definition writer. It never resumes schedules or starts runs.
public actor AddMissingAutomationAgentsUseCase {
    private let catalog: any LabCatalogRepository
    private let automations: any AutomationRepository
    private let createAgent: CreateAgentUseCase
    private var isCreating = false

    public init(
        catalog: any LabCatalogRepository,
        automations: any AutomationRepository,
        createAgent: CreateAgentUseCase
    ) {
        self.catalog = catalog
        self.automations = automations
        self.createAgent = createAgent
    }

    public func callAsFunction(_ plan: AutomationAgentRecoveryPlan) async throws -> [AgentProfile] {
        guard !isCreating else {
            throw RecoveryError.message("Missing agents are already being added. Wait for that change to finish.")
        }
        guard plan.providerID == .codex else {
            throw RecoveryError.message("Automatic agent creation is currently available for Codex projects only.")
        }
        isCreating = true
        defer { isCreating = false }
        let lab = try await catalog.snapshot()
        guard AutomationAgentRecoveryPolicy.plan(
            for: plan.occurrenceID, in: try await automations.automationSnapshot(), lab: lab
        ) == plan else {
            throw RecoveryError.message("This automation or its missing agents changed. Reopen Resolve to review the current selection.")
        }

        var created: [AgentProfile] = []
        do {
            for capability in plan.capabilities {
                let current = try await catalog.snapshot()
                // A successful earlier attempt or another authorized catalog
                // change may already cover this capability. Never duplicate it.
                let eligible = AgentRoutingMatcher.eligibleAgents(
                    for: plan.projectID, providerID: plan.providerID, in: current
                )
                guard !AgentRoutingMatcher.missingCapabilities(
                    required: [capability], among: eligible
                ).isEmpty else { continue }
                guard current.projectProviderConfigurations.contains(where: {
                    $0.projectID == plan.projectID && $0.providerIDs.contains(plan.providerID)
                }) else {
                    throw RecoveryError.message("The project's provider configuration changed. Review it before adding agents.")
                }
                let baseName = "Automation \(capability.displayName) Specialist"
                let occupied = Set(current.agents.filter {
                    $0.scope == .project(plan.projectID)
                }.map { $0.name.lowercased() })
                var name = baseName
                var suffix = 2
                while occupied.contains(name.lowercased()) {
                    name = "\(baseName) \(suffix)"
                    suffix += 1
                }
                let summary = "Handles \(capability.displayName) work for this project's automations."
                let agent = try await createAgent(
                    name: name,
                    summary: summary,
                    instructions: """
                    You are the project's \(capability.displayName) specialist.
                    Follow the project's instructions and the approved request scope.
                    Inspect relevant evidence, perform focused \(capability.displayName) work, and verify the result with appropriate checks.
                    Report changes, evidence, remaining risks, and any required user decision clearly.
                    Respect permission and Git approvals. Do not expand the scope or access secrets.
                    """,
                    capabilities: [capability],
                    scope: .project(plan.projectID)
                )
                created.append(agent)
            }
            return created
        } catch {
            throw RecoveryError.message(
                "Added \(created.count) of \(plan.capabilities.count) missing agents. \(error.localizedDescription) Successfully added agents were kept; use Add Missing Agents again for the remaining capabilities."
            )
        }
    }

    private enum RecoveryError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case let .message(message): message }
        }
    }
}
