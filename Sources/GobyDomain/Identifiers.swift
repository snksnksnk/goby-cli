import Foundation

public protocol GobyIdentifier: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}

public extension GobyIdentifier {
    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())
    }
}

public struct ProjectID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func derived(fromProjectRoot root: URL) -> ProjectID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in root.standardizedFileURL.path(percentEncoded: false).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return ProjectID(rawValue: "project-\(String(hash, radix: 16))")
    }
}

public struct ProjectGroupID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct ProjectTemplateID: GobyIdentifier, ExpressibleByStringLiteral, Identifiable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var id: String { rawValue }

    public static func < (lhs: ProjectTemplateID, rhs: ProjectTemplateID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AgentProviderID: GobyIdentifier, ExpressibleByStringLiteral, Comparable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var id: String { rawValue }

    public static let codex: AgentProviderID = "codex"
    public static let claude: AgentProviderID = "claude"
    public static let githubCopilot: AgentProviderID = "github-copilot"

    public static let builtIn: [AgentProviderID] = [.codex, .claude, .githubCopilot]

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .githubCopilot: "GitHub Copilot"
        default: rawValue
        }
    }

    public static func < (lhs: AgentProviderID, rhs: AgentProviderID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ProviderAgentBindingID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func derived(
        providerID: AgentProviderID,
        agentID: AgentID,
        projectID: ProjectID?,
        nativeID: String
    ) -> ProviderAgentBindingID {
        let components = [
            providerID.rawValue,
            agentID.rawValue,
            projectID?.rawValue ?? "global",
            nativeID,
        ]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in components.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return ProviderAgentBindingID(rawValue: "binding-\(String(hash, radix: 16))")
    }
}

public struct ProviderCollaborationSetID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AgentHandoffLinkID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct HandoffID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AgentID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct RunID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AutomationID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AutomationActionID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AutomationOccurrenceID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct AssignmentID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct ApprovalID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct InstructionPackID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct SharedResourceID: GobyIdentifier, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
