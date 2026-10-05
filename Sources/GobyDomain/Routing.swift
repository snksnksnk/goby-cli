import Foundation

public enum RouteScope: Codable, Hashable, Sendable {
    case all
    case platform(ProjectPlatform)
    case projects(Set<ProjectID>)
}

public struct AgentRouteTarget: Codable, Hashable, Sendable {
    public let providerID: AgentProviderID
    public let agentID: AgentID
    public let projectID: ProjectID

    public init(
        providerID: AgentProviderID = .codex,
        agentID: AgentID,
        projectID: ProjectID
    ) {
        self.providerID = providerID
        self.agentID = agentID
        self.projectID = projectID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case agentID
        case projectID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        agentID = try container.decode(AgentID.self, forKey: .agentID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
    }
}

public struct RouteRequest: Codable, Hashable, Sendable {
    public let prompt: String
    public let attachments: [PromptAttachment]
    public let scope: RouteScope
    public let providerID: AgentProviderID
    /// An explicit provider-native model for this request. `nil` preserves the
    /// provider's current default instead of guessing a model in Goby.
    public let model: String?
    public let agentTargets: Set<AgentRouteTarget>

    public var agentTarget: AgentRouteTarget? {
        agentTargets.count == 1 ? agentTargets.first : nil
    }

    public init(
        prompt: String,
        attachments: [PromptAttachment] = [],
        scope: RouteScope = .all,
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        agentTargets: Set<AgentRouteTarget> = []
    ) {
        self.prompt = prompt
        self.attachments = attachments
        self.scope = scope
        self.providerID = providerID
        self.model = model
        self.agentTargets = agentTargets
    }

    public init(
        prompt: String,
        attachments: [PromptAttachment] = [],
        scope: RouteScope = .all,
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        agentTarget: AgentRouteTarget?
    ) {
        self.init(
            prompt: prompt,
            attachments: attachments,
            scope: scope,
            providerID: providerID,
            model: model,
            agentTargets: agentTarget.map { Set([$0]) } ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case attachments
        case scope
        case providerID
        case model
        case agentTargets
        case agentTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        attachments = try container.decodeIfPresent([PromptAttachment].self, forKey: .attachments) ?? []
        scope = try container.decode(RouteScope.self, forKey: .scope)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        model = try container.decodeIfPresent(String.self, forKey: .model)
        if let targets = try container.decodeIfPresent(
            Set<AgentRouteTarget>.self,
            forKey: .agentTargets
        ) {
            agentTargets = targets
        } else if let target = try container.decodeIfPresent(
            AgentRouteTarget.self,
            forKey: .agentTarget
        ) {
            agentTargets = [target]
        } else {
            agentTargets = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(scope, forKey: .scope)
        try container.encode(providerID, forKey: .providerID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(agentTargets, forKey: .agentTargets)
    }
}

public enum PlanRisk: String, Codable, CaseIterable, Comparable, Sendable {
    case readOnly
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .readOnly: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: PlanRisk, rhs: PlanRisk) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The same review boundary applies to local and projected plans. A client
/// may skip the plan sheet only for a confident, warning-free read-only route.
public enum PlanAutomaticStartPolicy {
    public static func allows(
        risk: PlanRisk,
        confidence: Double,
        hasGitOperations: Bool,
        hasWarnings: Bool
    ) -> Bool {
        risk == .readOnly && confidence >= 0.8
            && !hasGitOperations && !hasWarnings
    }
}

public enum GitOperationKind: String, Codable, Hashable, Sendable {
    case createWorktree
    case createBranch
    case commit
    case push
    case merge
    case rebase
    case reset
    case tag
    case deleteBranch
    case remoteChange

    public var alwaysRequiresSeparateApproval: Bool {
        switch self {
        case .createWorktree, .createBranch, .commit:
            false
        case .push, .merge, .rebase, .reset, .tag, .deleteBranch, .remoteChange:
            true
        }
    }
}

public struct PlannedGitOperation: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: ProjectID
    public let kind: GitOperationKind
    public let branch: String?
    public let remote: String?

    public init(
        id: UUID = UUID(),
        projectID: ProjectID,
        kind: GitOperationKind,
        branch: String? = nil,
        remote: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.branch = branch
        self.remote = remote
    }
}

public struct ProviderRouteBinding: Codable, Hashable, Sendable {
    public let agentID: AgentID
    public let bindingID: ProviderAgentBindingID

    public init(agentID: AgentID, bindingID: ProviderAgentBindingID) {
        self.agentID = agentID
        self.bindingID = bindingID
    }
}

public struct ProjectRoute: Codable, Hashable, Identifiable, Sendable {
    public let projectID: ProjectID
    public let providerID: AgentProviderID
    public let model: String?
    public let agentIDs: [AgentID]
    /// Exact provider-native identities covered by this reviewed route.
    /// Empty values are accepted only for deterministic legacy migration.
    public let providerBindings: [ProviderRouteBinding]
    public let reason: String
    public var id: ProjectID { projectID }

    public init(
        projectID: ProjectID,
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        agentIDs: [AgentID],
        providerBindings: [ProviderRouteBinding] = [],
        reason: String
    ) {
        self.projectID = projectID
        self.providerID = providerID
        self.model = model
        self.agentIDs = agentIDs
        self.providerBindings = providerBindings
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case providerID
        case model
        case agentIDs
        case providerBindings
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        providerID = try container.decodeIfPresent(
            AgentProviderID.self,
            forKey: .providerID
        ) ?? .codex
        model = try container.decodeIfPresent(String.self, forKey: .model)
        agentIDs = try container.decode([AgentID].self, forKey: .agentIDs)
        providerBindings = try container.decodeIfPresent(
            [ProviderRouteBinding].self,
            forKey: .providerBindings
        ) ?? []
        reason = try container.decode(String.self, forKey: .reason)
    }
}

public struct RoutingPlan: Codable, Hashable, Identifiable, Sendable {
    public let id: RunID
    public let interpretedGoal: String
    public let attachments: [PromptAttachment]
    public let routes: [ProjectRoute]
    public let risk: PlanRisk
    public let confidence: Double
    public let gitOperations: [PlannedGitOperation]
    public let warnings: [String]
    public let createdAt: Date
    /// Ordered stages chosen by the host router. Nil keeps the original
    /// single-step behavior in which every route runs as one stage.
    public let deliveryPipeline: DeliveryPipeline?

    /// Stage continuation is automatic only when disclosed in a reviewed plan,
    /// so a multi-stage pipeline always needs approval.
    public var hasMultiStagePipeline: Bool {
        (deliveryPipeline?.stages.count ?? 0) > 1
    }

    public var requiresApproval: Bool {
        !gitOperations.isEmpty || risk >= .medium || hasMultiStagePipeline
            || deliveryPipeline?.includesRelease == true
    }

    public var canStartAutomatically: Bool {
        PlanAutomaticStartPolicy.allows(
            risk: risk,
            confidence: confidence,
            hasGitOperations: !gitOperations.isEmpty,
            hasWarnings: !warnings.isEmpty
        ) && !hasMultiStagePipeline && deliveryPipeline?.includesRelease != true
    }

    public init(
        id: RunID = .make(),
        interpretedGoal: String,
        attachments: [PromptAttachment] = [],
        routes: [ProjectRoute],
        risk: PlanRisk,
        confidence: Double,
        gitOperations: [PlannedGitOperation] = [],
        warnings: [String] = [],
        createdAt: Date = .now,
        deliveryPipeline: DeliveryPipeline? = nil
    ) {
        self.id = id
        self.interpretedGoal = interpretedGoal
        self.attachments = attachments
        self.routes = routes
        self.risk = risk
        self.confidence = min(max(confidence, 0), 1)
        self.gitOperations = gitOperations
        self.warnings = warnings
        self.createdAt = createdAt
        self.deliveryPipeline = deliveryPipeline?.stages.isEmpty == false ? deliveryPipeline : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, interpretedGoal, attachments, routes, risk, confidence
        case gitOperations, warnings, createdAt, deliveryPipeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RunID.self, forKey: .id)
        interpretedGoal = try container.decode(String.self, forKey: .interpretedGoal)
        attachments = try container.decodeIfPresent(
            [PromptAttachment].self,
            forKey: .attachments
        ) ?? []
        routes = try container.decode([ProjectRoute].self, forKey: .routes)
        risk = try container.decode(PlanRisk.self, forKey: .risk)
        confidence = try container.decode(Double.self, forKey: .confidence)
        gitOperations = try container.decodeIfPresent(
            [PlannedGitOperation].self,
            forKey: .gitOperations
        ) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let pipeline = try container.decodeIfPresent(DeliveryPipeline.self, forKey: .deliveryPipeline)
        deliveryPipeline = pipeline?.stages.isEmpty == false ? pipeline : nil
    }
}

/// Shared interpretation for new plans and legacy-plan recovery. Keeping one
/// rule prevents a saved read-only plan from silently retrying mutation work.
public enum RouteMutationIntent {
    public static func impliesMutation(_ request: String) -> Bool {
        impliesMutation(prompt: request.lowercased())
    }

    static let mutationWords: Set<String> = [
        "add", "adopt", "apply", "change", "create", "edit", "fix", "implement",
        "improve", "migrate", "modify", "refine", "remove", "replace", "update", "write",
        // Git and other unambiguous operations that change files or
        // history. Words common in questions ("release", "format") stay
        // out so read-only questions keep starting without review.
        "commit", "push", "merge", "rebase", "revert", "delete", "rename",
        "refactor", "rewrite", "rollback", "install", "uninstall", "upgrade",
        "downgrade", "bump", "deploy", "publish",
    ]

    /// "commit and push", "commit my changes", "push to git": the request is
    /// only to commit what is already in the project folder, and maybe push
    /// it. Any other change word means the agent has work to do first.
    public static func isCommitOnly(_ request: String) -> Bool {
        let words = Set(tokens(in: request.lowercased()))
        guard words.contains("commit") || words.contains("push") else { return false }
        return words.isDisjoint(with: mutationWords.subtracting(["commit", "push"]))
    }

    public static func requestsPush(_ request: String) -> Bool {
        tokens(in: request.lowercased()).contains("push")
    }

    private static func impliesMutation(prompt: String) -> Bool {
        let mutationWords = Self.mutationWords
        let readOnlyMarkers = [
            "do not change", "don't change", "do not edit", "don't edit",
            "do not modify", "don't modify", "do not write", "don't write",
            "without changing", "without editing", "without modifying", "without writing",
            "read-only", "read only", "inspect only", "report only"
        ]
        let explicitlyReadOnly = readOnlyMarkers.contains { marker in
            var searchStart = prompt.startIndex
            while let range = prompt.range(of: marker, range: searchStart..<prompt.endIndex) {
                if !isLimitedToCurrentPhase(prompt, after: range.upperBound) { return true }
                searchStart = range.upperBound
            }
            return false
        }

        if explicitlyReadOnly {
            let contrastMarkers = [" but ", " except ", " instead "]
            let contrastingSuffixes = contrastMarkers.compactMap { marker -> Substring? in
                guard let range = prompt.range(of: marker, options: .backwards) else { return nil }
                return prompt[range.upperBound...]
            }
            let hasContrastingMutation = contrastingSuffixes.contains { suffix in
                tokens(in: String(suffix)).contains { mutationWords.contains($0) }
            }
            if !hasContrastingMutation { return false }
        }

        if tokens(in: prompt).contains(where: mutationWords.contains) { return true }
        return prompt.contains("self improvement run") || prompt.contains("self-improvement run")
    }

    /// Git steps a run never performs itself; the plan says so instead of
    /// implying they will happen.
    public static func requestedUnsupportedGitOperations(_ request: String) -> [String] {
        let words = Set(tokens(in: request.lowercased()))
        return ["push", "merge", "rebase"].filter(words.contains)
    }

    public static func needsFreshChangePlan(_ plan: RoutingPlan) -> Bool {
        plan.risk == .readOnly && impliesMutation(plan.interpretedGoal)
    }

    private static func tokens(in value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func isLimitedToCurrentPhase(_ prompt: String, after markerEnd: String.Index) -> Bool {
        let followingClause = prompt[markerEnd...]
            .prefix(140)
            .prefix { $0 != "." && $0 != ";" && $0 != "\n" }
        return followingClause.range(
            of: #"\b(?:during|in|for)\s+(?:(?:this|the|current|first|initial|audit|review|discovery)\s+)?(?:phase|cycle|step)\b"#,
            options: .regularExpression
        ) != nil
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approved
    case denied
}

public struct ApprovalReceipt: Codable, Hashable, Identifiable, Sendable {
    public let id: ApprovalID
    public let runID: RunID
    public let decision: ApprovalDecision
    public let operationIDs: Set<UUID>
    public let decidedAt: Date

    public init(
        id: ApprovalID = .make(),
        runID: RunID,
        decision: ApprovalDecision,
        operationIDs: Set<UUID>,
        decidedAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.decision = decision
        self.operationIDs = operationIDs
        self.decidedAt = decidedAt
    }
}
