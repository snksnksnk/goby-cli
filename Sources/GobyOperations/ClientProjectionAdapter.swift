import Foundation
import GobyApplication
import GobyDomain

/// Reconstitutes the existing desktop presentation model from the bounded,
/// semantic host projection. Placeholder `goby://` URLs are identities only;
/// the local client never receives or dereferences canonical filesystem paths.
struct ClientProjectionAdapter {
    struct Snapshot {
        let lab: LabSnapshot
        let runs: [RunRecord]
        let graph: GraphLayoutSnapshot
        let instructions: [InstructionPack]
        let resources: [SharedResource]
        let approvals: [ProviderApprovalRequest]
        let codexTasks: [CodexTaskActivity]
        let codexAccount: CodexAccountSnapshot?
        let providerAccounts: [ProviderAccountSnapshot]
        let providerTasks: [ProviderTaskActivity]
        let health: SystemHealthSnapshot
        let plan: RoutingPlan?
        let selectedResourceIDs: Set<SharedResourceID>
        let availableProviderIDs: Set<AgentProviderID>
        let codexState: CodexConnectionState
    }

    func adapt(_ projection: DashboardProjection, providerID: AgentProviderID? = nil) -> Snapshot {
        let projects = projection.projects.map { project in
            LabProject(
                id: project.id,
                name: project.name,
                rootURL: identityURL(kind: "project", id: project.id.rawValue),
                platforms: Set(project.platforms),
                frameworks: project.frameworks,
                isGitRepository: project.isGitRepository,
                registeredAt: projection.generatedAt,
                template: project.template
            )
        }
        let agents = projection.agents.map { agent in
            AgentProfile(
                id: agent.id,
                name: agent.name,
                summary: agent.summary,
                capabilities: Set(agent.capabilities),
                scope: scope(agent.scope),
                sourceURL: agent.hasDefinition
                    ? identityURL(kind: "agent", id: agent.id.rawValue)
                    : nil,
                codexRegistrationKey: agent.isActiveInCodex ? agent.id.rawValue : nil,
                isEnabled: agent.isEnabled
            )
        }
        let configurations = projection.projects.map { project in
            ProjectProviderConfiguration(
                projectID: project.id,
                providerIDs: Set(project.providerIDs),
                configuredAt: projection.generatedAt
            )
        }
        let bindings = projection.providerBindings.map { binding in
            ProviderAgentBinding(
                id: binding.id,
                providerID: binding.providerID,
                agentID: binding.agentID,
                projectID: binding.projectID,
                nativeID: binding.id.rawValue,
                capabilities: Set(binding.capabilities),
                state: binding.state,
                instructionsOverride: binding.hasInstructionsOverride ? "[Stored on host]" : nil
            )
        }
        let links = projection.handoffLinks.map { link in
            AgentHandoffLink(
                id: link.id,
                source: endpoint(link.source),
                destination: endpoint(link.destination),
                purpose: link.purpose,
                conditions: link.conditions,
                triggers: Set(link.triggers),
                isEnabled: link.isEnabled,
                createdAt: projection.generatedAt
            )
        }
        let handoffs = projection.handoffs.map { handoff in
            projectedHandoff(handoff, generatedAt: projection.generatedAt)
        }
        let lab = LabSnapshot(
            projects: projects,
            agents: agents,
            projectGroups: projection.projectGroups.map {
                ProjectGroup(id: $0.id, name: $0.name, members: $0.members, createdAt: projection.generatedAt)
            },
            projectProviderConfigurations: configurations,
            providerBindings: bindings,
            agentHandoffLinks: links,
            handoffs: handoffs
        )
        let resources = projection.resources.map { resource in
            SharedResource(
                id: resource.id,
                name: resource.name,
                url: identityURL(kind: "resource", id: resource.id.rawValue),
                access: resource.access,
                isEnabled: resource.isEnabled,
                registeredAt: projection.generatedAt
            )
        }
        let instructions = projection.instructions.map { instruction in
            InstructionPack(
                id: instruction.id,
                name: instruction.name,
                body: "",
                scope: instruction.scope,
                version: instruction.version,
                isEnabled: instruction.isEnabled,
                updatedAt: instruction.updatedAt
            )
        }
        let runs = projection.runs.map { run in
            projectedRun(run, agents: agents, bindings: bindings)
        }
        let accounts = projection.providerAccounts.map { account in
            ProviderAccountSnapshot(
                providerID: account.providerID,
                connectionState: account.connectionState,
                planName: account.planName,
                selectedModel: account.selectedModel,
                availableModels: account.availableModels,
                usage: account.usage.map {
                    ProviderUsageSnapshot(
                        id: $0.id,
                        kind: $0.kind,
                        label: $0.label,
                        value: $0.value,
                        unit: $0.unit,
                        resetsAt: $0.resetsAt,
                        isEstimate: $0.isEstimate
                    )
                },
                observedAt: account.observedAt
            )
        }
        let tasks = projection.providerTasks.map { task in
            ProviderTaskActivity(
                identity: ProviderTaskIdentity(providerID: task.providerID, nativeID: task.id),
                projectID: task.projectID,
                title: task.title,
                summary: task.summary,
                status: task.status,
                updatedAt: task.updatedAt,
                parentTaskIdentity: task.parentTaskID.map {
                    ProviderTaskIdentity(providerID: task.providerID, nativeID: $0)
                },
                agentRole: task.agentRole
            )
        }
        let legacyCodexTasks = projection.codexTasks.map { task in
            CodexTaskActivity(
                id: task.id,
                projectID: task.projectID,
                title: task.title,
                summary: task.summary,
                status: task.status,
                updatedAt: task.updatedAt
            )
        }
        var codexTasksByID = Dictionary(uniqueKeysWithValues: legacyCodexTasks.map { ($0.id, $0) })
        for task in tasks where task.providerID == .codex {
            codexTasksByID[task.identity.nativeID] = CodexTaskActivity(
                id: task.identity.nativeID,
                projectID: task.projectID,
                title: task.title,
                summary: task.summary,
                status: codexStatus(task.status),
                updatedAt: task.updatedAt,
                isSubagent: task.agentRole != nil || task.parentTaskIdentity != nil,
                agentRole: task.agentRole,
                parentThreadID: task.parentTaskIdentity?.nativeID
            )
        }
        let codexTasks = codexTasksByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        let codexAccount = projection.account.map {
            CodexAccountSnapshot(
                authenticated: $0.authenticated,
                displayName: nil,
                planName: $0.planName,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt,
                secondaryUsedPercent: $0.secondaryUsedPercent,
                secondaryResetsAt: $0.secondaryResetsAt
            )
        }
        let approvals = projection.approvals.map { approval in
            ProviderApprovalRequest(
                id: approval.id,
                providerID: approval.providerID,
                assignmentID: approval.assignmentID,
                kind: approval.kind,
                summary: approval.summary,
                details: approval.details,
                canAccept: approval.actions.contains(.allowOnce),
                approvalSessionID: approval.approvalSessionID,
                operationDigest: approval.operationDigest,
                disclosureComplete: approval.disclosureComplete
            )
        }
        let plan = projection.plan.map(projectedPlan)
        let availableProviderIDs = Set(
            projection.projects.flatMap(\.providerIDs)
                + projection.providerAccounts.map(\.providerID)
                + projection.providerBindings.map(\.providerID)
                + [projection.draft.providerID]
        )

        return Snapshot(
            lab: lab,
            runs: runs,
            graph: graph(lab: lab, runs: runs, tasks: codexTasks, providerID: providerID ?? projection.draft.providerID),
            instructions: instructions,
            resources: resources,
            approvals: approvals,
            codexTasks: codexTasks,
            codexAccount: codexAccount,
            providerAccounts: accounts,
            providerTasks: tasks,
            health: SystemHealthSnapshot(
                checks: projection.health.map {
                    HealthCheck(kind: $0.kind, status: $0.status, summary: $0.summary)
                },
                checkedAt: projection.generatedAt
            ),
            plan: plan,
            selectedResourceIDs: Set(projection.plan?.selectedResourceIDs ?? []),
            availableProviderIDs: availableProviderIDs.isEmpty ? [.codex] : availableProviderIDs,
            codexState: codexConnectionState(accounts: accounts),
        )
    }

    private func projectedPlan(_ plan: GADPlanProjection) -> RoutingPlan {
        RoutingPlan(
            id: plan.id,
            interpretedGoal: plan.goal,
            routes: plan.routes.map {
                ProjectRoute(
                    projectID: $0.projectID,
                    providerID: $0.providerID,
                    model: $0.model,
                    agentIDs: $0.agentIDs,
                    providerBindings: $0.providerBindings,
                    reason: $0.reason
                )
            },
            risk: plan.risk,
            confidence: plan.confidence,
            gitOperations: plan.gitOperations.map {
                PlannedGitOperation(
                    id: $0.id,
                    projectID: $0.projectID,
                    kind: $0.kind,
                    branch: $0.branch,
                    remote: $0.remote
                )
            },
            warnings: plan.warnings,
            createdAt: plan.createdAt,
            deliveryPipeline: plan.deliveryPipeline
        )
    }

    private func projectedRun(
        _ run: GADRunProjection,
        agents: [AgentProfile],
        bindings: [ProviderAgentBinding]
    ) -> RunRecord {
        let assignments = run.assignments.map { assignment in
            AgentAssignment(
                id: assignment.id,
                runID: run.id,
                projectID: assignment.projectID,
                agentID: assignment.agentID,
                status: assignment.status,
                currentTask: assignment.currentTask,
                attachments: run.attachments.map(\.attachmentReference),
                progress: assignment.progress,
                statusReason: assignment.statusReason,
                providerID: assignment.providerID,
                providerBindingID: assignment.providerBindingID,
                model: assignment.model,
                providerTaskID: assignment.startIsIndeterminate
                    ? "projected-indeterminate-\(assignment.id.rawValue)"
                    : nil,
                deliveryStageID: assignment.deliveryStageID
            )
        }
        let routes = Dictionary(grouping: assignments, by: {
            ProjectProviderKey(projectID: $0.projectID, providerID: $0.providerID)
        }).map { key, attempts in
            // Stage rework repeats an agent; the route lists each agent once.
            var seenAgentIDs = Set<AgentID>()
            let values = attempts.filter { seenAgentIDs.insert($0.agentID).inserted }
            return ProjectRoute(
                projectID: key.projectID,
                providerID: key.providerID,
                model: values.first?.model,
                agentIDs: values.map(\.agentID),
                providerBindings: values.compactMap { assignment in
                    assignment.providerBindingID.map {
                        ProviderRouteBinding(agentID: assignment.agentID, bindingID: $0)
                    }
                },
                reason: "Approved assignment snapshot"
            )
        }.sorted {
            if $0.projectID != $1.projectID { return $0.projectID.rawValue < $1.projectID.rawValue }
            return $0.providerID < $1.providerID
        }
        let referencedAgentIDs = Set(assignments.map(\.agentID))
        let referencedBindingIDs = Set(assignments.compactMap(\.providerBindingID))
        return RunRecord(
            id: run.id,
            plan: RoutingPlan(
                id: run.id,
                interpretedGoal: run.goal,
                attachments: run.attachments.map(\.attachmentReference),
                routes: routes,
                risk: run.risk,
                confidence: run.confidence,
                gitOperations: run.gitOperations.map {
                    PlannedGitOperation(
                        id: $0.id,
                        projectID: $0.projectID,
                        kind: $0.kind,
                        branch: $0.branch,
                        remote: $0.remote
                    )
                },
                warnings: run.warnings,
                createdAt: run.createdAt,
                deliveryPipeline: run.deliveryPipeline
            ),
            status: run.status,
            assignments: assignments,
            helperTasks: run.helperTasks.map { task in
                ProviderTaskActivity(
                    identity: ProviderTaskIdentity(providerID: task.providerID, nativeID: task.id),
                    projectID: task.projectID,
                    title: task.title,
                    summary: task.summary,
                    status: task.status,
                    updatedAt: task.updatedAt,
                    parentTaskIdentity: task.parentTaskID.map {
                        ProviderTaskIdentity(providerID: task.providerID, nativeID: $0)
                    },
                    agentRole: task.agentRole
                )
            },
            outcome: run.outcome,
            agentSnapshot: agents.filter { referencedAgentIDs.contains($0.id) },
            providerBindingSnapshot: bindings.filter { referencedBindingIDs.contains($0.id) },
            projectSnapshot: run.projectSnapshot.map {
                LabProject(
                    id: $0.id,
                    name: $0.name,
                    rootURL: identityURL(kind: "project", id: $0.id.rawValue),
                    platforms: [],
                    isGitRepository: false
                )
            },
            journal: run.journal.map {
                RunJournalEntry(
                    id: $0.id,
                    kind: $0.kind,
                    message: $0.message,
                    assignmentID: $0.assignmentID,
                    occurredAt: $0.occurredAt
                )
            },
            createdAt: run.createdAt,
            updatedAt: run.updatedAt
        )
    }

    private func projectedHandoff(
        _ handoff: GADHandoffProjection,
        generatedAt: Date
    ) -> HandoffRecord {
        let bundle = HandoffBundle(
            id: handoff.id,
            idempotencyKey: "projected-\(handoff.id.rawValue)",
            runID: handoff.runID,
            linkID: handoff.linkID,
            createdAt: generatedAt,
            source: endpoint(handoff.source),
            destination: endpoint(handoff.destination),
            originalGoal: "",
            purpose: handoff.purpose,
            sourceOutcomeSummary: handoff.sourceOutcomeSummary,
            sourceTrigger: .checkpoint,
            requestedNextAction: handoff.requestedNextAction,
            sourceAssignmentID: handoff.sourceAssignmentID,
            integrityHash: "projected"
        )
        return HandoffRecord(
            bundle: bundle,
            state: handoff.state,
            destinationRunID: handoff.destinationRunID,
            attemptCount: handoff.attemptCount,
            statusReason: handoff.statusReason,
            updatedAt: handoff.updatedAt
        )
    }

    func graph(
        lab: LabSnapshot,
        runs: [RunRecord],
        tasks: [CodexTaskActivity],
        providerID: AgentProviderID? = nil
    ) -> GraphLayoutSnapshot {
        let scope = ProviderGraphScope(
            lab: lab, assignments: runs.flatMap(\.assignments), codexTasks: tasks, providerID: providerID
        )
        let lab = scope.lab
        let assignments = scope.assignments
        let tasks = scope.codexTasks
        guard !lab.projects.isEmpty else { return .empty }
        let tasksByProject = Dictionary(grouping: tasks, by: \.projectID)
        let activityReflection = MapActivityReflectionProjection(
            lab: lab,
            codexTasks: tasks
        )
        let platformGroups = Dictionary(grouping: lab.projects) {
            $0.platforms.sorted { $0.rawValue < $1.rawValue }.first ?? .general
        }
        let platforms = platformGroups.keys.sorted { $0.rawValue < $1.rawValue }
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for (platformIndex, platform) in platforms.enumerated() {
            let clusterAngle = angle(index: platformIndex, count: platforms.count)
            let center = point(radius: 620, angle: clusterAngle)
            let projects = (platformGroups[platform] ?? []).sorted { $0.name < $1.name }
            let platformAssignments = assignments.filter { assignment in
                projects.contains { $0.id == assignment.projectID }
            }
            let platformTasks = projects.flatMap { tasksByProject[$0.id] ?? [] }
            nodes.append(GraphNode(
                id: .cluster(platform),
                kind: .cluster(
                    platform,
                    projectCount: projects.count,
                    activeCount: platformAssignments.filter { $0.status == .working }.count
                        + platformTasks.filter(\.status.isActive).count,
                    attentionCount: platformAssignments.filter { $0.status == .waitingForApproval || $0.status == .failed }.count
                        + platformTasks.filter(\.status.needsAttention).count
                ),
                position: center
            ))
            for (projectIndex, project) in projects.enumerated() {
                let projectAngle = angle(index: projectIndex, count: projects.count)
                let projectPoint = center.adding(point(radius: 210, angle: projectAngle))
                let projectAssignments = assignments.filter { $0.projectID == project.id }
                let projectAgents = lab.agents.filter { agent in
                    switch agent.scope {
                    case .global, .union: true
                    case let .project(id): id == project.id
                    }
                }
                let projectAgentStatuses = projectAgents.map { agent in
                    projectAssignments.first { $0.agentID == agent.id }?.status ?? .available
                }
                nodes.append(GraphNode(
                    id: .project(project.id),
                    kind: .project(
                        project,
                        statusSummary: AgentStatusSummary(statuses: projectAgentStatuses)
                    ),
                    position: projectPoint
                ))
                edges.append(GraphEdge(
                    id: stableUUID("cluster:\(platform.rawValue):project:\(project.id.rawValue)"),
                    source: .cluster(platform),
                    destination: .project(project.id),
                    kind: .membership
                ))
                var agentNodeByID: [AgentID: GraphNodeID] = [:]
                for (agentIndex, agent) in projectAgents.enumerated() {
                    let agentPoint = projectPoint.adding(point(
                        radius: 115,
                        angle: angle(index: agentIndex, count: projectAgents.count)
                    ))
                    let assignment = projectAssignments.first { $0.agentID == agent.id }
                    let nodeID = GraphNodeID.agent(agent.id, project: project.id)
                    agentNodeByID[agent.id] = nodeID
                    nodes.append(GraphNode(id: nodeID, kind: .agent(agent, assignment: assignment), position: agentPoint))
                    edges.append(GraphEdge(
                        id: stableUUID("project:\(project.id.rawValue):agent:\(agent.id.rawValue)"),
                        source: .project(project.id),
                        destination: nodeID,
                        kind: assignment == nil ? .membership : .assignment
                    ))
                }

                let projectTasks = (tasksByProject[project.id] ?? []).sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id < $1.id
                }
                let taskNodeByID = Dictionary(uniqueKeysWithValues: projectTasks.map {
                    ($0.id, GraphNodeID.codexTask($0.id, project: project.id))
                })
                for (taskIndex, task) in projectTasks.enumerated() {
                    let taskPoint = projectPoint.adding(point(
                        radius: 235 + Double(taskIndex / 6) * 92,
                        angle: angle(index: taskIndex, count: min(max(projectTasks.count, 1), 6))
                    ))
                    let taskNodeID = GraphNodeID.codexTask(task.id, project: project.id)
                    nodes.append(GraphNode(id: taskNodeID, kind: .codexTask(task), position: taskPoint))
                    let taskIdentity = ProviderTaskIdentity(providerID: .codex, nativeID: task.id)
                    let parentNodeID: GraphNodeID
                    if let target = activityReflection.agentTargetsByTask[taskIdentity],
                       let agentNodeID = agentNodeByID[target.agentID] {
                        parentNodeID = agentNodeID
                    } else if let parentThreadID = task.parentThreadID,
                              parentThreadID != task.id,
                              let parentTaskNode = taskNodeByID[parentThreadID] {
                        parentNodeID = parentTaskNode
                    } else {
                        parentNodeID = .project(project.id)
                    }
                    edges.append(GraphEdge(
                        id: stableUUID("activity:\(project.id.rawValue):task:\(task.id)"),
                        source: parentNodeID,
                        destination: taskNodeID,
                        kind: .activity
                    ))
                }
            }
        }
        return GraphLayoutSnapshot(nodes: nodes, edges: edges)
    }

    private func codexStatus(_ status: ProviderTaskStatus) -> CodexTaskStatus {
        switch status {
        case .working: .active
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .saved: .idle
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private func endpoint(_ projection: GADHandoffEndpointProjection) -> AgentHandoffEndpoint {
        AgentHandoffEndpoint(
            providerID: projection.providerID,
            bindingID: projection.bindingID,
            agentID: projection.agentID,
            projectID: projection.projectID
        )
    }

    private func scope(_ projection: GADAgentScopeProjection) -> AgentScope {
        switch projection {
        case .global: .global
        case .union: .union
        case let .project(id): .project(id)
        }
    }

    private func codexConnectionState(accounts: [ProviderAccountSnapshot]) -> CodexConnectionState {
        guard let state = accounts.first(where: { $0.providerID == .codex })?.connectionState else {
            return .notChecked
        }
        return switch state {
        case .notChecked: .notChecked
        case let .unavailable(reason): .unavailable(reason)
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(version): .connected(version: version ?? "Available")
        case .needsAuthentication: .needsAuthentication
        case let .failed(message): .failed(message)
        }
    }

    private func identityURL(kind: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = "goby"
        components.host = kind
        components.path = "/\(id)"
        return components.url ?? URL(string: "goby://\(kind)")!
    }

    private func angle(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return (Double(index) / Double(count)) * 2 * .pi - (.pi / 2)
    }

    private func point(radius: Double, angle: Double) -> GraphPoint {
        GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private func stableUUID(_ source: String) -> UUID {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_11
        for byte in source.utf8 {
            first ^= UInt64(byte)
            first &*= 1_099_511_628_211
            second &+= UInt64(byte)
            second &*= 1_099_511_628_211
        }
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: first >> 56), UInt8(truncatingIfNeeded: first >> 48),
            UInt8(truncatingIfNeeded: first >> 40), UInt8(truncatingIfNeeded: first >> 32),
            UInt8(truncatingIfNeeded: first >> 24), UInt8(truncatingIfNeeded: first >> 16),
            UInt8(truncatingIfNeeded: first >> 8), UInt8(truncatingIfNeeded: first),
            UInt8(truncatingIfNeeded: second >> 56), UInt8(truncatingIfNeeded: second >> 48),
            UInt8(truncatingIfNeeded: second >> 40), UInt8(truncatingIfNeeded: second >> 32),
            UInt8(truncatingIfNeeded: second >> 24), UInt8(truncatingIfNeeded: second >> 16),
            UInt8(truncatingIfNeeded: second >> 8), UInt8(truncatingIfNeeded: second)
        ))
    }
}

private struct ProjectProviderKey: Hashable {
    let projectID: ProjectID
    let providerID: AgentProviderID
}
