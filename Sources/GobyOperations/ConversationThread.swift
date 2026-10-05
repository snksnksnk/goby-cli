import Foundation
import GobyDomain

/// What Home shows as a conversation: the submitted request while it is being
/// planned, then the run it became.
public enum ConversationThread: Equatable, Sendable {
    case pending(PendingConversation)
    case run(RunID)
    /// The host's temporary chat: no project, no files, not saved.
    case temporaryChat
}

public struct PendingConversation: Equatable, Sendable {
    public let prompt: String
    public let providerID: AgentProviderID
    public let projectIDs: [ProjectID]
    public let startedAt: Date
}

/// What the composer's Send does while a conversation is open.
public enum ComposerIntent: Equatable, Sendable {
    /// A new request: no conversation, or one that cannot take replies yet.
    case newRequest
    /// Deliver the text to the running agent (Codex only).
    case steer(RunID)
    /// Start a new run that continues from this finished run's answer.
    case continueThread(RunID)
    /// Ask the temporary chat.
    case temporaryChat
}
