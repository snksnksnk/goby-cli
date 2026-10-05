import Foundation
import GobyApplication
import GobyDomain

/// Goby's temporary chat on Codex.
///
/// Chats run in their own `codex app-server` process with a Goby-owned,
/// minimal Codex home. That home has no MCP servers, no shell or execution
/// features and no hooks or memories. Every turn also disables the account's
/// plugins, and the thread uses a read-only sandbox with approvals set to
/// never in an empty folder. What remains is the model and web search. The
/// thread is ephemeral, so Codex does not save it, and Goby keeps the chat in
/// memory only.
///
/// The chat home links to the Mac's existing Codex sign-in (`auth.json`) so
/// no second sign-in is needed. The user chose this knowingly: if Codex
/// replaces that file while refreshing a token, the link is restored before
/// the next chat starts.
public actor CodexTemporaryChatService: TemporaryChatServing {
    private let transport: CodexAppServerTransport
    private let homeURL: URL
    private let workspaceURL: URL
    private let sourceAuthURL: URL
    private let now: @Sendable () -> Date
    private var session = CodexTemporaryChatSession()
    private var connected = false
    private var disabledPluginIDs: [String] = []
    private var defaultModel: String?
    private var listener: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private let updateStream: AsyncStream<TemporaryChat?>
    private let updateContinuation: AsyncStream<TemporaryChat?>.Continuation

    public init(
        executableURL: URL,
        clientVersion: String,
        supportDirectoryURL: URL,
        sourceCodexHomeURL: URL = CodexTemporaryChatService.defaultCodexHome(),
        runtimeValidator: any CodexRuntimeValidating = CodexRuntimeIntegrityValidator(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        let root = supportDirectoryURL.appending(path: "TemporaryChat", directoryHint: .isDirectory)
        homeURL = root.appending(path: "CodexHome", directoryHint: .isDirectory)
        workspaceURL = root.appending(path: "Workspace", directoryHint: .isDirectory)
        sourceAuthURL = sourceCodexHomeURL.appending(path: "auth.json")
        self.now = now
        transport = CodexAppServerTransport(
            executableURL: executableURL,
            clientVersion: clientVersion,
            runtimeValidator: runtimeValidator,
            environmentOverrides: ["CODEX_HOME": homeURL.path(percentEncoded: false)]
        )
        let pair = AsyncStream<TemporaryChat?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    /// A disposable location outside Goby's backed-up data folder.
    public static func defaultSupportDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "com.demetrisgeorgiou.GobyAgenticDashboard", directoryHint: .isDirectory)
    }

    public static func defaultCodexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    // MARK: - TemporaryChatServing

    public func current() -> TemporaryChat? { session.chat }

    public func updates() -> AsyncStream<TemporaryChat?> { updateStream }

    public func ask(_ question: String, in chatID: TemporaryChatID?, model: String?) async throws -> TemporaryChat {
        guard let question = TemporaryChat.normalizedQuestion(question) else {
            throw TemporaryChatError.emptyQuestion
        }
        if let chat = session.chat {
            if let chatID {
                guard chat.id == chatID else { throw TemporaryChatError.staleChat }
            } else {
                // A new chat replaces the finished one.
                guard chat.canAsk else { throw TemporaryChatError.answering }
                await forgetChat()
            }
            guard session.chat?.canAsk ?? true else { throw TemporaryChatError.answering }
        } else if chatID != nil {
            throw TemporaryChatError.staleChat
        }

        try await ensureConnected()
        if session.chat == nil {
            session.chat = TemporaryChat(model: model ?? defaultModel, startedAt: now(), updatedAt: now())
        }
        session.beginAnswer(to: question, at: now())
        publishNow()

        do {
            if session.threadID == nil {
                let thread: JSONValue = try await transport.request(
                    method: "thread/start",
                    params: ThreadStartParameters(
                        approvalPolicy: "never",
                        cwd: workspaceURL.path(percentEncoded: false),
                        developerInstructions: Self.developerInstructions,
                        model: session.chat?.model,
                        sandbox: "read-only",
                        ephemeral: true
                    )
                )
                guard let threadID = thread["thread"]?["id"]?.stringValue else {
                    throw CodexTransportError.malformedResponse
                }
                session.threadID = threadID
            }
            guard let threadID = session.threadID else { throw CodexTransportError.malformedResponse }
            let turn: JSONValue = try await transport.request(
                method: "turn/start",
                params: TurnStartParameters(
                    threadID: threadID,
                    prompt: question,
                    approvalPolicy: "never",
                    disabledPluginIds: disabledPluginIDs
                )
            )
            if session.turnID == nil, session.chat?.status == .answering {
                session.turnID = turn["turn"]?["id"]?.stringValue
            }
        } catch {
            session.fail("Codex could not answer: \(error.localizedDescription)", at: now())
            publishNow()
        }
        scheduleExpiry()
        guard let chat = session.chat else { throw TemporaryChatError.staleChat }
        return chat
    }

    public func end(_ chatID: TemporaryChatID) async {
        guard session.chat?.id == chatID else { return }
        await forgetChat()
        publishNow()
    }

    // MARK: - Connection

    private func ensureConnected() async throws {
        try prepareHome()
        if connected { return }
        do {
            _ = try await transport.start()
        } catch {
            throw TemporaryChatError.unavailable("Codex could not start for temporary chat: \(error.localizedDescription)")
        }
        let notifications = await transport.notifications()
        listener?.cancel()
        listener = Task { [weak self] in
            for await message in notifications {
                guard !Task.isCancelled else { return }
                await self?.handle(message)
            }
        }
        // Fail closed: a chat never starts while plugins might still be on.
        do {
            let plugins: JSONValue = try await transport.request(method: "plugin/installed", params: EmptyParameters())
            disabledPluginIDs = Self.enabledPluginIDs(in: plugins)
        } catch {
            await transport.stop()
            throw TemporaryChatError.unavailable("Codex could not confirm which plugins to switch off, so temporary chat did not start.")
        }
        connected = true
        if let models: JSONValue = try? await transport.request(method: "model/list", params: EmptyParameters()) {
            defaultModel = Self.defaultModel(in: models)
        }
    }

    /// Writes the minimal chat home and links the Mac's Codex sign-in.
    private func prepareHome() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: sourceAuthURL.path(percentEncoded: false)) else {
            throw TemporaryChatError.notSignedIn
        }
        try files.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try files.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let configURL = homeURL.appending(path: "config.toml")
        let configuration = Data(Self.homeConfiguration.utf8)
        if (try? Data(contentsOf: configURL)) != configuration {
            try configuration.write(to: configURL, options: [.atomic])
        }
        let authURL = homeURL.appending(path: "auth.json")
        let existingDestination = try? files.destinationOfSymbolicLink(atPath: authURL.path(percentEncoded: false))
        if existingDestination != sourceAuthURL.path(percentEncoded: false) {
            try? files.removeItem(at: authURL)
            try files.createSymbolicLink(at: authURL, withDestinationURL: sourceAuthURL)
        }
    }

    private func handle(_ message: IncomingJSONRPCMessage) async {
        guard let method = message.method else { return }
        if let id = message.id {
            // No approvals are expected with approvals set to never; decline
            // anything that still asks, so nothing runs on the user's behalf.
            try? await transport.sendResponse(id: id, result: DeclineResponse())
            return
        }
        switch method {
        case "goby/connectionClosed", "goby/transportError":
            connected = false
            listener = nil
            if session.connectionLost(at: now()) { publishNow() }
        default:
            guard session.handle(method: method, params: message.params, at: now()) else { return }
            if session.chat?.status == .answering {
                publishSoon()
            } else {
                publishNow()
                scheduleExpiry()
            }
        }
    }

    private func forgetChat() async {
        if session.chat?.status == .answering, let threadID = session.threadID, let turnID = session.turnID {
            let _: JSONValue? = try? await transport.request(
                method: "turn/interrupt",
                params: TurnInterruptParameters(threadID: threadID, turnID: turnID)
            )
        }
        session = CodexTemporaryChatSession()
        expiryTask?.cancel()
        expiryTask = nil
    }

    // MARK: - Publishing

    private func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        updateContinuation.yield(session.chat)
    }

    /// Streamed text is published at most every 300 ms.
    private func publishSoon() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.publishNow()
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TemporaryChat.idleLifetime))
            guard !Task.isCancelled else { return }
            await self?.expireIfIdle()
        }
    }

    private func expireIfIdle() async {
        guard let chat = session.chat, chat.isExpired(at: now()) else { return }
        await forgetChat()
        publishNow()
        await transport.stop()
        connected = false
    }

    // MARK: - Pure helpers

    static let developerInstructions = """
    You are answering in Goby's temporary chat: a quick question outside any project. \
    Answer directly and concisely in Markdown. You have no access to the user's files, \
    projects, commands, plugins or connected services, and must not try to use them. \
    Web search is allowed when it helps. If a question needs work in a project, say so \
    briefly and suggest asking Goby with that project selected.
    """

    /// The chat home's whole configuration. Features that could reach files,
    /// commands or other agents are off; MCP servers are never configured.
    static let homeConfiguration = """
    # Written by Goby Agentic Dashboard for temporary chat. Do not edit.
    approval_policy = "never"
    sandbox_mode = "read-only"

    [features]
    shell_tool = false
    unified_exec = false
    apps = false
    multi_agent = false
    multi_agent_v2 = false
    memories = false
    hooks = false
    code_mode = false
    image_generation = false
    view_image = false
    request_permissions_tool = false
    goals = false

    """

    static func enabledPluginIDs(in response: JSONValue) -> [String] {
        guard case let .array(marketplaces)? = response["marketplaces"] else { return [] }
        return marketplaces.flatMap { marketplace -> [String] in
            guard case let .array(plugins)? = marketplace["plugins"] else { return [] }
            return plugins.compactMap { plugin in
                plugin["enabled"]?.boolValue == true ? plugin["id"]?.stringValue : nil
            }
        }
        .sorted()
    }

    static func defaultModel(in response: JSONValue) -> String? {
        guard case let .array(models)? = response["data"] else { return nil }
        let chosen = models.first { $0["isDefault"]?.boolValue == true } ?? models.first
        return chosen?["id"]?.stringValue ?? chosen?["model"]?.stringValue
    }

    private struct DeclineResponse: Encodable, Sendable {
        let decision = "decline"
    }
}

/// The chat and its Codex thread, advanced by app-server notifications.
struct CodexTemporaryChatSession: Sendable {
    var chat: TemporaryChat?
    var threadID: String?
    var turnID: String?
    private var answerItemID: String?

    mutating func beginAnswer(to question: String, at date: Date) {
        chat?.append(.init(role: .user, text: question, createdAt: date))
        chat?.status = .answering
        chat?.failureMessage = nil
        turnID = nil
        answerItemID = nil
    }

    mutating func fail(_ message: String, at date: Date) {
        chat?.status = .failed
        chat?.failureMessage = String(message.prefix(1_000))
        chat?.updatedAt = date
        turnID = nil
    }

    /// The process ended. Its threads are gone, so the next question starts
    /// a fresh thread. Returns whether the chat changed.
    mutating func connectionLost(at date: Date) -> Bool {
        threadID = nil
        guard chat?.status == .answering else { return false }
        fail("Codex stopped before answering. Ask again to continue in a new thread.", at: date)
        return true
    }

    /// Applies one notification. Returns whether the chat changed.
    mutating func handle(method: String, params: JSONValue?, at date: Date) -> Bool {
        guard chat != nil, let threadID, params?["threadId"]?.stringValue == threadID else { return false }
        let notificationTurnID = params?["turnId"]?.stringValue ?? params?["turn"]?["id"]?.stringValue
        if let turnID, let notificationTurnID, notificationTurnID != turnID { return false }
        switch method {
        case "turn/started":
            turnID = notificationTurnID ?? turnID
            return false
        case "item/agentMessage/delta":
            guard chat?.status == .answering, let delta = params?["delta"]?.stringValue else { return false }
            let itemID = params?["itemId"]?.stringValue
            if let itemID, let answerItemID, itemID != answerItemID,
               chat?.messages.last?.role == .assistant, chat?.messages.last?.text.isEmpty == false {
                chat?.appendAnswerText("\n\n", at: date)
            }
            answerItemID = itemID ?? answerItemID
            chat?.appendAnswerText(delta, at: date)
            return true
        case "turn/completed":
            let turn = params?["turn"]
            switch turn?["status"]?.stringValue {
            case "completed", "interrupted", "cancelled":
                if chat?.messages.last?.role != .assistant {
                    chat?.appendAnswerText(Self.finalText(in: turn) ?? "No answer was returned.", at: date)
                }
                chat?.status = .ready
                chat?.updatedAt = date
                turnID = nil
            default:
                fail(CodexGateway.turnFailureMessage(status: turn?["status"]?.stringValue, turn: turn), at: date)
            }
            return true
        case "error":
            guard params?["willRetry"]?.boolValue != true, chat?.status == .answering else { return false }
            fail(params?["error"]?["message"]?.stringValue ?? "Codex reported an error.", at: date)
            return true
        default:
            return false
        }
    }

    private static func finalText(in turn: JSONValue?) -> String? {
        guard case let .array(items)? = turn?["items"] else { return nil }
        let texts = items.compactMap { item -> String? in
            item["type"]?.stringValue == "agentMessage" ? item["text"]?.stringValue : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}
