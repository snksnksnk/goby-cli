import CryptoKit
import Foundation
import GobyApplication
import GobyDomain

private protocol VersionedStoreDocument: Codable, Sendable {
    var version: Int { get }
}

private enum PersistentStoreCompatibilityError: LocalizedError, Sendable {
    case unsupportedVersion(file: String, found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(file, found, supported):
            "\(file) uses data version \(found), but this Goby build supports version \(supported). Update Goby or restore a compatible backup; the file was not changed."
        }
    }
}

private enum PersistentStoreIntegrityError: LocalizedError, Sendable {
    case invalidDocument(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidDocument(file, reason):
            "\(file) contains inconsistent saved state: \(reason). Goby will try the previous verified snapshot."
        }
    }
}

private enum PersistentStoreCapacityError: LocalizedError, Sendable {
    case activeRuns(Int)
    case automations(Int)
    case activeAutomationOccurrences(Int)
    case instructionPacks(Int)
    case instructionCatalogTooLarge(Int)
    case documentTooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .activeRuns(limit):
            "Goby already has \(limit) unfinished runs. Complete or cancel one before starting more work."
        case let .automations(limit):
            "Goby supports up to \(limit) automation schedules in this beta. Remove one before creating another."
        case let .activeAutomationOccurrences(limit):
            "Goby already has \(limit) unfinished automation occurrences. Resolve or cancel one before starting another."
        case let .instructionPacks(limit):
            "Goby supports up to \(limit) instruction packs. Remove one before creating another."
        case let .instructionCatalogTooLarge(limit):
            "The instruction catalog exceeds its \(limit / 1_024 / 1_024) MiB safety budget. Shorten or remove an instruction before saving."
        case let .documentTooLarge(file):
            "\(file) exceeds Goby's protected state-file size limit. Restore a smaller previous snapshot or contact support before retrying."
        }
    }
}

public actor PersistentStore: LabCatalogRepository, ProjectCatalogManaging, ProjectGroupCatalogManaging, ProviderConfigurationCatalogManaging, HandoffCatalogManaging, RunRepository, AutomationRepository, AutomationExecutionAuthorityProviding, InstructionRepository, AgentCatalogManaging, SharedResourceRepository, AgentRestructureHistoryRepository, DeletedAgentHistoryRepository, MapLayoutRepository, GADOperationalContinuityRepository, GADCoordinatorCheckpointRepository {
    private static let currentDocumentVersion = 1
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    private struct CatalogDocument: VersionedStoreDocument {
        let version: Int
        var projects: [LabProject]
        var agents: [AgentProfile]
        var projectGroups: [ProjectGroup]
        var projectProviderConfigurations: [ProjectProviderConfiguration]
        var providerBindings: [ProviderAgentBinding]
        var providerCollaborationSets: [ProviderCollaborationSet]
        var agentHandoffLinks: [AgentHandoffLink]
        var handoffs: [HandoffRecord]

        init(
            version: Int,
            projects: [LabProject],
            agents: [AgentProfile],
            projectGroups: [ProjectGroup] = [],
            projectProviderConfigurations: [ProjectProviderConfiguration]? = nil,
            providerBindings: [ProviderAgentBinding]? = nil,
            providerCollaborationSets: [ProviderCollaborationSet] = [],
            agentHandoffLinks: [AgentHandoffLink] = [],
            handoffs: [HandoffRecord] = []
        ) {
            self.version = version
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
            case version
            case projects
            case agents
            case projectGroups
            case projectProviderConfigurations
            case providerBindings
            case providerCollaborationSets
            case agentHandoffLinks
            case handoffs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
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

        static let empty = CatalogDocument(
            version: 1,
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

    private struct RunsDocument: VersionedStoreDocument {
        let version: Int
        var runs: [RunRecord]

        static let empty = RunsDocument(version: 1, runs: [])
    }

    private struct AutomationsDocument: VersionedStoreDocument {
        let version: Int
        var definitions: [AutomationDefinition]
        var occurrences: [AutomationOccurrence]
        var catalogAuthorityDigest: Data?

        init(
            version: Int,
            definitions: [AutomationDefinition],
            occurrences: [AutomationOccurrence],
            catalogAuthorityDigest: Data? = nil
        ) {
            self.version = version
            self.definitions = definitions
            self.occurrences = occurrences
            self.catalogAuthorityDigest = catalogAuthorityDigest
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case definitions
            case occurrences
            case catalogAuthorityDigest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            definitions = try container.decode([AutomationDefinition].self, forKey: .definitions)
            occurrences = try container.decode([AutomationOccurrence].self, forKey: .occurrences)
            catalogAuthorityDigest = try container.decodeIfPresent(
                Data.self,
                forKey: .catalogAuthorityDigest
            )
        }

        static let empty = AutomationsDocument(
            version: 1,
            definitions: [],
            occurrences: []
        )
    }

    private struct InstructionsDocument: VersionedStoreDocument {
        let version: Int
        var packs: [InstructionPack]

        static let empty = InstructionsDocument(version: 1, packs: [])
    }

    private struct ResourcesDocument: VersionedStoreDocument {
        let version: Int
        var resources: [SharedResource]

        static let empty = ResourcesDocument(version: 1, resources: [])
    }

    private struct AgentRestructureDocument: VersionedStoreDocument {
        let version: Int
        var changes: [AgentDefinitionChangePreview]

        static let empty = AgentRestructureDocument(version: 1, changes: [])
    }

    private struct DeletedAgentDocument: VersionedStoreDocument {
        let version: Int
        var record: DeletedAgentRecord?

        static let empty = DeletedAgentDocument(version: 1, record: nil)
    }

    private struct MapLayoutDocument: VersionedStoreDocument {
        let version: Int
        var layout: MapLayoutOverrides

        static let empty = MapLayoutDocument(version: 1, layout: .empty)
    }

    private struct OperationalContinuityDocument: VersionedStoreDocument {
        let version: Int
        var state: GADOperationalContinuityState

        static let empty = OperationalContinuityDocument(version: 1, state: .empty)
    }

    private struct CoordinatorCheckpointDocument: VersionedStoreDocument {
        let version: Int
        var checkpoint: GADCoordinatorCheckpoint?

        static let empty = CoordinatorCheckpointDocument(version: 1, checkpoint: nil)
    }

    private struct AuthenticatedAutomationsDocument: VersionedStoreDocument {
        let version: Int
        let payload: AutomationsDocument
        let generation: UInt64
        let authenticationTag: Data
    }

    private struct AutomationExecutionAuthorityMaterialV1: Encodable, Sendable {
        let version = 1
        let projects: [LabProject]
        let agents: [AgentProfile]
        let projectGroups: [ProjectGroup]
        let projectProviderConfigurations: [ProjectProviderConfiguration]
        let providerBindings: [ProviderAgentBinding]
        let providerCollaborationSets: [ProviderCollaborationSet]
        let agentHandoffLinks: [AgentHandoffLink]
        let enabledInstructionPacks: [InstructionPack]
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let maximumStoredRuns: Int
    private let maximumActiveRuns: Int
    private let maximumAutomationDefinitions: Int
    private let maximumStoredOccurrences: Int
    private let maximumActiveOccurrences: Int
    private let maximumInstructionPacks: Int
    private let maximumInstructionCatalogBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let automationAuthenticator: any GADAutomationDocumentAuthenticating
    private var writesSuspended = false
    private var catalog: CatalogDocument?
    private var runs: RunsDocument?
    private var automations: AutomationsDocument?
    private var automationMutationActive = false
    private var automationMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var instructions: InstructionsDocument?
    private var resources: ResourcesDocument?
    private var agentRestructure: AgentRestructureDocument?
    private var deletedAgent: DeletedAgentDocument?
    private var mapLayout: MapLayoutDocument?
    private var operationalContinuity: OperationalContinuityDocument?
    private var coordinatorCheckpoint: CoordinatorCheckpointDocument?

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maximumStoredRuns: Int = 2_000,
        maximumActiveRuns: Int = 128,
        maximumAutomationDefinitions: Int = 256,
        maximumStoredOccurrences: Int = 4_000,
        maximumActiveOccurrences: Int = 128,
        maximumInstructionPacks: Int = InstructionCatalogPolicy.maximumPackCount,
        maximumInstructionCatalogBytes: Int = InstructionCatalogPolicy.maximumEncodedCatalogBytes,
        automationAuthenticator: (any GADAutomationDocumentAuthenticating)? = nil
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maximumStoredRuns = max(1, maximumStoredRuns)
        self.maximumActiveRuns = max(1, min(maximumActiveRuns, maximumStoredRuns))
        self.maximumAutomationDefinitions = max(1, maximumAutomationDefinitions)
        self.maximumStoredOccurrences = max(1, maximumStoredOccurrences)
        self.maximumActiveOccurrences = max(1, min(maximumActiveOccurrences, maximumStoredOccurrences))
        self.maximumInstructionPacks = max(
            1,
            min(maximumInstructionPacks, InstructionCatalogPolicy.maximumPackCount)
        )
        self.maximumInstructionCatalogBytes = max(
            1_024,
            min(
                maximumInstructionCatalogBytes,
                InstructionCatalogPolicy.maximumEncodedCatalogBytes
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.automationAuthenticator = automationAuthenticator
            ?? KeychainAutomationDocumentAuthenticator(
                scope: directoryURL.standardizedFileURL.path(percentEncoded: false)
            )
    }

    public func snapshot() throws -> LabSnapshot {
        let document = try loadCatalog()
        return LabSnapshot(
            projects: document.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            agents: document.agents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            projectGroups: document.projectGroups.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            projectProviderConfigurations: document.projectProviderConfigurations.sorted {
                $0.projectID.rawValue < $1.projectID.rawValue
            },
            providerBindings: document.providerBindings.sorted { $0.id.rawValue < $1.id.rawValue },
            providerCollaborationSets: document.providerCollaborationSets.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            agentHandoffLinks: document.agentHandoffLinks.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            handoffs: document.handoffs.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    public func register(projects newProjects: [LabProject], agents newAgents: [AgentProfile]) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        var projects = Dictionary(uniqueKeysWithValues: document.projects.map { ($0.id, $0) })
        var agents = Dictionary(uniqueKeysWithValues: document.agents.map { ($0.id, $0) })
        var projectProviderConfigurations = Dictionary(
            uniqueKeysWithValues: document.projectProviderConfigurations.map { ($0.projectID, $0) }
        )
        var providerBindings = Dictionary(
            uniqueKeysWithValues: document.providerBindings.map { ($0.id, $0) }
        )

        for project in newProjects {
            if let current = projects[project.id] {
                projects[project.id] = LabProject(
                    id: project.id,
                    name: project.name,
                    rootURL: project.rootURL,
                    platforms: project.platforms,
                    frameworks: project.frameworks,
                    testCommands: project.testCommands,
                    instructionFiles: project.instructionFiles,
                    isGitRepository: project.isGitRepository,
                    registeredAt: current.registeredAt,
                    fileSystemIdentity: project.fileSystemIdentity ?? current.fileSystemIdentity,
                    template: project.template ?? current.template
                )
            } else {
                projects[project.id] = project
                projectProviderConfigurations[project.id] = .migratedCodexConfiguration(for: project)
            }
        }
        for agent in newAgents {
            let effectiveAgent: AgentProfile
            if let current = agents[agent.id] {
                effectiveAgent = AgentProfile(
                    id: agent.id,
                    name: agent.name,
                    summary: agent.summary,
                    instructions: agent.instructions,
                    capabilities: agent.capabilities,
                    scope: agent.scope,
                    sourceURL: agent.sourceURL,
                    toolPreset: agent.toolPreset,
                    reviewedDefinitionDigest: agent.reviewedDefinitionDigest,
                    definitionReviewProvenance: agent.definitionReviewProvenance,
                    codexRegistrationKey: agent.codexRegistrationKey,
                    isEnabled: current.isEnabled
                )
            } else {
                effectiveAgent = agent
            }
            agents[agent.id] = effectiveAgent
            let binding = ProviderAgentBinding.migratedCodexBinding(for: effectiveAgent)
            providerBindings[binding.id] = binding
        }

        document.projects = Array(projects.values)
        document.agents = Array(agents.values)
        document.projectProviderConfigurations = Array(projectProviderConfigurations.values)
        document.providerBindings = Array(providerBindings.values)
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeProject(id: ProjectID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.projects.contains(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownProject(id)
        }
        document.projects.removeAll { $0.id == id }
        document.projectProviderConfigurations.removeAll { $0.projectID == id }
        document.agents.removeAll { agent in
            if case let .project(projectID) = agent.scope {
                return projectID == id
            }
            return false
        }
        let removedAgentIDs = Set(document.providerBindings.compactMap { binding in
            binding.projectID == id ? binding.agentID : nil
        })
        let removedBindingIDs = Set(document.providerBindings.compactMap { binding in
            binding.projectID == id || removedAgentIDs.contains(binding.agentID) ? binding.id : nil
        })
        document.providerBindings.removeAll { removedBindingIDs.contains($0.id) }
        document.providerCollaborationSets.removeAll { collaborationSet in
            collaborationSet.projectID == id
                || collaborationSet.members.contains {
                    removedBindingIDs.contains($0.bindingID)
                }
        }
        document.agentHandoffLinks.removeAll { link in
            link.source.projectID == id
                || link.destination.projectID == id
                || removedBindingIDs.contains(link.source.bindingID)
                || removedBindingIDs.contains(link.destination.bindingID)
        }
        document.projectGroups = document.projectGroups.compactMap { group in
            let members = group.members.filter { $0.projectID != id }
            guard members.count >= 2 else { return nil }
            return ProjectGroup(
                id: group.id,
                name: group.name,
                members: members,
                createdAt: group.createdAt
            )
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveProjectGroup(_ group: ProjectGroup) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        if let index = document.projectGroups.firstIndex(where: { $0.id == group.id }) {
            document.projectGroups[index] = group
        } else {
            document.projectGroups.append(group)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeProjectGroup(id: ProjectGroupID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.projectGroups.contains(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownProjectGroup(id)
        }
        document.projectGroups.removeAll { $0.id == id }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveProviderBinding(_ binding: ProviderAgentBinding) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.agents.contains(where: { $0.id == binding.agentID }) else {
            throw GobyApplicationError.unknownAgent(binding.agentID)
        }
        if let projectID = binding.projectID,
           !document.projects.contains(where: { $0.id == projectID }) {
            throw GobyApplicationError.unknownProject(projectID)
        }
        if let index = document.providerBindings.firstIndex(where: { $0.id == binding.id }) {
            document.providerBindings[index] = binding
        } else {
            document.providerBindings.append(binding)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveProjectProviderConfiguration(
        _ configuration: ProjectProviderConfiguration
    ) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.projects.contains(where: { $0.id == configuration.projectID }) else {
            throw GobyApplicationError.unknownProject(configuration.projectID)
        }
        if let index = document.projectProviderConfigurations.firstIndex(where: {
            $0.projectID == configuration.projectID
        }) {
            document.projectProviderConfigurations[index] = configuration
        } else {
            document.projectProviderConfigurations.append(configuration)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeProjectProviderConfiguration(projectID: ProjectID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        document.projectProviderConfigurations.removeAll { $0.projectID == projectID }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeProviderBinding(id: ProviderAgentBindingID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        document.providerBindings.removeAll { $0.id == id }
        document.agentHandoffLinks.removeAll {
            $0.source.bindingID == id || $0.destination.bindingID == id
        }
        document.providerCollaborationSets = document.providerCollaborationSets.compactMap { set in
            let members = set.members.filter { $0.bindingID != id }
            let updated = ProviderCollaborationSet(
                id: set.id,
                projectID: set.projectID,
                members: members,
                createdAt: set.createdAt
            )
            return updated.isCollaborative ? updated : nil
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveProviderCollaborationSet(_ collaborationSet: ProviderCollaborationSet) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.projects.contains(where: { $0.id == collaborationSet.projectID }) else {
            throw GobyApplicationError.unknownProject(collaborationSet.projectID)
        }
        let bindingsByID = Dictionary(
            uniqueKeysWithValues: document.providerBindings.map { ($0.id, $0) }
        )
        let hasInvalidMember = collaborationSet.members.contains { member in
            guard let binding = bindingsByID[member.bindingID] else { return true }
            return binding.providerID != member.providerID
                || binding.projectID != collaborationSet.projectID
        }
        guard collaborationSet.isCollaborative, !hasInvalidMember else {
            throw GobyApplicationError.invalidProviderCollaborationSet
        }
        if let index = document.providerCollaborationSets.firstIndex(where: {
            $0.id == collaborationSet.id || $0.projectID == collaborationSet.projectID
        }) {
            document.providerCollaborationSets[index] = collaborationSet
        } else {
            document.providerCollaborationSets.append(collaborationSet)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeProviderCollaborationSet(id: ProviderCollaborationSetID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        document.providerCollaborationSets.removeAll { $0.id == id }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveHandoffLink(_ link: AgentHandoffLink) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        try validate(link, in: document)
        if let index = document.agentHandoffLinks.firstIndex(where: { $0.id == link.id }) {
            document.agentHandoffLinks[index] = link
        } else {
            document.agentHandoffLinks.append(link)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeHandoffLink(id: AgentHandoffLinkID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        document.agentHandoffLinks.removeAll { $0.id == id }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveHandoff(_ handoff: HandoffRecord) throws {
        var document = try loadCatalog()
        guard document.agentHandoffLinks.contains(where: { $0.id == handoff.bundle.linkID }) else {
            throw GobyApplicationError.unknownHandoffLink(handoff.bundle.linkID)
        }
        if let duplicate = document.handoffs.first(where: {
            $0.bundle.idempotencyKey == handoff.bundle.idempotencyKey && $0.id != handoff.id
        }) {
            throw GobyApplicationError.duplicateHandoff(duplicate.id)
        }
        if let index = document.handoffs.firstIndex(where: { $0.id == handoff.id }) {
            document.handoffs[index] = handoff
        } else {
            document.handoffs.append(handoff)
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func saveAgent(_ agent: AgentProfile) async throws {
        try await register(projects: [], agents: [agent])
    }

    public func setAgentEnabled(id: AgentID, enabled: Bool) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard let index = document.agents.firstIndex(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAgent(id)
        }
        let current = document.agents[index]
        document.agents[index] = AgentProfile(
            id: current.id,
            name: current.name,
            summary: current.summary,
            instructions: current.instructions,
            capabilities: current.capabilities,
            scope: current.scope,
            sourceURL: current.sourceURL,
            toolPreset: current.toolPreset,
            reviewedDefinitionDigest: current.reviewedDefinitionDigest,
            definitionReviewProvenance: current.definitionReviewProvenance,
            codexRegistrationKey: current.codexRegistrationKey,
            isEnabled: enabled
        )
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func removeAgent(id: AgentID) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard document.agents.contains(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAgent(id)
        }
        document.agents.removeAll { $0.id == id }
        let removedBindingIDs = Set(document.providerBindings.compactMap { binding in
            binding.agentID == id ? binding.id : nil
        })
        document.providerBindings.removeAll { removedBindingIDs.contains($0.id) }
        document.agentHandoffLinks.removeAll {
            removedBindingIDs.contains($0.source.bindingID)
                || removedBindingIDs.contains($0.destination.bindingID)
        }
        document.providerCollaborationSets = document.providerCollaborationSets.compactMap { set in
            let members = set.members.filter { !removedBindingIDs.contains($0.bindingID) }
            let updated = ProviderCollaborationSet(
                id: set.id,
                projectID: set.projectID,
                members: members,
                createdAt: set.createdAt
            )
            return updated.isCollaborative ? updated : nil
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func replaceAgent(id: AgentID, with agent: AgentProfile) async throws {
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadCatalog()
        guard let index = document.agents.firstIndex(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAgent(id)
        }
        document.agents.remove(at: index)
        document.agents.removeAll { $0.id == agent.id }
        document.agents.append(agent)
        let replacedBindingIDs = Set(document.providerBindings.compactMap { binding in
            binding.agentID == id ? binding.id : nil
        })
        document.providerBindings.removeAll { replacedBindingIDs.contains($0.id) }
        document.agentHandoffLinks.removeAll {
            replacedBindingIDs.contains($0.source.bindingID)
                || replacedBindingIDs.contains($0.destination.bindingID)
        }
        let migrated = ProviderAgentBinding.migratedCodexBinding(for: agent)
        document.providerBindings.removeAll { $0.id == migrated.id }
        document.providerBindings.append(migrated)
        document.providerCollaborationSets = document.providerCollaborationSets.compactMap { set in
            let members = set.members.filter { !replacedBindingIDs.contains($0.bindingID) }
            let updated = ProviderCollaborationSet(
                id: set.id,
                projectID: set.projectID,
                members: members,
                createdAt: set.createdAt
            )
            return updated.isCollaborative ? updated : nil
        }
        try persist(document, to: catalogURL)
        catalog = document
    }

    public func allRuns() throws -> [RunRecord] {
        try loadRuns().runs.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ run: RunRecord) throws {
        var document = try loadRuns()
        if let index = document.runs.firstIndex(where: { $0.id == run.id }) {
            document.runs[index] = run
        } else {
            guard run.status.isFinished
                    || document.runs.lazy.filter({ !$0.status.isFinished }).count < maximumActiveRuns else {
                throw PersistentStoreCapacityError.activeRuns(maximumActiveRuns)
            }
            document.runs.append(run)
        }
        guard document.runs.lazy.filter({ !$0.status.isFinished }).count <= maximumActiveRuns else {
            throw PersistentStoreCapacityError.activeRuns(maximumActiveRuns)
        }
        document.runs = retainedRuns(document.runs)
        try persist(document, to: runsURL)
        runs = document
    }

    public func automationSnapshot() async throws -> AutomationSnapshot {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        let document = try await loadAutomations()
        return AutomationSnapshot(
            definitions: document.definitions.sorted {
                if $0.state != $1.state { return $0.state == .active }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            occurrences: document.occurrences.sorted { $0.scheduledAt > $1.scheduledAt }
        )
    }

    public func automationExecutionAuthorityDigest() async throws -> Data {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        let document = try await loadAutomations()
        guard let digest = document.catalogAuthorityDigest else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        return digest
    }

    public func saveAutomation(
        _ automation: AutomationDefinition,
        replacing expected: AutomationDefinition?
    ) async throws {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        var document = try await loadAutomations()
        let index = document.definitions.firstIndex(where: { $0.id == automation.id })
        guard index.map({ document.definitions[$0] }) == expected else {
            throw GobyApplicationError.automationChanged(automation.id)
        }
        if let index {
            document.definitions[index] = automation
        } else {
            guard document.definitions.count < maximumAutomationDefinitions else {
                throw PersistentStoreCapacityError.automations(maximumAutomationDefinitions)
            }
            document.definitions.append(automation)
        }
        automations = try await persistAutomations(document)
    }

    public func removeAutomation(
        id: AutomationID,
        replacing expected: AutomationDefinition
    ) async throws {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        var document = try await loadAutomations()
        guard let index = document.definitions.firstIndex(where: { $0.id == id }),
              document.definitions[index] == expected else {
            throw GobyApplicationError.automationChanged(id)
        }
        document.definitions.remove(at: index)
        // Retain immutable occurrence history for audit and recovery.
        automations = try await persistAutomations(document)
    }

    public func saveAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        replacing expected: AutomationOccurrence?
    ) async throws {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        var document = try await loadAutomations()
        let index = document.occurrences.firstIndex(where: { $0.id == occurrence.id })
        guard index.map({ document.occurrences[$0] }) == expected else {
            throw GobyApplicationError.automationOccurrenceChanged(occurrence.id)
        }
        if let index {
            document.occurrences[index] = occurrence
        } else {
            guard occurrence.status.isFinished
                    || document.occurrences.lazy.filter({ !$0.status.isFinished }).count < maximumActiveOccurrences else {
                throw PersistentStoreCapacityError.activeAutomationOccurrences(maximumActiveOccurrences)
            }
            document.occurrences.append(occurrence)
        }
        guard document.occurrences.lazy.filter({ !$0.status.isFinished }).count <= maximumActiveOccurrences else {
            throw PersistentStoreCapacityError.activeAutomationOccurrences(maximumActiveOccurrences)
        }
        document.occurrences = retainedOccurrences(document.occurrences)
        automations = try await persistAutomations(document)
    }

    public func claimAutomationOccurrence(
        _ occurrence: AutomationOccurrence,
        advancing automation: AutomationDefinition,
        replacing expectedAutomation: AutomationDefinition
    ) async throws {
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        var document = try await loadAutomations()
        guard let definitionIndex = document.definitions.firstIndex(where: {
            $0.id == expectedAutomation.id
        }), document.definitions[definitionIndex] == expectedAutomation else {
            throw GobyApplicationError.automationChanged(expectedAutomation.id)
        }
        guard automation.id == expectedAutomation.id,
              automation.name == expectedAutomation.name,
              automation.schedule == expectedAutomation.schedule,
              automation.actions == expectedAutomation.actions,
              automation.state == expectedAutomation.state,
              automation.revision == expectedAutomation.revision,
              automation.createdAt == expectedAutomation.createdAt,
              occurrence.automationID == expectedAutomation.id,
              occurrence.automationName == expectedAutomation.name,
              occurrence.definitionRevision == expectedAutomation.revision,
              occurrence.actions == expectedAutomation.actions,
              occurrence.status == .queued,
              occurrence.currentActionIndex == 0,
              occurrence.attempts.isEmpty else {
            throw GobyApplicationError.invalidAutomation(
                "The occurrence no longer matches the reviewed automation. Refresh and try again."
            )
        }
        guard !document.occurrences.contains(where: { $0.id == occurrence.id }) else {
            throw GobyApplicationError.automationOccurrenceChanged(occurrence.id)
        }
        guard !document.occurrences.contains(where: {
            $0.automationID == expectedAutomation.id && !$0.status.isFinished
        }) else {
            throw GobyApplicationError.automationHasUnfinishedOccurrence(expectedAutomation.id)
        }
        guard document.occurrences.lazy.filter({ !$0.status.isFinished }).count
                < maximumActiveOccurrences else {
            throw PersistentStoreCapacityError.activeAutomationOccurrences(maximumActiveOccurrences)
        }

        document.definitions[definitionIndex] = automation
        document.occurrences.append(occurrence)
        document.occurrences = retainedOccurrences(document.occurrences)
        automations = try await persistAutomations(document)
    }

    public func allInstructionPacks() throws -> [InstructionPack] {
        try loadInstructions().packs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ pack: InstructionPack) async throws {
        try InstructionCatalogPolicy.validate(pack)
        try await quarantineBeforeExecutionAuthorityMutation()
        var document = try loadInstructions()
        if let index = document.packs.firstIndex(where: { $0.id == pack.id }) {
            document.packs[index] = pack
        } else {
            guard document.packs.count < maximumInstructionPacks else {
                throw PersistentStoreCapacityError.instructionPacks(maximumInstructionPacks)
            }
            document.packs.append(pack)
        }
        try validateInstructionDocument(document)
        try persist(document, to: instructionsURL)
        instructions = document
    }

    public func allResources() throws -> [SharedResource] {
        try loadResources().resources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func saveResource(_ resource: SharedResource) throws {
        var document = try loadResources()
        if let duplicate = document.resources.firstIndex(where: { $0.url.standardizedFileURL == resource.url.standardizedFileURL }) {
            let current = document.resources[duplicate]
            document.resources[duplicate] = SharedResource(
                id: current.id,
                name: resource.name,
                url: resource.url,
                access: resource.access,
                isEnabled: resource.isEnabled,
                registeredAt: current.registeredAt,
                fileSystemIdentity: resource.fileSystemIdentity
            )
        } else {
            document.resources.append(resource)
        }
        try persist(document, to: resourcesURL)
        resources = document
    }

    public func setResourceEnabled(id: SharedResourceID, enabled: Bool) throws {
        var document = try loadResources()
        guard let index = document.resources.firstIndex(where: { $0.id == id }) else { return }
        let current = document.resources[index]
        document.resources[index] = SharedResource(
            id: current.id,
            name: current.name,
            url: current.url,
            access: current.access,
            isEnabled: enabled,
            registeredAt: current.registeredAt,
            fileSystemIdentity: current.fileSystemIdentity
        )
        try persist(document, to: resourcesURL)
        resources = document
    }

    public func lastAgentRestructure() throws -> [AgentDefinitionChangePreview] {
        try loadAgentRestructure().changes
    }

    public func saveLastAgentRestructure(_ changes: [AgentDefinitionChangePreview]) throws {
        let document = AgentRestructureDocument(version: 1, changes: changes)
        try persist(document, to: agentRestructureURL)
        agentRestructure = document
    }

    public func lastDeletedAgent() throws -> DeletedAgentRecord? {
        try loadDeletedAgent().record
    }

    public func saveLastDeletedAgent(_ record: DeletedAgentRecord?) throws {
        let document = DeletedAgentDocument(version: 1, record: record)
        try persist(document, to: deletedAgentURL)
        deletedAgent = document
    }

    public func loadMapLayout() throws -> MapLayoutOverrides {
        try loadMapLayoutDocument().layout
    }

    public func saveMapLayout(_ layout: MapLayoutOverrides) throws {
        let document = MapLayoutDocument(version: 1, layout: layout)
        try persist(document, to: mapLayoutURL)
        mapLayout = document
    }

    public func loadOperationalContinuity() throws -> GADOperationalContinuityState {
        try loadOperationalContinuityDocument().state
    }

    public func saveOperationalContinuity(_ state: GADOperationalContinuityState) throws {
        let document = OperationalContinuityDocument(version: 1, state: state)
        try persist(document, to: operationalContinuityURL)
        operationalContinuity = document
    }

    public func loadCoordinatorCheckpoint(hostID: HostID) throws -> GADCoordinatorCheckpoint? {
        let checkpoint = try loadCoordinatorCheckpointDocument().checkpoint
        return checkpoint?.hostID == hostID ? checkpoint : nil
    }

    public func saveCoordinatorCheckpoint(_ checkpoint: GADCoordinatorCheckpoint) throws {
        let document = CoordinatorCheckpointDocument(version: 1, checkpoint: checkpoint)
        try persist(document, to: coordinatorCheckpointURL)
        coordinatorCheckpoint = document
    }

    private var catalogURL: URL { directoryURL.appending(path: "catalog.json") }
    private var runsURL: URL { directoryURL.appending(path: "runs.json") }
    private var automationsURL: URL { directoryURL.appending(path: "automations.json") }
    private var instructionsURL: URL { directoryURL.appending(path: "instructions.json") }
    private var resourcesURL: URL { directoryURL.appending(path: "resources.json") }
    private var agentRestructureURL: URL { directoryURL.appending(path: "agent-restructure.json") }
    private var deletedAgentURL: URL { directoryURL.appending(path: "deleted-agent.json") }
    private var mapLayoutURL: URL { directoryURL.appending(path: "map-layout.json") }
    private var operationalContinuityURL: URL { directoryURL.appending(path: "operational-continuity.json") }
    private var coordinatorCheckpointURL: URL { directoryURL.appending(path: "coordinator-checkpoint.json") }

    private func loadCatalog() throws -> CatalogDocument {
        if let catalog { return catalog }
        let loaded: CatalogDocument = try load(
            from: catalogURL,
            fallback: .empty,
            validate: validateCatalog
        )
        catalog = loaded
        return loaded
    }

    private func validateCatalog(_ document: CatalogDocument) throws {
        try requireUnique(document.projects.map(\.id), label: "project identities")
        try requireUnique(document.agents.map(\.id), label: "agent identities")
        try requireUnique(document.projectGroups.map(\.id), label: "project-group identities")
        try requireUnique(
            document.projectProviderConfigurations.map(\.projectID),
            label: "project provider configurations"
        )
        try requireUnique(document.providerBindings.map(\.id), label: "provider binding identities")
        try requireUnique(
            document.providerCollaborationSets.map(\.id),
            label: "provider collaboration-set identities"
        )
        try requireUnique(document.agentHandoffLinks.map(\.id), label: "handoff-link identities")
        try requireUnique(document.handoffs.map(\.id), label: "handoff record identities")

        let projectIDs = Set(document.projects.map(\.id))
        let agentIDs = Set(document.agents.map(\.id))
        let bindingIDs = Set(document.providerBindings.map(\.id))
        for configuration in document.projectProviderConfigurations
        where !projectIDs.contains(configuration.projectID) {
            throw integrityError("provider configuration references an unknown project")
        }
        for group in document.projectGroups {
            try requireUnique(group.members.map(\.projectID), label: "members in project group \(group.id.rawValue)")
            guard group.members.allSatisfy({ projectIDs.contains($0.projectID) }) else {
                throw integrityError("project group references an unknown project")
            }
        }
        for binding in document.providerBindings {
            guard agentIDs.contains(binding.agentID) else {
                throw integrityError("provider binding references an unknown agent")
            }
            if let projectID = binding.projectID, !projectIDs.contains(projectID) {
                throw integrityError("provider binding references an unknown project")
            }
        }
        for collaborationSet in document.providerCollaborationSets {
            guard projectIDs.contains(collaborationSet.projectID),
                  collaborationSet.members.allSatisfy({ bindingIDs.contains($0.bindingID) }) else {
                throw integrityError("provider collaboration set has an unknown project or binding")
            }
        }
    }

    private func requireUnique<ID: Hashable>(_ values: [ID], label: String) throws {
        guard Set(values).count == values.count else {
            throw integrityError("duplicate \(label)")
        }
    }

    private func integrityError(_ reason: String) -> PersistentStoreIntegrityError {
        .invalidDocument(file: catalogURL.lastPathComponent, reason: reason)
    }

    private func validate(_ link: AgentHandoffLink, in document: CatalogDocument) throws {
        guard link.source != link.destination else {
            throw GobyApplicationError.invalidHandoffLink("source and destination must be different bindings")
        }
        guard !link.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GobyApplicationError.invalidHandoffLink("enter a plain-language purpose")
        }
        guard !link.conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GobyApplicationError.invalidHandoffLink("enter when this continuation is appropriate")
        }
        guard !link.acceptedArtifacts.isEmpty else {
            throw GobyApplicationError.invalidHandoffLink("choose at least one accepted artifact kind")
        }
        guard !link.triggers.isEmpty else {
            throw GobyApplicationError.invalidHandoffLink("choose at least one source checkpoint")
        }
        guard (1...8).contains(link.maximumDepth) else {
            throw GobyApplicationError.invalidHandoffLink("maximum depth must be between 1 and 8")
        }
        let bindings = Dictionary(uniqueKeysWithValues: document.providerBindings.map { ($0.id, $0) })
        for endpoint in [link.source, link.destination] {
            guard let binding = bindings[endpoint.bindingID],
                  binding.providerID == endpoint.providerID,
                  binding.agentID == endpoint.agentID,
                  binding.projectID == endpoint.projectID else {
                throw GobyApplicationError.invalidHandoffLink("an endpoint no longer matches its exact provider binding")
            }
        }
    }

    private func loadRuns() throws -> RunsDocument {
        if let runs { return runs }
        var loaded: RunsDocument = try load(from: runsURL, fallback: .empty)
        guard loaded.runs.lazy.filter({ !$0.status.isFinished }).count <= maximumActiveRuns else {
            throw PersistentStoreCapacityError.activeRuns(maximumActiveRuns)
        }
        let retained = retainedRuns(loaded.runs)
        if retained.count != loaded.runs.count {
            loaded.runs = retained
            try persist(loaded, to: runsURL)
        }
        runs = loaded
        return loaded
    }

    private func loadAutomations() async throws -> AutomationsDocument {
        if let automations {
            return try await enforceCurrentCatalogAuthority(for: automations)
        }
        guard fileManager.fileExists(atPath: automationsURL.path(percentEncoded: false)) else {
            automations = .empty
            return .empty
        }
        try secureFile(at: automationsURL)
        let loadedResult: (
            document: AutomationsDocument,
            freshness: GADAutomationDocumentFreshness,
            authentication: GADAutomationDocumentAuthentication,
            payload: Data
        )
        do {
            loadedResult = try await loadAuthenticatedAutomations(from: automationsURL)
        } catch let compatibilityError as PersistentStoreCompatibilityError {
            throw compatibilityError
        } catch let primaryError {
            if let legacy = try loadLegacyAutomationsIfPresent(from: automationsURL) {
                let quarantined = quarantineUnverifiedAutomations(legacy)
                try validateAutomationCapacity(quarantined)
                return try await persistAutomations(
                    quarantined,
                    preserveVerifiedCurrent: false,
                    rebindExecutionAuthority: true
                )
            }
            let backupURL = automationsURL.appendingPathExtension("previous")
            guard fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) else {
                throw primaryError
            }
            try secureFile(at: backupURL)
            let recovered: AutomationsDocument
            do {
                recovered = try await loadAuthenticatedAutomations(from: backupURL).document
            } catch let compatibilityError as PersistentStoreCompatibilityError {
                throw compatibilityError
            } catch {
                guard let legacy = try loadLegacyAutomationsIfPresent(from: backupURL) else {
                    throw primaryError
                }
                recovered = legacy
            }
            let corruptURL = automationsURL.appendingPathExtension(
                "corrupt-\(Int(Date.now.timeIntervalSince1970))"
            )
            try requireWriteAccess()
            if (try? fileManager.copyItem(at: automationsURL, to: corruptURL)) != nil {
                try? secureFile(at: corruptURL)
            }
            let quarantined = quarantineUnverifiedAutomations(recovered)
            try validateAutomationCapacity(quarantined)
            return try await writeRecoveredAutomations(quarantined)
        }
        if loadedResult.freshness == .current {
            if !writesSuspended { try await automationAuthenticator.discardPrepared() }
        } else if loadedResult.freshness == .prepared {
            try requireWriteAccess()
            try await automationAuthenticator.commit(
                loadedResult.authentication,
                payload: loadedResult.payload
            )
        }
        var loaded = loadedResult.freshness == .current
            ? loadedResult.document
            : quarantineUnverifiedAutomations(loadedResult.document)
        try validateAutomationCapacity(loaded)
        let retained = retainedOccurrences(loaded.occurrences)
        if retained.count != loaded.occurrences.count {
            loaded.occurrences = retained
            if loadedResult.freshness == .previous {
                loaded = try await writeRecoveredAutomations(loaded)
            } else {
                loaded = try await persistAutomations(
                    loaded,
                    rebindExecutionAuthority: true
                )
            }
        } else if loadedResult.freshness != .current {
            if loadedResult.freshness == .previous {
                loaded = try await writeRecoveredAutomations(loaded)
            } else {
                loaded = try await persistAutomations(loaded)
            }
        }
        automations = loaded
        return try await enforceCurrentCatalogAuthority(for: loaded)
    }

    private func acquireAutomationMutation() async {
        guard automationMutationActive else {
            automationMutationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            automationMutationWaiters.append(continuation)
        }
    }

    private func releaseAutomationMutation() {
        guard !automationMutationWaiters.isEmpty else {
            automationMutationActive = false
            return
        }
        automationMutationWaiters.removeFirst().resume()
    }

    private func loadAuthenticatedAutomations(
        from url: URL
    ) async throws -> (
        document: AutomationsDocument,
        freshness: GADAutomationDocumentFreshness,
        authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) {
        let envelope: AuthenticatedAutomationsDocument = try decode(
            AuthenticatedAutomationsDocument.self,
            from: url
        )
        guard envelope.payload.version == Self.currentDocumentVersion else {
            throw PersistentStoreCompatibilityError.unsupportedVersion(
                file: url.lastPathComponent,
                found: envelope.payload.version,
                supported: Self.currentDocumentVersion
            )
        }
        let payload = try encoder.encode(envelope.payload)
        let authentication = GADAutomationDocumentAuthentication(
            generation: envelope.generation,
            tag: envelope.authenticationTag
        )
        let freshness = try await automationAuthenticator.verify(
            authentication,
            payload: payload
        )
        return (envelope.payload, freshness, authentication, payload)
    }

    private func loadLegacyAutomationsIfPresent(from url: URL) throws -> AutomationsDocument? {
        do {
            return try decode(AutomationsDocument.self, from: url)
        } catch let compatibilityError as PersistentStoreCompatibilityError {
            throw compatibilityError
        } catch {
            return nil
        }
    }

    private func persistAutomations(
        _ document: AutomationsDocument,
        preserveVerifiedCurrent: Bool = true,
        rebindExecutionAuthority: Bool = false
    ) async throws -> AutomationsDocument {
        try requireWriteAccess()
        let backupURL = automationsURL.appendingPathExtension("previous")
        if preserveVerifiedCurrent,
           fileManager.fileExists(atPath: automationsURL.path(percentEncoded: false)) {
            let verified = try await loadAuthenticatedAutomations(from: automationsURL)
            guard verified.freshness == .current else {
                throw GADAutomationDocumentAuthenticationError.authenticationFailed
            }
            let verifiedCurrent = try Data(contentsOf: automationsURL)
            try verifiedCurrent.write(to: backupURL, options: .atomic)
            try secureFile(at: backupURL)
        }
        var authorityBoundDocument = document
        let currentAuthorityDigest = try currentExecutionAuthorityDigest()
        if rebindExecutionAuthority || authorityBoundDocument.catalogAuthorityDigest == nil {
            authorityBoundDocument.catalogAuthorityDigest = currentAuthorityDigest
        } else if authorityBoundDocument.catalogAuthorityDigest != currentAuthorityDigest {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        let sealed = try await authenticatedAutomationsEnvelope(for: authorityBoundDocument)
        let envelope = sealed.envelope
        let data = try encoder.encode(envelope)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try data.write(to: automationsURL, options: .atomic)
        try secureFile(at: automationsURL)
        try await automationAuthenticator.commit(sealed.authentication, payload: sealed.payload)
        automations = authorityBoundDocument
        if !preserveVerifiedCurrent {
            try data.write(to: backupURL, options: .atomic)
            try secureFile(at: backupURL)
        }
        return authorityBoundDocument
    }

    private func writeRecoveredAutomations(
        _ document: AutomationsDocument
    ) async throws -> AutomationsDocument {
        try requireWriteAccess()
        var authorityBoundDocument = document
        authorityBoundDocument.catalogAuthorityDigest = try currentExecutionAuthorityDigest()
        let sealed = try await authenticatedAutomationsEnvelope(for: authorityBoundDocument)
        let envelope = sealed.envelope
        let data = try encoder.encode(envelope)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try data.write(to: automationsURL, options: .atomic)
        try secureFile(at: automationsURL)
        try await automationAuthenticator.commit(sealed.authentication, payload: sealed.payload)
        automations = authorityBoundDocument
        let backupURL = automationsURL.appendingPathExtension("previous")
        try data.write(to: backupURL, options: .atomic)
        try secureFile(at: backupURL)
        return authorityBoundDocument
    }

    private func authenticatedAutomationsEnvelope(
        for document: AutomationsDocument
    ) async throws -> (
        envelope: AuthenticatedAutomationsDocument,
        authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) {
        let payload = try encoder.encode(document)
        let authentication = try await automationAuthenticator.issue(for: payload)
        return (AuthenticatedAutomationsDocument(
            version: Self.currentDocumentVersion,
            payload: document,
            generation: authentication.generation,
            authenticationTag: authentication.tag
        ), authentication, payload)
    }

    private func validateAutomationCapacity(_ document: AutomationsDocument) throws {
        guard document.definitions.count <= maximumAutomationDefinitions else {
            throw PersistentStoreCapacityError.automations(maximumAutomationDefinitions)
        }
        guard document.occurrences.lazy.filter({ !$0.status.isFinished }).count
                <= maximumActiveOccurrences else {
            throw PersistentStoreCapacityError.activeAutomationOccurrences(maximumActiveOccurrences)
        }
    }

    /// Advances authenticated automation state to a non-executable generation
    /// before any authority file changes. If the process stops between the two
    /// writes, replaying the previous catalog or instruction file still meets
    /// only a paused current automation generation.
    private func quarantineBeforeExecutionAuthorityMutation() async throws {
        guard fileManager.fileExists(atPath: automationsURL.path(percentEncoded: false)) else {
            return
        }
        await acquireAutomationMutation()
        defer { releaseAutomationMutation() }
        let document = try await loadAutomations()
        guard document.definitions.contains(where: { $0.state == .active })
                || document.occurrences.contains(where: { !$0.status.isFinished }) else {
            return
        }
        let quarantined = quarantineAutomations(
            document,
            message: "Goby paused this automation before its project, agent, provider, or instruction authority changed. Review the schedule before resuming it; unfinished work was closed without replay."
        )
        _ = try await persistAutomations(quarantined)
    }

    private func enforceCurrentCatalogAuthority(
        for document: AutomationsDocument
    ) async throws -> AutomationsDocument {
        let currentDigest = try currentExecutionAuthorityDigest()
        guard document.catalogAuthorityDigest == currentDigest else {
            let quarantined = quarantineAutomations(
                document,
                message: "Goby paused this automation because its project or agent execution authority changed. Review the schedule before resuming it; unfinished work was closed without running another action."
            )
            try validateAutomationCapacity(quarantined)
            return try await persistAutomations(
                quarantined,
                rebindExecutionAuthority: true
            )
        }
        return document
    }

    private func currentExecutionAuthorityDigest() throws -> Data {
        let catalog = try loadCatalog()
        let instructionDocument = try loadInstructions()
        let authority = AutomationExecutionAuthorityMaterialV1(
            projects: catalog.projects,
            agents: catalog.agents,
            projectGroups: catalog.projectGroups,
            projectProviderConfigurations: catalog.projectProviderConfigurations,
            providerBindings: catalog.providerBindings,
            providerCollaborationSets: catalog.providerCollaborationSets,
            agentHandoffLinks: catalog.agentHandoffLinks,
            enabledInstructionPacks: instructionDocument.packs.filter(\.isEnabled)
        )
        let encoded = try encoder.encode(authority)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let canonical = try Self.canonicalAuthorityJSON(object)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys]
        )
        return Data(SHA256.hash(data: canonicalData))
    }

    private nonisolated static func canonicalAuthorityJSON(_ value: Any) throws -> Any {
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues(canonicalAuthorityJSON)
        }
        if let array = value as? [Any] {
            return try array
                .map(canonicalAuthorityJSON)
                .sorted { lhs, rhs in
                    let lhsData = try? JSONSerialization.data(
                        withJSONObject: lhs,
                        options: [.sortedKeys, .fragmentsAllowed]
                    )
                    let rhsData = try? JSONSerialization.data(
                        withJSONObject: rhs,
                        options: [.sortedKeys, .fragmentsAllowed]
                    )
                    return (lhsData ?? Data()).lexicographicallyPrecedes(rhsData ?? Data())
                }
        }
        return value
    }

    private func quarantineUnverifiedAutomations(_ document: AutomationsDocument) -> AutomationsDocument {
        let message = "Goby paused this saved automation because its authenticity could not be verified. Review the schedule before resuming it; unfinished legacy work was closed without running another action."
        return quarantineAutomations(document, message: message)
    }

    private func quarantineAutomations(
        _ document: AutomationsDocument,
        message: String
    ) -> AutomationsDocument {
        return AutomationsDocument(
            version: document.version,
            definitions: document.definitions.map { definition in
                AutomationDefinition(
                    id: definition.id,
                    name: definition.name,
                    schedule: definition.schedule,
                    actions: definition.actions,
                    state: .paused,
                    automaticallyApproveRuntimeRequests: definition.automaticallyApproveRuntimeRequests,
                    nextRunAt: nil,
                    revision: definition.revision,
                    createdAt: definition.createdAt,
                    updatedAt: definition.updatedAt
                )
            },
            occurrences: document.occurrences.map { occurrence in
                guard !occurrence.status.isFinished else { return occurrence }
                return AutomationOccurrence(
                    id: occurrence.id,
                    automationID: occurrence.automationID,
                    automationName: occurrence.automationName,
                    definitionRevision: occurrence.definitionRevision,
                    actions: occurrence.actions,
                    trigger: occurrence.trigger,
                    scheduledAt: occurrence.scheduledAt,
                    status: .failed,
                    currentActionIndex: occurrence.currentActionIndex,
                    attempts: occurrence.attempts.map { attempt in
                        guard attempt.status != .completed,
                              attempt.status != .failed,
                              attempt.status != .cancelled else { return attempt }
                        return AutomationActionAttempt(
                            actionID: attempt.actionID,
                            plan: nil,
                            runID: nil,
                            status: .failed,
                            message: message,
                            updatedAt: .now
                        )
                    },
                    message: message,
                    createdAt: occurrence.createdAt,
                    updatedAt: .now
                )
            },
            catalogAuthorityDigest: document.catalogAuthorityDigest
        )
    }

    private func loadInstructions() throws -> InstructionsDocument {
        if let instructions { return instructions }
        let loaded: InstructionsDocument = try load(
            from: instructionsURL,
            fallback: .empty,
            validate: validateInstructionDocument
        )
        instructions = loaded
        return loaded
    }

    private func validateInstructionDocument(_ document: InstructionsDocument) throws {
        guard document.packs.count <= maximumInstructionPacks else {
            throw PersistentStoreCapacityError.instructionPacks(maximumInstructionPacks)
        }
        for pack in document.packs {
            try InstructionCatalogPolicy.validate(pack)
        }
        guard try encoder.encode(document).count <= maximumInstructionCatalogBytes else {
            throw PersistentStoreCapacityError.instructionCatalogTooLarge(
                maximumInstructionCatalogBytes
            )
        }
    }

    private func loadResources() throws -> ResourcesDocument {
        if let resources { return resources }
        let loaded: ResourcesDocument = try load(from: resourcesURL, fallback: .empty)
        resources = loaded
        return loaded
    }

    private func loadAgentRestructure() throws -> AgentRestructureDocument {
        if let agentRestructure { return agentRestructure }
        let loaded: AgentRestructureDocument = try load(from: agentRestructureURL, fallback: .empty)
        agentRestructure = loaded
        return loaded
    }

    private func loadDeletedAgent() throws -> DeletedAgentDocument {
        if let deletedAgent { return deletedAgent }
        let loaded: DeletedAgentDocument = try load(from: deletedAgentURL, fallback: .empty)
        deletedAgent = loaded
        return loaded
    }

    private func loadMapLayoutDocument() throws -> MapLayoutDocument {
        if let mapLayout { return mapLayout }
        let loaded: MapLayoutDocument = try load(from: mapLayoutURL, fallback: .empty)
        mapLayout = loaded
        return loaded
    }

    private func loadOperationalContinuityDocument() throws -> OperationalContinuityDocument {
        if let operationalContinuity { return operationalContinuity }
        let loaded: OperationalContinuityDocument = try load(
            from: operationalContinuityURL,
            fallback: .empty
        )
        operationalContinuity = loaded
        return loaded
    }

    private func loadCoordinatorCheckpointDocument() throws -> CoordinatorCheckpointDocument {
        if let coordinatorCheckpoint { return coordinatorCheckpoint }
        let loaded: CoordinatorCheckpointDocument = try load(
            from: coordinatorCheckpointURL,
            fallback: .empty
        )
        coordinatorCheckpoint = loaded
        return loaded
    }

    private func load<Document: VersionedStoreDocument>(
        from url: URL,
        fallback: Document,
        validate: (Document) throws -> Void = { _ in }
    ) throws -> Document {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            return fallback
        }
        try secureFile(at: url)
        do {
            let document = try decode(Document.self, from: url)
            try validate(document)
            return document
        } catch let error as PersistentStoreCompatibilityError {
            throw error
        } catch {
            let backupURL = url.appendingPathExtension("previous")
            guard fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) else {
                throw error
            }
            try secureFile(at: backupURL)
            let restored: Document
            do {
                restored = try decode(Document.self, from: backupURL)
                try validate(restored)
            } catch let compatibilityError as PersistentStoreCompatibilityError {
                throw compatibilityError
            } catch {
                throw error
            }
            try requireWriteAccess()
            let corruptURL = url.appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970))")
            if (try? fileManager.copyItem(at: url, to: corruptURL)) != nil {
                try? secureFile(at: corruptURL)
            }
            try encoder.encode(restored).write(to: url, options: .atomic)
            try secureFile(at: url)
            return restored
        }
    }

    private func decode<Document: VersionedStoreDocument>(_ type: Document.Type, from url: URL) throws -> Document {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 128 * 1_024 * 1_024 else {
            throw PersistentStoreCapacityError.documentTooLarge(url.lastPathComponent)
        }
        let document = try decoder.decode(type, from: Data(contentsOf: url, options: [.mappedIfSafe]))
        guard document.version == Self.currentDocumentVersion else {
            throw PersistentStoreCompatibilityError.unsupportedVersion(
                file: url.lastPathComponent,
                found: document.version,
                supported: Self.currentDocumentVersion
            )
        }
        return document
    }

    private func retainedRuns(_ values: [RunRecord]) -> [RunRecord] {
        let active = values.filter { !$0.status.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
        let terminalLimit = max(0, maximumStoredRuns - active.count)
        let terminal = values.filter(\.status.isFinished)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(terminalLimit)
        return active + Array(terminal)
    }

    private func retainedOccurrences(_ values: [AutomationOccurrence]) -> [AutomationOccurrence] {
        let active = values.filter { !$0.status.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
        let terminalLimit = max(0, maximumStoredOccurrences - active.count)
        let terminal = values.filter(\.status.isFinished)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(terminalLimit)
        return active + Array(terminal)
    }

    private func persist<Document: Encodable & Sendable>(_ document: Document, to url: URL) throws {
        try requireWriteAccess()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directoryURL.path(percentEncoded: false)
        )
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            let backupURL = url.appendingPathExtension("previous")
            if fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
            try secureFile(at: backupURL)
        }
        try encoder.encode(document).write(to: url, options: .atomic)
        try secureFile(at: url)
    }

    private func secureFile(at url: URL) throws {
        // Reading a retired store must not rewrite file metadata either.
        guard !writesSuspended else { return }
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func requireWriteAccess() throws {
        guard !writesSuspended else { throw GADPersistenceOwnershipError.writesSuspended }
    }
}

extension PersistentStore: GADPersistenceOwnershipControlling {
    public func suspendWrites() async {
        // Automation authentication suspends between file writes and its
        // Keychain commit. Drain that entire transaction before fencing the
        // actor; synchronous document writes are already actor-serialized.
        await acquireAutomationMutation()
        writesSuspended = true
        releaseAutomationMutation()
    }

    public func resumeWrites() {
        writesSuspended = false
    }
}
