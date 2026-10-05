import Foundation

public struct AgentDefinitionChangePreview: Codable, Hashable, Identifiable, Sendable {
    public let agentID: AgentID
    public let sourceURL: URL
    public let archiveURL: URL
    public let targetURL: URL
    public let proposedContents: String
    public let authorizedDirectoryURL: URL?
    public let expectedSourceContents: String?

    public var id: AgentID { agentID }

    public init(
        agentID: AgentID,
        sourceURL: URL,
        archiveURL: URL,
        targetURL: URL,
        proposedContents: String,
        authorizedDirectoryURL: URL? = nil,
        expectedSourceContents: String? = nil
    ) {
        self.agentID = agentID
        self.sourceURL = sourceURL
        self.archiveURL = archiveURL
        self.targetURL = targetURL
        self.proposedContents = proposedContents
        self.authorizedDirectoryURL = authorizedDirectoryURL
        self.expectedSourceContents = expectedSourceContents
    }
}
