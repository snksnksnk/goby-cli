import CryptoKit
import Foundation
import GobyApplication
import GobyDomain

public actor CodexGateway: CodexServing {
    private struct CodexGlobalState: Decodable {
        struct LocalProject: Decodable {
            let name: String
            let rootPaths: [String]
        }

        let localProjects: [String: LocalProject]
        let savedWorkspaceRoots: [String]
        let activeWorkspaceRoots: [String]

        enum CodingKeys: String, CodingKey {
            case localProjects = "local-projects"
            case savedWorkspaceRoots = "electron-saved-workspace-roots"
            case activeWorkspaceRoots = "active-workspace-roots"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localProjects = try container.decodeIfPresent([String: LocalProject].self, forKey: .localProjects) ?? [:]
            savedWorkspaceRoots = try container.decodeIfPresent([String].self, forKey: .savedWorkspaceRoots) ?? []
            activeWorkspaceRoots = try container.decodeIfPresent([String].self, forKey: .activeWorkspaceRoots) ?? []
        }
    }

    private struct ActiveTurn: Sendable {
        let threadID: String
        let turnID: String
    }

    private struct PendingApproval: Equatable, Sendable {
        let rpcID: JSONRPCID
        let assignmentID: AssignmentID
        let kind: CodexApprovalKind
        let requestedPermissions: JSONValue?
        let operationDigest: String?
        let canAccept: Bool
    }

    private struct FileChangeReview: Sendable {
        let assignmentID: AssignmentID
        let payload: JSONValue
    }

    private struct DeferredFileChangeApproval: Sendable {
        let rpcID: JSONRPCID
        let assignmentID: AssignmentID
        let params: JSONValue
    }

    private struct ThreadRootScan: Sendable {
        var roots: [URL] = []
        var tasks: [CodexTaskActivity] = []
        var threadIDs = Set<String>()
        var failure: String?
        var reachedOverlap = false
    }

    private let transport: CodexAppServerTransport
    private let projectDiscoveryPageTimeout: TimeInterval
    private let projectDiscoveryTimeBudget: TimeInterval
    private let preferredProjectDiscoveryPageSize: Int
    private let globalStateURL: URL?
    private let codexWorktreesURL: URL
    private var state: CodexConnectionState = .disconnected
    private var connectionGeneration = UUID()
    private var connectionTask: Task<CodexConnectionState, any Error>?
    private var disconnectionTask: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var assignmentByThread: [String: AssignmentID] = [:]
    private var projectByAssignment: [AssignmentID: ProjectID] = [:]
    private var helperActivityByThread: [String: CodexTaskActivity] = [:]
    private var activeTurnByAssignment: [AssignmentID: ActiveTurn] = [:]
    private var startingAssignmentByThread: [String: AssignmentID] = [:]
    private var pendingStartMessagesByThread: [String: [IncomingJSONRPCMessage]] = [:]
    private var quarantinedStartByThread: [String: AssignmentID] = [:]
    private var interruptingQuarantinedThreads = Set<String>()
    private var approvalSessionByAssignment: [AssignmentID: ApprovalSessionID] = [:]
    private var outputByAssignment: [AssignmentID: String] = [:]
    private var resourcesByAssignment: [AssignmentID: [SharedResource]] = [:]
    private var approvals: [String: PendingApproval] = [:]
    private var approvalResponsesInFlight = Set<String>()
    private var fileChangeReviews: [String: FileChangeReview] = [:]
    private var deferredFileChangeApprovals: [String: DeferredFileChangeApproval] = [:]
    private let eventStream: AsyncStream<CodexRunEvent>
    private let eventContinuation: AsyncStream<CodexRunEvent>.Continuation

    public init(
        executableURL: URL,
        clientVersion: String,
        requestTimeout: TimeInterval = 30,
        projectDiscoveryPageTimeout: TimeInterval = 4,
        projectDiscoveryTimeBudget: TimeInterval = 10,
        preferredProjectDiscoveryPageSize: Int = 50,
        runtimeValidator: any CodexRuntimeValidating = CodexRuntimeIntegrityValidator(),
        globalStateURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/.codex-global-state.json")
    ) {
        self.transport = CodexAppServerTransport(
            executableURL: executableURL,
            clientVersion: clientVersion,
            requestTimeout: requestTimeout,
            runtimeValidator: runtimeValidator
        )
        self.projectDiscoveryPageTimeout = max(0.1, projectDiscoveryPageTimeout)
        self.projectDiscoveryTimeBudget = max(projectDiscoveryPageTimeout, projectDiscoveryTimeBudget)
        self.preferredProjectDiscoveryPageSize = max(1, preferredProjectDiscoveryPageSize)
        self.globalStateURL = globalStateURL
        self.codexWorktreesURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/worktrees", directoryHint: .isDirectory)
            .standardizedFileURL
        let pair = AsyncStream<CodexRunEvent>.makeStream(bufferingPolicy: .bufferingNewest(1_000))
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    public func connectionState() -> CodexConnectionState {
        state
    }

    public func connect() async throws -> CodexConnectionState {
        if case .connected = state { return state }
        if let connectionTask { return try await connectionTask.value }
        let generation = UUID()
        connectionGeneration = generation
        state = .connecting
        listener?.cancel()
        listener = nil
        let disconnectionTask = self.disconnectionTask
        let task = Task {
            await disconnectionTask?.value
            return try await self.establishConnection(generation: generation)
        }
        connectionTask = task
        return try await task.value
    }

    private func establishConnection(generation: UUID) async throws -> CodexConnectionState {
        do {
            try requireCurrentConnection(generation)
            let response = try await transport.start()
            let notifications = await transport.notifications()
            try requireCurrentConnection(generation)
            let userAgent = response["userAgent"]?.stringValue ?? "Codex App Server"
            state = .connected(version: userAgent)
            listener = Task { [weak self] in
                for await message in notifications {
                    guard !Task.isCancelled else { return }
                    await self?.handleConnectionMessage(message, generation: generation)
                }
            }
            connectionTask = nil
            return state
        } catch {
            if connectionGeneration == generation {
                connectionTask = nil
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func requireCurrentConnection(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw CodexTransportError.closed }
    }

    private func handleConnectionMessage(_ message: IncomingJSONRPCMessage, generation: UUID) {
        guard connectionGeneration == generation else { return }
        handle(message)
    }

    public func accountSnapshot() async throws -> CodexAccountSnapshot {
        let account = try await transport.request(
            method: "account/read",
            params: GetAccountParameters()
        )
        let accountValue = account["account"]
        let authenticated: Bool
        let displayName: String?
        let planName: String?
        if case .null = accountValue {
            authenticated = false
            displayName = nil
            planName = nil
        } else {
            authenticated = accountValue != nil
            displayName = accountValue?["email"]?.stringValue
            planName = accountValue?["planType"]?.stringValue ?? accountValue?["type"]?.stringValue
        }

        let limits = try? await transport.request(
            method: "account/rateLimits/read",
            params: EmptyParameters()
        )
        let config = try? await transport.request(
            method: "config/read",
            params: CodexConfigReadParameters(includeLayers: false)
        )
        let modelList = try? await transport.request(
            method: "model/list",
            params: CodexModelListParameters(limit: 100)
        )
        let models: [JSONValue]
        if case let .array(values) = modelList?["data"] {
            models = values
        } else {
            models = []
        }
        let availableModels = models.compactMap { $0["model"]?.stringValue }
        let selectedModel = config?["config"]?["model"]?.stringValue
            ?? models.first(where: { $0["isDefault"]?.boolValue == true })?["model"]?.stringValue
        let preferred = limits?["rateLimitsByLimitId"]?["codex"] ?? limits?["rateLimits"]
        let primary = preferred?["primary"]
        let secondary = preferred?["secondary"]
        let usedPercent = primary?["usedPercent"]?.doubleValue
        let resetsAt = primary?["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        return CodexAccountSnapshot(
            authenticated: authenticated,
            displayName: displayName,
            planName: planName,
            selectedModel: selectedModel,
            availableModels: availableModels,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            primaryWindowDurationMinutes: primary?["windowDurationMins"]?.doubleValue,
            secondaryUsedPercent: secondary?["usedPercent"]?.doubleValue,
            secondaryResetsAt: secondary?["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
            secondaryWindowDurationMinutes: secondary?["windowDurationMins"]?.doubleValue
        )
    }

    public func recentProjectRoots() async throws -> CodexProjectRootsSnapshot {
        let registry = savedProjectRoots()
        let newestFirst = await scanProjectRoots(sortDirection: "desc", stoppingAt: [])
        var taskRoots = newestFirst.roots
        var taskActivity = newestFirst.tasks
        var warnings = registry.warning.map { [$0] } ?? []
        if newestFirst.failure != nil {
            let oldestFirst = await scanProjectRoots(
                sortDirection: "asc",
                stoppingAt: newestFirst.threadIDs
            )
            taskRoots.append(contentsOf: oldestFirst.roots)
            taskActivity.append(contentsOf: oldestFirst.tasks)
            if !oldestFirst.reachedOverlap || oldestFirst.failure != nil {
                warnings.append(
                    "Some Codex task history could not be read before the timeout. Goby included every readable project and kept the existing catalog unchanged; refresh again after Codex finishes any heavy background work."
                )
            }
        }

        var seenRoots = Set<String>()
        let combined = (registry.roots + taskRoots).filter { root in
            seenRoots.insert(root.path(percentEncoded: false)).inserted
        }
        var seenTaskIDs = Set<String>()
        let tasks = taskActivity
            .filter { seenTaskIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
        return CodexProjectRootsSnapshot(
            roots: combined,
            savedProjects: registry.savedProjects,
            tasks: tasks,
            warnings: warnings
        )
    }

    private func savedProjectRoots() -> (
        roots: [URL],
        savedProjects: [CodexSavedProjectReference],
        warning: String?
    ) {
        guard let globalStateURL,
              FileManager.default.fileExists(atPath: globalStateURL.path(percentEncoded: false)) else {
            return ([], [], nil)
        }
        do {
            let state = try JSONDecoder().decode(
                CodexGlobalState.self,
                from: Data(contentsOf: globalStateURL, options: .mappedIfSafe)
            )
            let savedProjects = state.localProjects.values.flatMap { project in
                project.rootPaths.compactMap { path -> CodexSavedProjectReference? in
                    guard !path.isEmpty else { return nil }
                    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                    guard !isCodexManagedWorktree(root) else { return nil }
                    return CodexSavedProjectReference(name: project.name, rootURL: root)
                }
            }
            let paths = savedProjects.map { $0.rootURL.path(percentEncoded: false) }
                + state.savedWorkspaceRoots
                + state.activeWorkspaceRoots
            var seen = Set<String>()
            let roots = paths.compactMap { path -> URL? in
                guard !path.isEmpty else { return nil }
                let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                let normalized = root.path(percentEncoded: false)
                guard !isCodexManagedWorktree(root), seen.insert(normalized).inserted else { return nil }
                return root
            }
            return (roots, savedProjects, nil)
        } catch {
            return (
                [],
                [],
                "Codex’s saved-project registry could not be read. Goby still inspected every readable project found in task history."
            )
        }
    }

    private func isCodexManagedWorktree(_ root: URL) -> Bool {
        let separators = CharacterSet(charactersIn: "/")
        let path = root.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: separators)
        let worktreesPath = codexWorktreesURL.path(percentEncoded: false)
            .trimmingCharacters(in: separators)
        return path == worktreesPath || path.hasPrefix(worktreesPath + "/")
    }

    private func scanProjectRoots(
        sortDirection: String,
        stoppingAt knownThreadIDs: Set<String>
    ) async -> ThreadRootScan {
        var result = ThreadRootScan()
        var seenRoots = Set<String>()
        var cursor: String?
        var seenCursors = Set<String>()
        var pageSize = preferredProjectDiscoveryPageSize
        let deadline = Date.now.addingTimeInterval(projectDiscoveryTimeBudget)

        repeat {
            let remainingTime = deadline.timeIntervalSinceNow
            guard remainingTime > 0 else {
                result.failure = "Codex project discovery reached its time budget."
                return result
            }
            let response: JSONValue
            do {
                let responseTimeout = pageSize > 1
                    ? min(1, projectDiscoveryPageTimeout)
                    : projectDiscoveryPageTimeout
                response = try await transport.request(
                    method: "thread/list",
                    params: ThreadListParameters(
                        cursor: cursor,
                        limit: pageSize,
                        sortDirection: sortDirection,
                        sourceKinds: Self.projectActivityThreadSourceKinds
                    ),
                    timeout: min(responseTimeout, remainingTime)
                )
            } catch {
                // Most history is inexpensive to list in batches. If a batch contains
                // an unusually large task, retry from the same cursor one item at a
                // time so only that task is omitted by the opposite-direction scan.
                if pageSize > 1 {
                    pageSize = 1
                    continue
                }
                result.failure = error.localizedDescription
                return result
            }
            guard case let .array(threads) = response["data"] else {
                result.failure = CodexTransportError.malformedResponse.localizedDescription
                return result
            }
            for thread in threads {
                if let threadID = thread["id"]?.stringValue {
                    if knownThreadIDs.contains(threadID) {
                        result.reachedOverlap = true
                        return result
                    }
                    result.threadIDs.insert(threadID)
                }
                guard let cwd = thread["cwd"]?.stringValue else { continue }
                let url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
                guard !isCodexManagedWorktree(url) else { continue }
                if seenRoots.insert(url.path(percentEncoded: false)).inserted {
                    result.roots.append(url)
                }
                if let task = Self.taskActivity(from: thread, rootURL: url) {
                    result.tasks.append(task)
                }
            }

            guard let nextCursor = response["nextCursor"]?.stringValue,
                  !nextCursor.isEmpty else { break }
            guard seenCursors.insert(nextCursor).inserted else {
                result.failure = "Codex returned a repeated project-history cursor."
                return result
            }
            cursor = nextCursor
        } while true

        return result
    }

    private static let projectActivityThreadSourceKinds = [
        "cli", "vscode", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
    ]

    private static func taskActivity(from thread: JSONValue, rootURL: URL) -> CodexTaskActivity? {
        guard let id = thread["id"]?.stringValue else { return nil }
        let rawName = thread["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = thread["preview"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentThreadID = thread["parentThreadId"]?.stringValue
        let agentRole = thread["agentRole"]?.stringValue
        let sourceKind = thread["source"]?.stringValue?.localizedCaseInsensitiveContains("subagent") == true
            || thread["source"]?["subAgent"] != nil
            || thread["source"]?["subAgentReview"] != nil
            || thread["source"]?["subAgentCompact"] != nil
            || thread["source"]?["subAgentThreadSpawn"] != nil
            || thread["source"]?["subAgentOther"] != nil
        let isSubagent = parentThreadID != nil || agentRole != nil || sourceKind
        let copy = CodexTaskCopySanitizer.copy(
            id: id,
            name: rawName,
            preview: preview,
            isSubagent: isSubagent
        )
        return CodexTaskActivity(
            id: id,
            projectID: ProjectID.derived(fromProjectRoot: rootURL),
            title: copy.title,
            summary: copy.summary,
            status: taskStatus(from: thread["status"]),
            updatedAt: Date(timeIntervalSince1970: thread["updatedAt"]?.doubleValue ?? 0),
            isSubagent: isSubagent,
            agentRole: agentRole,
            parentThreadID: parentThreadID
        )
    }

    private static func taskStatus(from value: JSONValue?) -> CodexTaskStatus {
        guard let type = value?["type"]?.stringValue else { return .idle }
        switch type {
        case "active":
            let flags: [String]
            if case let .array(values) = value?["activeFlags"] {
                flags = values.compactMap(\.stringValue)
            } else {
                flags = []
            }
            if flags.contains("waitingOnApproval") { return .waitingForApproval }
            if flags.contains("waitingOnUserInput") { return .waitingForInput }
            return .active
        case "systemError": return .failed
        case "idle", "notLoaded": return .idle
        default: return .idle
        }
    }

    public func recover(
        assignment: AgentAssignment,
        project: LabProject,
        resources: [SharedResource]
    ) async throws -> ProviderExecutionRecovery? {
        guard let threadID = assignment.providerTaskID ?? assignment.codexThreadID else {
            return nil
        }
        guard case .connected = state else {
            _ = try await connect()
            return try await recover(
                assignment: assignment,
                project: project,
                resources: resources
            )
        }

        // Register the durable identity before asking app-server to rejoin the
        // thread so notifications that race with the response are not lost.
        assignmentByThread[threadID] = assignment.id
        projectByAssignment[assignment.id] = project.id
        resourcesByAssignment[assignment.id] = resources
        approvalSessionByAssignment[assignment.id] = .make()
        outputByAssignment[assignment.id] = ""

        do {
            let response = try await transport.request(
                method: "thread/resume",
                params: ThreadResumeParameters(threadID: threadID)
            )
            guard let thread = response["thread"],
                  thread["id"]?.stringValue == threadID,
                  let recoveredCWD = thread["cwd"]?.stringValue,
                  URL(fileURLWithPath: recoveredCWD, isDirectory: true).standardizedFileURL
                    == project.rootURL.standardizedFileURL else {
                throw CodexTransportError.malformedResponse
            }
            let persistedTurnID = assignment.providerTurnID ?? assignment.codexTurnID
            let turn = Self.recoveryTurn(in: thread, preferredID: persistedTurnID)
            if persistedTurnID != nil, turn == nil {
                throw CodexTransportError.malformedResponse
            }
            let turnID = turn?["id"]?.stringValue ?? persistedTurnID
            let status = Self.recoveryStatus(thread: thread, turn: turn)
            let output = Self.recoveryOutput(from: turn)
            let evidence = Self.recoveryEvidence(from: turn)
            let handle = ProviderExecutionHandle(
                providerID: .codex,
                taskID: threadID,
                turnID: turnID
            )

            switch status {
            case .working, .waitingForApproval, .waitingForInput:
                guard let turnID else {
                    throw CodexTransportError.malformedResponse
                }
                activeTurnByAssignment[assignment.id] = ActiveTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                outputByAssignment[assignment.id] = output ?? ""
            case .saved, .completed, .failed, .cancelled:
                clearRecoveredAssignment(assignment.id, keepingThread: threadID)
            }

            return ProviderExecutionRecovery(
                handle: handle,
                status: status,
                message: Self.recoveryMessage(for: status, output: output),
                outcome: status == .completed ? output : nil,
                evidence: evidence
            )
        } catch {
            clearRecoveredAssignment(assignment.id, keepingThread: nil)
            throw error
        }
    }

    private func clearRecoveredAssignment(_ assignmentID: AssignmentID, keepingThread threadID: String?) {
        activeTurnByAssignment.removeValue(forKey: assignmentID)
        approvalSessionByAssignment.removeValue(forKey: assignmentID)
        projectByAssignment.removeValue(forKey: assignmentID)
        resourcesByAssignment.removeValue(forKey: assignmentID)
        outputByAssignment.removeValue(forKey: assignmentID)
        if let threadID {
            assignmentByThread.removeValue(forKey: threadID)
        } else {
            assignmentByThread = assignmentByThread.filter { $0.value != assignmentID }
        }
    }

    nonisolated private static func recoveryTurn(
        in thread: JSONValue,
        preferredID: String?
    ) -> JSONValue? {
        guard case let .array(turns)? = thread["turns"] else { return nil }
        if let preferredID {
            return turns.last(where: { $0["id"]?.stringValue == preferredID })
        }
        return turns.last
    }

    nonisolated private static func recoveryStatus(
        thread: JSONValue,
        turn: JSONValue?
    ) -> ProviderTaskStatus {
        switch turn?["status"]?.stringValue {
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted", "cancelled": return .cancelled
        default: break
        }
        switch taskStatus(from: thread["status"]) {
        case .active: return .working
        case .waitingForApproval: return .waitingForApproval
        case .waitingForInput: return .waitingForInput
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .completed: return .completed
        case .idle:
            switch turn?["status"]?.stringValue {
            case "inProgress": return .working
            default: return .saved
            }
        }
    }

    nonisolated private static func recoveryOutput(from turn: JSONValue?) -> String? {
        guard case let .array(items)? = turn?["items"] else { return nil }
        let text = items.reversed().compactMap { item -> String? in
            guard item["type"]?.stringValue == "agentMessage" else { return nil }
            return item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
        guard let text, !text.isEmpty else { return nil }
        return String(text.suffix(32_000))
    }

    nonisolated private static func recoveryEvidence(
        from turn: JSONValue?
    ) -> [ProviderCommandExecutionEvidence] {
        guard case let .array(items)? = turn?["items"] else { return [] }
        return items.compactMap { item in
            commandExecutionEvidence(from: .object(["item": item])).map {
                ProviderCommandExecutionEvidence(
                    id: $0.id,
                    providerID: .codex,
                    command: $0.command,
                    actionCommands: $0.actionCommands,
                    workingDirectory: $0.workingDirectory,
                    status: $0.status,
                    exitCode: $0.exitCode,
                    durationMilliseconds: $0.durationMilliseconds,
                    source: $0.source
                )
            }
        }
    }

    nonisolated private static func recoveryMessage(
        for status: ProviderTaskStatus,
        output: String?
    ) -> String {
        if let output, !output.isEmpty { return String(output.suffix(240)) }
        return switch status {
        case .working: "Reconnected to the running Codex task"
        case .waitingForApproval: "Codex is waiting for approval"
        case .waitingForInput: "Codex is waiting for input"
        case .saved: "Codex no longer reports this task as running"
        case .completed: "Codex completed while Goby was closed"
        case .failed: "Codex reported that the recovered task failed"
        case .cancelled: "Codex reported that the recovered task was cancelled"
        }
    }

    public func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) async throws -> CodexExecutionHandle {
        guard activeTurnByAssignment[assignment.id] == nil else {
            throw CodexTransportError.assignmentAlreadyActive(assignment.id)
        }
        guard !quarantinedStartByThread.values.contains(assignment.id) else {
            throw CodexTransportError.assignmentAlreadyActive(assignment.id)
        }
        guard case .connected = state else {
            _ = try await connect()
            return try await start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: instructions,
                resources: resources,
                risk: risk
            )
        }
        let developerInstructions = Self.makeDeveloperInstructions(
            agent: agent,
            project: project,
            instructions: instructions,
            resources: resources,
            task: assignment.currentTask,
            risk: risk
        )
        let shellCacheDirectory = Self.shellCacheDirectory(
            for: assignment.id,
            under: FileManager.default.temporaryDirectory
        )
        try FileManager.default.createDirectory(
            at: shellCacheDirectory,
            withIntermediateDirectories: true
        )
        let thread: JSONValue = try await transport.request(
            method: "thread/start",
            params: ThreadStartParameters(
                config: Self.shellCacheConfiguration(cacheDirectory: shellCacheDirectory),
                cwd: project.rootURL.path(percentEncoded: false),
                developerInstructions: developerInstructions,
                model: assignment.model,
                sandbox: Self.sandbox(for: risk)
            )
        )
        guard let threadID = thread["thread"]?["id"]?.stringValue else {
            throw CodexTransportError.malformedResponse
        }
        startingAssignmentByThread[threadID] = assignment.id
        let turn: JSONValue
        do {
            turn = try await transport.request(
                method: "turn/start",
                params: TurnStartParameters(
                    threadID: threadID,
                    prompt: assignment.currentTask,
                    attachments: assignment.attachments
                )
            )
        } catch {
            startingAssignmentByThread.removeValue(forKey: threadID)
            quarantinedStartByThread[threadID] = assignment.id
            let pendingMessages = pendingStartMessagesByThread.removeValue(forKey: threadID) ?? []
            for message in pendingMessages { handle(message) }
            throw CodexTransportError.indeterminateTurnStart(threadID: threadID)
        }
        guard let turnID = turn["turn"]?["id"]?.stringValue else {
            startingAssignmentByThread.removeValue(forKey: threadID)
            quarantinedStartByThread[threadID] = assignment.id
            let pendingMessages = pendingStartMessagesByThread.removeValue(forKey: threadID) ?? []
            for message in pendingMessages { handle(message) }
            throw CodexTransportError.indeterminateTurnStart(threadID: threadID)
        }
        guard startingAssignmentByThread[threadID] == assignment.id else {
            pendingStartMessagesByThread.removeValue(forKey: threadID)
            throw CodexTransportError.closed
        }
        assignmentByThread[threadID] = assignment.id
        projectByAssignment[assignment.id] = project.id
        resourcesByAssignment[assignment.id] = resources
        outputByAssignment[assignment.id] = ""
        activeTurnByAssignment[assignment.id] = ActiveTurn(threadID: threadID, turnID: turnID)
        approvalSessionByAssignment[assignment.id] = .make()
        startingAssignmentByThread.removeValue(forKey: threadID)
        let pendingMessages = pendingStartMessagesByThread.removeValue(forKey: threadID) ?? []
        eventContinuation.yield(.assignmentStarted(assignment.id))
        for message in pendingMessages {
            handle(message)
        }
        return CodexExecutionHandle(threadID: threadID, turnID: turnID)
    }

    public func interrupt(assignmentID: AssignmentID) async throws {
        guard let active = activeTurnByAssignment[assignmentID] else { return }
        _ = try await transport.request(
            method: "turn/interrupt",
            params: TurnInterruptParameters(threadID: active.threadID, turnID: active.turnID)
        )
    }

    public func steer(assignmentID: AssignmentID, text: String) async throws {
        guard let active = activeTurnByAssignment[assignmentID] else {
            throw CodexTransportError.malformedResponse
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GobyApplicationError.emptyPrompt }
        let response = try await transport.request(
            method: "turn/steer",
            params: TurnSteerParameters(
                threadID: active.threadID,
                expectedTurnID: active.turnID,
                text: String(normalized.prefix(32_000))
            )
        )
        guard response["turnId"]?.stringValue == active.turnID else {
            throw CodexTransportError.malformedResponse
        }
    }

    public func respond(to approvalID: String, decision: CodexApprovalDecision) async throws {
        try await respond(to: approvalID, decision: decision, operationDigest: nil)
    }

    public func respond(
        to approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) async throws {
        guard let pending = approvals[approvalID] else {
            throw CodexTransportError.malformedResponse
        }
        guard activeTurnByAssignment[pending.assignmentID] != nil else {
            approvals.removeValue(forKey: approvalID)
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        let requestedDecision: CodexApprovalDecision = switch decision {
        case .acceptForSession, .acceptAllForRun: .accept
        case .accept, .decline, .cancel: decision
        }
        if requestedDecision == .accept {
            guard pending.canAccept,
                  let expectedDigest = pending.operationDigest,
                  operationDigest == expectedDigest else {
                throw ProviderApprovalBindingError.missingOrChangedOperationDigest
            }
        }
        guard approvalResponsesInFlight.insert(approvalID).inserted else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        defer { approvalResponsesInFlight.remove(approvalID) }
        let effectiveDecision = requestedDecision
        switch pending.kind {
        case .command, .fileChange:
            try await transport.sendResponse(
                id: pending.rpcID,
                result: CodexApprovalResponse(decision: effectiveDecision.rawValue)
            )
        case .permissions:
            let grants: JSONValue = switch effectiveDecision {
            case .accept, .acceptForSession:
                pending.requestedPermissions ?? .object([:])
            case .acceptAllForRun:
                pending.requestedPermissions ?? .object([:])
            case .decline, .cancel:
                .object([:])
            }
            try await transport.sendResponse(
                id: pending.rpcID,
                result: CodexPermissionsApprovalResponse(
                    permissions: grants,
                    scope: effectiveDecision == .acceptForSession ? "session" : "turn"
                )
            )
        }
        guard approvals[approvalID] == pending else {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        approvals.removeValue(forKey: approvalID)
    }

    public func events() -> AsyncStream<CodexRunEvent> {
        eventStream
    }

    public func disconnect() async {
        let generation = UUID()
        connectionGeneration = generation
        connectionTask?.cancel()
        connectionTask = nil
        listener?.cancel()
        listener = nil
        state = .disconnected
        assignmentByThread.removeAll()
        startingAssignmentByThread.removeAll()
        pendingStartMessagesByThread.removeAll()
        quarantinedStartByThread.removeAll()
        interruptingQuarantinedThreads.removeAll()
        projectByAssignment.removeAll()
        helperActivityByThread.removeAll()
        activeTurnByAssignment.removeAll()
        approvalSessionByAssignment.removeAll()
        outputByAssignment.removeAll()
        resourcesByAssignment.removeAll()
        approvals.removeAll()
        fileChangeReviews.removeAll()
        deferredFileChangeApprovals.removeAll()
        let previousDisconnection = disconnectionTask
        let transport = self.transport
        let task = Task {
            await previousDisconnection?.value
            await transport.stop()
        }
        disconnectionTask = task
        await task.value
        if connectionGeneration == generation { disconnectionTask = nil }
    }

    private func handle(_ message: IncomingJSONRPCMessage) {
        guard let method = message.method else { return }
        let threadID = message.params?["threadId"]?.stringValue
        let notificationTurnID = message.params?["turnId"]?.stringValue
            ?? message.params?["turn"]?["id"]?.stringValue
            ?? message.params?["item"]?["turnId"]?.stringValue
        if let threadID, quarantinedStartByThread[threadID] != nil {
            handleQuarantinedStart(
                message,
                method: method,
                threadID: threadID,
                turnID: notificationTurnID
            )
            return
        }
        if let threadID,
           assignmentByThread[threadID] == nil,
           startingAssignmentByThread[threadID] != nil,
           method != "goby/connectionClosed",
           method != "goby/transportError" {
            var pending = pendingStartMessagesByThread[threadID, default: []]
            if pending.count < 64 { pending.append(message) }
            pendingStartMessagesByThread[threadID] = pending
            return
        }
        let mappedAssignmentID = threadID.flatMap { assignmentByThread[$0] }
        let assignmentID = mappedAssignmentID.flatMap { candidate -> AssignmentID? in
            guard let threadID,
                  let active = activeTurnByAssignment[candidate],
                  active.threadID == threadID,
                  notificationTurnID == nil || notificationTurnID == active.turnID else {
                return nil
            }
            return candidate
        }

        switch method {
        case "goby/connectionClosed", "goby/transportError":
            let status = message.params?.doubleValue.map(Int.init) ?? 0
            let failureMessage = if method == "goby/transportError" {
                message.params?.stringValue ?? CodexTransportError.closed.localizedDescription
            } else if status == 0 {
                CodexTransportError.closed.localizedDescription
            } else {
                CodexTransportError.processExited(Int32(status)).localizedDescription
            }
            state = .failed(failureMessage)
            let interruptedAssignments = Array(Set(
                activeTurnByAssignment.keys.map(\.self)
                    + startingAssignmentByThread.values.map(\.self)
            ))
            activeTurnByAssignment.removeAll()
            approvalSessionByAssignment.removeAll()
            assignmentByThread.removeAll()
            startingAssignmentByThread.removeAll()
            pendingStartMessagesByThread.removeAll()
            quarantinedStartByThread.removeAll()
            interruptingQuarantinedThreads.removeAll()
            projectByAssignment.removeAll()
            helperActivityByThread.removeAll()
            outputByAssignment.removeAll()
            resourcesByAssignment.removeAll()
            approvals.removeAll()
            fileChangeReviews.removeAll()
            deferredFileChangeApprovals.removeAll()
            for assignmentID in interruptedAssignments {
                eventContinuation.yield(.assignmentFailed(assignmentID, message: failureMessage))
            }

        case "item/agentMessage/delta":
            guard let assignmentID, let delta = message.params?["delta"]?.stringValue else { return }
            var output = outputByAssignment[assignmentID, default: ""]
            output.append(delta)
            if output.count > 32_000 { output = String(output.suffix(32_000)) }
            outputByAssignment[assignmentID] = output
            eventContinuation.yield(.progress(assignmentID, fraction: nil, message: String(output.suffix(240))))

        case "item/started", "item/completed":
            if method == "item/started", let assignmentID {
                captureFileChangeReview(params: message.params, assignmentID: assignmentID)
            } else if method == "item/completed",
                      assignmentID != nil,
                      let itemID = message.params?["item"]?["id"]?.stringValue {
                fileChangeReviews.removeValue(forKey: itemID)
            }
            handleHelperActivity(
                params: message.params,
                fallbackAssignmentID: assignmentID,
                notificationThreadID: threadID
            )
            if let assignmentID,
               let progressMessage = Self.workProgressMessage(
                   item: message.params?["item"],
                   completed: method == "item/completed"
               ) {
                eventContinuation.yield(.progress(
                    assignmentID,
                    fraction: nil,
                    message: progressMessage
                ))
            }
            if let assignmentID,
               let step = Self.activityStep(
                   from: message.params?["item"],
                   assignmentID: assignmentID,
                   completed: method == "item/completed"
               ) {
                eventContinuation.yield(.activity(assignmentID, step: step))
            }
            if method == "item/completed",
               let assignmentID,
               let evidence = Self.commandExecutionEvidence(from: message.params) {
                eventContinuation.yield(.commandExecutionCompleted(assignmentID, evidence: evidence))
            }

        case "item/fileChange/patchUpdated":
            if let assignmentID {
                captureFileChangeReview(params: message.params, assignmentID: assignmentID)
            }

        case "turn/completed":
            guard let assignmentID,
                  let threadID,
                  let active = activeTurnByAssignment[assignmentID],
                  active.threadID == threadID,
                  message.params?["turn"]?["id"]?.stringValue == active.turnID else { return }
            let turn = message.params?["turn"]
            let status = turn?["status"]?.stringValue
            let outcome = outputByAssignment.removeValue(forKey: assignmentID) ?? "Completed without a text summary."
            activeTurnByAssignment.removeValue(forKey: assignmentID)
            assignmentByThread.removeValue(forKey: threadID)
            projectByAssignment.removeValue(forKey: assignmentID)
            approvalSessionByAssignment.removeValue(forKey: assignmentID)
            resourcesByAssignment.removeValue(forKey: assignmentID)
            approvals = approvals.filter { $0.value.assignmentID != assignmentID }
            fileChangeReviews = fileChangeReviews.filter { $0.value.assignmentID != assignmentID }
            deferredFileChangeApprovals = deferredFileChangeApprovals.filter {
                $0.value.assignmentID != assignmentID
            }
            if status == "failed" || status == "interrupted" || status == "cancelled" {
                eventContinuation.yield(.assignmentFailed(
                    assignmentID,
                    message: Self.turnFailureMessage(status: status, turn: turn)
                ))
            } else {
                eventContinuation.yield(.assignmentCompleted(assignmentID, outcome: outcome))
            }

        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            guard let rpcID = message.id, let assignmentID else { return }
            let token = approvalToken(for: rpcID)
            guard approvals[token] == nil,
                  !deferredFileChangeApprovals.values.contains(where: {
                      approvalToken(for: $0.rpcID) == token
                  }) else {
                approvals.removeValue(forKey: token)
                eventContinuation.yield(.assignmentFailed(
                    assignmentID,
                    message: ProviderApprovalBindingError.duplicatePendingApproval.localizedDescription
                ))
                Task {
                    try? await transport.sendResponse(
                        id: rpcID,
                        result: CodexApprovalResponse(decision: CodexApprovalDecision.decline.rawValue)
                    )
                }
                return
            }
            if method == "item/fileChange/requestApproval",
               let params = message.params,
               let itemID = params["itemId"]?.stringValue,
               fileChangeReviews[itemID] == nil {
                deferredFileChangeApprovals[itemID] = DeferredFileChangeApproval(
                    rpcID: rpcID,
                    assignmentID: assignmentID,
                    params: params
                )
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await self?.publishDeferredFileChangeApproval(itemID: itemID)
                }
                return
            }
            publishApprovalRequest(
                rpcID: rpcID,
                assignmentID: assignmentID,
                method: method,
                params: message.params
            )

        default:
            break
        }
    }

    private func handleQuarantinedStart(
        _ message: IncomingJSONRPCMessage,
        method: String,
        threadID: String,
        turnID: String?
    ) {
        if let rpcID = message.id {
            Task {
                switch method {
                case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                    try? await transport.sendResponse(
                        id: rpcID,
                        result: CodexApprovalResponse(decision: CodexApprovalDecision.decline.rawValue)
                    )
                case "item/permissions/requestApproval":
                    try? await transport.sendResponse(
                        id: rpcID,
                        result: CodexPermissionsApprovalResponse(
                            permissions: .object([:]),
                            scope: "turn"
                        )
                    )
                default:
                    break
                }
            }
        }
        if method == "turn/completed" {
            quarantinedStartByThread.removeValue(forKey: threadID)
            interruptingQuarantinedThreads.remove(threadID)
            return
        }
        guard let turnID, interruptingQuarantinedThreads.insert(threadID).inserted else { return }
        Task {
            let _: JSONValue? = try? await transport.request(
                method: "turn/interrupt",
                params: TurnInterruptParameters(threadID: threadID, turnID: turnID)
            )
        }
    }

    private func handleHelperActivity(
        params: JSONValue?,
        fallbackAssignmentID: AssignmentID?,
        notificationThreadID: String?
    ) {
        guard let item = params?["item"], let type = item["type"]?.stringValue else { return }
        let updatedAt = Self.notificationDate(from: params)
        switch type {
        case "subAgentActivity":
            guard let helperThreadID = item["agentThreadId"]?.stringValue else { return }
            let parentThreadID = notificationThreadID
            let assignmentID = fallbackAssignmentID
                ?? parentThreadID.flatMap { assignmentByThread[$0] }
                ?? assignmentByThread[helperThreadID]
            guard let assignmentID, let projectID = projectByAssignment[assignmentID] else { return }
            assignmentByThread[helperThreadID] = assignmentID
            let existing = helperActivityByThread[helperThreadID]
            let agentPath = item["agentPath"]?.stringValue
            let title = Self.helperTitle(agentPath: agentPath, threadID: helperThreadID)
            let status = Self.helperStatus(activityKind: item["kind"]?.stringValue)
            publishHelper(CodexTaskActivity(
                id: helperThreadID,
                projectID: projectID,
                title: title,
                summary: existing?.summary,
                status: status,
                updatedAt: updatedAt,
                isSubagent: true,
                agentRole: Self.helperRole(agentPath: agentPath) ?? existing?.agentRole,
                parentThreadID: existing?.parentThreadID ?? parentThreadID
            ), assignmentID: assignmentID)

        case "collabAgentToolCall":
            let senderThreadID = item["senderThreadId"]?.stringValue ?? notificationThreadID
            let assignmentID = senderThreadID.flatMap { assignmentByThread[$0] }
                ?? fallbackAssignmentID
            guard let assignmentID, let projectID = projectByAssignment[assignmentID] else { return }
            let receiverThreadIDs: [String]
            if case let .array(values) = item["receiverThreadIds"] {
                receiverThreadIDs = values.compactMap(\.stringValue)
            } else {
                receiverThreadIDs = []
            }
            let states = item["agentsStates"]?.objectValue ?? [:]
            let helperThreadIDs = Array(Set(receiverThreadIDs + states.keys)).sorted()
            guard !helperThreadIDs.isEmpty else { return }
            let tool = item["tool"]?.stringValue
            let prompt = item["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            for helperThreadID in helperThreadIDs {
                assignmentByThread[helperThreadID] = assignmentID
                let existing = helperActivityByThread[helperThreadID]
                let state = states[helperThreadID]
                let message = state?["message"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = [message, existing?.summary, prompt]
                    .compactMap { value -> String? in
                        guard let value, !value.isEmpty else { return nil }
                        return String(value.prefix(4_000))
                    }
                    .first
                let status = Self.helperStatus(
                    agentStatus: state?["status"]?.stringValue,
                    tool: tool,
                    toolStatus: item["status"]?.stringValue,
                    existing: existing?.status
                )
                publishHelper(CodexTaskActivity(
                    id: helperThreadID,
                    projectID: projectID,
                    title: existing?.title ?? Self.helperTitle(agentPath: nil, threadID: helperThreadID),
                    summary: summary,
                    status: status,
                    updatedAt: updatedAt,
                    isSubagent: true,
                    agentRole: existing?.agentRole,
                    parentThreadID: existing?.parentThreadID ?? senderThreadID
                ), assignmentID: assignmentID)
            }

        default:
            return
        }
    }

    private func captureFileChangeReview(params: JSONValue?, assignmentID: AssignmentID) {
        guard let params,
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue else { return }
        let itemID: String?
        let changes: JSONValue?
        if params["item"]?["type"]?.stringValue == "fileChange" {
            itemID = params["item"]?["id"]?.stringValue
            changes = params["item"]?["changes"]
        } else {
            itemID = params["itemId"]?.stringValue
            changes = params["changes"]
        }
        guard let itemID, case .array = changes else { return }
        if fileChangeReviews.count >= 256,
           fileChangeReviews[itemID] == nil,
           let oldestKey = fileChangeReviews.keys.first {
            fileChangeReviews.removeValue(forKey: oldestKey)
        }
        fileChangeReviews[itemID] = FileChangeReview(
            assignmentID: assignmentID,
            payload: .object([
                "changes": changes ?? .array([]),
                "itemId": .string(itemID),
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        publishDeferredFileChangeApproval(itemID: itemID)
    }

    private func publishDeferredFileChangeApproval(itemID: String) {
        guard let deferred = deferredFileChangeApprovals.removeValue(forKey: itemID) else { return }
        publishApprovalRequest(
            rpcID: deferred.rpcID,
            assignmentID: deferred.assignmentID,
            method: "item/fileChange/requestApproval",
            params: deferred.params
        )
    }

    private func publishApprovalRequest(
        rpcID: JSONRPCID,
        assignmentID: AssignmentID,
        method: String,
        params: JSONValue?
    ) {
        let kind: CodexApprovalKind = switch method {
        case "item/commandExecution/requestApproval": .command
        case "item/fileChange/requestApproval": .fileChange
        default: .permissions
        }
        let requestedPermissionProfile: JSONValue? = switch kind {
        case .command: params?["additionalPermissions"]
        case .permissions: params?["permissions"]
        case .fileChange: nil
        }
        let resourcePolicy = Self.enforcingResourceAccess(
            on: requestedPermissionProfile,
            resources: resourcesByAssignment[assignmentID] ?? []
        )
        let commandIsBlocked = kind == .command && resourcePolicy.removedWriteAccess
        let fileChangeReview = params?["itemId"]?.stringValue
            .flatMap { fileChangeReviews[$0]?.payload }
        let binding = Self.approvalOperationBinding(
            method: method,
            params: params,
            effectivePermissions: kind == .permissions ? resourcePolicy.profile : nil,
            fileChangeReview: fileChangeReview
        )
        var summary = params?["command"]?.stringValue
            ?? params?["reason"]?.stringValue
            ?? "Codex requests \(kind.rawValue) approval."
        if commandIsBlocked {
            summary += " Goby blocked approval because it requests write access outside the run's selected read-write resources."
        } else if kind == .permissions, resourcePolicy.removedWriteAccess {
            summary += " Goby removed write access outside the run's selected read-write resources."
        }
        if !binding.disclosureComplete {
            summary += " Goby could not capture every executable field, so this request is decline-only."
        }
        let canAccept = !commandIsBlocked
            && binding.disclosureComplete
            && binding.operationDigest != nil
        let token = approvalToken(for: rpcID)
        approvals[token] = PendingApproval(
            rpcID: rpcID,
            assignmentID: assignmentID,
            kind: kind,
            requestedPermissions: kind == .permissions ? resourcePolicy.profile : nil,
            operationDigest: binding.operationDigest,
            canAccept: canAccept
        )
        eventContinuation.yield(.approvalRequired(.init(
            id: token,
            assignmentID: assignmentID,
            kind: kind,
            summary: summary,
            details: binding.details,
            canAccept: canAccept,
            approvalSessionID: approvalSessionByAssignment[assignmentID],
            operationDigest: binding.operationDigest,
            disclosureComplete: binding.disclosureComplete
        )))
    }

    private func publishHelper(_ activity: CodexTaskActivity, assignmentID: AssignmentID) {
        helperActivityByThread[activity.id] = activity
        eventContinuation.yield(.helperUpdated(assignmentID, activity: activity))
    }

    nonisolated static func notificationDate(from params: JSONValue?) -> Date {
        let milliseconds = params?["completedAtMs"]?.doubleValue
            ?? params?["startedAtMs"]?.doubleValue
        guard let milliseconds, milliseconds > 0 else { return .now }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    nonisolated static func helperRole(agentPath: String?) -> String? {
        guard let component = agentPath?
            .split(separator: "/", omittingEmptySubsequences: true)
            .last else { return nil }
        return String(component)
    }

    nonisolated static func helperTitle(agentPath: String?, threadID: String) -> String {
        let role = helperRole(agentPath: agentPath)
        let raw = role ?? "Helper \(threadID.prefix(6))"
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .map { word in
                let text = String(word)
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Produces bounded, non-sensitive activity copy for work that happens
    /// between assistant text updates. Raw commands, paths, and tool inputs are
    /// deliberately excluded from the map inspector.
    nonisolated static func workProgressMessage(
        item: JSONValue?,
        completed: Bool
    ) -> String? {
        guard let type = item?["type"]?.stringValue else { return nil }
        return switch type {
        case "commandExecution":
            completed ? "Command finished" : "Running a command"
        case "fileChange":
            completed ? "File changes updated" : "Preparing file changes"
        case "mcpToolCall", "dynamicToolCall":
            completed ? "Tool activity finished" : "Using a tool"
        case "webSearch":
            completed ? "Web search finished" : "Searching the web"
        case "imageView":
            completed ? "Image inspection finished" : "Inspecting an image"
        case "reasoning":
            completed ? nil : "Working through the request"
        case "collabAgentToolCall", "subAgentActivity":
            completed ? "Helper-agent activity updated" : "Coordinating helper agents"
        case "plan":
            completed ? "Work plan updated" : "Updating the work plan"
        default:
            nil
        }
    }

    nonisolated static func helperStatus(activityKind: String?) -> CodexTaskStatus {
        switch activityKind {
        case "completed": .completed
        case "interrupted": .cancelled
        case "started", "interacted": .active
        default: .active
        }
    }

    nonisolated static func helperStatus(
        agentStatus: String?,
        tool: String?,
        toolStatus: String?,
        existing: CodexTaskStatus?
    ) -> CodexTaskStatus {
        switch agentStatus {
        case "completed", "shutdown": return .completed
        case "errored", "notFound": return .failed
        case "interrupted": return .cancelled
        case "pendingInit", "running": return .active
        default: break
        }
        if tool == "spawnAgent" { return .active }
        switch toolStatus {
        case "failed": return .failed
        case "interrupted": return .cancelled
        case "inProgress": return .active
        default: return existing ?? .active
        }
    }

    private func approvalToken(for id: JSONRPCID) -> String {
        switch id {
        case let .integer(value): "integer:\(value)"
        case let .string(value): "string:\(value)"
        }
    }

    nonisolated static func turnFailureMessage(status: String?, turn: JSONValue?) -> String {
        switch status {
        case "interrupted":
            return "Codex turn was interrupted before completion. Retry the assignment when ready."
        case "cancelled":
            return "Codex turn was cancelled before completion."
        case "failed":
            let message = turn?["error"]?["message"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let details = turn?["error"]?["additionalDetails"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = [message, details]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n")
            return explanation.isEmpty
                ? "Codex reported that the turn failed without an error message."
                : "Codex turn failed: \(String(explanation.suffix(4_000)))"
        default:
            return "Codex turn ended unexpectedly."
        }
    }

    nonisolated static func shellCacheDirectory(
        for assignmentID: AssignmentID,
        under temporaryDirectory: URL
    ) -> URL {
        let safeID = assignmentID.rawValue.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "_"
        }
        return temporaryDirectory
            .appending(path: "GobyAgentCaches", directoryHint: .isDirectory)
            .appending(path: String(safeID.prefix(96)), directoryHint: .isDirectory)
    }

    nonisolated static func shellCacheConfiguration(
        cacheDirectory: URL,
        toolchainVariables: [String: String] = DeveloperToolchainEnvironment.variables()
    ) -> [String: JSONValue] {
        let cachePath = cacheDirectory.path(percentEncoded: false)
        let moduleCachePath = cacheDirectory
            .appending(path: "clang-module-cache", directoryHint: .isDirectory)
            .path(percentEncoded: false)
        // Required project checks such as `./gradlew test` run exactly as
        // written; a JDK that only a login shell could find must be supplied.
        var variables: [String: JSONValue] = [
            "CLANG_MODULE_CACHE_PATH": .string(moduleCachePath),
            "SWIFTPM_MODULECACHE_OVERRIDE": .string(moduleCachePath),
            "XDG_CACHE_HOME": .string(cachePath),
        ]
        for (name, value) in toolchainVariables { variables[name] = .string(value) }
        for (name, value) in pushBlockingGitConfiguration { variables[name] = .string(value) }
        // Reads such as `git status` would otherwise refresh the index, which
        // a read-only sandbox refuses and turns into an approval request.
        variables["GIT_OPTIONAL_LOCKS"] = .string("0")
        return [
            "shell_environment_policy": .object([
                "inherit": .string("core"),
                "ignore_default_excludes": .bool(false),
                "exclude": .array([
                    "*PASSWORD*", "*PASSWD*", "*CREDENTIAL*", "*AUTH*",
                    "AWS_*", "AZURE_*", "DATABASE_*", "DB_*", "GOOGLE_*",
                    "MONGO*", "MYSQL*", "PG*", "REDIS*", "SSH_*",
                ].map(JSONValue.string)),
                "set": .object(variables)
            ])
        ]
    }

    /// Pushing needs its own approval, which a run never carries. A user's
    /// Codex rules can allow `git push` without asking, so every push from a
    /// Goby turn is rewritten to an address that cannot resolve. Fetching is
    /// unaffected.
    nonisolated static let pushBlockingGitConfiguration: [String: String] = [
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url.goby-blocks-push-during-runs:.pushInsteadOf",
        "GIT_CONFIG_VALUE_0": "",
    ]

    nonisolated static func makeDeveloperInstructions(
        agent: AgentProfile,
        project: LabProject? = nil,
        instructions: [InstructionPack],
        resources: [SharedResource],
        task: String? = nil,
        risk: PlanRisk? = nil
    ) -> String {
        let sharedInstructions = instructions.map { pack in
            "Shared instruction pack: \(pack.name), version \(pack.version)\n\(pack.body)"
        }.joined(separator: "\n\n")
        let roleInstructions = agent.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verification = project.flatMap { project -> String? in
            guard !project.testCommands.isEmpty else { return nil }
            let commands = project.testCommands.enumerated().map {
                "Check \($0.offset + 1): \($0.element)"
            }.joined(separator: "\n")
            if risk == .readOnly {
                return "This request is read-only: answer it without modifying project files, and do not run the project checks below. Only if you change project files anyway, run each check exactly as written, as its own command execution from the project root, before reporting completion:\n\(commands)\nGoby validates the App Server's structured command status and exit code."
            }
            return "Verification requirement: run each check exactly as written, as its own command execution from the project root, inside this Codex turn before reporting completion:\n\(commands)\nGoby validates the App Server's structured command status and exit code. Do not claim completion if a required check was not run or failed."
        }
        let projectTerminology = project.flatMap { project -> String? in
            guard let task,
                  task.range(
                    of: #"\bcore\b"#,
                    options: [.regularExpression, .caseInsensitive]
                  ) != nil else { return nil }
            return "Project terminology for this assignment:\n- “core” means the root folder of the specific assigned project, \(project.name). In this Codex turn, that is the current project workspace root (`.`). Apply instructions about the core there; do not infer a `Core` subfolder or an architectural core layer unless the user explicitly names one."
        }
        return [
            "You are the \(agent.name) agent. \(agent.summary) Work only on the assigned goal and report verification clearly.",
            "Goby usually runs you in an isolated copy of the project that starts from its last commit, so the user's uncommitted changes may not be here. Never push, publish, merge or rebase: Goby blocks pushes during a run, and the user publishes reviewed work themselves. If the request needs the user's uncommitted changes or a push, say so plainly instead of reporting success.",
            roleInstructions.flatMap { $0.isEmpty ? nil : "Agent definition instructions:\n\($0)" } ?? "",
            projectTerminology ?? "",
            verification ?? "",
            sharedInstructions,
            resources.isEmpty ? "" : "User-authorized shared resources:\n" + resources.map {
                "- \($0.name): \($0.url.path(percentEncoded: false)) (\($0.access.displayName.lowercased()))"
            }.joined(separator: "\n") + "\nRespect each declared access level and use the normal approval flow if the sandbox requires broader access."
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    nonisolated static func permissionDetails(for permissions: JSONValue?) -> String? {
        guard let permissions,
              let data = try? JSONEncoder.sortedPretty.encode(permissions) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Produces the bounded, canonical object that an approval decision binds to.
    /// Unknown app-server fields fail closed so protocol evolution cannot silently
    /// make a partial disclosure appear complete.
    nonisolated static func approvalOperationBinding(
        method: String,
        params: JSONValue?,
        effectivePermissions: JSONValue? = nil,
        fileChangeReview: JSONValue? = nil,
        maximumBytes: Int = ApprovalDisclosureLimits.canonicalDetailsUTF8Limit
    ) -> (details: String?, operationDigest: String?, disclosureComplete: Bool) {
        guard case let .object(request)? = params else {
            return (nil, nil, false)
        }

        let allowedKeys: Set<String>
        let requiredKeys: Set<String>
        switch method {
        case "item/commandExecution/requestApproval":
            allowedKeys = [
                "additionalPermissions", "approvalId", "availableDecisions", "command",
                "commandActions", "cwd", "environmentId", "itemId", "kind",
                "networkApprovalContext", "proposedExecpolicyAmendment",
                "proposedNetworkPolicyAmendments", "reason", "startedAtMs", "threadId", "turnId",
            ]
            requiredKeys = ["itemId", "startedAtMs", "threadId", "turnId"]
        case "item/fileChange/requestApproval":
            allowedKeys = ["grantRoot", "itemId", "reason", "startedAtMs", "threadId", "turnId"]
            requiredKeys = ["itemId", "startedAtMs", "threadId", "turnId"]
        case "item/permissions/requestApproval":
            allowedKeys = ["cwd", "environmentId", "itemId", "permissions", "reason", "startedAtMs", "threadId", "turnId"]
            requiredKeys = ["cwd", "itemId", "permissions", "startedAtMs", "threadId", "turnId"]
        default:
            return (nil, nil, false)
        }

        guard Set(request.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(request.keys)),
              request["itemId"]?.stringValue?.isEmpty == false,
              request["threadId"]?.stringValue?.isEmpty == false,
              request["turnId"]?.stringValue?.isEmpty == false,
              request["startedAtMs"]?.doubleValue != nil else {
            return (nil, nil, false)
        }

        var operation: [String: JSONValue] = [
            "method": .string(method),
            "request": .object(request),
            "schema": .string("goby.codex.approval-operation.v1"),
        ]
        var complete = true

        switch method {
        case "item/commandExecution/requestApproval":
            guard !request.keys.contains("kind")
                    || request["kind"]?.stringValue == "command" else {
                complete = false
                break
            }
            let hasCommand = request.keys.contains("command")
            let hasActions = request.keys.contains("commandActions")
            let command = request["command"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actions: [JSONValue]? = if case let .array(values)? = request["commandActions"] {
                values
            } else {
                nil
            }
            let commandIsComplete = hasCommand && command?.isEmpty == false
            let actionsAreComplete = hasActions
                && actions?.isEmpty == false
                && actions?.allSatisfy(Self.commandActionIsStructurallyComplete) == true
            let executableRepresentationIsComplete: Bool = switch (hasCommand, hasActions) {
            case (true, false):
                commandIsComplete
            case (false, true):
                actionsAreComplete
            case (true, true):
                // commandActions is best-effort display metadata. When it accompanies the
                // authoritative command, keep it structurally valid and digest-bound without
                // requiring its parsed actions to reproduce the shell wrapper byte-for-byte.
                commandIsComplete && actionsAreComplete
            case (false, false):
                false
            }
            guard request["cwd"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                executableRepresentationIsComplete else {
                complete = false
                break
            }

        case "item/permissions/requestApproval":
            guard request["cwd"]?.stringValue?.isEmpty == false,
                  request["permissions"] != nil,
                  let effectivePermissions else {
                complete = false
                break
            }
            operation["effectiveGrant"] = effectivePermissions
            operation["responseScope"] = .string("turn")

        case "item/fileChange/requestApproval":
            guard let review = fileChangeReview?.objectValue,
                  review["itemId"]?.stringValue == request["itemId"]?.stringValue,
                  review["threadId"]?.stringValue == request["threadId"]?.stringValue,
                  review["turnId"]?.stringValue == request["turnId"]?.stringValue,
                  case .array? = review["changes"] else {
                complete = false
                break
            }
            operation["changes"] = review["changes"]

        default:
            break
        }

        guard let prettyData = try? JSONEncoder.sortedPretty.encode(JSONValue.object(operation)),
              prettyData.count <= maximumBytes else {
            return (nil, nil, false)
        }
        let details = String(decoding: prettyData, as: UTF8.self)
        guard complete,
              let canonicalData = try? JSONEncoder.sortedCompact.encode(JSONValue.object(operation)) else {
            return (details, nil, false)
        }
        let digest = SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
        return (details, digest, true)
    }

    private nonisolated static func commandActionIsStructurallyComplete(_ value: JSONValue) -> Bool {
        guard case let .object(action) = value,
              let type = action["type"]?.stringValue,
              let command = action["command"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return false
        }

        let optionalStringOrNull: (JSONValue?) -> Bool = { value in
            guard let value else { return true }
            switch value {
            case .string, .null: return true
            default: return false
            }
        }

        switch type {
        case "read":
            return Set(action.keys).isSubset(of: ["command", "name", "path", "type"])
                && action["name"]?.stringValue != nil
                && action["path"]?.stringValue != nil
        case "listFiles":
            return Set(action.keys).isSubset(of: ["command", "path", "type"])
                && optionalStringOrNull(action["path"])
        case "search":
            return Set(action.keys).isSubset(of: ["command", "path", "query", "type"])
                && optionalStringOrNull(action["path"])
                && optionalStringOrNull(action["query"])
        case "unknown":
            return Set(action.keys).isSubset(of: ["command", "type"])
        default:
            return false
        }
    }

    nonisolated static func enforcingResourceAccess(
        on requestedPermissions: JSONValue?,
        resources: [SharedResource]
    ) -> (profile: JSONValue, removedWriteAccess: Bool) {
        let requestedPermissions = requestedPermissions ?? .object([:])
        guard case var .object(profile) = requestedPermissions,
              case let .object(fileSystem)? = profile["fileSystem"] else {
            return (requestedPermissions, false)
        }

        let readWriteRoots = resources
            .filter { $0.access == .readWrite }
            .map { $0.url.standardizedFileURL.resolvingSymlinksInPath() }
        var filteredFileSystem = fileSystem
        var removedWriteAccess = false

        if case let .array(entries)? = filteredFileSystem["entries"] {
            let allowedEntries = entries.filter { entry in
                guard entry["access"]?.stringValue == "write" else { return true }
                guard let path = entry["path"]?.objectValue,
                      path["type"]?.stringValue == "path",
                      let requestedPath = path["path"]?.stringValue,
                      isWritePath(requestedPath, containedIn: readWriteRoots) else {
                    removedWriteAccess = true
                    return false
                }
                return true
            }
            filteredFileSystem["entries"] = .array(allowedEntries)
        }

        if case let .array(writePaths)? = filteredFileSystem["write"] {
            let allowedPaths = writePaths.filter { value in
                guard let path = value.stringValue,
                      isWritePath(path, containedIn: readWriteRoots) else {
                    removedWriteAccess = true
                    return false
                }
                return true
            }
            filteredFileSystem["write"] = .array(allowedPaths)
        }

        profile["fileSystem"] = .object(filteredFileSystem)
        return (.object(profile), removedWriteAccess)
    }

    nonisolated private static func isWritePath(_ path: String, containedIn roots: [URL]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return roots.contains { root in
            let rootComponents = root.pathComponents
            let candidateComponents = candidate.pathComponents
            return candidateComponents.count >= rootComponents.count
                && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        }
    }

    /// Maps an App Server item to a run-thread step. Credentials are removed;
    /// local paths stay because steps are only shown on this Mac.
    nonisolated static func activityStep(
        from item: JSONValue?,
        assignmentID: AssignmentID,
        completed: Bool,
        now: Date = .now
    ) -> RunActivityStep? {
        guard let item, let type = item["type"]?.stringValue, let id = item["id"]?.stringValue else { return nil }
        func clean(_ text: String?, limit: Int) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SensitiveTextRedactor.redactCredentials(text, limit: limit)
        }
        let itemStatus = item["status"]?.stringValue
        let status: RunActivityStep.Status = switch itemStatus {
        case "failed", "declined": .failed
        default: completed ? .succeeded : .running
        }
        let finishedAt = completed ? now : nil
        switch type {
        case "commandExecution":
            guard let command = clean(item["command"]?.stringValue.map(unwrappedShellCommand), limit: RunActivityStep.titleLimit) else {
                return nil
            }
            let exitCode = item["exitCode"]?.doubleValue.map(Int.init)
            let commandStatus: RunActivityStep.Status = if let exitCode, completed {
                exitCode == 0 ? .succeeded : .failed
            } else { status }
            let output = clean(item["aggregatedOutput"]?.stringValue, limit: 64_000)
            // Codex parses what a command does (read, search, list). Name the
            // step by that; the exact command stays in the detail.
            if let described = describedCommand(actions: item["commandActions"]) {
                return RunActivityStep(
                    id: id, assignmentID: assignmentID, kind: described.kind,
                    title: clean(described.title, limit: RunActivityStep.titleLimit) ?? described.title,
                    detail: "$ \(command)" + (output.map { "\n\n\($0)" } ?? ""),
                    status: commandStatus, exitCode: exitCode, startedAt: now, finishedAt: finishedAt
                )
            }
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .command, title: command,
                detail: output,
                status: commandStatus, exitCode: exitCode, startedAt: now, finishedAt: finishedAt
            )
        case "fileChange":
            var paths: [String] = []
            if case let .array(changes)? = item["changes"] {
                paths = changes.compactMap { $0["path"]?.stringValue }
            }
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            let title = names.isEmpty
                ? "Editing files"
                : "Edited \(names.count == 1 ? names[0] : "\(names.count) files: \(names.prefix(4).joined(separator: ", "))")"
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .fileChange, title: title,
                detail: paths.isEmpty ? nil : paths.joined(separator: "\n"),
                status: status, startedAt: now, finishedAt: finishedAt
            )
        case "webSearch":
            let query = clean(item["query"]?.stringValue, limit: RunActivityStep.titleLimit)
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .webSearch,
                title: query.map { "Searched “\($0)”" } ?? "Searching the web",
                status: status, startedAt: now, finishedAt: finishedAt
            )
        case "mcpToolCall", "dynamicToolCall":
            let failure = item["error"]?["message"]?.stringValue ?? item["error"]?.stringValue
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .tool,
                title: toolDisplayName(server: item["server"]?.stringValue, tool: item["tool"]?.stringValue),
                detail: clean(failure, limit: RunActivityStep.detailLimit),
                status: failure != nil && completed ? .failed : status, startedAt: now, finishedAt: finishedAt
            )
        case "agentMessage":
            guard completed, let text = clean(item["text"]?.stringValue, limit: RunActivityStep.messageLimit) else { return nil }
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .message, title: text,
                status: .succeeded, startedAt: now, finishedAt: now
            )
        case "plan":
            guard completed, let text = clean(item["text"]?.stringValue, limit: RunActivityStep.messageLimit) else { return nil }
            return RunActivityStep(
                id: id, assignmentID: assignmentID, kind: .plan, title: text,
                status: .succeeded, startedAt: now, finishedAt: now
            )
        default:
            return nil
        }
    }

    /// A read, search or list description when every parsed action is one
    /// of those; nil for real work (builds, tests) or unparsed commands.
    nonisolated static func describedCommand(actions: JSONValue?) -> (kind: RunActivityStep.Kind, title: String)? {
        guard case let .array(values)? = actions, !values.isEmpty else { return nil }
        var reads: [String] = []
        var searches: [String] = []
        var lists: [String] = []
        for action in values {
            switch action["type"]?.stringValue {
            case "read":
                let path = action["path"]?.stringValue ?? action["name"]?.stringValue ?? ""
                reads.append(action["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent)
            case "search":
                let query = action["query"]?.stringValue
                let path = action["path"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent }
                searches.append([query.map { "“\($0)”" }, path.map { "in \($0)" }].compactMap { $0 }.joined(separator: " "))
            case "listFiles":
                lists.append(action["path"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
            default:
                return nil
            }
        }
        func joined(_ names: [String]) -> String {
            let unique = names.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.count > 3 ? unique.prefix(3).joined(separator: ", ") + " +\(unique.count - 3)" : unique.joined(separator: ", ")
        }
        if !reads.isEmpty, searches.isEmpty, lists.isEmpty { return (.read, "Read \(joined(reads))") }
        if !searches.isEmpty, reads.isEmpty {
            let text = joined(searches)
            return (.search, text.isEmpty ? "Searched files" : "Searched \(text)")
        }
        if !lists.isEmpty, reads.isEmpty, searches.isEmpty {
            let text = joined(lists)
            return (.list, text.isEmpty ? "Listed files" : "Listed \(text)")
        }
        return (.read, "Explored \(joined(reads + searches + lists))")
    }

    /// Readable names for tools that report only an internal identifier.
    nonisolated static func toolDisplayName(server: String?, tool: String?) -> String {
        switch (server, tool) {
        case ("cua_repl", _): return "Used the browser"
        case ("codex_apps", let tool?): return "Used Codex apps · \(tool.replacingOccurrences(of: "_", with: " "))"
        default:
            let parts = [server, tool].compactMap { $0?.replacingOccurrences(of: "_", with: " ") }
            return parts.isEmpty ? "Used a tool" : "Used \(parts.joined(separator: " · "))"
        }
    }

    /// `/bin/zsh -lc 'npm test'` reads better as `npm test`.
    nonisolated static func unwrappedShellCommand(_ command: String) -> String {
        let pattern = #"^\S*/(?:zsh|bash|sh) -l?c (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return command }
        var inner = String(command[range]).trimmingCharacters(in: .whitespaces)
        if inner.count >= 2, let first = inner.first, first == inner.last, first == "'" || first == "\"" {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner
    }

    nonisolated static func commandExecutionEvidence(from params: JSONValue?) -> CodexCommandExecutionEvidence? {
        guard let item = params?["item"],
              item["type"]?.stringValue == "commandExecution",
              let id = item["id"]?.stringValue,
              let command = item["command"]?.stringValue,
              let cwd = item["cwd"]?.stringValue,
              let statusValue = item["status"]?.stringValue else { return nil }
        let actionCommands: [String]
        if case let .array(actions)? = item["commandActions"] {
            actionCommands = actions.compactMap { $0["command"]?.stringValue }
        } else {
            actionCommands = []
        }
        return CodexCommandExecutionEvidence(
            id: id,
            command: command,
            actionCommands: actionCommands,
            workingDirectory: URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL,
            status: CodexCommandExecutionStatus(rawValue: statusValue) ?? .unknown,
            exitCode: item["exitCode"]?.doubleValue.map(Int.init),
            durationMilliseconds: item["durationMs"]?.doubleValue.map(Int.init),
            source: item["source"]?.stringValue ?? "agent"
        )
    }

    nonisolated static func sandbox(for risk: PlanRisk) -> String {
        risk == .readOnly ? "read-only" : "workspace-write"
    }
}

private struct CodexConfigReadParameters: Codable, Sendable {
    let includeLayers: Bool
}

private struct CodexModelListParameters: Codable, Sendable {
    let limit: Int
}

private extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var sortedCompact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
