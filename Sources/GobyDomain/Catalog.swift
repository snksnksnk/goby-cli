import Foundation

public enum ProjectPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case web
    case macOS
    case iOS
    case android
    case backend
    case research
    case general

    public var displayName: String {
        switch self {
        case .web: "Web"
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .android: "Android"
        case .backend: "Backend"
        case .research: "Research"
        case .general: "General"
        }
    }
}

public enum AgentCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case routing
    case research
    case web
    case macOS
    case iOS
    case android
    case backend
    case testing
    case review
    case security
    case documentation
    case release
    case design

    public var displayName: String {
        switch self {
        case .routing: "Routing"
        case .research: "Research"
        case .web: "Web"
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .android: "Android"
        case .backend: "Backend"
        case .testing: "Testing"
        case .review: "Review"
        case .security: "Security"
        case .documentation: "Documentation"
        case .release: "Release"
        case .design: "Visual Design"
        }
    }
}

public struct LabProject: Codable, Hashable, Identifiable, Sendable {
    public let id: ProjectID
    public let name: String
    public let rootURL: URL
    public let platforms: Set<ProjectPlatform>
    public let frameworks: [String]
    public let testCommands: [String]
    public let instructionFiles: [URL]
    public let isGitRepository: Bool
    public let registeredAt: Date
    public let fileSystemIdentity: GADFileSystemIdentity?
    public let template: ProjectTemplateReference?

    public init(
        id: ProjectID,
        name: String,
        rootURL: URL,
        platforms: Set<ProjectPlatform>,
        frameworks: [String] = [],
        testCommands: [String] = [],
        instructionFiles: [URL] = [],
        isGitRepository: Bool,
        registeredAt: Date = .now,
        fileSystemIdentity: GADFileSystemIdentity? = nil,
        template: ProjectTemplateReference? = nil
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.platforms = platforms
        self.frameworks = frameworks
        self.testCommands = testCommands
        self.instructionFiles = instructionFiles
        self.isGitRepository = isGitRepository
        self.registeredAt = registeredAt
        self.fileSystemIdentity = fileSystemIdentity ?? GADFileSystemIdentity.capture(rootURL)
        self.template = template
    }
}

public enum ProjectGroupRole: String, Codable, CaseIterable, Hashable, Sendable {
    case frontend
    case backend
    case mobile
    case service
    case shared

    public var displayName: String {
        switch self {
        case .frontend: "Frontend"
        case .backend: "Backend"
        case .mobile: "Mobile"
        case .service: "Service"
        case .shared: "Shared"
        }
    }
}

public struct ProjectGroupMember: Codable, Hashable, Identifiable, Sendable {
    public let projectID: ProjectID
    public let role: ProjectGroupRole
    public var id: ProjectID { projectID }

    public init(projectID: ProjectID, role: ProjectGroupRole) {
        self.projectID = projectID
        self.role = role
    }
}

/// A user-defined product made from independently registered project folders.
/// Membership changes coordination only; each folder remains its own execution,
/// authorization, Git, test, and recovery boundary.
public struct ProjectGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: ProjectGroupID
    public let name: String
    public let members: [ProjectGroupMember]
    public let createdAt: Date

    public init(
        id: ProjectGroupID = .make(),
        name: String,
        members: [ProjectGroupMember],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.createdAt = createdAt
    }

    public var projectIDs: Set<ProjectID> {
        Set(members.map(\.projectID))
    }
}

public enum AgentScope: Codable, Hashable, Sendable {
    case global
    /// A Goby-managed personal definition deliberately attached to every
    /// registered project rather than matched by capability.
    case union
    case project(ProjectID)
}

public enum AgentToolPreset: String, Codable, Hashable, Sendable {
    case iconComposer = "icon-composer"
}

/// Records what the user actually reviewed before a definition gained
/// execution authority. Missing provenance is legacy data and must not be
/// treated as a review of executable file contents.
public enum AgentDefinitionReviewProvenance: String, Codable, Hashable, Sendable {
    case fullContent
    case semanticOnly
    case gobyGenerated
}

public struct AgentProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: AgentID
    public let name: String
    public let summary: String
    public let instructions: String?
    public let capabilities: Set<AgentCapability>
    public let scope: AgentScope
    public let sourceURL: URL?
    public let toolPreset: AgentToolPreset?
    /// SHA-256 of the complete file bytes reviewed before an imported
    /// definition may be activated. Nil means the file needs a fresh review.
    public let reviewedDefinitionDigest: String?
    public let definitionReviewProvenance: AgentDefinitionReviewProvenance?
    /// The native `[agents.<key>]` entry currently activating this definition
    /// in Codex. A definition file can exist without being registered.
    public let codexRegistrationKey: String?
    public let isEnabled: Bool

    /// One-run agents use a reserved identifier namespace. The identifier is
    /// persisted in the run snapshot, so retirement needs no separate marker
    /// that could be lost during a catalog migration.
    public var isTemporary: Bool { id.rawValue.hasPrefix("temporary-agent-") }

    public init(
        id: AgentID,
        name: String,
        summary: String,
        instructions: String? = nil,
        capabilities: Set<AgentCapability>,
        scope: AgentScope,
        sourceURL: URL? = nil,
        toolPreset: AgentToolPreset? = nil,
        reviewedDefinitionDigest: String? = nil,
        definitionReviewProvenance: AgentDefinitionReviewProvenance? = nil,
        codexRegistrationKey: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.scope = scope
        self.sourceURL = sourceURL
        self.toolPreset = toolPreset
        self.reviewedDefinitionDigest = reviewedDefinitionDigest
        self.definitionReviewProvenance = definitionReviewProvenance
        self.codexRegistrationKey = codexRegistrationKey
        self.isEnabled = isEnabled
    }
}

public enum ProjectInspectionLevel: String, Codable, Hashable, Sendable {
    case inspected
    case metadataOnly
}

public struct ProjectCandidate: Codable, Hashable, Identifiable, Sendable {
    public let project: LabProject
    public let detectedAgents: [AgentProfile]
    public let evidence: [String]
    public let inspectionLevel: ProjectInspectionLevel
    public var id: ProjectID { project.id }

    public init(
        project: LabProject,
        detectedAgents: [AgentProfile] = [],
        evidence: [String] = [],
        inspectionLevel: ProjectInspectionLevel = .inspected
    ) {
        self.project = project
        self.detectedAgents = detectedAgents
        self.evidence = evidence
        self.inspectionLevel = inspectionLevel
    }
}

public struct LabSnapshot: Codable, Equatable, Sendable {
    public let projects: [LabProject]
    public let agents: [AgentProfile]
    public let projectGroups: [ProjectGroup]
    public let projectProviderConfigurations: [ProjectProviderConfiguration]
    public let providerBindings: [ProviderAgentBinding]
    public let providerCollaborationSets: [ProviderCollaborationSet]
    public let agentHandoffLinks: [AgentHandoffLink]
    public let handoffs: [HandoffRecord]

    public init(
        projects: [LabProject],
        agents: [AgentProfile],
        projectGroups: [ProjectGroup] = [],
        projectProviderConfigurations: [ProjectProviderConfiguration]? = nil,
        providerBindings: [ProviderAgentBinding]? = nil,
        providerCollaborationSets: [ProviderCollaborationSet] = [],
        agentHandoffLinks: [AgentHandoffLink] = [],
        handoffs: [HandoffRecord] = []
    ) {
        self.projects = projects
        self.agents = agents
        self.projectGroups = projectGroups
        self.projectProviderConfigurations = projectProviderConfigurations
            ?? projects.map(ProjectProviderConfiguration.migratedCodexConfiguration)
        self.providerBindings = providerBindings ?? agents.map(ProviderAgentBinding.migratedCodexBinding)
        self.providerCollaborationSets = providerCollaborationSets
        self.agentHandoffLinks = agentHandoffLinks
        self.handoffs = handoffs
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case agents
        case projectGroups
        case projectProviderConfigurations
        case providerBindings
        case providerCollaborationSets
        case agentHandoffLinks
        case handoffs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([LabProject].self, forKey: .projects)
        agents = try container.decode([AgentProfile].self, forKey: .agents)
        projectGroups = try container.decodeIfPresent([ProjectGroup].self, forKey: .projectGroups) ?? []
        projectProviderConfigurations = try container.decodeIfPresent(
            [ProjectProviderConfiguration].self,
            forKey: .projectProviderConfigurations
        ) ?? projects.map(ProjectProviderConfiguration.migratedCodexConfiguration)
        providerBindings = try container.decodeIfPresent(
            [ProviderAgentBinding].self,
            forKey: .providerBindings
        ) ?? agents.map(ProviderAgentBinding.migratedCodexBinding)
        providerCollaborationSets = try container.decodeIfPresent(
            [ProviderCollaborationSet].self,
            forKey: .providerCollaborationSets
        ) ?? []
        agentHandoffLinks = try container.decodeIfPresent(
            [AgentHandoffLink].self,
            forKey: .agentHandoffLinks
        ) ?? []
        handoffs = try container.decodeIfPresent(
            [HandoffRecord].self,
            forKey: .handoffs
        ) ?? []
    }

    public static let empty = LabSnapshot(
        projects: [],
        agents: [],
        projectGroups: [],
        projectProviderConfigurations: [],
        providerBindings: [],
        providerCollaborationSets: [],
        agentHandoffLinks: [],
        handoffs: []
    )
}

public struct AgentImportCandidate: Codable, Hashable, Identifiable, Sendable {
    public let profile: AgentProfile
    public let configurationPreview: String
    public let evidence: [String]
    public var id: AgentID { profile.id }

    public init(profile: AgentProfile, configurationPreview: String, evidence: [String]) {
        self.profile = profile
        self.configurationPreview = configurationPreview
        self.evidence = evidence
    }
}

public enum AgentStructureSuggestionKind: String, Codable, Sendable {
    case consolidate
    case rename
    case promoteToShared
    case missingCoverage
}

public struct AgentStructureSuggestion: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: AgentStructureSuggestionKind
    public let title: String
    public let detail: String
    public let affectedAgentIDs: [AgentID]

    public init(
        id: UUID = UUID(),
        kind: AgentStructureSuggestionKind,
        title: String,
        detail: String,
        affectedAgentIDs: [AgentID] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.affectedAgentIDs = affectedAgentIDs
    }
}

public struct AgentImportPlan: Codable, Equatable, Sendable {
    public let candidates: [AgentImportCandidate]
    public let suggestions: [AgentStructureSuggestion]

    public init(candidates: [AgentImportCandidate], suggestions: [AgentStructureSuggestion]) {
        self.candidates = candidates
        self.suggestions = suggestions
    }

    public static let empty = AgentImportPlan(candidates: [], suggestions: [])
}

public struct CodexCatalogSyncPlan: Codable, Equatable, Sendable {
    public let projects: [ProjectCandidate]
    public let agents: AgentImportPlan
    public let tasks: [CodexTaskActivity]
    public let scannedProjectCount: Int
    public let scannedAgentCount: Int
    public let limitedProjectAccessCount: Int
    public let warnings: [String]

    public init(
        projects: [ProjectCandidate],
        agents: AgentImportPlan,
        tasks: [CodexTaskActivity] = [],
        scannedProjectCount: Int,
        scannedAgentCount: Int,
        limitedProjectAccessCount: Int = 0,
        warnings: [String] = []
    ) {
        self.projects = projects
        self.agents = agents
        self.tasks = tasks
        self.scannedProjectCount = scannedProjectCount
        self.scannedAgentCount = scannedAgentCount
        self.limitedProjectAccessCount = limitedProjectAccessCount
        self.warnings = warnings
    }

    public var hasChanges: Bool {
        !projects.isEmpty || !agents.candidates.isEmpty
    }
}
