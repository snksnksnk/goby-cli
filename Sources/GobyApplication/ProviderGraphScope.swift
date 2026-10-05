import GobyDomain

/// The same provider boundary applies to host layouts and projected clients.
/// Projects retain their geography while roles and execution state follow a plane.
public struct ProviderGraphScope: Sendable {
    public let lab: LabSnapshot
    public let assignments: [AgentAssignment]
    public let codexTasks: [CodexTaskActivity]

    public init(
        lab: LabSnapshot,
        assignments: [AgentAssignment],
        codexTasks: [CodexTaskActivity],
        providerID: AgentProviderID?
    ) {
        guard let providerID else {
            self.lab = lab
            self.assignments = assignments
            self.codexTasks = codexTasks
            return
        }
        let bindings = lab.providerBindings.filter { $0.providerID == providerID }
        let boundAgentIDs = Set(bindings.map(\.agentID))
        self.lab = LabSnapshot(
            projects: lab.projects,
            agents: lab.agents.filter { boundAgentIDs.contains($0.id) },
            projectGroups: lab.projectGroups,
            projectProviderConfigurations: lab.projectProviderConfigurations,
            providerBindings: bindings,
            providerCollaborationSets: lab.providerCollaborationSets,
            agentHandoffLinks: lab.agentHandoffLinks,
            handoffs: lab.handoffs
        )
        self.assignments = assignments.filter { $0.providerID == providerID }
        self.codexTasks = providerID == .codex ? codexTasks : []
    }
}
