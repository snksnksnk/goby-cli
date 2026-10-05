import Foundation
import GobyDomain

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

public enum JSONRPCID: Codable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public struct JSONRPCRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: JSONRPCID
    public let method: String
    public let params: Parameters

    public init(id: JSONRPCID, method: String, params: Parameters) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification<Parameters: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let method: String
    public let params: Parameters

    public init(method: String, params: Parameters) {
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse<Result: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: JSONRPCID
    public let result: Result

    public init(id: JSONRPCID, result: Result) {
        self.id = id
        self.result = result
    }
}

public struct IncomingJSONRPCMessage: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: JSONRPCID?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?
}

public struct JSONRPCErrorObject: Codable, Equatable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum JSONRPCCodec {
    public static func encodeLine<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> IncomingJSONRPCMessage {
        let trimmed = data.last == 0x0A ? data.dropLast() : data[...]
        return try JSONDecoder().decode(IncomingJSONRPCMessage.self, from: Data(trimmed))
    }
}

enum JSONRPCLineFramingError: LocalizedError, Equatable, Sendable {
    case frameTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .frameTooLarge(maximumBytes):
            "The provider returned a JSON-RPC frame larger than the \(maximumBytes)-byte safety limit."
        }
    }
}

/// Incrementally frames newline-delimited JSON-RPC without retaining an
/// unbounded partial line supplied by a provider process.
struct JSONRPCLineBuffer: Sendable {
    static let defaultMaximumFrameBytes = 4 * 1_024 * 1_024

    private let maximumFrameBytes: Int
    private var buffer = Data()

    init(maximumFrameBytes: Int = defaultMaximumFrameBytes) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex

        while let newline = data[start...].firstIndex(of: 0x0A) {
            try appendSegment(data[start..<newline])
            lines.append(buffer)
            buffer.removeAll(keepingCapacity: true)
            start = data.index(after: newline)
        }

        try appendSegment(data[start...])
        return lines
    }

    mutating func finish() throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        guard buffer.count <= maximumFrameBytes else {
            throw JSONRPCLineFramingError.frameTooLarge(maximumBytes: maximumFrameBytes)
        }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return line
    }

    mutating func reset(keepingCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    private mutating func appendSegment(_ segment: Data.SubSequence) throws {
        guard segment.count <= maximumFrameBytes - buffer.count else {
            buffer.removeAll(keepingCapacity: false)
            throw JSONRPCLineFramingError.frameTooLarge(maximumBytes: maximumFrameBytes)
        }
        buffer.append(contentsOf: segment)
    }
}

public struct EmptyParameters: Codable, Sendable {
    public init() {}
}

public struct InitializeParameters: Codable, Sendable {
    public struct ClientInfo: Codable, Sendable {
        public let name: String
        public let title: String?
        public let version: String

        public init(name: String, title: String?, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }
    }

    public struct Capabilities: Codable, Sendable {
        public let experimentalApi: Bool
        public let optOutNotificationMethods: [String]?

        public init(experimentalApi: Bool = false, optOutNotificationMethods: [String]? = nil) {
            self.experimentalApi = experimentalApi
            self.optOutNotificationMethods = optOutNotificationMethods
        }
    }

    public let clientInfo: ClientInfo
    public let capabilities: Capabilities

    public init(clientInfo: ClientInfo, capabilities: Capabilities = .init()) {
        self.clientInfo = clientInfo
        self.capabilities = capabilities
    }
}

public struct ThreadStartParameters: Codable, Sendable {
    public let approvalPolicy: String
    public let approvalsReviewer: String
    public let config: [String: JSONValue]?
    public let cwd: String
    public let developerInstructions: String?
    public let model: String?
    public let sandbox: String
    public let threadSource: String
    /// When true, Codex keeps the thread in memory only and never writes it
    /// to its session history. Omitted from the request when nil.
    public let ephemeral: Bool?

    public init(
        approvalPolicy: String = "on-request",
        approvalsReviewer: String = "user",
        config: [String: JSONValue]? = nil,
        cwd: String,
        developerInstructions: String? = nil,
        model: String? = nil,
        sandbox: String = "workspace-write",
        threadSource: String = "goby-agentic-dashboard",
        ephemeral: Bool? = nil
    ) {
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.config = config
        self.cwd = cwd
        self.developerInstructions = developerInstructions
        self.model = model
        self.sandbox = sandbox
        self.threadSource = threadSource
        self.ephemeral = ephemeral
    }
}

public struct TurnStartParameters: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public let type: String
        public let text: String?
        public let path: String?
        public let name: String?

        public init(text: String) {
            self.type = "text"
            self.text = text
            self.path = nil
            self.name = nil
        }

        public init(localImageURL: URL) {
            self.type = "localImage"
            self.text = nil
            self.path = localImageURL.path(percentEncoded: false)
            self.name = nil
        }

        public init(fileURL: URL, displayName: String) {
            self.type = "mention"
            self.text = nil
            self.path = fileURL.path(percentEncoded: false)
            self.name = displayName
        }
    }

    public let threadId: String
    public let input: [Input]
    public let approvalPolicy: String
    /// Plugins switched off for this turn. Omitted from the request when nil.
    public let disabledPluginIds: [String]?

    public init(
        threadID: String,
        prompt: String,
        attachments: [PromptAttachment] = [],
        approvalPolicy: String = "on-request",
        disabledPluginIds: [String]? = nil
    ) {
        self.threadId = threadID
        self.input = [Input(text: prompt)] + attachments.map { attachment in
            switch attachment.source {
            case let .localFile(url) where attachment.kind == .image:
                Input(localImageURL: url)
            case let .localFile(url):
                Input(fileURL: url, displayName: attachment.displayName)
            case let .text(text):
                Input(text: Self.snippetPrompt(attachment, text: text))
            case nil:
                Input(text: "Attached \(attachment.kind.rawValue): \(attachment.displayName) (source unavailable).")
            }
        }
        self.approvalPolicy = approvalPolicy
        self.disabledPluginIds = disabledPluginIds
    }

    private static func snippetPrompt(_ attachment: PromptAttachment, text: String) -> String {
        let language = attachment.typeHint?.lowercased() ?? "text"
        return "Attached \(attachment.displayName):\n```\(language)\n\(text)\n```"
    }
}

public struct TurnSteerParameters: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public let type: String
        public let text: String

        public init(text: String) {
            self.type = "text"
            self.text = text
        }
    }

    public let threadId: String
    public let expectedTurnId: String
    public let input: [Input]

    public init(threadID: String, expectedTurnID: String, text: String) {
        self.threadId = threadID
        self.expectedTurnId = expectedTurnID
        self.input = [Input(text: text)]
    }
}

public struct GetAccountParameters: Codable, Sendable {
    public let refreshToken: Bool

    public init(refreshToken: Bool = false) {
        self.refreshToken = refreshToken
    }
}

public struct TurnInterruptParameters: Codable, Sendable {
    public let threadId: String
    public let turnId: String

    public init(threadID: String, turnID: String) {
        self.threadId = threadID
        self.turnId = turnID
    }
}

public struct CodexApprovalResponse: Codable, Sendable {
    public let decision: String

    public init(decision: String) {
        self.decision = decision
    }
}

public struct CodexPermissionsApprovalResponse: Codable, Sendable {
    public let permissions: JSONValue
    public let scope: String

    public init(permissions: JSONValue, scope: String) {
        self.permissions = permissions
        self.scope = scope
    }
}

public struct ThreadListParameters: Codable, Sendable {
    public let cursor: String?
    public let limit: Int
    public let sortKey: String
    public let sortDirection: String
    public let useStateDbOnly: Bool
    public let sourceKinds: [String]?

    public init(
        cursor: String? = nil,
        limit: Int = 1,
        sortKey: String = "created_at",
        sortDirection: String = "desc",
        useStateDbOnly: Bool = true,
        sourceKinds: [String]? = nil
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.useStateDbOnly = useStateDbOnly
        self.sourceKinds = sourceKinds
    }
}

public struct ThreadResumeParameters: Codable, Sendable {
    public let threadId: String

    public init(threadID: String) {
        self.threadId = threadID
    }
}
