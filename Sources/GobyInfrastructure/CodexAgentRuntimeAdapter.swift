import Foundation
import GobyApplication
import GobyDomain

/// Preserves the existing Codex gateway while exposing it through the shared
/// provider runtime contract. The current orchestrator can migrate to this
/// boundary without changing Codex's protocol implementation.
public actor CodexAgentRuntimeAdapter: AgentRuntimeServing {
    public nonisolated let providerID = AgentProviderID.codex
    private let codex: any CodexServing

    public init(codex: any CodexServing) {
        self.codex = codex
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities([
            .accountInspection,
            .taskDiscovery,
            .agentDiscovery,
            .agentPublication,
            .execution,
            .interruption,
            .resume,
            .activeSteering,
            .approvals,
            .usageReporting,
            .quotaReporting,
            .skills,
            .plugins,
            .mcp,
        ])
    }

    public func connectionState() async -> ProviderConnectionState {
        normalized(await codex.connectionState())
    }

    public func connect() async throws -> ProviderConnectionState {
        normalized(try await codex.connect())
    }

    public func accountSnapshot() async throws -> ProviderAccountSnapshot {
        let account = try await codex.accountSnapshot()
        var usage: [ProviderUsageSnapshot] = []
        if let used = account.usedPercent {
            usage.append(ProviderUsageSnapshot(
                id: "primary",
                kind: .consumedPercentage,
                label: "Primary usage",
                value: used,
                unit: "percent",
                resetsAt: account.resetsAt
            ))
        }
        if let used = account.secondaryUsedPercent {
            usage.append(ProviderUsageSnapshot(
                id: "secondary",
                kind: .consumedPercentage,
                label: "Secondary usage",
                value: used,
                unit: "percent",
                resetsAt: account.secondaryResetsAt
            ))
        }
        let state = normalized(await codex.connectionState())
        return ProviderAccountSnapshot(
            providerID: providerID,
            connectionState: account.authenticated ? state : .needsAuthentication,
            displayName: account.displayName,
            planName: account.planName,
            selectedModel: account.selectedModel,
            availableModels: account.availableModels,
            usage: usage
        )
    }

    public func recentTasks(projects: [LabProject]) async throws -> [ProviderTaskActivity] {
        let roots = try await codex.recentProjectRoots()
        return roots.tasks.map { task in
            ProviderTaskActivity(
                identity: ProviderTaskIdentity(providerID: providerID, nativeID: task.id),
                projectID: task.projectID,
                title: task.title,
                summary: task.summary,
                status: normalized(task.status),
                updatedAt: task.updatedAt,
                parentTaskIdentity: task.parentThreadID.map {
                    ProviderTaskIdentity(providerID: providerID, nativeID: $0)
                },
                agentRole: task.agentRole
            )
        }
    }

    public func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery? {
        try await codex.recover(
            assignment: assignment,
            project: project,
            resources: resources
        )
    }

    public func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        binding: ProviderAgentBinding,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) async throws -> ProviderExecutionHandle {
        guard binding.providerID == providerID else {
            throw AgentRuntimeRegistryError.providerMismatch(
                expected: providerID,
                found: binding.providerID
            )
        }
        let handle = try await codex.start(
            assignment: assignment,
            project: project,
            agent: agent,
            instructions: instructions,
            resources: resources,
            risk: risk
        )
        return ProviderExecutionHandle(
            providerID: providerID,
            taskID: handle.threadID,
            turnID: handle.turnID
        )
    }

    public func interrupt(assignmentID: AssignmentID) async throws {
        try await codex.interrupt(assignmentID: assignmentID)
    }

    public func steer(assignmentID: AssignmentID, text: String) async throws {
        try await codex.steer(assignmentID: assignmentID, text: text)
    }

    public func respond(to approvalID: String, decision: ProviderApprovalDecision) async throws {
        try await respond(to: approvalID, decision: decision, operationDigest: nil)
    }

    public func respond(
        to approvalID: String,
        decision: ProviderApprovalDecision,
        operationDigest: String?
    ) async throws {
        let codexDecision: CodexApprovalDecision = switch decision {
        case .accept: .accept
        case .acceptAlways: throw RememberedCommandApprovalError.unavailable
        case .acceptForSession, .acceptAllForRun: .accept
        case .decline: .decline
        case .cancel: .cancel
        }
        try await codex.respond(
            to: approvalID,
            decision: codexDecision,
            operationDigest: operationDigest
        )
    }

    public func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws {
        guard approval.providerID == providerID else {
            throw AgentRuntimeRegistryError.providerMismatch(
                expected: providerID,
                found: approval.providerID
            )
        }
        let codexDecision: CodexApprovalDecision = switch decision {
        case .accept: .accept
        case .acceptAlways: throw RememberedCommandApprovalError.unavailable
        case .acceptForSession, .acceptAllForRun: .accept
        case .decline: .decline
        case .cancel: .cancel
        }
        try await codex.respond(
            to: approval.id,
            decision: codexDecision,
            operationDigest: approval.operationDigest
        )
    }

    public func events() async -> AsyncStream<ProviderRunEvent> {
        let source = await codex.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in source {
                    continuation.yield(Self.normalized(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func normalized(_ state: CodexConnectionState) -> ProviderConnectionState {
        switch state {
        case .notChecked: .notChecked
        case let .unavailable(reason): .unavailable(reason: reason)
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(version): .connected(version: version)
        case .needsAuthentication: .needsAuthentication
        case let .failed(message): .failed(message: message)
        }
    }

    private func normalized(_ status: CodexTaskStatus) -> ProviderTaskStatus {
        switch status {
        case .active: .working
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .idle: .saved
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private static func normalized(_ event: CodexRunEvent) -> ProviderRunEvent {
        switch event {
        case let .assignmentStarted(id):
            .assignmentStarted(.codex, id)
        case let .progress(id, fraction, message):
            .progress(.codex, id, fraction: fraction, message: message)
        case let .approvalRequired(request):
            .approvalRequired(ProviderApprovalRequest(
                id: request.id,
                providerID: .codex,
                assignmentID: request.assignmentID,
                kind: request.kind,
                summary: request.summary,
                details: request.details,
                canAccept: request.canAccept,
                approvalSessionID: request.approvalSessionID,
                operationDigest: request.operationDigest,
                disclosureComplete: request.disclosureComplete,
                rememberedCommandScope: CodexRememberedCommandScope.scope(for: request)
            ))
        case let .commandExecutionCompleted(id, evidence):
            .commandExecutionCompleted(id, evidence: ProviderCommandExecutionEvidence(
                id: evidence.id,
                providerID: .codex,
                command: evidence.command,
                actionCommands: evidence.actionCommands,
                workingDirectory: evidence.workingDirectory,
                status: evidence.status,
                exitCode: evidence.exitCode,
                durationMilliseconds: evidence.durationMilliseconds,
                source: evidence.source
            ))
        case let .activity(id, step):
            .activity(.codex, id, step: step)
        case let .helperUpdated(id, activity):
            .helperUpdated(id, activity: ProviderTaskActivity(
                identity: ProviderTaskIdentity(providerID: .codex, nativeID: activity.id),
                projectID: activity.projectID,
                title: activity.title,
                summary: activity.summary,
                status: normalized(activity.status),
                updatedAt: activity.updatedAt,
                parentTaskIdentity: activity.parentThreadID.map {
                    ProviderTaskIdentity(providerID: .codex, nativeID: $0)
                },
                agentRole: activity.agentRole
            ))
        case let .assignmentCompleted(id, outcome):
            .assignmentCompleted(.codex, id, outcome: outcome)
        case let .assignmentFailed(id, message):
            .assignmentFailed(.codex, id, message: message)
        }
    }

    private nonisolated static func normalized(_ status: CodexTaskStatus) -> ProviderTaskStatus {
        switch status {
        case .active: .working
        case .waitingForApproval: .waitingForApproval
        case .waitingForInput: .waitingForInput
        case .idle: .saved
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

public enum AgentRuntimeRegistryError: LocalizedError, Equatable, Sendable {
    case providerMismatch(expected: AgentProviderID, found: AgentProviderID)

    public var errorDescription: String? {
        switch self {
        case let .providerMismatch(expected, found):
            "Expected a \(expected.displayName) binding, but received \(found.displayName)."
        }
    }
}
