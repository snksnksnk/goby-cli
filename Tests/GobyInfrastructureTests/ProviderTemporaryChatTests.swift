import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

@Suite("ProviderTemporaryChatTests")
struct ProviderTemporaryChatTests {
    private func waitUntilReady(_ service: ClaudeTemporaryChatService) async throws -> TemporaryChat {
        for _ in 0..<100 {
            if let chat = await service.current(), chat.status != .answering { return chat }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(await service.current())
    }

    @Test("Claude chat answers and carries earlier turns in the prompt")
    func claudeChatAnswers() async throws {
        let prompts = PromptLog()
        let service = ClaudeTemporaryChatService(ask: { prompt, _ in
            await prompts.record(prompt)
            return "Answer \(await prompts.count)"
        })
        let first = try await service.ask("What is Swift?", in: nil, model: nil)
        #expect(first.providerID == .claude)
        #expect(first.status == .answering)
        let answered = try await waitUntilReady(service)
        #expect(answered.messages.map(\.text) == ["What is Swift?", "Answer 1"])

        _ = try await service.ask("And Kotlin?", in: answered.id, model: nil)
        let second = try await waitUntilReady(service)
        #expect(second.messages.last?.text == "Answer 2")
        let lastPrompt = try #require(await prompts.last)
        #expect(lastPrompt.contains("What is Swift?"))
        #expect(lastPrompt.contains("User: And Kotlin?"))
    }

    @Test("A failed answer keeps the chat usable")
    func claudeChatFailure() async throws {
        let service = ClaudeTemporaryChatService(ask: { _, _ in throw TemporaryChatError.unavailable("offline") })
        _ = try await service.ask("Hello", in: nil, model: nil)
        let chat = try await waitUntilReady(service)
        #expect(chat.status == .failed)
        #expect(chat.failureMessage?.contains("offline") == true)
        #expect(chat.canAsk)
    }

    @Test("The router keeps one chat and switches providers by starting fresh")
    func routerSwitchesProviders() async throws {
        let codex = ClaudeTemporaryChatService(ask: { _, _ in "codex" })
        let claude = ClaudeTemporaryChatService(ask: { _, _ in "claude" })
        let router = ProviderTemporaryChatService(services: [.codex: codex, .claude: claude])
        let codexChat = try await router.ask("Hi", in: nil, model: nil, providerID: .codex)
        _ = try await waitUntilReady(codex)
        await #expect(throws: TemporaryChatError.staleChat) {
            _ = try await router.ask("Hi", in: codexChat.id, model: nil, providerID: .claude)
        }
        _ = try await router.ask("Hi", in: nil, model: nil, providerID: .claude)
        #expect(await codex.current() == nil)
        #expect(await claude.current() != nil)
        await #expect(throws: TemporaryChatError.self) {
            _ = try await router.ask("Hi", in: nil, model: nil, providerID: .githubCopilot)
        }
    }
}

private actor PromptLog {
    private var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
    var count: Int { prompts.count }
    var last: String? { prompts.last }
}
