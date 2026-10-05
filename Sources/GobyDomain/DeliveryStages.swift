import Foundation

public struct DeliveryStageID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Goby-owned stage vocabulary. The host selects stages per request; users do
/// not author stage graphs, so the order below is the only legal order.
public enum DeliveryStageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case plan
    case implement
    case qualityAssurance
    case stressTest
    case securityTest
    case release

    public var displayName: String {
        switch self {
        case .plan: "Plan"
        case .implement: "Engineer"
        case .qualityAssurance: "QA"
        case .stressTest: "Stress test"
        case .securityTest: "Security test"
        case .release: "Release"
        }
    }

    /// Position in the fixed delivery order.
    public var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// Capabilities a logical role must declare to own this stage. The
    /// implementation stage is matched by the project's platform capability,
    /// which the router resolves per project.
    public var requiredCapabilities: Set<AgentCapability> {
        switch self {
        case .plan: [.research]
        case .implement: []
        case .qualityAssurance, .stressTest: [.testing]
        case .securityTest: [.security]
        case .release: [.release]
        }
    }

    /// Only the implementation stage owns the mutable working copy. Every
    /// other stage inspects the handed-off result.
    public var mutatesWorkingCopy: Bool {
        self == .implement
    }

    /// Stages whose failure can send findings back to implementation.
    public var isVerification: Bool {
        switch self {
        case .qualityAssurance, .stressTest, .securityTest: true
        case .plan, .implement, .release: false
        }
    }

    /// Artifacts this stage hands to the next stage through a handoff bundle.
    public var producedArtifacts: Set<HandoffArtifactKind> {
        switch self {
        case .plan: [.summary, .researchNotes]
        case .implement: [.summary, .patch, .changedFileList]
        case .qualityAssurance, .stressTest, .securityTest: [.summary, .verificationEvidence, .reviewFindings]
        case .release: [.summary]
        }
    }
}

/// One reviewed step of a delivery pipeline, bound to an exact provider-native
/// identity so a display name can never select a different agent.
public struct DeliveryStage: Codable, Hashable, Identifiable, Sendable {
    public let id: DeliveryStageID
    public let kind: DeliveryStageKind
    public let target: AgentHandoffEndpoint
    /// Plain-language explanation of why the host selected this stage and owner.
    public let reason: String
    /// What must be true for the stage to pass and hand off.
    public let passCriteria: String

    public init(
        id: DeliveryStageID = .make(),
        kind: DeliveryStageKind,
        target: AgentHandoffEndpoint,
        reason: String,
        passCriteria: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.reason = reason
        self.passCriteria = passCriteria
    }
}

public enum DeliveryPipelineIssue: Hashable, Sendable {
    case empty
    case outOfOrder(DeliveryStageKind)
    case duplicateStage(DeliveryStageKind, ProjectID)
    case releaseWithoutVerification
}

/// An ordered chain of stages proposed by the host router and disclosed in one
/// plan. Approval of the plan covers the disclosed stage handoffs; push, merge,
/// history rewriting, and deletion still require their own approval.
public struct DeliveryPipeline: Codable, Hashable, Sendable {
    public static let reworkCycleLimit = 0...3
    public static let defaultReworkCycles = 2

    public let stages: [DeliveryStage]
    /// How many times failed verification may return findings to
    /// implementation before the run asks the user.
    public let maximumReworkCycles: Int

    public init(stages: [DeliveryStage], maximumReworkCycles: Int = Self.defaultReworkCycles) {
        self.stages = stages
        self.maximumReworkCycles = Self.clampedReworkCycles(maximumReworkCycles)
    }

    public var includesRelease: Bool {
        stages.contains { $0.kind == .release }
    }

    public var projectIDs: Set<ProjectID> {
        Set(stages.map(\.target.projectID))
    }

    public func stage(after id: DeliveryStageID) -> DeliveryStage? {
        guard let index = stages.firstIndex(where: { $0.id == id }),
              stages.indices.contains(index + 1) else { return nil }
        return stages[index + 1]
    }

    /// The implementation stage that receives findings when a verification
    /// stage fails. Nil means the failure goes to the user, for example in a
    /// verification-only pipeline.
    public func reworkTarget(forFailed id: DeliveryStageID) -> DeliveryStage? {
        guard let index = stages.firstIndex(where: { $0.id == id }),
              stages[index].kind.isVerification else { return nil }
        let projectID = stages[index].target.projectID
        return stages[..<index].last {
            $0.kind == .implement && $0.target.projectID == projectID
        }
    }

    public var issues: [DeliveryPipelineIssue] {
        guard !stages.isEmpty else { return [.empty] }
        var result: [DeliveryPipelineIssue] = []
        var seen = Set<String>()
        for (index, stage) in stages.enumerated() {
            if index > 0, stage.kind.order < stages[index - 1].kind.order {
                result.append(.outOfOrder(stage.kind))
            }
            let key = stage.kind.rawValue + "\u{1f}" + stage.target.projectID.rawValue
            if !seen.insert(key).inserted {
                result.append(.duplicateStage(stage.kind, stage.target.projectID))
            }
        }
        if let releaseIndex = stages.firstIndex(where: { $0.kind == .release }),
           !stages[..<releaseIndex].contains(where: { $0.kind.isVerification }) {
            result.append(.releaseWithoutVerification)
        }
        return result
    }

    public var isValid: Bool { issues.isEmpty }

    /// Keeps only stages whose exact owner remains in the edited routes. A
    /// release left without verification is dropped rather than widened, and
    /// a single remaining stage falls back to ordinary single-step execution.
    public func restricted(to routes: [ProjectRoute]) -> DeliveryPipeline? {
        let targets = Set(routes.flatMap { route in
            route.agentIDs.map {
                AgentRouteTarget(providerID: route.providerID, agentID: $0, projectID: route.projectID)
            }
        })
        var kept = stages.filter {
            targets.contains(AgentRouteTarget(
                providerID: $0.target.providerID,
                agentID: $0.target.agentID,
                projectID: $0.target.projectID
            ))
        }
        if DeliveryPipeline(stages: kept).issues.contains(.releaseWithoutVerification) {
            kept.removeAll { $0.kind == .release }
        }
        guard kept.count > 1 else { return nil }
        return DeliveryPipeline(stages: kept, maximumReworkCycles: maximumReworkCycles)
    }

    private enum CodingKeys: String, CodingKey {
        case stages, maximumReworkCycles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decode([DeliveryStage].self, forKey: .stages)
        maximumReworkCycles = Self.clampedReworkCycles(
            try container.decodeIfPresent(Int.self, forKey: .maximumReworkCycles)
                ?? Self.defaultReworkCycles
        )
    }

    private static func clampedReworkCycles(_ value: Int) -> Int {
        min(max(value, reworkCycleLimit.lowerBound), reworkCycleLimit.upperBound)
    }
}

/// The machine-readable result line every verification stage must end with.
public enum DeliveryStageVerdict: Equatable, Sendable {
    case passed
    case failed
    /// The stage did not report a result. Goby fails closed and asks the user.
    case missing

    public static let marker = "STAGE RESULT:"

    public static func parse(_ outcome: String?) -> DeliveryStageVerdict {
        guard let outcome else { return .missing }
        for line in outcome.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*`_>#-"))
            guard let range = trimmed.range(of: marker, options: [.caseInsensitive, .anchored]) else { continue }
            let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()
            if value.hasPrefix("PASS") { return .passed }
            if value.hasPrefix("FAIL") { return .failed }
        }
        return .missing
    }
}

public enum DeliveryStageState: String, Codable, Hashable, Sendable {
    case pending
    case running
    case passed
    case failed
    case needsAttention

    public var displayName: String {
        switch self {
        case .pending: "Waiting"
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        case .needsAttention: "Needs attention"
        }
    }

    /// SF Symbol so state never depends on color alone.
    public var symbolName: String {
        switch self {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

public struct DeliveryStageProgress: Hashable, Identifiable, Sendable {
    public let stage: DeliveryStage
    public let state: DeliveryStageState
    /// Number of execution attempts, including rework.
    public let attempts: Int
    public var id: DeliveryStageID { stage.id }
}

/// Pure sequencing rules for a staged run. Assignments stay in execution
/// order; rework appends new attempts instead of rewriting history.
public enum DeliveryPipelineSchedule {
    public static func isSuperseded(_ assignment: AgentAssignment, in assignments: [AgentAssignment]) -> Bool {
        guard let stageID = assignment.deliveryStageID,
              let index = assignments.firstIndex(where: { $0.id == assignment.id }) else { return false }
        return assignments[(index + 1)...].contains { $0.deliveryStageID == stageID }
    }

    /// Current attempts only, in execution order.
    public static func activeAssignments(_ assignments: [AgentAssignment]) -> [AgentAssignment] {
        assignments.filter { !isSuperseded($0, in: assignments) }
    }

    public static func latestAttempt(
        for stageID: DeliveryStageID,
        in assignments: [AgentAssignment]
    ) -> AgentAssignment? {
        assignments.last { $0.deliveryStageID == stageID }
    }

    public static func nextAssignment(in assignments: [AgentAssignment]) -> AgentAssignment? {
        activeAssignments(assignments).first { $0.status != .completed }
    }

    public static func isComplete(_ pipeline: DeliveryPipeline, assignments: [AgentAssignment]) -> Bool {
        pipeline.stages.allSatisfy { stage in
            latestAttempt(for: stage.id, in: assignments)?.status == .completed
        }
    }

    public static func reworkCyclesUsed(
        for implementation: DeliveryStage,
        in assignments: [AgentAssignment]
    ) -> Int {
        max(0, assignments.filter { $0.deliveryStageID == implementation.id }.count - 1)
    }

    /// New attempts for a failed verification: the owning implementation
    /// stage, then every verification stage of that project from the first
    /// one after implementation through the failed stage. Nil means the run
    /// must ask the user instead.
    public static func reworkAttempts(
        afterFailed failed: AgentAssignment,
        in pipeline: DeliveryPipeline,
        assignments: [AgentAssignment]
    ) -> [AgentAssignment]? {
        guard let stageID = failed.deliveryStageID,
              let target = pipeline.reworkTarget(forFailed: stageID),
              reworkCyclesUsed(for: target, in: assignments) < pipeline.maximumReworkCycles,
              let targetIndex = pipeline.stages.firstIndex(where: { $0.id == target.id }),
              let failedIndex = pipeline.stages.firstIndex(where: { $0.id == stageID }),
              let implementation = latestAttempt(for: target.id, in: assignments) else { return nil }
        let reverify = pipeline.stages[(targetIndex + 1)...failedIndex].filter {
            $0.kind.isVerification && $0.target.projectID == target.target.projectID
        }
        return [freshAttempt(of: implementation, stage: target)] + reverify.compactMap { stage in
            latestAttempt(for: stage.id, in: assignments).map { freshAttempt(of: $0, stage: stage) }
        }
    }

    public static func progress(
        of pipeline: DeliveryPipeline,
        assignments: [AgentAssignment]
    ) -> [DeliveryStageProgress] {
        pipeline.stages.map { stage in
            let attempts = assignments.filter { $0.deliveryStageID == stage.id }
            let state: DeliveryStageState = switch attempts.last?.status {
            case nil, .available, .queued: .pending
            case .working: .running
            case .waitingForApproval, .paused: .needsAttention
            case .completed: .passed
            case .failed, .cancelled: .failed
            }
            return DeliveryStageProgress(stage: stage, state: state, attempts: attempts.count)
        }
    }

    public static func finalStatus(
        _ pipeline: DeliveryPipeline,
        assignments: [AgentAssignment]
    ) -> RunStatus {
        if isComplete(pipeline, assignments: assignments) { return .completed }
        let active = activeAssignments(assignments)
        if active.contains(where: { $0.status == .paused || $0.status == .waitingForApproval }) {
            return .needsAttention
        }
        if active.contains(where: { $0.status == .failed }) { return .failed }
        // Remaining stages are queued, for example after recovery.
        return .needsAttention
    }

    private static func freshAttempt(of assignment: AgentAssignment, stage: DeliveryStage) -> AgentAssignment {
        AgentAssignment(
            runID: assignment.runID,
            projectID: stage.target.projectID,
            agentID: stage.target.agentID,
            status: .queued,
            currentTask: assignment.currentTask,
            attachments: assignment.attachments,
            workingDirectory: assignment.workingDirectory,
            workingDirectoryIdentity: assignment.workingDirectoryIdentity,
            providerID: stage.target.providerID,
            providerBindingID: stage.target.bindingID,
            model: assignment.model,
            deliveryStageID: stage.id
        )
    }
}

/// Builds the provider-neutral task for one stage from the reviewed goal and
/// the results of earlier stages in the same run.
public enum DeliveryStagePrompt {
    static let priorResultLimit = 3_000

    public static func render(
        stage: DeliveryStage,
        pipeline: DeliveryPipeline,
        goal: String,
        assignments: [AgentAssignment]
    ) -> String {
        var sections = [
            "You are the \(stage.kind.displayName) stage of a Goby delivery pipeline: "
                + pipeline.stages.map(\.kind.displayName).joined(separator: " → ") + ".",
            "Request:\n\(goal)",
            "Your responsibility:\n\(responsibility(for: stage.kind))",
            "Pass criteria:\n\(stage.passCriteria)",
        ]
        let stageIndex = pipeline.stages.firstIndex(where: { $0.id == stage.id }) ?? 0
        let earlier = pipeline.stages[..<stageIndex].compactMap { earlierStage -> String? in
            guard let attempt = DeliveryPipelineSchedule.latestAttempt(for: earlierStage.id, in: assignments),
                  attempt.status == .completed,
                  let result = attempt.statusReason, !result.isEmpty else { return nil }
            return "### \(earlierStage.kind.displayName)\n" + String(result.prefix(priorResultLimit))
        }
        if !earlier.isEmpty {
            sections.append("Results from earlier stages:\n" + earlier.joined(separator: "\n\n"))
        }
        let verificationStageIDs = Set(pipeline.stages.filter(\.kind.isVerification).map(\.id))
        let findings = assignments.last { assignment in
            assignment.status == .failed
                && assignment.deliveryStageID.map(verificationStageIDs.contains) == true
        }?.statusReason
        if stage.kind == .implement, let findings, !findings.isEmpty {
            sections.append(
                "Rework: a verification stage failed. Fix these findings first:\n"
                    + String(findings.prefix(priorResultLimit))
            )
        }
        if stage.kind.isVerification {
            sections.append(
                "End your answer with exactly one line: `\(DeliveryStageVerdict.marker) PASS` or "
                    + "`\(DeliveryStageVerdict.marker) FAIL`. When failing, list each finding above that line."
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private static func responsibility(for kind: DeliveryStageKind) -> String {
        switch kind {
        case .plan:
            "Produce a concise implementation plan: affected files, steps, risks, and tests to add. Do not modify files."
        case .implement:
            "Implement the request in this working copy, following the plan if one is provided. Add or update tests."
        case .qualityAssurance:
            "Verify the implementation: build, run the relevant tests, and review the change for correctness. Do not modify source files."
        case .stressTest:
            "Exercise the change under heavy load, large inputs, and concurrency on the local build only. Report measurements. Do not modify source files."
        case .securityTest:
            "Review and probe the change for vulnerabilities, secret or path leaks, and unsafe input handling. Target only this local working copy and build, never external hosts. Do not modify source files."
        case .release:
            "Prepare release notes and a release-readiness checklist. Do not push, merge, tag, or publish anything."
        }
    }
}
