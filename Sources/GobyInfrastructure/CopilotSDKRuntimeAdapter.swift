import Foundation
import GobyApplication
import GobyDomain

public actor CopilotSDKRuntimeAdapter: AgentRuntimeServing {
    /// Per-assignment count of assistant messages, for stable step ids.
    private var activityMessageCounts: [String: Int] = [:]
    public nonisolated let providerID = AgentProviderID.githubCopilot
    private let transport: JSONRPCProcessTransport
    private let credentialRepository: (any ProviderCredentialRepository)?
    private let integrityBundleURL: URL?
    private let trustPolicy: any ProviderRuntimeTrustPolicy
    private let nodeExecutableURL: URL?
    private let bridgeEntryURL: URL?
    private let baseDirectoryURL: URL?
    private var state = ProviderConnectionState.notChecked
    private var listenerTask: Task<Void, Never>?
    private var latestUsage: [ProviderUsageSnapshot] = []
    private let eventStream: AsyncStream<ProviderRunEvent>
    private let eventContinuation: AsyncStream<ProviderRunEvent>.Continuation

    public init(
        nodeExecutableURL: URL,
        bridgeEntryURL: URL,
        environment: [String: String]? = nil,
        credentialRepository: (any ProviderCredentialRepository)? = nil,
        baseDirectoryURL: URL? = nil,
        integrityBundleURL: URL? = nil,
        trustPolicy: any ProviderRuntimeTrustPolicy = AppProviderRuntimeTrustPolicy(),
        requestTimeout: TimeInterval = 30
    ) {
        transport = JSONRPCProcessTransport(
            executableURL: nodeExecutableURL,
            arguments: [bridgeEntryURL.path(percentEncoded: false)],
            environment: environment,
            requestTimeout: requestTimeout
        )
        self.credentialRepository = credentialRepository
        self.baseDirectoryURL = baseDirectoryURL
        self.integrityBundleURL = integrityBundleURL
        self.trustPolicy = trustPolicy
        self.nodeExecutableURL = nodeExecutableURL
        self.bridgeEntryURL = bridgeEntryURL
        let pair = AsyncStream<ProviderRunEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(500)
        )
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    public init(
        transport: JSONRPCProcessTransport,
        credentialRepository: (any ProviderCredentialRepository)? = nil,
        baseDirectoryURL: URL? = nil
    ) {
        self.transport = transport
        self.credentialRepository = credentialRepository
        self.baseDirectoryURL = baseDirectoryURL
        self.integrityBundleURL = nil
        self.trustPolicy = AppProviderRuntimeTrustPolicy()
        self.nodeExecutableURL = nil
        self.bridgeEntryURL = nil
        let pair = AsyncStream<ProviderRunEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(500)
        )
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    deinit {
        listenerTask?.cancel()
        eventContinuation.finish()
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities([
            .accountInspection,
            .taskDiscovery,
            .execution,
            .interruption,
            .resume,
            .approvals,
            .usageReporting,
            .hooks,
        ])
    }

    public func connectionState() -> ProviderConnectionState {
        state
    }

    public func connect() async throws -> ProviderConnectionState {
        if case .connected = state { return state }
        await transport.stop()
        state = .connecting
        do {
            try validateRuntimeIntegrity()
            try await configureCredentialEnvironment()
            try await transport.start()
            startListeningIfNeeded()
            let value = try await transport.request(
                method: "initialize",
                params: CopilotInitializeRequest(
                    clientInfo: .init(name: "goby-agentic-dashboard", version: "0.2.0-beta.1")
                )
            )
            let response = try decode(CopilotInitializeResponse.self, from: value)
            guard response.providerId == providerID.rawValue,
                  ProviderBridgeProtocol.accepts(response.protocolVersion) else {
                throw CopilotRuntimeError.incompatibleBridge(
                    providerID: response.providerId,
                    protocolVersion: response.protocolVersion
                )
            }
            state = .connected(version: response.helperVersion)
            return state
        } catch {
            await transport.stop()
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    public func accountSnapshot() async throws -> ProviderAccountSnapshot {
        try await ensureConnected()
        let value = try await transport.request(
            method: "account/read",
            params: EmptyParameters()
        )
        let response = try decode(CopilotAccountResponse.self, from: value)
        let reportedState = normalizedAccountState(response)
        if case .needsAuthentication = reportedState {
            state = reportedState
        } else if case .failed = reportedState {
            state = reportedState
        }
        latestUsage = normalizedUsage(response.usage)
        return ProviderAccountSnapshot(
            providerID: providerID,
            connectionState: reportedState,
            displayName: response.login,
            selectedModel: response.selectedModel,
            availableModels: response.availableModels.map(\.id),
            usage: latestUsage,
            observedAt: Self.date(response.observedAt) ?? .now
        )
    }

    public func recentTasks(projects: [LabProject]) async throws -> [ProviderTaskActivity] {
        try await ensureConnected()
        // A project whose reviewed folder identity is missing is left out of
        // read-only activity listing; it must not fail the whole provider.
        let request = CopilotTasksRequest(projects: projects.compactMap { project in
            guard let identity = try? ProviderFileSystemBoundary.directoryIdentity(
                project.fileSystemIdentity,
                label: project.name
            ) else { return nil }
            return .init(
                projectId: project.id.rawValue,
                rootPath: project.rootURL.path(percentEncoded: false),
                rootIdentity: identity
            )
        })
        let value = try await transport.request(method: "tasks/list", params: request, timeout: 60)
        let response = try decode(CopilotTasksResponse.self, from: value)
        return response.tasks.map { task in
            ProviderTaskActivity(
                identity: ProviderTaskIdentity(providerID: providerID, nativeID: task.sessionId),
                projectID: ProjectID(rawValue: task.projectId),
                title: task.title,
                summary: task.summary,
                status: .saved,
                updatedAt: Self.date(task.updatedAt) ?? .distantPast
            )
        }
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
        guard assignment.providerID == providerID, binding.providerID == providerID else {
            throw AgentRuntimeRegistryError.providerMismatch(
                expected: providerID,
                found: binding.providerID
            )
        }
        guard binding.state == .configured else {
            throw CopilotRuntimeError.bindingUnavailable(binding.id, state: binding.state)
        }
        try validateRuntimeIntegrity()
        try await ensureConnected()
        let workingDirectory = assignment.workingDirectory ?? project.rootURL
        let workingDirectoryIdentity = try ProviderFileSystemBoundary.directoryIdentity(
            project.fileSystemIdentity,
            label: project.name
        )
        let attachmentGrants = try ProviderFileSystemBoundary.localAttachments(assignment.attachments)
        let request = CopilotStartRequest(
            assignmentId: assignment.id.rawValue,
            prompt: PromptAttachmentPromptRenderer.render(
                assignment.currentTask,
                attachments: assignment.attachments
            ),
            cwd: workingDirectory.path(percentEncoded: false),
            cwdIdentity: workingDirectoryIdentity,
            agentName: agent.name,
            agentSummary: agent.summary,
            agentInstructions: agent.instructions,
            instructionPacks: instructions.map {
                .init(name: $0.name, version: $0.version, body: $0.body)
            },
            resources: try resources.filter(\.isEnabled).map {
                .init(
                    path: $0.url.path(percentEncoded: false),
                    access: $0.access.rawValue,
                    identity: try ProviderFileSystemBoundary.directoryIdentity(
                        $0.fileSystemIdentity,
                        label: $0.name
                    )
                )
            },
            attachments: attachmentGrants,
            risk: risk.rawValue,
            model: assignment.model
        )
        let value = try await transport.request(
            method: "assignment/start",
            params: request,
            timeout: 60
        )
        let response = try decode(CopilotStartResponse.self, from: value)
        return ProviderExecutionHandle(
            providerID: providerID,
            taskID: response.taskId,
            turnID: response.turnId
        )
    }

    public func interrupt(assignmentID: AssignmentID) async throws {
        try await ensureConnected()
        _ = try await transport.request(
            method: "assignment/interrupt",
            params: CopilotInterruptRequest(assignmentId: assignmentID.rawValue)
        )
    }

    public func respond(to approvalID: String, decision: ProviderApprovalDecision) async throws {
        try await respond(to: approvalID, decision: decision, operationDigest: nil)
    }

    public func respond(
        to approvalID: String,
        decision: ProviderApprovalDecision,
        operationDigest: String?
    ) async throws {
        try await ensureConnected()
        let boundedDecision: ProviderApprovalDecision = switch decision {
        case .acceptAlways: throw RememberedCommandApprovalError.unavailable
        case .acceptForSession, .acceptAllForRun: .accept
        case .accept, .decline, .cancel: decision
        }
        _ = try await transport.request(
            method: "approval/respond",
            params: CopilotApprovalResponseRequest(
                approvalId: approvalID,
                assignmentId: nil,
                decision: boundedDecision.rawValue,
                operationDigest: operationDigest
            )
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
        try await ensureConnected()
        let boundedDecision: ProviderApprovalDecision = switch decision {
        case .acceptAlways: throw RememberedCommandApprovalError.unavailable
        case .acceptForSession, .acceptAllForRun: .accept
        case .accept, .decline, .cancel: decision
        }
        _ = try await transport.request(
            method: "approval/respond",
            params: CopilotApprovalResponseRequest(
                approvalId: approval.id,
                assignmentId: approval.assignmentID.rawValue,
                decision: boundedDecision.rawValue,
                operationDigest: approval.operationDigest
            )
        )
    }

    public func events() -> AsyncStream<ProviderRunEvent> {
        eventStream
    }

    public func shutdown() async {
        if case .connected = state {
            _ = try? await transport.request(
                method: "shutdown",
                params: EmptyParameters(),
                timeout: 5
            )
        }
        await transport.stop()
        listenerTask?.cancel()
        listenerTask = nil
        state = .disconnected
    }

    public func disconnect() async {
        await shutdown()
    }

    private func ensureConnected() async throws {
        if case .connected = state { return }
        _ = try await connect()
    }

    private func configureCredentialEnvironment() async throws {
        var environment = ProviderProcessEnvironment.sanitized(ProcessInfo.processInfo.environment)
        // Agent shells run project checks exactly as written; supply a JDK path
        // that only a login shell could otherwise find.
        environment.merge(DeveloperToolchainEnvironment.variables()) { current, _ in current }
        if let storedCredential = try await credentialRepository?.credential(for: providerID) {
            environment["GOBY_COPILOT_GITHUB_TOKEN"] = storedCredential
        }
        if let baseDirectoryURL {
            environment["GOBY_COPILOT_HOME"] = baseDirectoryURL.path(percentEncoded: false)
        }
        try await transport.setEnvironment(environment)
    }

    private func validateRuntimeIntegrity() throws {
        if let integrityBundleURL {
            try trustPolicy.validateProviderRuntime(
                bundleURL: integrityBundleURL,
                runtimeURLs: [nodeExecutableURL, bridgeEntryURL].compactMap { $0 }
            )
        }
    }

    private func startListeningIfNeeded() {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self, transport] in
            let notifications = await transport.notifications()
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                await self?.receive(notification)
            }
        }
    }

    private func receive(_ notification: IncomingJSONRPCMessage) {
        do {
            switch notification.method {
            case "assignment/started":
                let payload = try decode(CopilotAssignmentStarted.self, from: notification.params)
                eventContinuation.yield(.assignmentStarted(providerID, .init(rawValue: payload.assignmentId)))
            case "assignment/progress":
                let payload = try decode(CopilotAssignmentProgress.self, from: notification.params)
                eventContinuation.yield(.progress(
                    providerID,
                    .init(rawValue: payload.assignmentId),
                    fraction: payload.fraction,
                    message: payload.message
                ))
                let sequence = activityMessageCounts[payload.assignmentId, default: 0] + 1
                activityMessageCounts[payload.assignmentId] = sequence
                if let step = BridgedRunActivity.messageStep(
                    assignmentID: .init(rawValue: payload.assignmentId),
                    text: payload.message,
                    sequence: sequence
                ) {
                    eventContinuation.yield(.activity(providerID, step.assignmentID, step: step))
                }
            case "approval/required":
                let payload = try decode(CopilotApprovalRequired.self, from: notification.params)
                let bindingComplete = payload.disclosureComplete == true
                    && Self.isValidOperationDigest(payload.operationDigest)
                eventContinuation.yield(.approvalRequired(ProviderApprovalRequest(
                    id: payload.approvalId,
                    providerID: providerID,
                    assignmentID: .init(rawValue: payload.assignmentId),
                    kind: payload.kind,
                    summary: payload.summary,
                    details: payload.details,
                    canAccept: payload.canAccept && bindingComplete,
                    approvalSessionID: payload.approvalSessionId.map { .init(rawValue: $0) },
                    operationDigest: payload.operationDigest,
                    disclosureComplete: bindingComplete
                )))
            case "command/completed":
                let payload = try decode(CopilotCommandCompleted.self, from: notification.params)
                let assignmentID = AssignmentID(rawValue: payload.assignmentId)
                eventContinuation.yield(.activity(providerID, assignmentID, step: BridgedRunActivity.toolStep(
                    assignmentID: assignmentID,
                    evidenceID: payload.evidenceId,
                    command: payload.command,
                    actionCommands: payload.actionCommands,
                    succeeded: payload.status == .completed && (payload.exitCode ?? 0) == 0,
                    exitCode: payload.exitCode,
                    output: payload.outputSummary
                )))
                eventContinuation.yield(.commandExecutionCompleted(
                    assignmentID,
                    evidence: ProviderCommandExecutionEvidence(
                        id: payload.evidenceId,
                        providerID: providerID,
                        command: payload.command,
                        actionCommands: payload.actionCommands,
                        workingDirectory: URL(fileURLWithPath: payload.workingDirectory),
                        status: payload.status,
                        exitCode: payload.exitCode,
                        durationMilliseconds: payload.durationMilliseconds,
                        source: payload.source
                    )
                ))
            case "usage/updated":
                let payload = try decode(CopilotUsageUpdated.self, from: notification.params)
                latestUsage = normalizedUsage(payload)
            case "assignment/completed":
                let payload = try decode(CopilotAssignmentCompleted.self, from: notification.params)
                eventContinuation.yield(.assignmentCompleted(
                    providerID,
                    .init(rawValue: payload.assignmentId),
                    outcome: payload.outcome
                ))
            case "assignment/failed":
                let payload = try decode(CopilotAssignmentFailed.self, from: notification.params)
                eventContinuation.yield(.assignmentFailed(
                    providerID,
                    .init(rawValue: payload.assignmentId),
                    message: payload.message
                ))
            case "goby/connectionClosed":
                state = .failed(message: "GitHub Copilot SDK bridge closed unexpectedly.")
            case "goby/transportError":
                state = .failed(message: notification.params?.stringValue ?? "Copilot bridge protocol error.")
            default:
                break
            }
        } catch {
            state = .failed(message: "Copilot bridge sent an invalid \(notification.method ?? "notification"): \(error.localizedDescription)")
        }
    }

    private static func isValidOperationDigest(_ digest: String?) -> Bool {
        guard let digest, digest.count == 64 else { return false }
        return digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private func normalizedAccountState(_ response: CopilotAccountResponse) -> ProviderConnectionState {
        switch response.connectionState {
        case "connected":
            .connected(version: response.runtimeVersion)
        case "needsAuthentication":
            .needsAuthentication
        case "failed":
            .failed(message: response.statusMessage ?? "GitHub Copilot could not verify the configured account.")
        case "notChecked":
            response.credentialConfigured ? .connected(version: response.runtimeVersion) : .notChecked
        default:
            state
        }
    }

    private func normalizedUsage(_ usage: CopilotUsagePayload) -> [ProviderUsageSnapshot] {
        var result: [ProviderUsageSnapshot] = []
        if let value = usage.nanoAIU {
            result.append(.init(
                id: "nano-aiu",
                kind: .estimatedCost,
                label: "Copilot AI usage",
                value: value,
                unit: "nano-AIU"
            ))
        }
        if let value = usage.inputTokens {
            result.append(.init(
                id: "input-tokens",
                kind: .inputTokens,
                label: "Input tokens",
                value: value,
                unit: "tokens"
            ))
        }
        if let value = usage.outputTokens {
            result.append(.init(
                id: "output-tokens",
                kind: .outputTokens,
                label: "Output tokens",
                value: value,
                unit: "tokens"
            ))
        }
        return result
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue?) throws -> Value {
        guard let value else { throw JSONRPCProcessTransportError.malformedResponse }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

public enum CopilotRuntimeError: LocalizedError, Sendable {
    case incompatibleBridge(providerID: String, protocolVersion: String)
    case bindingUnavailable(ProviderAgentBindingID, state: ProviderBindingState)

    public var errorDescription: String? {
        switch self {
        case let .incompatibleBridge(providerID, protocolVersion):
            "The GitHub Copilot helper identified as \(providerID) with unsupported protocol \(protocolVersion)."
        case let .bindingUnavailable(id, state):
            "GitHub Copilot binding \(id.rawValue) is \(state.rawValue) and cannot execute."
        }
    }
}

public struct CopilotBridgeInstallation: Equatable, Sendable {
    public let nodeExecutableURL: URL
    public let bridgeEntryURL: URL

    public init(nodeExecutableURL: URL, bridgeEntryURL: URL) {
        self.nodeExecutableURL = nodeExecutableURL
        self.bridgeEntryURL = bridgeEntryURL
    }
}

public enum InstalledCopilotSDKBridgeLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> CopilotBridgeInstallation? {
        guard let node = locateNode(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager,
            allowDevelopmentOverrides: developmentRuntimeOverridesEnabled
        ),
              let bridge = locateBridge(environment: environment, bundle: bundle, fileManager: fileManager) else {
            return nil
        }
        return CopilotBridgeInstallation(nodeExecutableURL: node, bridgeEntryURL: bridge)
    }

    static func locateNode(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager,
        allowDevelopmentOverrides: Bool
    ) -> URL? {
        let bundled = bundle.resourceURL?
            .appending(path: "CopilotSDKBridge/bin/node", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        let candidates: [String]
        if allowDevelopmentOverrides {
            candidates = [
                environment["GOBY_NODE_EXECUTABLE"],
                bundled,
                "/opt/homebrew/bin/node",
                "/usr/local/bin/node",
                "/usr/bin/node",
            ].compactMap { $0 }
        } else {
            candidates = [bundled].compactMap { $0 }
        }
        return candidates.lazy
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    private static var developmentRuntimeOverridesEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    private static func locateBridge(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> URL? {
        let bundled = bundle.resourceURL?.appending(
            path: "CopilotSDKBridge/index.js",
            directoryHint: .notDirectory
        )
#if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let development = sourceRoot
            .appending(path: "Helpers/CopilotSDK/dist/src/index.js", directoryHint: .notDirectory)
        let explicit = environment["GOBY_COPILOT_BRIDGE_ENTRY"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let candidates = [explicit, bundled, development].compactMap { $0 }
#else
        let candidates = [bundled].compactMap { $0 }
#endif
        return candidates.first { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) }
    }
}

private struct CopilotInitializeRequest: Codable, Sendable {
    struct ClientInfo: Codable, Sendable {
        let name: String
        let version: String
    }
    let clientInfo: ClientInfo
}

private struct CopilotInitializeResponse: Decodable {
    let protocolVersion: String
    let helperVersion: String
    let sdkVersion: String
    let providerId: String
    let capabilities: [String]
}

private struct CopilotAccountResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let name: String
    }
    let connectionState: String
    let credentialConfigured: Bool
    let credentialSource: String?
    let login: String?
    let authType: String?
    let runtimeVersion: String?
    let selectedModel: String?
    let availableModels: [Model]
    let usage: CopilotUsagePayload
    let statusMessage: String?
    let observedAt: String?
}

private struct CopilotUsagePayload: Decodable {
    let inputTokens: Double?
    let outputTokens: Double?
    let nanoAIU: Double?
}

private struct CopilotTasksRequest: Codable, Sendable {
    struct Project: Codable, Sendable {
        let projectId: String
        let rootPath: String
        let rootIdentity: ProviderFileSystemIdentityPayload
    }
    let projects: [Project]
}

private struct CopilotTasksResponse: Decodable {
    struct Task: Decodable {
        let projectId: String
        let sessionId: String
        let title: String
        let summary: String?
        let updatedAt: String
    }
    let tasks: [Task]
}

private struct CopilotStartRequest: Codable, Sendable {
    struct Instruction: Codable, Sendable {
        let name: String
        let version: Int
        let body: String
    }
    struct Resource: Codable, Sendable {
        let path: String
        let access: String
        let identity: ProviderFileSystemIdentityPayload
    }
    let assignmentId: String
    let prompt: String
    let cwd: String
    let cwdIdentity: ProviderFileSystemIdentityPayload
    let agentName: String
    let agentSummary: String
    let agentInstructions: String?
    let instructionPacks: [Instruction]
    let resources: [Resource]
    let attachments: [ProviderLocalAttachmentPayload]
    let risk: String
    let model: String?
}

private struct CopilotStartResponse: Decodable {
    let taskId: String
    let turnId: String
}

private struct CopilotInterruptRequest: Codable, Sendable {
    let assignmentId: String
}

private struct CopilotApprovalResponseRequest: Codable, Sendable {
    let approvalId: String
    let assignmentId: String?
    let decision: String
    let operationDigest: String?
}

private struct CopilotAssignmentStarted: Decodable {
    let assignmentId: String
}

private struct CopilotAssignmentProgress: Decodable {
    let assignmentId: String
    let fraction: Double?
    let message: String
}

private struct CopilotApprovalRequired: Decodable {
    let approvalId: String
    let assignmentId: String
    let kind: CodexApprovalKind
    let summary: String
    let details: String?
    let canAccept: Bool
    let approvalSessionId: String?
    let operationDigest: String?
    let disclosureComplete: Bool?
}

private struct CopilotCommandCompleted: Decodable {
    let assignmentId: String
    let outputSummary: String?
    let evidenceId: String
    let command: String
    let actionCommands: [String]
    let workingDirectory: String
    let status: CodexCommandExecutionStatus
    let exitCode: Int?
    let durationMilliseconds: Int?
    let source: String
}

private typealias CopilotUsageUpdated = CopilotUsagePayload

private struct CopilotAssignmentCompleted: Decodable {
    let assignmentId: String
    let outcome: String
}

private struct CopilotAssignmentFailed: Decodable {
    let assignmentId: String
    let message: String
}
