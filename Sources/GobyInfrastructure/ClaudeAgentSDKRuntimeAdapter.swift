import Foundation
import GobyApplication
import GobyDomain

public actor ClaudeAgentSDKRuntimeAdapter: AgentRuntimeServing {
    /// Per-assignment count of assistant messages, for stable step ids.
    private var activityMessageCounts: [String: Int] = [:]
    public nonisolated let providerID = AgentProviderID.claude
    private let transport: JSONRPCProcessTransport
    private let credentialRepository: (any ProviderCredentialRepository)?
    private let allowsSubscriptionCredentials: Bool
    private var savedCredentials = ClaudeSavedCredentials(subscriptionToken: nil, apiKey: nil)
    private let integrityBundleURL: URL?
    private let trustPolicy: any ProviderRuntimeTrustPolicy
    private let nodeExecutableURL: URL?
    private let bridgeEntryURL: URL?
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
        integrityBundleURL: URL? = nil,
        trustPolicy: any ProviderRuntimeTrustPolicy = AppProviderRuntimeTrustPolicy(),
        requestTimeout: TimeInterval = 30,
        allowsSubscriptionCredentials: Bool = true
    ) {
        transport = JSONRPCProcessTransport(
            executableURL: nodeExecutableURL,
            arguments: [bridgeEntryURL.path(percentEncoded: false)],
            environment: environment,
            requestTimeout: requestTimeout
        )
        self.credentialRepository = credentialRepository
        self.allowsSubscriptionCredentials = allowsSubscriptionCredentials
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
        credentialRepository: (any ProviderCredentialRepository)? = nil
    ) {
        self.transport = transport
        self.credentialRepository = credentialRepository
        self.allowsSubscriptionCredentials = true
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
            .quotaReporting,
            .hooks,
            .mcp,
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
                params: ClaudeInitializeRequest(
                    clientInfo: .init(name: "goby-agentic-dashboard", version: "0.2.0-beta.1")
                )
            )
            let response = try decode(ClaudeInitializeResponse.self, from: value)
            guard response.providerId == providerID.rawValue,
                  ProviderBridgeProtocol.accepts(response.protocolVersion) else {
                throw ClaudeRuntimeError.incompatibleBridge(
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
            params: EmptyParameters(),
            // The helper may ask Claude for its model list first.
            timeout: 30
        )
        let response = try decode(ClaudeAccountResponse.self, from: value)
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
            planName: Self.credentialPlanName(
                route: response.credentialRoute,
                subscriptionType: response.subscriptionType,
                subscriptionPausedUntil: Self.date(response.subscriptionPausedUntil)
            ),
            selectedModel: response.selectedModel,
            availableModels: response.availableModels ?? response.selectedModel.map { [$0] } ?? [],
            usage: latestUsage,
            observedAt: Self.date(response.observedAt) ?? .now
        )
    }

    public func recentTasks(projects: [LabProject]) async throws -> [ProviderTaskActivity] {
        try await ensureConnected()
        // A project whose reviewed folder identity is missing is left out of
        // read-only activity listing; it must not fail the whole provider.
        let request = ClaudeTasksRequest(projects: projects.compactMap { project in
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
        let response = try decode(ClaudeTasksResponse.self, from: value)
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
            throw ClaudeRuntimeError.bindingUnavailable(binding.id, state: binding.state)
        }
        try validateRuntimeIntegrity()
        try await ensureConnected()
        let workingDirectory = assignment.workingDirectory ?? project.rootURL
        let workingDirectoryIdentity = try ProviderFileSystemBoundary.directoryIdentity(
            project.fileSystemIdentity,
            label: project.name
        )
        let attachmentGrants = try ProviderFileSystemBoundary.localAttachments(assignment.attachments)
        let request = ClaudeStartRequest(
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
        let response = try decode(ClaudeStartResponse.self, from: value)
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
            params: ClaudeInterruptRequest(assignmentId: assignmentID.rawValue)
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
            params: ClaudeApprovalResponseRequest(
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
            params: ClaudeApprovalResponseRequest(
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

    /// One tool-less temporary chat turn through the bridge's `chat/ask`.
    public func askTemporaryChat(prompt: String, model: String?) async throws -> String {
        try await ensureConnected()
        let response = try await transport.request(
            method: "chat/ask",
            params: ClaudeTemporaryChatRequest(prompt: prompt, model: model),
            timeout: 180
        )
        guard let text = response["text"]?.stringValue else {
            throw TemporaryChatError.unavailable("Claude returned no answer.")
        }
        return text
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
        savedCredentials = ClaudeSavedCredentials(
            subscriptionSlot: allowsSubscriptionCredentials ? try await credentialRepository?.credential(for: providerID, kind: .subscriptionToken) : nil,
            apiKeySlot: try await credentialRepository?.credential(for: providerID, kind: .apiKey)
        )
        if !allowsSubscriptionCredentials {
            guard savedCredentials.apiKey?.isEmpty == false, savedCredentials.subscriptionToken == nil else {
                throw GADCommandFailure(.rejectedPolicy, "Goby CLI requires an Anthropic API key. Use goby login claude; subscription credentials are unavailable.")
            }
            for key in ["CLAUDE_CODE_OAUTH_TOKEN", "GOBY_CLAUDE_SUBSCRIPTION_TOKEN"] { environment.removeValue(forKey: key) }
        }
        environment.merge(savedCredentials.bridgeEnvironment) { _, saved in saved }
        try await transport.setEnvironment(environment)
    }

    /// Anthropic's limit and billing errors name no fix. Explain which saved
    /// credential ran out and how the other one would keep work going.
    nonisolated static func actionableFailureMessage(
        _ message: String,
        savedCredentials: ClaudeSavedCredentials
    ) -> String {
        let creditsExhausted = message.localizedCaseInsensitiveContains("credit balance is too low")
        let usageLimit = message.localizedCaseInsensitiveContains("usage limit")
            || message.localizedCaseInsensitiveContains("out of extra usage")
        guard creditsExhausted || usageLimit else { return message }
        let subscriptionFix = "To bill a Claude Pro/Max plan first, use Sign in with Claude in Settings → Providers, or run `claude setup-token` and save the token as the Claude subscription."
        let apiKeyFallback = "Save an Anthropic API key in Settings → Providers so Goby continues on API credits whenever the subscription runs out."
        switch (savedCredentials.subscriptionToken != nil, savedCredentials.apiKey != nil) {
        case (true, false):
            return "\(message). Your Claude subscription has reached its usage limit and no API key is saved for Goby to continue on. \(apiKeyFallback)"
        case (true, true):
            return "\(message). Your Claude subscription reached its usage limit and the saved Anthropic API key has no prepaid credits. Add credits at console.anthropic.com, or wait for the subscription limit to reset."
        case (false, true):
            return "\(message). The Anthropic API key saved in Goby has no prepaid credits. Add credits at console.anthropic.com, or replace it. \(subscriptionFix)"
        case (false, false):
            return "\(message). Goby has no saved Claude credential, so Claude used this Mac's Claude Code sign-in, which is an Anthropic Console (API-billed) account without prepaid credits. Add credits at console.anthropic.com, or sign Claude Code in with your Claude account (`claude`, then `/login`). \(subscriptionFix)"
        }
    }

    /// How the Claude row reads in Settings and on the map: which saved
    /// credential new work bills right now.
    nonisolated static func credentialPlanName(
        route: String?,
        subscriptionType: String? = nil,
        subscriptionPausedUntil: Date?
    ) -> String? {
        switch route {
        case "subscription":
            guard let subscriptionType, !subscriptionType.isEmpty else { return "Claude subscription" }
            return "Claude \(subscriptionType.prefix(1).uppercased())\(subscriptionType.dropFirst()) subscription"
        case "apiKey":
            guard let subscriptionPausedUntil else { return "Anthropic API key" }
            let resumes = subscriptionPausedUntil.formatted(date: .omitted, time: .shortened)
            return "Anthropic API key · subscription resumes at \(resumes)"
        case "claudeCodeLogin": return "Claude Code sign-in"
        default: return nil
        }
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
                let payload = try decode(ClaudeAssignmentStarted.self, from: notification.params)
                eventContinuation.yield(.assignmentStarted(providerID, .init(rawValue: payload.assignmentId)))
            case "assignment/progress":
                let payload = try decode(ClaudeAssignmentProgress.self, from: notification.params)
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
                let payload = try decode(ClaudeApprovalRequired.self, from: notification.params)
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
                let payload = try decode(ClaudeCommandCompleted.self, from: notification.params)
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
                let payload = try decode(ClaudeUsageUpdated.self, from: notification.params)
                latestUsage = normalizedUsage(payload)
            case "assignment/completed":
                let payload = try decode(ClaudeAssignmentCompleted.self, from: notification.params)
                eventContinuation.yield(.assignmentCompleted(
                    providerID,
                    .init(rawValue: payload.assignmentId),
                    outcome: payload.outcome
                ))
            case "assignment/failed":
                let payload = try decode(ClaudeAssignmentFailed.self, from: notification.params)
                eventContinuation.yield(.assignmentFailed(
                    providerID,
                    .init(rawValue: payload.assignmentId),
                    message: allowsSubscriptionCredentials ? Self.actionableFailureMessage(
                        payload.message,
                        savedCredentials: savedCredentials
                    ) : payload.message + " CLI authentication uses an Anthropic API key; review API credits or rerun goby login claude."
                ))
            case "goby/connectionClosed":
                state = .failed(message: "Claude Agent SDK bridge closed unexpectedly.")
            case "goby/transportError":
                state = .failed(message: notification.params?.stringValue ?? "Claude bridge protocol error.")
            default:
                break
            }
        } catch {
            state = .failed(message: "Claude bridge sent an invalid \(notification.method ?? "notification"): \(error.localizedDescription)")
        }
    }

    private static func isValidOperationDigest(_ digest: String?) -> Bool {
        guard let digest, digest.count == 64 else { return false }
        return digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private func normalizedAccountState(_ response: ClaudeAccountResponse) -> ProviderConnectionState {
        switch response.connectionState {
        case "connected":
            .connected(version: response.claudeCodeVersion)
        case "needsAuthentication":
            .needsAuthentication
        case "failed":
            .failed(message: "Claude could not verify the configured account.")
        case "notChecked":
            response.credentialConfigured ? .connected(version: response.claudeCodeVersion) : .notChecked
        default:
            state
        }
    }

    private func normalizedUsage(_ usage: ClaudeUsagePayload) -> [ProviderUsageSnapshot] {
        var result: [ProviderUsageSnapshot] = []
        if let value = usage.estimatedCostUsd {
            result.append(.init(
                id: "estimated-cost",
                kind: .estimatedCost,
                label: "Estimated run cost",
                value: value,
                unit: "USD",
                isEstimate: true
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
        result.append(contentsOf: (usage.rateLimits ?? []).map { limit in
            let percentage = limit.utilization <= 1 ? limit.utilization * 100 : limit.utilization
            return ProviderUsageSnapshot(
                id: "rate-limit-\(limit.id)",
                kind: .consumedPercentage,
                label: "Claude \(limit.id.replacingOccurrences(of: "_", with: " ")) usage",
                value: percentage,
                unit: "percent",
                resetsAt: limit.resetsAt.map { Date(timeIntervalSince1970: $0) }
            )
        })
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

public enum ClaudeRuntimeError: LocalizedError, Sendable {
    case incompatibleBridge(providerID: String, protocolVersion: String)
    case bindingUnavailable(ProviderAgentBindingID, state: ProviderBindingState)

    public var errorDescription: String? {
        switch self {
        case let .incompatibleBridge(providerID, protocolVersion):
            "The Claude helper identified as \(providerID) with unsupported protocol \(protocolVersion)."
        case let .bindingUnavailable(id, state):
            "Claude binding \(id.rawValue) is \(state.rawValue) and cannot execute."
        }
    }
}

public struct ClaudeBridgeInstallation: Equatable, Sendable {
    public let nodeExecutableURL: URL
    public let bridgeEntryURL: URL

    public init(nodeExecutableURL: URL, bridgeEntryURL: URL) {
        self.nodeExecutableURL = nodeExecutableURL
        self.bridgeEntryURL = bridgeEntryURL
    }
}

public enum InstalledClaudeAgentSDKBridgeLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ClaudeBridgeInstallation? {
        guard let node = locateNode(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager,
            allowDevelopmentOverrides: developmentRuntimeOverridesEnabled
        ),
              let bridge = locateBridge(environment: environment, bundle: bundle, fileManager: fileManager) else {
            return nil
        }
        return ClaudeBridgeInstallation(nodeExecutableURL: node, bridgeEntryURL: bridge)
    }

    static func locateNode(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager,
        allowDevelopmentOverrides: Bool
    ) -> URL? {
        let bundled = bundle.resourceURL?
            .appending(path: "ClaudeAgentSDKBridge/bin/node", directoryHint: .notDirectory)
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
            path: "ClaudeAgentSDKBridge/index.js",
            directoryHint: .notDirectory
        )
#if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let development = sourceRoot
            .appending(path: "Helpers/ClaudeAgentSDK/dist/src/index.js", directoryHint: .notDirectory)
        let explicit = environment["GOBY_CLAUDE_BRIDGE_ENTRY"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let candidates = [explicit, bundled, development].compactMap { $0 }
#else
        let candidates = [bundled].compactMap { $0 }
#endif
        return candidates.first { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) }
    }
}

private struct ClaudeTemporaryChatRequest: Codable, Sendable {
    let prompt: String
    let model: String?
}

private struct ClaudeInitializeRequest: Codable, Sendable {
    struct ClientInfo: Codable, Sendable {
        let name: String
        let version: String
    }
    let clientInfo: ClientInfo
}

private struct ClaudeInitializeResponse: Decodable {
    let protocolVersion: String
    let helperVersion: String
    let sdkVersion: String
    let providerId: String
    let capabilities: [String]
}

private struct ClaudeAccountResponse: Decodable {
    let connectionState: String
    let credentialConfigured: Bool
    let credentialSource: String?
    /// Absent from helpers older than subscription routing.
    let credentialRoute: String?
    let subscriptionPausedUntil: String?
    /// `pro`, `max`, `team` or `enterprise`, once plan usage has been read.
    let subscriptionType: String?
    let selectedModel: String?
    /// Absent from helpers older than the model list.
    let availableModels: [String]?
    let claudeCodeVersion: String?
    let usage: ClaudeUsagePayload
    let observedAt: String?
}

private struct ClaudeUsagePayload: Decodable {
    let estimatedCostUsd: Double?
    let inputTokens: Double?
    let outputTokens: Double?
    let rateLimits: [ClaudeRateLimitPayload]?
}

private struct ClaudeRateLimitPayload: Decodable {
    let id: String
    let utilization: Double
    let resetsAt: Double?
}

private struct ClaudeTasksRequest: Codable, Sendable {
    struct Project: Codable, Sendable {
        let projectId: String
        let rootPath: String
        let rootIdentity: ProviderFileSystemIdentityPayload
    }
    let projects: [Project]
}

private struct ClaudeTasksResponse: Decodable {
    struct Task: Decodable {
        let projectId: String
        let sessionId: String
        let title: String
        let summary: String?
        let updatedAt: String
    }
    let tasks: [Task]
}

private struct ClaudeStartRequest: Codable, Sendable {
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

private struct ClaudeStartResponse: Decodable {
    let taskId: String
    let turnId: String
}

private struct ClaudeInterruptRequest: Codable, Sendable {
    let assignmentId: String
}

private struct ClaudeApprovalResponseRequest: Codable, Sendable {
    let approvalId: String
    let assignmentId: String?
    let decision: String
    let operationDigest: String?
}

private struct ClaudeAssignmentStarted: Decodable {
    let assignmentId: String
}

private struct ClaudeAssignmentProgress: Decodable {
    let assignmentId: String
    let fraction: Double?
    let message: String
}

private struct ClaudeApprovalRequired: Decodable {
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

private struct ClaudeCommandCompleted: Decodable {
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

private typealias ClaudeUsageUpdated = ClaudeUsagePayload

private struct ClaudeAssignmentCompleted: Decodable {
    let assignmentId: String
    let outcome: String
}

private struct ClaudeAssignmentFailed: Decodable {
    let assignmentId: String
    let message: String
}

/// The Claude credentials saved in Goby's Keychain, as the bridge receives
/// them. A subscription token is the default; the API key is its fallback.
public struct ClaudeSavedCredentials: Equatable, Sendable {
    public let subscriptionToken: String?
    public let apiKey: String?

    public init(subscriptionToken: String?, apiKey: String?) {
        self.subscriptionToken = subscriptionToken
        self.apiKey = apiKey
    }

    /// Before the subscription slot existed, a `claude setup-token` token
    /// could only be saved in the API key slot; it still counts as the
    /// subscription unless one is saved separately.
    public init(subscriptionSlot: String?, apiKeySlot: String?) {
        if let apiKeySlot, ProviderCredentialKind.isClaudeSubscriptionToken(apiKeySlot) {
            self.init(subscriptionToken: subscriptionSlot ?? apiKeySlot, apiKey: nil)
        } else {
            self.init(subscriptionToken: subscriptionSlot, apiKey: apiKeySlot)
        }
    }

    /// The helper picks which one each query runs on.
    var bridgeEnvironment: [String: String] {
        var environment: [String: String] = [:]
        environment["GOBY_CLAUDE_SUBSCRIPTION_TOKEN"] = subscriptionToken
        environment["GOBY_CLAUDE_API_KEY"] = apiKey
        return environment
    }
}
