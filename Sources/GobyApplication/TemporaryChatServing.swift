import Foundation
import GobyDomain

/// Runs Goby's temporary chat on the Mac host: quick questions outside any
/// project, answered by the provider without file, command, plugin or
/// connector access, and never saved.
public protocol TemporaryChatServing: Sendable {
    /// Asks a question. `chatID` must name the current chat to continue it;
    /// nil starts a new chat, replacing a finished one.
    func ask(_ question: String, in chatID: TemporaryChatID?, model: String?) async throws -> TemporaryChat
    /// Ends the chat and forgets it. Unknown or already-ended chats are ignored.
    func end(_ chatID: TemporaryChatID) async
    /// The current chat, if any.
    func current() async -> TemporaryChat?
    /// Every change to the current chat; nil when it ends. One consumer.
    func updates() async -> AsyncStream<TemporaryChat?>
    /// Asks on a specific provider. Single-provider services ignore it.
    func ask(
        _ question: String,
        in chatID: TemporaryChatID?,
        model: String?,
        providerID: AgentProviderID
    ) async throws -> TemporaryChat
}

public extension TemporaryChatServing {
    func ask(
        _ question: String,
        in chatID: TemporaryChatID?,
        model: String?,
        providerID: AgentProviderID
    ) async throws -> TemporaryChat {
        try await ask(question, in: chatID, model: model)
    }
}

public enum TemporaryChatError: LocalizedError, Equatable, Sendable {
    case emptyQuestion
    case staleChat
    case answering
    case notSignedIn
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            "Type a question first."
        case .staleChat:
            "This temporary chat has ended. Start a new one."
        case .answering:
            "Wait for the current answer before asking again."
        case .notSignedIn:
            "Sign in to Codex on this Mac to use temporary chat."
        case let .unavailable(reason):
            reason
        }
    }
}
