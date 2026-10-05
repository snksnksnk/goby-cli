import Foundation

public enum GraphNodeID: Codable, Hashable, Sendable {
    case cluster(ProjectPlatform)
    case project(ProjectID)
    case agent(AgentID, project: ProjectID)
    case codexTask(String, project: ProjectID)
}

public struct GraphPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MapLayoutOverrides: Codable, Equatable, Sendable {
    public let projectOffsets: [ProjectID: GraphPoint]
    public let nodeOffsets: [GraphNodeID: GraphPoint]
    public let preferredProjectPositions: [ProjectID: GraphPoint]
    public let preferredAgentPositionsRelativeToProject: [GraphNodeID: GraphPoint]
    /// Presentation only: hidden agents remain eligible for routing and visible in List.
    public let hiddenAgentTargets: Set<AgentRouteTarget>

    public init(
        projectOffsets: [ProjectID: GraphPoint] = [:],
        nodeOffsets: [GraphNodeID: GraphPoint] = [:],
        preferredProjectPositions: [ProjectID: GraphPoint] = [:],
        preferredAgentPositionsRelativeToProject: [GraphNodeID: GraphPoint] = [:],
        hiddenAgentTargets: Set<AgentRouteTarget> = []
    ) {
        self.projectOffsets = projectOffsets
        self.nodeOffsets = nodeOffsets
        self.preferredProjectPositions = preferredProjectPositions
        self.preferredAgentPositionsRelativeToProject = preferredAgentPositionsRelativeToProject
        self.hiddenAgentTargets = hiddenAgentTargets
    }

    public static let empty = MapLayoutOverrides()

    public var isEmpty: Bool {
        projectOffsets.isEmpty
            && nodeOffsets.isEmpty
            && preferredProjectPositions.isEmpty
            && preferredAgentPositionsRelativeToProject.isEmpty
            && hiddenAgentTargets.isEmpty
    }

    public func isAgentHidden(_ nodeID: GraphNodeID, providerID: AgentProviderID) -> Bool {
        guard case let .agent(agentID, projectID) = nodeID else { return false }
        return hiddenAgentTargets.contains(AgentRouteTarget(
            providerID: providerID, agentID: agentID, projectID: projectID
        ))
    }

    public func settingAgentVisibility(_ target: AgentRouteTarget, isVisible: Bool) -> MapLayoutOverrides {
        var hidden = hiddenAgentTargets
        if isVisible {
            hidden.remove(target)
        } else {
            hidden.insert(target)
        }
        return MapLayoutOverrides(
            projectOffsets: projectOffsets,
            nodeOffsets: nodeOffsets,
            preferredProjectPositions: preferredProjectPositions,
            preferredAgentPositionsRelativeToProject: preferredAgentPositionsRelativeToProject,
            hiddenAgentTargets: hidden
        )
    }

    /// Resetting geometry must not undo the user's visibility choices.
    public func resettingPositions() -> MapLayoutOverrides {
        MapLayoutOverrides(hiddenAgentTargets: hiddenAgentTargets)
    }

    public func projectOffset(for projectID: ProjectID) -> GraphPoint {
        projectOffsets[projectID] ?? .zero
    }

    public func nodeOffset(for nodeID: GraphNodeID) -> GraphPoint {
        nodeOffsets[nodeID] ?? .zero
    }

    public func offset(for nodeID: GraphNodeID) -> GraphPoint {
        switch nodeID {
        case .cluster:
            return .zero
        case let .project(projectID):
            return projectOffset(for: projectID)
        case let .agent(_, projectID):
            return projectOffset(for: projectID).adding(nodeOffset(for: nodeID))
        case let .codexTask(_, projectID):
            return projectOffset(for: projectID)
        }
    }

    public func hasIndividualOverride(for nodeID: GraphNodeID) -> Bool {
        switch nodeID {
        case let .project(projectID):
            projectOffsets[projectID] != nil || preferredProjectPositions[projectID] != nil
        case .agent:
            nodeOffsets[nodeID] != nil || preferredAgentPositionsRelativeToProject[nodeID] != nil
        case .cluster, .codexTask: false
        }
    }

    public func resolvedProjectPosition(
        for projectID: ProjectID,
        automaticPosition: GraphPoint
    ) -> GraphPoint {
        preferredProjectPositions[projectID]
            ?? automaticPosition.adding(projectOffset(for: projectID))
    }

    public func resolvedPosition(
        for nodeID: GraphNodeID,
        automaticPosition: GraphPoint,
        automaticProjectPosition: GraphPoint? = nil
    ) -> GraphPoint {
        switch nodeID {
        case .cluster:
            return automaticPosition
        case let .project(projectID):
            return resolvedProjectPosition(for: projectID, automaticPosition: automaticPosition)
        case let .agent(_, projectID):
            guard let automaticProjectPosition else {
                return automaticPosition.adding(offset(for: nodeID))
            }
            let projectPosition = resolvedProjectPosition(
                for: projectID,
                automaticPosition: automaticProjectPosition
            )
            let relativePosition = preferredAgentPositionsRelativeToProject[nodeID]
                ?? automaticPosition
                    .subtracting(automaticProjectPosition)
                    .adding(nodeOffset(for: nodeID))
            return projectPosition.adding(relativePosition)
        case let .codexTask(_, projectID):
            guard let automaticProjectPosition else {
                return automaticPosition.adding(projectOffset(for: projectID))
            }
            return resolvedProjectPosition(
                for: projectID,
                automaticPosition: automaticProjectPosition
            ).adding(automaticPosition.subtracting(automaticProjectPosition))
        }
    }

    /// Records the actual map coordinate chosen by the user. Agent positions
    /// remain relative to their pinned project so moving a project continues
    /// to move its whole subgraph without tying the result to auto-layout.
    public func preferring(
        _ nodeID: GraphNodeID,
        at position: GraphPoint,
        relativeTo projectPosition: GraphPoint? = nil
    ) -> MapLayoutOverrides {
        guard position.isFinite else { return self }
        var nextProjectOffsets = projectOffsets
        var nextNodeOffsets = nodeOffsets
        var nextProjectPositions = preferredProjectPositions
        var nextAgentPositions = preferredAgentPositionsRelativeToProject

        switch nodeID {
        case let .project(projectID):
            nextProjectOffsets.removeValue(forKey: projectID)
            nextProjectPositions[projectID] = position
        case let .agent(_, projectID):
            guard let projectPosition, projectPosition.isFinite else { return self }
            nextProjectOffsets.removeValue(forKey: projectID)
            nextNodeOffsets.removeValue(forKey: nodeID)
            nextProjectPositions[projectID] = projectPosition
            nextAgentPositions[nodeID] = position.subtracting(projectPosition)
        case .cluster, .codexTask:
            return self
        }

        return MapLayoutOverrides(
            projectOffsets: nextProjectOffsets,
            nodeOffsets: nextNodeOffsets,
            preferredProjectPositions: nextProjectPositions,
            preferredAgentPositionsRelativeToProject: nextAgentPositions,
            hiddenAgentTargets: hiddenAgentTargets
        )
    }

    public func moving(_ nodeID: GraphNodeID, by delta: GraphPoint) -> MapLayoutOverrides {
        guard delta.isFinite, delta != .zero else { return self }
        switch nodeID {
        case let .project(projectID):
            var next = projectOffsets
            let offset = projectOffset(for: projectID).adding(delta)
            guard offset.isFinite else { return self }
            if offset == .zero {
                next.removeValue(forKey: projectID)
            } else {
                next[projectID] = offset
            }
            return MapLayoutOverrides(
                projectOffsets: next,
                nodeOffsets: nodeOffsets,
                preferredProjectPositions: preferredProjectPositions,
                preferredAgentPositionsRelativeToProject: preferredAgentPositionsRelativeToProject,
                hiddenAgentTargets: hiddenAgentTargets
            )
        case .agent:
            var next = nodeOffsets
            let offset = nodeOffset(for: nodeID).adding(delta)
            guard offset.isFinite else { return self }
            if offset == .zero {
                next.removeValue(forKey: nodeID)
            } else {
                next[nodeID] = offset
            }
            return MapLayoutOverrides(
                projectOffsets: projectOffsets,
                nodeOffsets: next,
                preferredProjectPositions: preferredProjectPositions,
                preferredAgentPositionsRelativeToProject: preferredAgentPositionsRelativeToProject,
                hiddenAgentTargets: hiddenAgentTargets
            )
        case .cluster, .codexTask:
            return self
        }
    }

    public func resetting(_ nodeID: GraphNodeID) -> MapLayoutOverrides {
        switch nodeID {
        case let .project(projectID):
            var next = projectOffsets
            var nextPositions = preferredProjectPositions
            next.removeValue(forKey: projectID)
            nextPositions.removeValue(forKey: projectID)
            return MapLayoutOverrides(
                projectOffsets: next,
                nodeOffsets: nodeOffsets,
                preferredProjectPositions: nextPositions,
                preferredAgentPositionsRelativeToProject: preferredAgentPositionsRelativeToProject,
                hiddenAgentTargets: hiddenAgentTargets
            )
        case .agent:
            var next = nodeOffsets
            var nextPositions = preferredAgentPositionsRelativeToProject
            next.removeValue(forKey: nodeID)
            nextPositions.removeValue(forKey: nodeID)
            return MapLayoutOverrides(
                projectOffsets: projectOffsets,
                nodeOffsets: next,
                preferredProjectPositions: preferredProjectPositions,
                preferredAgentPositionsRelativeToProject: nextPositions,
                hiddenAgentTargets: hiddenAgentTargets
            )
        case .cluster, .codexTask:
            return self
        }
    }

    /// Recalculates stored deltas after the automatic graph layout changes so
    /// manually positioned projects and agents stay at the same coordinates.
    public func rebased(
        preservingPositionsFrom previous: GraphLayoutSnapshot,
        to refreshed: GraphLayoutSnapshot
    ) -> MapLayoutOverrides {
        guard !isEmpty, !previous.nodes.isEmpty else { return self }
        let previousPositions = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.id, $0.position) })
        let refreshedPositions = Dictionary(uniqueKeysWithValues: refreshed.nodes.map { ($0.id, $0.position) })

        let retainedProjectPositions = preferredProjectPositions.filter { projectID, position in
            refreshedPositions[.project(projectID)] != nil && position.isFinite
        }
        let retainedAgentPositions = preferredAgentPositionsRelativeToProject.filter { nodeID, position in
            refreshedPositions[nodeID] != nil && position.isFinite
        }

        var rebasedProjectOffsets: [ProjectID: GraphPoint] = [:]
        for (projectID, offset) in projectOffsets where retainedProjectPositions[projectID] == nil {
            let nodeID = GraphNodeID.project(projectID)
            guard let refreshedPosition = refreshedPositions[nodeID] else { continue }
            guard let previousPosition = previousPositions[nodeID] else {
                rebasedProjectOffsets[projectID] = offset
                continue
            }
            let rebased = previousPosition.adding(offset).subtracting(refreshedPosition)
            guard rebased.isFinite, rebased != .zero else { continue }
            rebasedProjectOffsets[projectID] = rebased
        }

        var rebasedNodeOffsets: [GraphNodeID: GraphPoint] = [:]
        for (nodeID, offset) in nodeOffsets where retainedAgentPositions[nodeID] == nil {
            guard case let .agent(_, projectID) = nodeID,
                  let refreshedPosition = refreshedPositions[nodeID],
                  let refreshedProjectPosition = refreshedPositions[.project(projectID)] else { continue }
            guard let previousPosition = previousPositions[nodeID],
                  let previousProjectPosition = previousPositions[.project(projectID)] else {
                rebasedNodeOffsets[nodeID] = offset
                continue
            }
            let preservedPosition = resolvedPosition(
                for: nodeID,
                automaticPosition: previousPosition,
                automaticProjectPosition: previousProjectPosition
            )
            let refreshedResolvedProjectPosition = retainedProjectPositions[projectID]
                ?? refreshedProjectPosition.adding(rebasedProjectOffsets[projectID] ?? .zero)
            let rebased = preservedPosition
                .subtracting(refreshedResolvedProjectPosition)
                .subtracting(refreshedPosition.subtracting(refreshedProjectPosition))
            guard rebased.isFinite, rebased != .zero else { continue }
            rebasedNodeOffsets[nodeID] = rebased
        }

        return MapLayoutOverrides(
            projectOffsets: rebasedProjectOffsets,
            nodeOffsets: rebasedNodeOffsets,
            preferredProjectPositions: retainedProjectPositions,
            preferredAgentPositionsRelativeToProject: retainedAgentPositions,
            hiddenAgentTargets: hiddenAgentTargets
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectOffsets
        case nodeOffsets
        case preferredProjectPositions
        case preferredAgentPositionsRelativeToProject
        case hiddenAgentTargets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectOffsets = try container.decodeIfPresent(
            [ProjectID: GraphPoint].self,
            forKey: .projectOffsets
        ) ?? [:]
        nodeOffsets = try container.decodeIfPresent(
            [GraphNodeID: GraphPoint].self,
            forKey: .nodeOffsets
        ) ?? [:]
        preferredProjectPositions = try container.decodeIfPresent(
            [ProjectID: GraphPoint].self,
            forKey: .preferredProjectPositions
        ) ?? [:]
        hiddenAgentTargets = try container.decodeIfPresent(
            Set<AgentRouteTarget>.self, forKey: .hiddenAgentTargets
        ) ?? []
        preferredAgentPositionsRelativeToProject = try container.decodeIfPresent(
            [GraphNodeID: GraphPoint].self,
            forKey: .preferredAgentPositionsRelativeToProject
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hiddenAgentTargets, forKey: .hiddenAgentTargets)
        try container.encode(projectOffsets, forKey: .projectOffsets)
        try container.encode(nodeOffsets, forKey: .nodeOffsets)
        try container.encode(preferredProjectPositions, forKey: .preferredProjectPositions)
        try container.encode(
            preferredAgentPositionsRelativeToProject,
            forKey: .preferredAgentPositionsRelativeToProject
        )
    }
}

public extension GraphPoint {
    static let zero = GraphPoint(x: 0, y: 0)

    var isFinite: Bool { x.isFinite && y.isFinite }

    func adding(_ other: GraphPoint) -> GraphPoint {
        GraphPoint(x: x + other.x, y: y + other.y)
    }

    func subtracting(_ other: GraphPoint) -> GraphPoint {
        GraphPoint(x: x - other.x, y: y - other.y)
    }
}

public enum GraphNodeKind: Codable, Hashable, Sendable {
    case cluster(ProjectPlatform, projectCount: Int, activeCount: Int, attentionCount: Int)
    case project(LabProject, statusSummary: AgentStatusSummary)
    case agent(AgentProfile, assignment: AgentAssignment?)
    case codexTask(CodexTaskActivity)
}

public struct AgentStatusSummary: Codable, Hashable, Sendable {
    public let counts: [AgentStatus: Int]

    public init(statuses: [AgentStatus]) {
        self.counts = statuses.reduce(into: [:]) { result, status in
            result[status, default: 0] += 1
        }
    }

    public var total: Int { counts.values.reduce(0, +) }

    public func count(_ status: AgentStatus) -> Int {
        counts[status, default: 0]
    }
}

public struct GraphNode: Codable, Hashable, Identifiable, Sendable {
    public let id: GraphNodeID
    public let kind: GraphNodeKind
    public let position: GraphPoint

    public init(id: GraphNodeID, kind: GraphNodeKind, position: GraphPoint) {
        self.id = id
        self.kind = kind
        self.position = position
    }
}

public enum GraphEdgeKind: String, Codable, Hashable, Sendable {
    case assignment
    case activity
    case dependency
    case membership
}

public struct GraphEdge: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let source: GraphNodeID
    public let destination: GraphNodeID
    public let kind: GraphEdgeKind

    public init(id: UUID = UUID(), source: GraphNodeID, destination: GraphNodeID, kind: GraphEdgeKind) {
        self.id = id
        self.source = source
        self.destination = destination
        self.kind = kind
    }
}

public struct GraphLayoutSnapshot: Codable, Equatable, Sendable {
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static let empty = GraphLayoutSnapshot(nodes: [], edges: [])
}
