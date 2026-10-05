import Foundation

/// Live provider activity that can be reflected on an existing project or
/// logical-agent node without turning external provider work into a Goby run.
public struct ReflectedProviderActivity: Hashable, Sendable {
    public let providerID: AgentProviderID
    public let status: AgentStatus
    public let taskCount: Int
    public let latestTaskTitle: String
    public let latestUpdatedAt: Date

    public init(
        providerID: AgentProviderID,
        status: AgentStatus,
        taskCount: Int,
        latestTaskTitle: String,
        latestUpdatedAt: Date
    ) {
        self.providerID = providerID
        self.status = status
        self.taskCount = taskCount
        self.latestTaskTitle = latestTaskTitle
        self.latestUpdatedAt = latestUpdatedAt
    }
}

/// Attributes live provider tasks to the project they belong to and, only
/// when the provider reports an unambiguous role, to the exact logical agent
/// binding. The projection is observational and never creates assignments.
public struct MapActivityReflectionProjection: Equatable, Sendable {
    public let projects: [ProjectID: ReflectedProviderActivity]
    public let agents: [AgentRouteTarget: ReflectedProviderActivity]
    public let agentTargetsByTask: [ProviderTaskIdentity: AgentRouteTarget]

    public init(
        providerID: AgentProviderID,
        lab: LabSnapshot,
        tasks: [ProviderTaskActivity]
    ) {
        let liveTasks = tasks.filter {
            $0.providerID == providerID && Self.reflectedStatus(for: $0.status) != nil
        }
        projects = Dictionary(grouping: liveTasks, by: \.projectID).mapValues {
            Self.activity(providerID: providerID, tasks: $0)
        }

        var targetsByTask: [ProviderTaskIdentity: AgentRouteTarget] = [:]
        for task in tasks where task.providerID == providerID {
            guard let target = Self.unambiguousTarget(
                for: task,
                providerID: providerID,
                lab: lab
            ) else { continue }
            targetsByTask[task.identity] = target
        }
        agentTargetsByTask = targetsByTask
        agents = Dictionary(grouping: liveTasks.compactMap { task in
            targetsByTask[task.identity].map { ($0, task) }
        }, by: { $0.0 }).mapValues { entries in
            Self.activity(providerID: providerID, tasks: entries.map { $0.1 })
        }
    }

    public init(lab: LabSnapshot, codexTasks: [CodexTaskActivity]) {
        self.init(
            providerID: .codex,
            lab: lab,
            tasks: codexTasks.map { task in
                let status: ProviderTaskStatus = switch task.status {
                case .active: .working
                case .waitingForApproval: .waitingForApproval
                case .waitingForInput: .waitingForInput
                case .idle: .saved
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
                return ProviderTaskActivity(
                    identity: ProviderTaskIdentity(providerID: .codex, nativeID: task.id),
                    projectID: task.projectID,
                    title: task.title,
                    summary: task.summary,
                    status: status,
                    updatedAt: task.updatedAt,
                    parentTaskIdentity: task.parentThreadID.map {
                        ProviderTaskIdentity(providerID: .codex, nativeID: $0)
                    },
                    agentRole: task.agentRole
                )
            }
        )
    }

    private static func activity(
        providerID: AgentProviderID,
        tasks: [ProviderTaskActivity]
    ) -> ReflectedProviderActivity {
        let latest = tasks.max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }!
        let status: AgentStatus = tasks.contains {
            reflectedStatus(for: $0.status) == .waitingForApproval
        } ? .waitingForApproval : .working
        return ReflectedProviderActivity(
            providerID: providerID,
            status: status,
            taskCount: tasks.count,
            latestTaskTitle: latest.title,
            latestUpdatedAt: latest.updatedAt
        )
    }

    private static func reflectedStatus(for status: ProviderTaskStatus) -> AgentStatus? {
        switch status {
        case .working:
            .working
        case .waitingForApproval, .waitingForInput:
            .waitingForApproval
        case .saved, .completed, .failed, .cancelled:
            nil
        }
    }

    private static func unambiguousTarget(
        for task: ProviderTaskActivity,
        providerID: AgentProviderID,
        lab: LabSnapshot
    ) -> AgentRouteTarget? {
        guard let agentRole = task.agentRole,
              !agentRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let roleAliases = aliases(for: agentRole)
        guard !roleAliases.isEmpty else { return nil }

        let agentsByID = Dictionary(uniqueKeysWithValues: lab.agents.map { ($0.id, $0) })
        let targets = Set(lab.providerBindings.compactMap { binding -> AgentRouteTarget? in
            guard binding.providerID == providerID,
                  binding.projectID == nil || binding.projectID == task.projectID,
                  let agent = agentsByID[binding.agentID],
                  agentSupportsProject(agent, projectID: task.projectID) else { return nil }
            let knownAliases = aliases(for: agent.id.rawValue)
                .union(aliases(for: agent.name))
                .union(agent.codexRegistrationKey.map(aliases(for:)) ?? [])
                .union(aliases(for: binding.nativeID))
                .union(binding.nativeDefinitionURL.map { aliases(for: $0) } ?? [])
            guard !roleAliases.isDisjoint(with: knownAliases) else { return nil }
            return AgentRouteTarget(
                providerID: providerID,
                agentID: agent.id,
                projectID: task.projectID
            )
        })
        return targets.count == 1 ? targets.first : nil
    }

    private static func agentSupportsProject(
        _ agent: AgentProfile,
        projectID: ProjectID
    ) -> Bool {
        switch agent.scope {
        case .global, .union:
            true
        case let .project(scopedProjectID):
            scopedProjectID == projectID
        }
    }

    private static func aliases(for url: URL) -> Set<String> {
        aliases(for: url.path(percentEncoded: false))
            .union(aliases(for: url.deletingPathExtension().lastPathComponent))
    }

    private static func aliases(for value: String) -> Set<String> {
        var values = [value]
        if value.contains("/") || value.contains("\\") {
            let standardized = value.replacingOccurrences(of: "\\", with: "/")
            let lastComponent = standardized.split(separator: "/").last.map(String.init) ?? value
            values.append(lastComponent)
            values.append((lastComponent as NSString).deletingPathExtension)
        }
        return Set(values.compactMap(normalizedAlias))
    }

    private static func normalizedAlias(_ value: String) -> String? {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalized = String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
