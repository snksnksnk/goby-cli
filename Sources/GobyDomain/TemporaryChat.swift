import Foundation

public struct TemporaryChatID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// A quick question-and-answer conversation outside any project. It has no
/// file, command, plugin or connector access, is never written to disk by Goby
/// or the provider, and exists only while the Mac host keeps it: until it is
/// ended, left idle, or the host restarts.
public struct TemporaryChat: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Hashable, Sendable {
        /// Waiting for the next question.
        case ready
        /// The provider is writing an answer.
        case answering
        /// The last question could not be answered; the chat can continue.
        case failed
    }

    public struct Message: Codable, Hashable, Sendable, Identifiable {
        public enum Role: String, Codable, Hashable, Sendable {
            case user
            case assistant
        }

        public let id: String
        public let role: Role
        public var text: String
        public let createdAt: Date

        public init(id: String = UUID().uuidString.lowercased(), role: Role, text: String, createdAt: Date = .now) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// Questions longer than this are rejected before reaching the provider.
    public static let questionLimit = 8_000
    /// Each answer is kept to this many characters.
    public static let answerLimit = 32_000
    /// Older messages are dropped beyond this count; the provider thread keeps
    /// its own context for the rest of the chat.
    public static let messageLimit = 40
    /// A chat left idle this long is ended automatically.
    public static let idleLifetime: TimeInterval = 60 * 60

    public let id: TemporaryChatID
    public let providerID: AgentProviderID
    public var model: String?
    public var status: Status
    public var failureMessage: String?
    public var messages: [Message]
    public let startedAt: Date
    public var updatedAt: Date

    public init(
        id: TemporaryChatID = .make(),
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        status: Status = .ready,
        failureMessage: String? = nil,
        messages: [Message] = [],
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.providerID = providerID
        self.model = model
        self.status = status
        self.failureMessage = failureMessage
        self.messages = messages
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// Trims and bounds a question; nil when it is empty.
    public static func normalizedQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(questionLimit))
    }

    /// Appends a message, keeping the newest `messageLimit`.
    public mutating func append(_ message: Message) {
        messages.append(message)
        if messages.count > Self.messageLimit {
            messages.removeFirst(messages.count - Self.messageLimit)
        }
        updatedAt = message.createdAt
    }

    /// Adds streamed answer text to the answer in progress.
    public mutating func appendAnswerText(_ delta: String, at date: Date = .now) {
        guard !delta.isEmpty else { return }
        if messages.last?.role != .assistant {
            append(Message(role: .assistant, text: "", createdAt: date))
        }
        var text = messages[messages.count - 1].text + delta
        if text.count > Self.answerLimit { text = String(text.prefix(Self.answerLimit)) }
        messages[messages.count - 1].text = text
        updatedAt = date
    }

    public var canAsk: Bool { status != .answering }

    public func isExpired(at date: Date) -> Bool {
        status != .answering && date.timeIntervalSince(updatedAt) >= Self.idleLifetime
    }
}
