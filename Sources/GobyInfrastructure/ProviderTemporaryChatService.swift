import Foundation
import GobyApplication
import GobyDomain

/// Goby's temporary chat on Claude. Each question runs as one tool-less
/// Claude turn in an empty folder through the bridge's `chat/ask`; earlier
/// turns travel in the prompt because the bridge keeps no session. The chat
/// lives in memory only.
public actor ClaudeTemporaryChatService: TemporaryChatServing {
    public typealias Asker = @Sendable (_ prompt: String, _ model: String?) async throws -> String

    private let askClaude: Asker
    private let now: @Sendable () -> Date
    private var chat: TemporaryChat?
    private var answerTask: Task<Void, Never>?
    private let updateStream: AsyncStream<TemporaryChat?>
    private let updateContinuation: AsyncStream<TemporaryChat?>.Continuation

    public init(ask: @escaping Asker, now: @escaping @Sendable () -> Date = { .now }) {
        askClaude = ask
        self.now = now
        let pair = AsyncStream<TemporaryChat?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    public func current() -> TemporaryChat? { chat }
    public func updates() -> AsyncStream<TemporaryChat?> { updateStream }

    public func ask(_ question: String, in chatID: TemporaryChatID?, model: String?) async throws -> TemporaryChat {
        guard let question = TemporaryChat.normalizedQuestion(question) else {
            throw TemporaryChatError.emptyQuestion
        }
        if let existing = chat {
            if let chatID {
                guard existing.id == chatID else { throw TemporaryChatError.staleChat }
                guard existing.canAsk else { throw TemporaryChatError.answering }
            } else {
                guard existing.canAsk else { throw TemporaryChatError.answering }
                chat = nil
            }
        } else if chatID != nil {
            throw TemporaryChatError.staleChat
        }
        var current = chat ?? TemporaryChat(providerID: .claude, model: model, startedAt: now(), updatedAt: now())
        let prompt = Self.prompt(history: current.messages, question: question)
        current.append(.init(role: .user, text: question, createdAt: now()))
        current.status = .answering
        current.failureMessage = nil
        chat = current
        publish()
        let chatID = current.id
        let chatModel = current.model
        answerTask = Task { [askClaude] in
            do {
                let answer = try await askClaude(prompt, chatModel)
                self.finish(chatID: chatID, answer: answer, failure: nil)
            } catch {
                self.finish(chatID: chatID, answer: nil, failure: "Claude could not answer: \(error.localizedDescription)")
            }
        }
        return current
    }

    public func end(_ chatID: TemporaryChatID) {
        guard chat?.id == chatID else { return }
        answerTask?.cancel()
        answerTask = nil
        chat = nil
        publish()
    }

    private func finish(chatID: TemporaryChatID, answer: String?, failure: String?) {
        guard chat?.id == chatID else { return }
        if let answer {
            chat?.appendAnswerText(answer, at: now())
            chat?.status = .ready
        } else {
            chat?.status = .failed
            chat?.failureMessage = failure.map { String($0.prefix(1_000)) }
            chat?.updatedAt = now()
        }
        answerTask = nil
        publish()
    }

    private func publish() { updateContinuation.yield(chat) }

    /// Earlier turns, newest last, bounded so a long chat stays within the
    /// bridge's limit.
    static func prompt(history: [TemporaryChat.Message], question: String) -> String {
        guard !history.isEmpty else { return question }
        var transcript = ""
        for message in history.suffix(12) {
            let speaker = message.role == .user ? "User" : "Assistant"
            transcript += "\(speaker): \(message.text.prefix(4_000))\n\n"
        }
        return """
        The conversation so far:

        \(transcript)User: \(question)
        """
    }
}

/// Sends each temporary chat to the provider it was started on. Only one chat
/// exists at a time: starting one on another provider ends the previous one.
public actor ProviderTemporaryChatService: TemporaryChatServing {
    private let services: [AgentProviderID: any TemporaryChatServing]
    private var activeProviderID: AgentProviderID = .codex
    private var forwarding: [Task<Void, Never>] = []
    private let updateStream: AsyncStream<TemporaryChat?>
    private let updateContinuation: AsyncStream<TemporaryChat?>.Continuation

    public init(services: [AgentProviderID: any TemporaryChatServing]) {
        self.services = services
        let pair = AsyncStream<TemporaryChat?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    public var supportedProviderIDs: Set<AgentProviderID> { Set(services.keys) }

    public func current() async -> TemporaryChat? {
        await services[activeProviderID]?.current()
    }

    public func updates() async -> AsyncStream<TemporaryChat?> {
        if forwarding.isEmpty {
            for (providerID, service) in services {
                let stream = await service.updates()
                forwarding.append(Task { [weak self] in
                    for await chat in stream {
                        await self?.forward(chat, from: providerID)
                    }
                })
            }
        }
        return updateStream
    }

    public func ask(_ question: String, in chatID: TemporaryChatID?, model: String?) async throws -> TemporaryChat {
        try await ask(question, in: chatID, model: model, providerID: activeProviderID)
    }

    public func ask(
        _ question: String,
        in chatID: TemporaryChatID?,
        model: String?,
        providerID: AgentProviderID
    ) async throws -> TemporaryChat {
        guard let service = services[providerID] else {
            throw TemporaryChatError.unavailable("Temporary chat is not available for \(providerID.displayName) on this Mac.")
        }
        if providerID != activeProviderID {
            // Switching providers starts a new chat; the old one is cleared.
            guard chatID == nil else { throw TemporaryChatError.staleChat }
            if let previous = await services[activeProviderID]?.current() {
                await services[activeProviderID]?.end(previous.id)
            }
            activeProviderID = providerID
        }
        return try await service.ask(question, in: chatID, model: model)
    }

    public func end(_ chatID: TemporaryChatID) async {
        for service in services.values { await service.end(chatID) }
    }

    private func forward(_ chat: TemporaryChat?, from providerID: AgentProviderID) {
        guard providerID == activeProviderID else { return }
        updateContinuation.yield(chat)
    }
}
