import Foundation

public enum InstructionScope: Codable, Hashable, Sendable {
    case allProjects
    case platform(ProjectPlatform)
    case projects(Set<ProjectID>)

    public func includes(_ project: LabProject) -> Bool {
        switch self {
        case .allProjects: true
        case let .platform(platform): project.platforms.contains(platform)
        case let .projects(ids): ids.contains(project.id)
        }
    }
}

public struct InstructionPack: Codable, Hashable, Identifiable, Sendable {
    public let id: InstructionPackID
    public let name: String
    public let body: String
    public let scope: InstructionScope
    public let version: Int
    public let isEnabled: Bool
    public let updatedAt: Date

    public init(
        id: InstructionPackID = .make(),
        name: String,
        body: String,
        scope: InstructionScope,
        version: Int = 1,
        isEnabled: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.scope = scope
        self.version = max(1, version)
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}
