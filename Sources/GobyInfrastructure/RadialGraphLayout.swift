import Foundation
import GobyApplication
import GobyDomain

public actor RadialGraphLayout: GraphLayoutProviding {
    private static let activityRingCapacity = 4

    private struct AssignmentKey: Hashable {
        let projectID: ProjectID
        let agentID: AgentID
    }

    public init() {}

    public func layout(
        lab: LabSnapshot,
        assignments: [AgentAssignment],
        codexTasks: [CodexTaskActivity] = []
    ) -> GraphLayoutSnapshot {
        let assignmentsByProject = Dictionary(grouping: assignments, by: \.projectID)
        let tasksByProject = Dictionary(grouping: codexTasks, by: \.projectID)
        let activityReflection = MapActivityReflectionProjection(
            lab: lab,
            codexTasks: codexTasks
        )
        let assignmentByPair = Dictionary(
            uniqueKeysWithValues: assignments.map {
                (AssignmentKey(projectID: $0.projectID, agentID: $0.agentID), $0)
            }
        )
        let orderedProjects = lab.projects.sorted { lhs, rhs in
            let lhsPlatform = primaryPlatform(for: lhs)
            let rhsPlatform = primaryPlatform(for: rhs)
            if lhsPlatform != rhsPlatform {
                return lhsPlatform.rawValue < rhsPlatform.rawValue
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        let projectPositions = projectPositions(for: orderedProjects)
        let grouped = Dictionary(grouping: lab.projects) { primaryPlatform(for: $0) }
        let platforms = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []

        for (platformIndex, platform) in platforms.enumerated() {
            let projects = (grouped[platform] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
            let center = platformClusterPosition(
                index: platformIndex,
                count: platforms.count,
                projectCount: orderedProjects.count
            )
            let attachedAssignments = projects.flatMap { assignmentsByProject[$0.id] ?? [] }
            let attachedTasks = projects.flatMap { tasksByProject[$0.id] ?? [] }
            let active = attachedAssignments.filter { $0.status == .working || $0.status == .queued }.count
                + attachedTasks.filter(\.status.isActive).count
            let attention = attachedAssignments.filter { $0.status == .waitingForApproval || $0.status == .failed }.count
                + attachedTasks.filter(\.status.needsAttention).count
            nodes.append(GraphNode(
                id: .cluster(platform),
                kind: .cluster(platform, projectCount: projects.count, activeCount: active, attentionCount: attention),
                position: center
            ))

            for project in projects {
                guard let projectPoint = projectPositions[project.id] else { continue }
                let scopedAgents = scopedAgents(
                    for: project,
                    in: lab,
                    assignmentsByProject: assignmentsByProject
                )
                let statusSummary = AgentStatusSummary(statuses: scopedAgents.map { agent in
                    assignmentByPair[AssignmentKey(projectID: project.id, agentID: agent.id)]?.status ?? .available
                })
                nodes.append(GraphNode(
                    id: .project(project.id),
                    kind: .project(project, statusSummary: statusSummary),
                    position: projectPoint
                ))

                let projectTasks = (tasksByProject[project.id] ?? []).sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                let orderedAgents = scopedAgents.sorted(by: { $0.id.rawValue < $1.id.rawValue })
                var assignmentNodeByTaskID: [String: GraphNodeID] = [:]
                for (agentIndex, agent) in orderedAgents.enumerated() {
                    let agentPoint = activityPoint(index: agentIndex, count: orderedAgents.count, center: projectPoint)
                    let assignment = assignmentByPair[AssignmentKey(projectID: project.id, agentID: agent.id)]
                    let agentNodeID = GraphNodeID.agent(agent.id, project: project.id)
                    nodes.append(GraphNode(
                        id: agentNodeID,
                        kind: .agent(agent, assignment: assignment),
                        position: agentPoint
                    ))
                    edges.append(GraphEdge(source: .project(project.id), destination: agentNodeID, kind: .assignment))
                    if let providerTaskID = assignment?.providerTaskID {
                        assignmentNodeByTaskID[providerTaskID] = agentNodeID
                    }
                }

                let taskNodeByID = Dictionary(uniqueKeysWithValues: projectTasks.map {
                    ($0.id, GraphNodeID.codexTask($0.id, project: project.id))
                })

                for (taskIndex, task) in projectTasks.enumerated() {
                    let taskPoint = activityPoint(
                        index: taskIndex,
                        count: projectTasks.count,
                        center: projectPoint,
                        startingRing: max(
                            1,
                            (orderedAgents.count + Self.activityRingCapacity - 1)
                                / Self.activityRingCapacity
                        )
                    )
                    let taskNodeID = GraphNodeID.codexTask(task.id, project: project.id)
                    nodes.append(GraphNode(
                        id: taskNodeID,
                        kind: .codexTask(task),
                        position: taskPoint
                    ))
                    let taskIdentity = ProviderTaskIdentity(providerID: .codex, nativeID: task.id)
                    let parentNodeID: GraphNodeID = if let target = activityReflection.agentTargetsByTask[taskIdentity] {
                        .agent(target.agentID, project: target.projectID)
                    } else if let parentThreadID = task.parentThreadID,
                                                       parentThreadID != task.id,
                                                       let assignmentNode = assignmentNodeByTaskID[parentThreadID] {
                        assignmentNode
                    } else if let parentThreadID = task.parentThreadID,
                              parentThreadID != task.id,
                              let parentTaskNode = taskNodeByID[parentThreadID] {
                        parentTaskNode
                    } else {
                        .project(project.id)
                    }
                    edges.append(GraphEdge(source: parentNodeID, destination: taskNodeID, kind: .activity))
                }
            }
        }

        let registeredProjectIDs = Set(lab.projects.map(\.id))
        for group in lab.projectGroups {
            let memberIDs = group.projectIDs
                .intersection(registeredProjectIDs)
                .sorted { $0.rawValue < $1.rawValue }
            guard let anchor = memberIDs.first else { continue }
            for memberID in memberIDs.dropFirst() {
                edges.append(GraphEdge(
                    source: .project(anchor),
                    destination: .project(memberID),
                    kind: .membership
                ))
            }
        }
        return GraphLayoutSnapshot(nodes: nodes, edges: edges)
    }

    private func primaryPlatform(for project: LabProject) -> ProjectPlatform {
        let precedence: [ProjectPlatform] = [.web, .macOS, .iOS, .android, .backend, .research, .general]
        return precedence.first(where: project.platforms.contains) ?? .general
    }

    private func projectPositions(for projects: [LabProject]) -> [ProjectID: GraphPoint] {
        guard let onlyProject = projects.first else { return [:] }
        guard projects.count > 1 else {
            return [onlyProject.id: GraphPoint(x: 302, y: 0)]
        }

        let minimumSpacing = 160.0
        let ringSpacing = 168.0
        let maximumRadius = 1_800.0
        let grouped = Dictionary(grouping: projects) { primaryPlatform(for: $0) }
        let platforms = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        let sectorSpan = 2 * Double.pi / Double(max(platforms.count, 1))
        let firstSectorCenter = platforms.count == 1 ? 0 : -Double.pi / 2
        var result: [ProjectID: GraphPoint] = [:]

        for (platformIndex, platform) in platforms.enumerated() {
            let members = (grouped[platform] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
            let sectorCenter = firstSectorCenter + Double(platformIndex) * sectorSpan
            var nextMemberIndex = 0
            var radius = 410.0

            while nextMemberIndex < members.count {
                let capacity = max(1, Int(floor(radius * sectorSpan / minimumSpacing)))
                let ringCount = min(capacity, members.count - nextMemberIndex)
                for ringIndex in 0..<ringCount {
                    let angle = sectorCenter
                        + sectorSpan * ((Double(ringIndex) + 0.5) / Double(ringCount) - 0.5)
                    let project = members[nextMemberIndex + ringIndex]
                    result[project.id] = GraphPoint(
                        x: cos(angle) * radius,
                        y: sin(angle) * radius
                    )
                }
                nextMemberIndex += ringCount
                radius = min(radius + ringSpacing, maximumRadius)
            }
        }
        return result
    }

    private func platformClusterPosition(
        index: Int,
        count: Int,
        projectCount: Int
    ) -> GraphPoint {
        guard projectCount > 1 else { return GraphPoint(x: 302, y: 0) }
        let angle = count == 1
            ? 0
            : -Double.pi / 2 + Double(index) / Double(count) * 2 * Double.pi
        let radius = 330.0
        return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private func activityPoint(
        index: Int,
        count: Int,
        center: GraphPoint,
        startingRing: Int = 0
    ) -> GraphPoint {
        // Children expand into an outward-facing fan rather than surrounding
        // their project on every side. This leaves the Codex-to-project trunk
        // clear and makes each project read as a distinct branch of the lab.
        let ringCapacity = Self.activityRingCapacity
        let localRing = index / ringCapacity
        let ring = startingRing + localRing
        let ringStart = localRing * ringCapacity
        let itemsInRing = min(ringCapacity, count - ringStart)
        let indexInRing = index - ringStart
        // Map children use a stable 198-point-wide base collision envelope at
        // full semantic scale and may grow vertically for two lines of detail.
        // A 276-point first ring and 216-point ring gap keep both adjacent
        // cards and the project hub clear at any fan angle.
        let radius = 276 + Double(ring) * 216
        let outwardAngle = hypot(center.x, center.y) > 1
            ? atan2(center.y, center.x)
            : 0
        let spacing = 0.80
        let span = min(.pi * 0.78, Double(max(itemsInRing - 1, 0)) * spacing)
        let progress = itemsInRing > 1
            ? Double(indexInRing) / Double(itemsInRing - 1)
            : 0.5
        let activityAngle = outwardAngle - span / 2 + span * progress
        return GraphPoint(
            x: center.x + cos(activityAngle) * radius,
            y: center.y + sin(activityAngle) * radius
        )
    }

    private func scopedAgents(
        for project: LabProject,
        in lab: LabSnapshot,
        assignmentsByProject: [ProjectID: [AgentAssignment]]
    ) -> [AgentProfile] {
        lab.agents.filter { agent in
            switch agent.scope {
            case let .project(projectID):
                projectID == project.id
            case .global:
                supports(agent: agent, project: project)
                    || assignmentsByProject[project.id]?.contains(where: { $0.agentID == agent.id }) == true
            case .union:
                true
            }
        }
    }

    private func supports(agent: AgentProfile, project: LabProject) -> Bool {
        if agent.capabilities.contains(.routing) || agent.capabilities.contains(.design) { return true }
        let platformCapabilities: [(ProjectPlatform, AgentCapability)] = [
            (.web, .web), (.macOS, .macOS), (.iOS, .iOS), (.android, .android),
            (.backend, .backend), (.research, .research)
        ]
        return platformCapabilities.contains { platform, capability in
            project.platforms.contains(platform) && agent.capabilities.contains(capability)
        }
    }
}
