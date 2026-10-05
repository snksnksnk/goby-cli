import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct CodexTemporaryChatTests {
    private func object(_ values: [String: JSONValue]) -> JSONValue { .object(values) }

    private func answering() -> CodexTemporaryChatSession {
        var session = CodexTemporaryChatSession()
        session.chat = TemporaryChat()
        session.threadID = "thread-1"
        session.beginAnswer(to: "What is 17 × 23?", at: .now)
        return session
    }

    @Test("Streamed text builds one answer and completion makes the chat ready")
    func streamsAnswer() {
        var session = answering()
        for delta in ["39", "1"] {
            do { let changed = session.handle(method: "item/agentMessage/delta", params: object([
                "threadId": .string("thread-1"), "turnId": .string("turn-1"),
                "itemId": .string("item-1"), "delta": .string(delta),
            ]), at: .now); #expect(changed) }
        }
        do { let changed = session.handle(method: "turn/completed", params: object([
            "threadId": .string("thread-1"),
            "turn": object(["id": .string("turn-1"), "status": .string("completed")]),
        ]), at: .now); #expect(changed) }
        #expect(session.chat?.messages.map(\.role) == [.user, .assistant])
        #expect(session.chat?.messages.last?.text == "391")
        #expect(session.chat?.status == .ready)
    }

    @Test("Separate answer messages in one turn are kept as paragraphs")
    func separatesMessages() {
        var session = answering()
        for (item, delta) in [("a", "Checking."), ("b", "391")] {
            _ = session.handle(method: "item/agentMessage/delta", params: object([
                "threadId": .string("thread-1"), "itemId": .string(item), "delta": .string(delta),
            ]), at: .now)
        }
        #expect(session.chat?.messages.last?.text == "Checking.\n\n391")
    }

    @Test("Other threads and stale turns cannot change the chat")
    func ignoresOtherThreads() {
        var session = answering()
        session.turnID = "turn-1"
        do { let changed = session.handle(method: "item/agentMessage/delta", params: object([
            "threadId": .string("run-thread"), "delta": .string("secret"),
        ]), at: .now); #expect(!changed) }
        do { let changed = session.handle(method: "item/agentMessage/delta", params: object([
            "threadId": .string("thread-1"), "turnId": .string("old-turn"), "delta": .string("late"),
        ]), at: .now); #expect(!changed) }
        #expect(session.chat?.messages.count == 1)
    }

    @Test("A failed turn keeps the chat usable and explains why")
    func failedTurn() {
        var session = answering()
        do { let changed = session.handle(method: "turn/completed", params: object([
            "threadId": .string("thread-1"),
            "turn": object([
                "status": .string("failed"),
                "error": object(["message": .string("The model is not supported.")]),
            ]),
        ]), at: .now); #expect(changed) }
        #expect(session.chat?.status == .failed)
        #expect(session.chat?.failureMessage?.contains("not supported") == true)
        #expect(session.chat?.canAsk == true)
    }

    @Test("Losing Codex mid-answer fails the question and forgets the dead thread")
    func connectionLoss() {
        var session = answering()
        do { let changed = session.connectionLost(at: .now); #expect(changed) }
        #expect(session.threadID == nil)
        #expect(session.chat?.status == .failed)
    }

    @Test("Only enabled plugins are switched off, and the default model is chosen")
    func parsesCatalogs() {
        let plugins = object(["marketplaces": .array([object(["plugins": .array([
            object(["id": .string("github@remote"), "enabled": .bool(true)]),
            object(["id": .string("gmail@remote"), "enabled": .bool(false)]),
            object(["id": .string("codex-security@remote"), "enabled": .bool(true)]),
        ])])])])
        #expect(CodexTemporaryChatService.enabledPluginIDs(in: plugins) == ["codex-security@remote", "github@remote"])
        let models = object(["data": .array([
            object(["id": .string("model-a"), "isDefault": .bool(false)]),
            object(["id": .string("model-b"), "isDefault": .bool(true)]),
        ])])
        #expect(CodexTemporaryChatService.defaultModel(in: models) == "model-b")
    }

    @Test("The chat home turns off every tool that reaches files, commands or other agents")
    func homeConfiguration() {
        let config = CodexTemporaryChatService.homeConfiguration
        for feature in ["shell_tool", "unified_exec", "apps", "multi_agent", "code_mode", "hooks", "memories"] {
            #expect(config.contains("\(feature) = false"))
        }
        #expect(config.contains("approval_policy = \"never\""))
        #expect(config.contains("sandbox_mode = \"read-only\""))
        #expect(!config.contains("mcp_servers"))
    }

    @Test("Temporary chat requests are ephemeral, read-only and never ask for approval")
    func requestShape() throws {
        let thread = String(decoding: try JSONEncoder().encode(ThreadStartParameters(
            approvalPolicy: "never", cwd: "/tmp/chat", sandbox: "read-only", ephemeral: true
        )), as: UTF8.self)
        #expect(thread.contains("\"ephemeral\":true"))
        let turn = String(decoding: try JSONEncoder().encode(TurnStartParameters(
            threadID: "t", prompt: "hi", approvalPolicy: "never", disabledPluginIds: ["github@remote"]
        )), as: UTF8.self)
        #expect(turn.contains("disabledPluginIds"))
        // Existing run requests are unchanged.
        let run = String(decoding: try JSONEncoder().encode(TurnStartParameters(threadID: "t", prompt: "hi")), as: UTF8.self)
        #expect(!run.contains("disabledPluginIds"))
    }

    @Test("Questions are trimmed, bounded and never empty")
    func questions() {
        #expect(TemporaryChat.normalizedQuestion("   \n") == nil)
        #expect(TemporaryChat.normalizedQuestion(" hi ") == "hi")
        #expect(TemporaryChat.normalizedQuestion(String(repeating: "a", count: 9_000))?.count == TemporaryChat.questionLimit)
    }

    /// Talks to the real Codex on this Mac. Opt in with GOBY_LIVE_CODEX_CHAT=1.
    @Test(
        "Live: answers a question without file or command access",
        .enabled(if: ProcessInfo.processInfo.environment["GOBY_LIVE_CODEX_CHAT"] == "1")
    )
    func liveChat() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "goby-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let service = CodexTemporaryChatService(
            executableURL: InstalledCodexLocator.locate(),
            clientVersion: "test",
            supportDirectoryURL: support
        )
        var chat = try await service.ask("What is 17*23? Reply with just the number.", in: nil, model: nil)
        chat = try await waitForAnswer(service)
        #expect(chat.messages.last?.text.contains("391") == true)
        _ = try await service.ask(
            "Use any tool to list the files in my home folder and tell me the first one. If you cannot, reply exactly NO ACCESS.",
            in: chat.id, model: nil
        )
        chat = try await waitForAnswer(service)
        #expect(chat.messages.count == 4)
        #expect(chat.messages.last?.text.contains("NO ACCESS") == true)
        await service.end(chat.id)
        #expect(await service.current() == nil)
    }

    private func waitForAnswer(_ service: CodexTemporaryChatService) async throws -> TemporaryChat {
        for _ in 0..<240 {
            if let chat = await service.current(), chat.status != .answering {
                if chat.status == .failed { print("LIVE FAILURE:", chat.failureMessage ?? "failed"); Issue.record("\(chat.failureMessage ?? "failed")") }
                return chat
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CancellationError()
    }
}
