import Foundation

public struct AgentDefinitionActivationResult: Sendable {
    public let agent: AgentProfile
    public let createdRegistration: Bool

    public init(agent: AgentProfile, createdRegistration: Bool) {
        self.agent = agent
        self.createdRegistration = createdRegistration
    }
}

public struct AgentDefinitionDraft: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let instructions: String
    public let capabilities: Set<AgentCapability>
    public let scope: AgentScope
    public let toolPreset: AgentToolPreset?

    public init(
        name: String,
        summary: String,
        instructions: String,
        capabilities: Set<AgentCapability>,
        scope: AgentScope,
        toolPreset: AgentToolPreset? = nil
    ) {
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.scope = scope
        self.toolPreset = toolPreset
    }
}

public struct DeletedAgentRecord: Codable, Equatable, Sendable {
    public let agent: AgentProfile
    public let sourceURL: URL?
    public let archiveURL: URL?
    public let expectedContents: String?
    public let registrationURL: URL?
    public let registrationKey: String?
    public let registrationBlock: String?
    public let deletedAt: Date

    public init(
        agent: AgentProfile,
        sourceURL: URL? = nil,
        archiveURL: URL? = nil,
        expectedContents: String? = nil,
        registrationURL: URL? = nil,
        registrationKey: String? = nil,
        registrationBlock: String? = nil,
        deletedAt: Date = .now
    ) {
        self.agent = agent
        self.sourceURL = sourceURL
        self.archiveURL = archiveURL
        self.expectedContents = expectedContents
        self.registrationURL = registrationURL
        self.registrationKey = registrationKey
        self.registrationBlock = registrationBlock
        self.deletedAt = deletedAt
    }
}
