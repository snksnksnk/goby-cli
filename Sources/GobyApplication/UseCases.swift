import Foundation
import GobyDomain

public enum GobyApplicationError: LocalizedError, Equatable, Sendable {
    case emptyPrompt
    case emptyCatalog
    case noRoute
    case noAppropriateAgent(
        projectID: ProjectID,
        projectName: String,
        providerID: AgentProviderID,
        capabilities: Set<AgentCapability>
    )
    case unknownProject(ProjectID)
    case unknownProjectGroup(ProjectGroupID)
    case emptyProjectGroupName
    case projectGroupNeedsMultipleProjects
    case projectAlreadyGrouped(projectName: String, groupName: String)
    case emptyProjectName
    case emptyProjectPlatforms
    case invalidProjectDirectoryName
    case projectParentAuthorizationChanged
    case projectDirectoryAuthorizationChanged
    case invalidGitRepositorySource
    case gitCloneFailed(String)
    case projectDirectoryAlreadyExists(String)
    case projectRootAlreadyRegistered(String)
    case unknownProjectTemplate(ProjectTemplateID)
    case incompatibleProjectTemplateVersion(ProjectTemplateID, Int)
    case invalidProjectTemplateParameters(String)
    case projectTemplateRequiresBlankSource
    case projectTemplateRecoveryRequired([String])
    case duplicateProjectAgentName(String)
    case invalidProjectAgent(String)
    case invalidProjectProviderSelection
    case invalidProjectAgentProvider(String)
    case invalidProviderCollaborationSet
    case invalidProviderCredential(AgentProviderID)
    case misplacedProviderCredential(AgentProviderID, expected: ProviderCredentialKind)
    case invalidHandoffLink(String)
    case invalidDeliveryPipeline(String)
    case unknownHandoffLink(AgentHandoffLinkID)
    case unknownHandoff(HandoffID)
    case handoffNotDispatchable(HandoffID)
    case automaticHandoffsUnavailable
    case duplicateHandoff(HandoffID)
    case handoffSourceNotReady(AssignmentID)
    case handoffDepthExceeded(maximum: Int)
    case providerUnavailable(AgentProviderID)
    case providerRouteMismatch(expected: AgentProviderID, actual: AgentProviderID)
    case unknownProviderBinding(ProviderAgentBindingID)
    case missingProviderBinding(agentID: AgentID, providerID: AgentProviderID, projectID: ProjectID)
    case ambiguousProviderBinding(agentID: AgentID, providerID: AgentProviderID, projectID: ProjectID)
    case projectHasUnfinishedRun(String)
    case projectIsNotGitRepository(String)
    case invalidProjectGitBranchSwitch
    case unknownAgent(AgentID)
    case agentUnavailable(AgentID)
    case agentOutsideProject(AgentID, ProjectID)
    case agentTemplateRequiresProject
    case approvalRequired
    case incompleteApproval
    case incompleteAgentDefinitionReview
    case unknownSharedResource(SharedResourceID)
    case sharedResourceUnavailable(SharedResourceID)
    case sharedResourceAuthorizationChanged(SharedResourceID)
    case projectAuthorizationChanged(ProjectID)
    case invalidAutomation(String)
    case invalidRunModelChange(String)
    case unknownAutomation(AutomationID)
    case automationChanged(AutomationID)
    case automationHasUnfinishedOccurrence(AutomationID)
    case unknownAutomationOccurrence(AutomationOccurrenceID)
    case automationOccurrenceChanged(AutomationOccurrenceID)
    case automationOccurrenceNotReviewable(AutomationOccurrenceID)
    case invalidInstruction(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "Enter a request before preparing a plan."
        case .emptyCatalog:
            "Import at least one project before routing work."
        case .noRoute:
            "No registered project and agent combination matched this request."
        case let .noAppropriateAgent(_, projectName, providerID, capabilities):
            "\(projectName) has no enabled \(providerID.displayName) agent covering \(capabilities.map(\.displayName).sorted().joined(separator: ", ")). Create or configure a project agent with those capabilities, then review the request again."
        case let .unknownProject(id):
            "The plan references an unregistered project: \(id.rawValue)."
        case let .unknownProjectGroup(id):
            "The project group is no longer registered: \(id.rawValue)."
        case .emptyProjectGroupName:
            "Enter a name for this project group."
        case .projectGroupNeedsMultipleProjects:
            "Choose at least two different projects to link."
        case let .projectAlreadyGrouped(projectName, groupName):
            "\(projectName) already belongs to \(groupName). Remove it there before linking it to another group."
        case .emptyProjectName:
            "Enter a name for the new project."
        case .emptyProjectPlatforms:
            "Choose at least one project platform."
        case .invalidProjectDirectoryName:
            "Enter a single folder name without slashes, colons, or path traversal."
        case .projectParentAuthorizationChanged:
            "The selected parent folder changed after review. Choose and authorize it again before creating the project."
        case .projectDirectoryAuthorizationChanged:
            "The newly created project folder changed before Goby could register it. Nothing was authorized; create the project again."
        case .invalidGitRepositorySource:
            "Enter a Git repository URL or an absolute local repository path."
        case let .gitCloneFailed(message):
            "Git could not clone the repository. \(message)"
        case let .projectDirectoryAlreadyExists(name):
            "A file or folder named \(name) already exists at that location."
        case let .projectRootAlreadyRegistered(name):
            "\(name) is already registered as a Goby project."
        case let .unknownProjectTemplate(id):
            "The selected project template is not installed: \(id.rawValue)."
        case let .incompatibleProjectTemplateVersion(id, version):
            "Version \(version) of the \(id.rawValue) project template is not available in this Goby build. Review the template again before creating the project."
        case let .invalidProjectTemplateParameters(reason):
            "The project template options are invalid: \(reason)"
        case .projectTemplateRequiresBlankSource:
            "A project template can create a new folder, but it cannot be applied over a Git clone. Choose either the template or the repository."
        case let .projectTemplateRecoveryRequired(paths):
            "Goby preserved template content that changed during recovery: \(paths.joined(separator: ", ")). Review the new folder before trying again."
        case let .duplicateProjectAgentName(name):
            "The new project contains more than one agent named \(name). Use a unique name for each agent."
        case let .invalidProjectAgent(name):
            "Complete the name, responsibility, and at least one capability for \(name)."
        case .invalidProjectProviderSelection:
            "Choose only supported provider planes for this project. You may also choose none and configure providers later."
        case let .invalidProjectAgentProvider(name):
            "Choose provider bindings for \(name) only from the providers linked to this project."
        case .invalidProviderCollaborationSet:
            "Choose at least two valid provider agent bindings from this project to collaborate."
        case let .invalidProviderCredential(providerID):
            "Enter a valid \(providerID.displayName) credential without spaces or line breaks."
        case let .misplacedProviderCredential(_, expected):
            switch expected {
            case .subscriptionToken:
                "This is not a Claude subscription token. Run `claude setup-token` and paste the token that starts with sk-ant-oat, or save an API key in the API key field."
            case .apiKey:
                "This is a Claude subscription token. Save it in the Claude subscription field so Goby bills your Pro/Max plan first."
            }
        case let .invalidHandoffLink(reason):
            "This handoff link is invalid: \(reason)"
        case let .invalidDeliveryPipeline(reason):
            "This plan's stages are invalid: \(reason) Prepare the plan again."
        case let .unknownHandoffLink(id):
            "The handoff link is no longer registered: \(id.rawValue)."
        case let .unknownHandoff(id):
            "The handoff is no longer registered: \(id.rawValue)."
        case let .handoffNotDispatchable(id):
            "Handoff \(id.rawValue) is not ready for manual dispatch."
        case .automaticHandoffsUnavailable:
            "Automatic handoffs are not enabled yet. Save this link as Suggest only and dispatch it after review."
        case let .duplicateHandoff(id):
            "This handoff was already delivered as \(id.rawValue); Goby did not create a duplicate destination task."
        case let .handoffSourceNotReady(id):
            "Assignment \(id.rawValue) has not reached a safe handoff checkpoint."
        case let .handoffDepthExceeded(maximum):
            "This continuation exceeds the handoff link's maximum depth of \(maximum)."
        case let .providerUnavailable(providerID):
            "\(providerID.displayName) is not connected yet. Your request draft has been preserved."
        case let .providerRouteMismatch(expected, actual):
            "The \(expected.displayName) plan contains a \(actual.displayName) target. Choose agents from one provider plane per route."
        case let .unknownProviderBinding(id):
            "The provider binding is no longer registered: \(id.rawValue)."
        case let .missingProviderBinding(agentID, providerID, projectID):
            "Agent \(agentID.rawValue) has no configured \(providerID.displayName) binding for project \(projectID.rawValue)."
        case let .ambiguousProviderBinding(agentID, providerID, projectID):
            "Agent \(agentID.rawValue) has more than one eligible \(providerID.displayName) binding for project \(projectID.rawValue). Choose one exact provider binding before reviewing the run."
        case let .projectHasUnfinishedRun(name):
            "Finish or cancel the unfinished run for \(name) before removing it from Goby."
        case let .projectIsNotGitRepository(name):
            "\(name) is not a Git repository, so it has no branches to switch."
        case .invalidProjectGitBranchSwitch:
            "Choose a different existing local branch and approve that exact switch."
        case let .unknownAgent(id):
            "The plan references an unregistered agent: \(id.rawValue)."
        case let .agentUnavailable(id):
            "The selected agent is disabled: \(id.rawValue)."
        case let .agentOutsideProject(agentID, projectID):
            "The selected agent is not authorized for project \(projectID.rawValue): \(agentID.rawValue)."
        case .agentTemplateRequiresProject:
            "Templated tool agents must be added to one project. Choose a project and try again."
        case .approvalRequired:
            "This plan requires approval before it can run."
        case .incompleteApproval:
            "The approval does not cover every disclosed operation."
        case .incompleteAgentDefinitionReview:
            "The complete executable agent definition was not reviewed. Import an instruction-only copy or review the complete local file before activating it."
        case let .unknownSharedResource(id):
            "The shared resource is no longer registered: \(id.rawValue)."
        case let .sharedResourceUnavailable(id):
            "The shared resource is no longer enabled: \(id.rawValue). Review the current scope before running."
        case let .sharedResourceAuthorizationChanged(id):
            "The shared resource changed since it was added: \(id.rawValue). Add it again before running."
        case let .projectAuthorizationChanged(id):
            "The project folder changed or needs renewed access: \(id.rawValue). Choose its folder in Projects, then select Refresh Selected before running."
        case let .invalidRunModelChange(reason): reason
        case let .invalidAutomation(reason):
            "This automation is invalid: \(reason)"
        case let .unknownAutomation(id):
            "The automation is no longer available: \(id.rawValue)."
        case .automationChanged:
            "This automation changed while Goby was saving it. Review the refreshed schedule before trying again."
        case .automationHasUnfinishedOccurrence:
            "Wait for the current occurrence to finish or cancel it before deleting this automation."
        case let .unknownAutomationOccurrence(id):
            "The automation occurrence is no longer available: \(id.rawValue)."
        case .automationOccurrenceChanged:
            "This automation occurrence changed while Goby was saving it. Goby kept the newer state."
        case let .automationOccurrenceNotReviewable(id):
            "Automation occurrence \(id.rawValue) has no action waiting for review."
        case let .invalidInstruction(reason):
            "This instruction pack is invalid: \(reason)."
        }
    }
}

public enum AgentRoutingMatcher {
    public static func inferredCapabilities(from prompt: String) -> Set<AgentCapability> {
        let normalized = prompt.lowercased()
        var result = Set<AgentCapability>()
        let mapping: [(AgentCapability, [String])] = [
            (.web, ["web", "website", "frontend", "browser", "google"]),
            (.macOS, ["macos", "mac os", "appkit", "mac app"]),
            (.iOS, ["ios", "iphone", "ipad", "uikit"]),
            (.android, ["android", "kotlin", "gradle"]),
            (.backend, ["backend", "server", "database", "api"]),
            (.research, ["research", "source", "compare", "investigate"]),
            (.testing, ["test", "verify", "regression", "launch", "launches", "error", "errors"]),
            (.review, ["review", "audit"]),
            (.security, ["security", "vulnerability", "threat"]),
            (.documentation, ["documentation", "docs", "readme"]),
            (.release, ["release", "deploy", "ship"]),
            (.design, ["icon", "logo", "branding", "visual design", "app icon"]),
        ]
        for (capability, terms) in mapping where terms.contains(where: normalized.contains) {
            result.insert(capability)
        }
        return result.isEmpty ? [.routing] : result
    }

    public static func eligibleAgents(
        for projectID: ProjectID,
        providerID: AgentProviderID,
        in lab: LabSnapshot,
        includingTemporary selectedTemporaryIDs: Set<AgentID> = []
    ) -> [AgentProfile] {
        lab.agents.filter { agent in
            guard !agent.isTemporary || selectedTemporaryIDs.contains(agent.id) else { return false }
            return isEligible(
                AgentRouteTarget(
                    providerID: providerID,
                    agentID: agent.id,
                    projectID: projectID
                ),
                in: lab
            )
        }
    }

    /// Returns whether one exact provider/project/agent recipient can be used
    /// for direct assignment. Presentation and operation surfaces share this
    /// predicate so a node is never offered as routable and then rejected by
    /// the request store for the same catalog snapshot.
    public static func isEligible(
        _ target: AgentRouteTarget,
        in lab: LabSnapshot
    ) -> Bool {
        guard lab.projects.contains(where: { $0.id == target.projectID }),
              let agent = lab.agents.first(where: { $0.id == target.agentID }),
              agent.isEnabled,
              agentCanWork(agent, in: target.projectID) else { return false }

        return lab.providerBindings.contains { binding in
            binding.providerID == target.providerID
                && binding.agentID == target.agentID
                && (binding.projectID == nil || binding.projectID == target.projectID)
                && binding.state == .configured
        }
    }

    /// Capabilities that make an agent a platform specialist.
    public static let platformCapabilities: Set<AgentCapability> = [.web, .macOS, .iOS, .android, .backend]

    public static func platformCapability(for platform: ProjectPlatform) -> AgentCapability? {
        switch platform {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .backend: .backend
        case .research, .general: nil
        }
    }

    /// Agents that fit a request in this project. When the request names no
    /// platform, a platform specialist fits only a single-platform project of
    /// that platform, and a general request suits no functional specialist; otherwise a growth plan or UI fix could go to, say, the
    /// Android agent just because it sorts first. Returns an empty list when
    /// only unrelated specialists exist, so a temporary agent can be offered.
    public static func suitableAgents(
        _ agents: [AgentProfile],
        for project: LabProject,
        required: Set<AgentCapability>
    ) -> [AgentProfile] {
        guard required.isDisjoint(with: platformCapabilities) else { return agents }
        // A general request (only the neutral `routing` capability) suits no
        // functional specialist either: testing, docs or release agents are
        // right only when the request asks for that function.
        let isGeneralRequest = required.isSubset(of: [.routing])
        let projectPlatforms = Set(project.platforms.compactMap(platformCapability(for:)))
        let suited = agents.filter { agent in
            let specialties = agent.capabilities.intersection(platformCapabilities)
            let functions = agent.capabilities.subtracting(platformCapabilities).subtracting([.routing])
            if isGeneralRequest, !functions.isEmpty { return false }
            return specialties.isEmpty
                || (projectPlatforms.count == 1 && specialties.isSubset(of: projectPlatforms))
        }
        // With a single agent there is no arbitrary choice to avoid: the
        // project's only agent is the one its owner set up for its work.
        return suited.isEmpty && agents.count == 1 ? agents : suited
    }

    public static func missingCapabilities(
        required: Set<AgentCapability>,
        among agents: [AgentProfile]
    ) -> Set<AgentCapability> {
        // Routing is the neutral capability inferred when the request does not
        // name a specialty. Any authorized enabled agent is an appropriate
        // candidate in that case; exact capability coverage applies once the
        // user asks for a recognizable specialty.
        if required == [.routing], !agents.isEmpty { return [] }
        let covered = agents.reduce(into: Set<AgentCapability>()) { result, agent in
            result.formUnion(agent.capabilities)
        }
        return required.subtracting(covered)
    }

    public static func agentCanWork(_ agent: AgentProfile, in projectID: ProjectID) -> Bool {
        switch agent.scope {
        case .global, .union: true
        case let .project(scopedProjectID): scopedProjectID == projectID
        }
    }
}

/// Resolves the provider-native identity once and fails closed when legacy
/// data could refer to more than one configured binding.
public enum ProviderBindingResolver {
    public static func eligibleBindings(
        agentID: AgentID,
        providerID: AgentProviderID,
        projectID: ProjectID,
        in bindings: [ProviderAgentBinding]
    ) -> [ProviderAgentBinding] {
        bindings.filter {
            $0.providerID == providerID
                && $0.agentID == agentID
                && ($0.projectID == nil || $0.projectID == projectID)
                && $0.state == .configured
        }
    }

    public static func resolve(
        agentID: AgentID,
        providerID: AgentProviderID,
        projectID: ProjectID,
        bindingID: ProviderAgentBindingID? = nil,
        in bindings: [ProviderAgentBinding]
    ) throws -> ProviderAgentBinding {
        let eligible = eligibleBindings(
            agentID: agentID,
            providerID: providerID,
            projectID: projectID,
            in: bindings
        )
        if let bindingID {
            guard let exact = eligible.first(where: { $0.id == bindingID }) else {
                throw GobyApplicationError.unknownProviderBinding(bindingID)
            }
            return exact
        }
        guard let only = eligible.first else {
            throw GobyApplicationError.missingProviderBinding(
                agentID: agentID,
                providerID: providerID,
                projectID: projectID
            )
        }
        guard eligible.count == 1 else {
            throw GobyApplicationError.ambiguousProviderBinding(
                agentID: agentID,
                providerID: providerID,
                projectID: projectID
            )
        }
        return only
    }

    public static func routeBindings(
        agentIDs: [AgentID],
        providerID: AgentProviderID,
        projectID: ProjectID,
        in bindings: [ProviderAgentBinding]
    ) throws -> [ProviderRouteBinding] {
        try agentIDs.map { agentID in
            let binding = try resolve(
                agentID: agentID,
                providerID: providerID,
                projectID: projectID,
                in: bindings
            )
            return ProviderRouteBinding(agentID: agentID, bindingID: binding.id)
        }
    }
}

public struct LoadDashboardUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let runs: any RunRepository

    public init(catalog: any LabCatalogRepository, runs: any RunRepository) {
        self.catalog = catalog
        self.runs = runs
    }

    public func callAsFunction() async throws -> (LabSnapshot, [RunRecord]) {
        async let lab = catalog.snapshot()
        async let records = runs.allRuns()
        return try await (lab, records)
    }
}

public struct DiscoverProjectsUseCase: Sendable {
    private let discovery: any ProjectDiscovering

    public init(discovery: any ProjectDiscovering) {
        self.discovery = discovery
    }

    public func callAsFunction(selectedRoots: [URL]) async throws -> [ProjectCandidate] {
        try await discovery.discover(selectedRoots: selectedRoots)
    }
}

public struct DiscoverCurrentCodexProjectsUseCase: Sendable {
    private let codex: any CodexServing
    private let discovery: any ProjectDiscovering

    public init(codex: any CodexServing, discovery: any ProjectDiscovering) {
        self.codex = codex
        self.discovery = discovery
    }

    public func callAsFunction() async throws -> [ProjectCandidate] {
        _ = try await codex.connect()
        let snapshot = try await codex.recentProjectRoots()
        return try await discovery.discover(selectedRoots: snapshot.roots)
    }
}

public struct DiscoverCodexCatalogSyncUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let codex: any CodexServing
    private let projectDiscovery: any ProjectDiscovering
    private let agentDiscovery: any AgentDiscovering

    public init(
        catalog: any LabCatalogRepository,
        codex: any CodexServing,
        projectDiscovery: any ProjectDiscovering,
        agentDiscovery: any AgentDiscovering
    ) {
        self.catalog = catalog
        self.codex = codex
        self.projectDiscovery = projectDiscovery
        self.agentDiscovery = agentDiscovery
    }

    public func callAsFunction() async throws -> CodexCatalogSyncPlan {
        _ = try await codex.connect()
        async let existingSnapshot = catalog.snapshot()
        async let currentRoots = codex.recentProjectRoots()
        let (existing, rootsSnapshot) = try await (existingSnapshot, currentRoots)
        let fileDiscovered = try await projectDiscovery.discover(selectedRoots: rootsSnapshot.roots)
        let existingProjects = Dictionary(uniqueKeysWithValues: existing.projects.map { ($0.id, $0) })
        let inspectedPaths = Set(fileDiscovered.map {
            $0.project.rootURL.standardizedFileURL.path(percentEncoded: false)
        })
        let metadataOnly = rootsSnapshot.savedProjects.compactMap { saved -> ProjectCandidate? in
            let root = saved.rootURL.standardizedFileURL
            guard !inspectedPaths.contains(root.path(percentEncoded: false)) else { return nil }
            let projectID = ProjectID.derived(fromProjectRoot: root)
            let reviewedProject = existingProjects[projectID]
            return ProjectCandidate(
                project: reviewedProject ?? LabProject(
                    id: projectID,
                    name: saved.name,
                    rootURL: root,
                    platforms: [.general],
                    isGitRepository: false
                ),
                evidence: [
                    "Saved in Codex",
                    reviewedProject == nil
                        ? "Folder access required to inspect project type, Git state, tests, and agent definitions"
                        : "Using the last reviewed project structure because this Codex scan could not inspect the folder",
                ],
                inspectionLevel: .metadataOnly
            )
        }
        var discoveredByID = Dictionary(uniqueKeysWithValues: fileDiscovered.map { ($0.id, $0) })
        for candidate in metadataOnly where discoveredByID[candidate.id] == nil {
            discoveredByID[candidate.id] = candidate
        }
        let discovered = discoveredByID.values.sorted {
            $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending
        }
        let metadataOnlyIDs = Set(metadataOnly.map(\.id))

        var projectsByID = Dictionary(uniqueKeysWithValues: existing.projects.map { ($0.id, $0) })
        for candidate in discovered {
            projectsByID[candidate.id] = candidate.project
        }
        let projectsToInspect = projectsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let discoveredAgents = try await agentDiscovery.discover(
            projects: projectsToInspect.filter { !metadataOnlyIDs.contains($0.id) }
        )
        let inferredAgents = Self.inferredAgentCandidates(
            for: projectsToInspect,
            existingAgents: existing.agents + discoveredAgents.candidates.map(\.profile)
        )
        let importableAgents = discoveredAgents.candidates + inferredAgents

        let changedProjects = discovered.filter { candidate in
            guard let current = existingProjects[candidate.id] else { return true }
            return !Self.isEquivalentForSync(current, candidate.project)
        }
        let existingAgents = Dictionary(uniqueKeysWithValues: existing.agents.map { ($0.id, $0) })
        let changedAgents = importableAgents.filter { candidate in
            guard let current = existingAgents[candidate.id] else { return true }
            return !Self.isEquivalentForSync(current, candidate.profile)
        }
        let inspectedAgentIDs = Set(existing.agents.map(\.id))
            .union(importableAgents.map(\.id))

        return CodexCatalogSyncPlan(
            projects: changedProjects,
            agents: AgentImportPlan(
                candidates: changedAgents,
                suggestions: inferredAgents.isEmpty
                    ? discoveredAgents.suggestions
                    : discoveredAgents.suggestions.filter { $0.kind != .missingCoverage }
            ),
            tasks: rootsSnapshot.tasks,
            scannedProjectCount: projectsToInspect.count,
            scannedAgentCount: inspectedAgentIDs.count,
            limitedProjectAccessCount: metadataOnly.count,
            warnings: rootsSnapshot.warnings
        )
    }

    private static func isEquivalentForSync(_ lhs: LabProject, _ rhs: LabProject) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.rootURL.standardizedFileURL == rhs.rootURL.standardizedFileURL
            && lhs.platforms == rhs.platforms
            && lhs.frameworks == rhs.frameworks
            && lhs.testCommands == rhs.testCommands
            && lhs.instructionFiles == rhs.instructionFiles
            && lhs.isGitRepository == rhs.isGitRepository
    }

    private static func isEquivalentForSync(_ lhs: AgentProfile, _ rhs: AgentProfile) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.summary == rhs.summary
            && lhs.instructions == rhs.instructions
            && lhs.capabilities == rhs.capabilities
            && lhs.scope == rhs.scope
            && lhs.sourceURL?.standardizedFileURL == rhs.sourceURL?.standardizedFileURL
            && lhs.toolPreset == rhs.toolPreset
            && lhs.reviewedDefinitionDigest == rhs.reviewedDefinitionDigest
            && lhs.definitionReviewProvenance == rhs.definitionReviewProvenance
            && lhs.codexRegistrationKey == rhs.codexRegistrationKey
    }

    private static func inferredAgentCandidates(
        for projects: [LabProject],
        existingAgents: [AgentProfile]
    ) -> [AgentImportCandidate] {
        let coveredCapabilities = existingAgents.reduce(into: [ProjectID: Set<AgentCapability>]()) { result, agent in
            guard case let .project(projectID) = agent.scope else { return }
            result[projectID, default: []].formUnion(agent.capabilities)
        }

        return projects.flatMap { project in
            let required = Set(project.platforms.map(capability(for:)))
            let missing = required.subtracting(coveredCapabilities[project.id, default: []])
            return missing.sorted { $0.rawValue < $1.rawValue }.map { capability in
                let role = capability == .routing ? "Project" : capability.displayName
                let profile = AgentProfile(
                    id: AgentID(rawValue: "inferred-\(project.id.rawValue)-\(capability.rawValue)"),
                    name: "\(role) Agent",
                    summary: "Owns \(capability.displayName.lowercased()) work for \(project.name)",
                    capabilities: [capability],
                    scope: .project(project.id)
                )
                return AgentImportCandidate(
                    profile: profile,
                    configurationPreview: "Goby-managed \(capability.displayName) role inferred from \(project.platforms.map(\.displayName).sorted().joined(separator: ", ")) project markers.",
                    evidence: ["Detected \(capability.displayName) project capability"]
                )
            }
        }
    }

    private static func capability(for platform: ProjectPlatform) -> AgentCapability {
        switch platform {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .backend: .backend
        case .research: .research
        case .general: .routing
        }
    }
}

public struct DiscoverCodexActivityUseCase: Sendable {
    private let codex: any CodexServing

    public init(codex: any CodexServing) {
        self.codex = codex
    }

    public func callAsFunction() async throws -> [CodexTaskActivity] {
        _ = try await codex.connect()
        return try await codex.recentProjectRoots().tasks
    }
}

public struct SyncCodexCatalogUseCase: Sendable {
    private let catalog: any LabCatalogRepository

    public init(catalog: any LabCatalogRepository) {
        self.catalog = catalog
    }

    public func callAsFunction(
        projects: [ProjectCandidate],
        agents: [AgentImportCandidate]
    ) async throws {
        let existing = try await catalog.snapshot()
        let allowedProjectIDs = Set(existing.projects.map(\.id)).union(projects.map(\.id))
        let validAgents = agents.filter { candidate in
            switch candidate.profile.scope {
            case .global, .union:
                true
            case let .project(projectID):
                allowedProjectIDs.contains(projectID)
            }
        }
        let reviewedAgents = try validAgents.map { candidate in
            let profile = candidate.profile
            let provenance: AgentDefinitionReviewProvenance
            if profile.sourceURL != nil {
                guard let digest = profile.reviewedDefinitionDigest,
                      digest == DefinitionReviewDigest.sha256(candidate.configurationPreview) else {
                    throw GobyApplicationError.incompleteAgentDefinitionReview
                }
                provenance = .fullContent
            } else {
                provenance = .semanticOnly
            }
            return AgentProfile(
                id: profile.id,
                name: profile.name,
                summary: profile.summary,
                instructions: profile.instructions,
                capabilities: profile.capabilities,
                scope: profile.scope,
                sourceURL: profile.sourceURL,
                toolPreset: provenance == .semanticOnly ? nil : profile.toolPreset,
                reviewedDefinitionDigest: provenance == .semanticOnly ? nil : profile.reviewedDefinitionDigest,
                definitionReviewProvenance: provenance,
                codexRegistrationKey: provenance == .semanticOnly ? nil : profile.codexRegistrationKey,
                isEnabled: profile.isEnabled
            )
        }
        try await catalog.register(
            projects: projects.map(\.project),
            agents: reviewedAgents
        )
    }
}

public struct RegisterProjectsUseCase: Sendable {
    private let catalog: any LabCatalogRepository

    public init(catalog: any LabCatalogRepository) {
        self.catalog = catalog
    }

    public func callAsFunction(candidates: [ProjectCandidate]) async throws {
        try await catalog.register(
            projects: candidates.map(\.project),
            agents: []
        )
    }
}

public struct NewProjectAgentDraft: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let instructions: String?
    public let capabilities: Set<AgentCapability>
    public let providerIDs: Set<AgentProviderID>
    public let providerInstructions: [AgentProviderID: String]

    public init(
        name: String,
        summary: String,
        instructions: String? = nil,
        capabilities: Set<AgentCapability>,
        providerIDs: Set<AgentProviderID> = [.codex],
        providerInstructions: [AgentProviderID: String] = [:]
    ) {
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.providerIDs = providerIDs
        self.providerInstructions = providerInstructions
    }
}

public struct NewProjectLinkDraft: Equatable, Sendable {
    public let projectID: ProjectID
    public let groupName: String?
    public let projectRole: ProjectGroupRole
    public let linkedProjectRole: ProjectGroupRole

    public init(
        projectID: ProjectID,
        groupName: String? = nil,
        projectRole: ProjectGroupRole,
        linkedProjectRole: ProjectGroupRole = .service
    ) {
        self.projectID = projectID
        self.groupName = groupName
        self.projectRole = projectRole
        self.linkedProjectRole = linkedProjectRole
    }
}

/// A directional, suggest-only continuation path between two provider
/// realizations of roles created with the project.
public struct NewProjectHandoffDraft: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceAgentIndex: Int
    public let sourceProviderID: AgentProviderID
    public let destinationAgentIndex: Int
    public let destinationProviderID: AgentProviderID
    public let purpose: String
    public let conditions: String
    public let acceptedArtifacts: Set<HandoffArtifactKind>
    public let maximumDepth: Int
    public let triggers: Set<HandoffTrigger>

    public init(
        id: UUID = UUID(),
        sourceAgentIndex: Int,
        sourceProviderID: AgentProviderID,
        destinationAgentIndex: Int,
        destinationProviderID: AgentProviderID,
        purpose: String,
        conditions: String,
        acceptedArtifacts: Set<HandoffArtifactKind> = [.summary, .changedFileList, .verificationEvidence],
        maximumDepth: Int = 1,
        triggers: Set<HandoffTrigger> = [.success, .blockage, .checkpoint]
    ) {
        self.id = id
        self.sourceAgentIndex = sourceAgentIndex
        self.sourceProviderID = sourceProviderID
        self.destinationAgentIndex = destinationAgentIndex
        self.destinationProviderID = destinationProviderID
        self.purpose = purpose
        self.conditions = conditions
        self.acceptedArtifacts = acceptedArtifacts
        self.maximumDepth = maximumDepth
        self.triggers = triggers
    }
}

public enum NewProjectSource: Equatable, Sendable {
    case blank
    case gitClone(repository: String)

    public var isGitRepository: Bool {
        if case .gitClone = self { return true }
        return false
    }
}

public struct NewProjectDraft: Equatable, Sendable {
    public let name: String
    public let directoryName: String
    public let parentURL: URL
    public let parentFileSystemIdentity: GADFileSystemIdentity?
    public let source: NewProjectSource
    public let platforms: Set<ProjectPlatform>
    public let providerIDs: Set<AgentProviderID>
    public let agents: [NewProjectAgentDraft]
    public let link: NewProjectLinkDraft?
    public let collaborateAcrossProviders: Bool
    public let handoffLinks: [NewProjectHandoffDraft]
    public let template: ProjectTemplateSelection?

    public init(
        name: String,
        directoryName: String,
        parentURL: URL,
        parentFileSystemIdentity: GADFileSystemIdentity? = nil,
        source: NewProjectSource = .blank,
        platforms: Set<ProjectPlatform>,
        providerIDs: Set<AgentProviderID> = [.codex],
        agents: [NewProjectAgentDraft] = [],
        link: NewProjectLinkDraft? = nil,
        collaborateAcrossProviders: Bool = false,
        handoffLinks: [NewProjectHandoffDraft] = [],
        template: ProjectTemplateSelection? = nil
    ) {
        self.name = name
        self.directoryName = directoryName
        self.parentURL = parentURL
        self.parentFileSystemIdentity = parentFileSystemIdentity ?? GADFileSystemIdentity.capture(parentURL)
        self.source = source
        self.platforms = platforms
        self.providerIDs = providerIDs
        self.agents = agents
        self.link = link
        self.collaborateAcrossProviders = collaborateAcrossProviders
        self.handoffLinks = handoffLinks
        self.template = template
    }
}

public struct CreatedProjectBundle: Sendable {
    public let project: LabProject
    public let agents: [AgentProfile]
    public let projectGroup: ProjectGroup?
    public let providerConfiguration: ProjectProviderConfiguration
    public let providerBindings: [ProviderAgentBinding]
    public let providerCollaborationSet: ProviderCollaborationSet?
    public let handoffLinks: [AgentHandoffLink]

    public init(
        project: LabProject,
        agents: [AgentProfile],
        projectGroup: ProjectGroup?,
        providerConfiguration: ProjectProviderConfiguration,
        providerBindings: [ProviderAgentBinding],
        providerCollaborationSet: ProviderCollaborationSet?,
        handoffLinks: [AgentHandoffLink] = []
    ) {
        self.project = project
        self.agents = agents
        self.projectGroup = projectGroup
        self.providerConfiguration = providerConfiguration
        self.providerBindings = providerBindings
        self.providerCollaborationSet = providerCollaborationSet
        self.handoffLinks = handoffLinks
    }
}

public struct CreateProjectUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let projectCatalog: any ProjectCatalogManaging
    private let groups: any ProjectGroupCatalogManaging
    private let agentCatalog: any AgentCatalogManaging
    private let providerConfigurations: any ProviderConfigurationCatalogManaging
    private let handoffs: (any HandoffCatalogManaging)?
    private let definitions: any CodexAgentDefinitionManaging
    private let directories: any ProjectDirectoryCreating
    private let templates: (any ProjectTemplateInstantiating)?
    private let configuredProviderIDs: Set<AgentProviderID>

    public init(
        catalog: any LabCatalogRepository,
        projectCatalog: any ProjectCatalogManaging,
        groups: any ProjectGroupCatalogManaging,
        agentCatalog: any AgentCatalogManaging,
        providerConfigurations: any ProviderConfigurationCatalogManaging,
        handoffs: (any HandoffCatalogManaging)? = nil,
        definitions: any CodexAgentDefinitionManaging,
        directories: any ProjectDirectoryCreating,
        templates: (any ProjectTemplateInstantiating)? = nil,
        configuredProviderIDs: Set<AgentProviderID> = [.codex]
    ) {
        self.catalog = catalog
        self.projectCatalog = projectCatalog
        self.groups = groups
        self.agentCatalog = agentCatalog
        self.providerConfigurations = providerConfigurations
        self.handoffs = handoffs
        self.definitions = definitions
        self.directories = directories
        self.templates = templates
        self.configuredProviderIDs = configuredProviderIDs
    }

    public func callAsFunction(_ draft: NewProjectDraft) async throws -> CreatedProjectBundle {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GobyApplicationError.emptyProjectName }
        guard !draft.platforms.isEmpty else { throw GobyApplicationError.emptyProjectPlatforms }
        try validateProviders(draft.providerIDs)
        try validateAgents(draft.agents, projectProviderIDs: draft.providerIDs)
        try validateHandoffDrafts(draft.handoffLinks, agents: draft.agents)
        if draft.template != nil, draft.source != .blank {
            throw GobyApplicationError.projectTemplateRequiresBlankSource
        }
        guard let parentIdentity = draft.parentFileSystemIdentity,
              parentIdentity.kind == .directory,
              parentIdentity.matchesCurrentObject(at: draft.parentURL) else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }

        let original = try await catalog.snapshot()
        let linkedProject = try linkedProject(for: draft.link, in: original)
        let placement: ProjectDirectoryPlacement
        var templateReceipt: ProjectTemplateInstantiationReceipt?
        switch draft.source {
        case .blank:
            if let selection = draft.template {
                guard let templates else {
                    throw GobyApplicationError.unknownProjectTemplate(selection.id)
                }
                let receipt = try await templates.instantiate(
                    selection: selection,
                    projectName: name,
                    directoryName: draft.directoryName,
                    in: draft.parentURL,
                    expectedParentIdentity: parentIdentity
                )
                templateReceipt = receipt
                placement = receipt.placement
            } else {
                placement = try await directories.createProjectDirectory(
                    named: draft.directoryName,
                    in: draft.parentURL,
                    expectedParentIdentity: parentIdentity
                )
            }
        case let .gitClone(repository):
            let source = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw GobyApplicationError.invalidGitRepositorySource }
            placement = try await directories.cloneProjectRepository(
                from: source,
                named: draft.directoryName,
                in: draft.parentURL,
                expectedParentIdentity: parentIdentity
            )
        }
        guard placement.matchesCurrentObject() else {
            try? await directories.removeProjectDirectoryIfEmpty(placement)
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        let rootURL = placement.rootURL
        let templatePlan = templateReceipt?.plan
        let project = LabProject(
            id: .derived(fromProjectRoot: rootURL),
            name: name,
            rootURL: rootURL,
            platforms: draft.platforms,
            frameworks: templatePlan?.frameworks ?? [],
            testCommands: templatePlan?.testCommands ?? [],
            instructionFiles: templatePlan?.instructionRelativePaths.map {
                rootURL.appending(path: $0)
            } ?? [],
            isGitRepository: draft.source.isGitRepository,
            fileSystemIdentity: placement.fileSystemIdentity,
            template: templatePlan.map {
                ProjectTemplateReference(id: $0.descriptor.id, version: $0.descriptor.version)
            }
        )

        if original.projects.contains(where: {
            $0.rootURL.standardizedFileURL == project.rootURL.standardizedFileURL
        }) {
            if let templateReceipt, let templates {
                _ = try? await templates.rollback(templateReceipt)
            }
            try? await directories.removeProjectDirectoryIfEmpty(placement)
            throw GobyApplicationError.projectRootAlreadyRegistered(name)
        }

        var registeredProject = false
        var createdAgents: [AgentProfile] = []
        var codexDefinitionAgentIDs = Set<AgentID>()
        do {
            guard placement.matchesCurrentObject() else {
                throw GobyApplicationError.projectDirectoryAuthorizationChanged
            }
            try await catalog.register(projects: [project], agents: [])
            registeredProject = true

            let providerConfiguration = ProjectProviderConfiguration(
                projectID: project.id,
                providerIDs: draft.providerIDs
            )
            try await providerConfigurations.saveProjectProviderConfiguration(providerConfiguration)

            for agentDraft in draft.agents {
                guard placement.matchesCurrentObject() else {
                    throw GobyApplicationError.projectDirectoryAuthorizationChanged
                }
                let agent = try await createAgent(agentDraft, for: project)
                createdAgents.append(agent)
                if agentDraft.providerIDs.contains(.codex) {
                    codexDefinitionAgentIDs.insert(agent.id)
                }
            }

            let bindings = try await configureProviderBindings(
                for: Array(zip(draft.agents, createdAgents)),
                project: project
            )
            let collaborationSet = try await saveCollaborationSet(
                enabled: draft.collaborateAcrossProviders,
                project: project,
                bindings: bindings
            )
            let handoffLinks = try await saveHandoffLinks(
                draft.handoffLinks,
                agentPairs: Array(zip(draft.agents, createdAgents)),
                project: project,
                bindings: bindings
            )

            let group = try await saveLink(
                draft.link,
                linkedProject: linkedProject,
                newProject: project,
                original: original
            )
            guard placement.matchesCurrentObject() else {
                throw GobyApplicationError.projectDirectoryAuthorizationChanged
            }
            return CreatedProjectBundle(
                project: project,
                agents: createdAgents,
                projectGroup: group,
                providerConfiguration: providerConfiguration,
                providerBindings: bindings,
                providerCollaborationSet: collaborationSet,
                handoffLinks: handoffLinks
            )
        } catch {
            for agent in createdAgents.reversed() where codexDefinitionAgentIDs.contains(agent.id) {
                try? await definitions.undoCreatedDefinition(
                    agent,
                    expectedProjectIdentity: placement.fileSystemIdentity
                )
            }
            if registeredProject {
                try? await projectCatalog.removeProject(id: project.id)
            }
            var preservedTemplatePaths: [String] = []
            if let templateReceipt, let templates {
                do {
                    if case let .preservedChanges(relativePaths) = try await templates.rollback(templateReceipt) {
                        preservedTemplatePaths = relativePaths
                    }
                } catch {
                    preservedTemplatePaths = templateReceipt.plan.artifacts.map(\.relativePath)
                }
            }
            try? await directories.removeProjectDirectoryIfEmpty(placement)
            if !preservedTemplatePaths.isEmpty {
                throw GobyApplicationError.projectTemplateRecoveryRequired(preservedTemplatePaths)
            }
            throw error
        }
    }

    private func validateProviders(_ providerIDs: Set<AgentProviderID>) throws {
        guard providerIDs.isSubset(of: Set(AgentProviderID.builtIn)) else {
            throw GobyApplicationError.invalidProjectProviderSelection
        }
    }

    private func validateAgents(
        _ agents: [NewProjectAgentDraft],
        projectProviderIDs: Set<AgentProviderID>
    ) throws {
        var names = Set<String>()
        for agent in agents {
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = agent.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !summary.isEmpty, !agent.capabilities.isEmpty else {
                throw GobyApplicationError.invalidProjectAgent(name.isEmpty ? "a new agent" : name)
            }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard names.insert(key).inserted else {
                throw GobyApplicationError.duplicateProjectAgentName(name)
            }
            guard agent.providerIDs.isSubset(of: projectProviderIDs) else {
                throw GobyApplicationError.invalidProjectAgentProvider(name)
            }
            guard Set(agent.providerInstructions.keys).isSubset(of: agent.providerIDs) else {
                throw GobyApplicationError.invalidProjectAgentProvider(name)
            }
        }
    }

    private func validateHandoffDrafts(
        _ handoffDrafts: [NewProjectHandoffDraft],
        agents: [NewProjectAgentDraft]
    ) throws {
        for draft in handoffDrafts {
            guard agents.indices.contains(draft.sourceAgentIndex),
                  agents.indices.contains(draft.destinationAgentIndex),
                  agents[draft.sourceAgentIndex].providerIDs.contains(draft.sourceProviderID),
                  agents[draft.destinationAgentIndex].providerIDs.contains(draft.destinationProviderID),
                  draft.sourceAgentIndex != draft.destinationAgentIndex
                    || draft.sourceProviderID != draft.destinationProviderID,
                  !draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.acceptedArtifacts.isEmpty,
                  !draft.triggers.isEmpty,
                  (1...8).contains(draft.maximumDepth) else {
                throw GobyApplicationError.invalidHandoffLink("complete both exact endpoints, purpose, conditions, artifacts, trigger, and depth")
            }
        }
    }

    private func linkedProject(
        for link: NewProjectLinkDraft?,
        in snapshot: LabSnapshot
    ) throws -> LabProject? {
        guard let link else { return nil }
        guard let project = snapshot.projects.first(where: { $0.id == link.projectID }) else {
            throw GobyApplicationError.unknownProject(link.projectID)
        }
        if snapshot.projectGroups.contains(where: { $0.projectIDs.contains(project.id) }) {
            return project
        }
        guard !(link.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GobyApplicationError.emptyProjectGroupName
        }
        return project
    }

    private func createAgent(
        _ draft: NewProjectAgentDraft,
        for project: LabProject
    ) async throws -> AgentProfile {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = draft.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstructions = instructions.flatMap { $0.isEmpty ? nil : $0 }
        let agent: AgentProfile
        if draft.providerIDs.contains(.codex) {
            let definition = AgentDefinitionDraft(
                name: name,
                summary: summary,
                instructions: normalizedInstructions ?? summary,
                capabilities: draft.capabilities,
                scope: .project(project.id)
            )
            agent = try await definitions.createDefinition(
                from: definition,
                projectRootURL: project.rootURL,
                expectedProjectIdentity: project.fileSystemIdentity
            )
        } else {
            agent = AgentProfile(
                id: .make(),
                name: name,
                summary: summary,
                instructions: normalizedInstructions,
                capabilities: draft.capabilities,
                scope: .project(project.id)
            )
        }
        do {
            try await agentCatalog.saveAgent(agent)
        } catch {
            if draft.providerIDs.contains(.codex) {
                try? await definitions.undoCreatedDefinition(agent)
            }
            throw error
        }
        return agent
    }

    private func configureProviderBindings(
        for pairs: [(NewProjectAgentDraft, AgentProfile)],
        project: LabProject
    ) async throws -> [ProviderAgentBinding] {
        var created: [ProviderAgentBinding] = []
        for (draft, agent) in pairs {
            let migratedCodexBinding = ProviderAgentBinding.migratedCodexBinding(for: agent)
            if draft.providerIDs.contains(.codex) {
                let binding = ProviderAgentBinding(
                    id: migratedCodexBinding.id,
                    providerID: migratedCodexBinding.providerID,
                    agentID: migratedCodexBinding.agentID,
                    projectID: migratedCodexBinding.projectID,
                    nativeID: migratedCodexBinding.nativeID,
                    nativeDefinitionURL: migratedCodexBinding.nativeDefinitionURL,
                    capabilities: migratedCodexBinding.capabilities,
                    state: migratedCodexBinding.state,
                    instructionsOverride: normalizedProviderInstructions(
                        draft.providerInstructions[.codex],
                        sharedInstructions: draft.instructions
                    )
                )
                try await providerConfigurations.saveProviderBinding(binding)
                created.append(binding)
            } else {
                try await providerConfigurations.removeProviderBinding(id: migratedCodexBinding.id)
            }

            for providerID in draft.providerIDs.sorted() where providerID != .codex {
                let isConfigured = configuredProviderIDs.contains(providerID)
                let binding = ProviderAgentBinding(
                    providerID: providerID,
                    agentID: agent.id,
                    projectID: project.id,
                    nativeID: isConfigured
                        ? "goby-agent:\(agent.id.rawValue)"
                        : "pending:\(providerID.rawValue):\(agent.id.rawValue)",
                    capabilities: agent.capabilities,
                    state: isConfigured ? .configured : .unavailable,
                    instructionsOverride: normalizedProviderInstructions(
                        draft.providerInstructions[providerID],
                        sharedInstructions: draft.instructions
                    )
                )
                try await providerConfigurations.saveProviderBinding(binding)
                created.append(binding)
            }
        }
        return created
    }

    private func normalizedProviderInstructions(
        _ value: String?,
        sharedInstructions: String?
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let shared = sharedInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == shared ? nil : normalized
    }

    private func saveCollaborationSet(
        enabled: Bool,
        project: LabProject,
        bindings: [ProviderAgentBinding]
    ) async throws -> ProviderCollaborationSet? {
        guard enabled else { return nil }
        let collaborationSet = ProviderCollaborationSet(
            projectID: project.id,
            members: Set(bindings.map {
                ProviderCollaborationMember(providerID: $0.providerID, bindingID: $0.id)
            })
        )
        guard collaborationSet.isCollaborative else {
            throw GobyApplicationError.invalidProviderCollaborationSet
        }
        try await providerConfigurations.saveProviderCollaborationSet(collaborationSet)
        return collaborationSet
    }

    private func saveHandoffLinks(
        _ drafts: [NewProjectHandoffDraft],
        agentPairs: [(NewProjectAgentDraft, AgentProfile)],
        project: LabProject,
        bindings: [ProviderAgentBinding]
    ) async throws -> [AgentHandoffLink] {
        guard !drafts.isEmpty else { return [] }
        guard let handoffs else {
            throw GobyApplicationError.invalidHandoffLink("handoff storage is unavailable")
        }
        var saved: [AgentHandoffLink] = []
        for draft in drafts {
            let sourceAgent = agentPairs[draft.sourceAgentIndex].1
            let destinationAgent = agentPairs[draft.destinationAgentIndex].1
            guard let sourceBinding = bindings.first(where: {
                $0.providerID == draft.sourceProviderID && $0.agentID == sourceAgent.id
            }), let destinationBinding = bindings.first(where: {
                $0.providerID == draft.destinationProviderID && $0.agentID == destinationAgent.id
            }) else {
                throw GobyApplicationError.invalidHandoffLink("a selected provider role has no exact binding")
            }
            let link = AgentHandoffLink(
                source: AgentHandoffEndpoint(
                    providerID: sourceBinding.providerID,
                    bindingID: sourceBinding.id,
                    agentID: sourceAgent.id,
                    projectID: project.id
                ),
                destination: AgentHandoffEndpoint(
                    providerID: destinationBinding.providerID,
                    bindingID: destinationBinding.id,
                    agentID: destinationAgent.id,
                    projectID: project.id
                ),
                purpose: draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                conditions: draft.conditions.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: .suggestOnly,
                acceptedArtifacts: draft.acceptedArtifacts,
                maximumDepth: draft.maximumDepth,
                triggers: draft.triggers
            )
            try await handoffs.saveHandoffLink(link)
            saved.append(link)
        }
        return saved
    }

    private func saveLink(
        _ link: NewProjectLinkDraft?,
        linkedProject: LabProject?,
        newProject: LabProject,
        original: LabSnapshot
    ) async throws -> ProjectGroup? {
        guard let link, let linkedProject else { return nil }
        if let existing = original.projectGroups.first(where: {
            $0.projectIDs.contains(linkedProject.id)
        }) {
            let updated = ProjectGroup(
                id: existing.id,
                name: existing.name,
                members: existing.members + [
                    ProjectGroupMember(projectID: newProject.id, role: link.projectRole)
                ],
                createdAt: existing.createdAt
            )
            try await groups.saveProjectGroup(updated)
            return updated
        }

        let group = ProjectGroup(
            name: link.groupName ?? "",
            members: [
                ProjectGroupMember(projectID: linkedProject.id, role: link.linkedProjectRole),
                ProjectGroupMember(projectID: newProject.id, role: link.projectRole),
            ]
        )
        try await groups.saveProjectGroup(group)
        return group
    }
}

public struct RemoveProjectUseCase: Sendable {
    private let catalog: any ProjectCatalogManaging
    private let runs: any RunRepository

    public init(catalog: any ProjectCatalogManaging, runs: any RunRepository) {
        self.catalog = catalog
        self.runs = runs
    }

    public func callAsFunction(project: LabProject) async throws {
        let hasUnfinishedRun = try await runs.allRuns().contains { run in
            guard run.assignments.contains(where: { $0.projectID == project.id }) else { return false }
            return switch run.status {
            case .draft, .ready, .running, .needsAttention, .failed:
                true
            case .completed, .cancelled:
                false
            }
        }
        guard !hasUnfinishedRun else {
            throw GobyApplicationError.projectHasUnfinishedRun(project.name)
        }
        try await catalog.removeProject(id: project.id)
    }
}

public struct SaveProjectGroupUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let groups: any ProjectGroupCatalogManaging

    public init(catalog: any LabCatalogRepository, groups: any ProjectGroupCatalogManaging) {
        self.catalog = catalog
        self.groups = groups
    }

    public func callAsFunction(_ proposed: ProjectGroup) async throws -> ProjectGroup {
        let name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GobyApplicationError.emptyProjectGroupName }

        let memberIDs = proposed.members.map(\.projectID)
        guard Set(memberIDs).count >= 2, Set(memberIDs).count == memberIDs.count else {
            throw GobyApplicationError.projectGroupNeedsMultipleProjects
        }

        let snapshot = try await catalog.snapshot()
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        for member in proposed.members where projects[member.projectID] == nil {
            throw GobyApplicationError.unknownProject(member.projectID)
        }
        for other in snapshot.projectGroups where other.id != proposed.id {
            if let projectID = other.projectIDs.intersection(memberIDs).first,
               let project = projects[projectID] {
                throw GobyApplicationError.projectAlreadyGrouped(
                    projectName: project.name,
                    groupName: other.name
                )
            }
        }

        let createdAt = snapshot.projectGroups.first(where: { $0.id == proposed.id })?.createdAt
            ?? proposed.createdAt
        let group = ProjectGroup(
            id: proposed.id,
            name: name,
            members: proposed.members.sorted {
                (projects[$0.projectID]?.name ?? $0.projectID.rawValue)
                    .localizedStandardCompare(projects[$1.projectID]?.name ?? $1.projectID.rawValue)
                    == .orderedAscending
            },
            createdAt: createdAt
        )
        try await groups.saveProjectGroup(group)
        return group
    }
}

public struct RemoveProjectGroupUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let groups: any ProjectGroupCatalogManaging

    public init(catalog: any LabCatalogRepository, groups: any ProjectGroupCatalogManaging) {
        self.catalog = catalog
        self.groups = groups
    }

    public func callAsFunction(id: ProjectGroupID) async throws {
        let snapshot = try await catalog.snapshot()
        guard snapshot.projectGroups.contains(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownProjectGroup(id)
        }
        try await groups.removeProjectGroup(id: id)
    }
}

public struct DiscoverAgentsUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let discovery: any AgentDiscovering

    public init(catalog: any LabCatalogRepository, discovery: any AgentDiscovering) {
        self.catalog = catalog
        self.discovery = discovery
    }

    public func callAsFunction() async throws -> AgentImportPlan {
        let lab = try await catalog.snapshot()
        return try await discovery.discover(projects: lab.projects)
    }
}

public struct RegisterAgentsUseCase: Sendable {
    private let catalog: any LabCatalogRepository

    public init(catalog: any LabCatalogRepository) {
        self.catalog = catalog
    }

    public func callAsFunction(candidates: [AgentImportCandidate]) async throws {
        let reviewedProfiles = try candidates.map { candidate in
            let profile = candidate.profile
            let provenance: AgentDefinitionReviewProvenance
            if profile.sourceURL != nil {
                guard let digest = profile.reviewedDefinitionDigest,
                      digest == DefinitionReviewDigest.sha256(candidate.configurationPreview) else {
                    throw GobyApplicationError.incompleteAgentDefinitionReview
                }
                provenance = .fullContent
            } else {
                provenance = .semanticOnly
            }
            return AgentProfile(
                id: profile.id,
                name: profile.name,
                summary: profile.summary,
                instructions: profile.instructions,
                capabilities: profile.capabilities,
                scope: profile.scope,
                sourceURL: profile.sourceURL,
                toolPreset: provenance == .semanticOnly ? nil : profile.toolPreset,
                reviewedDefinitionDigest: provenance == .semanticOnly ? nil : profile.reviewedDefinitionDigest,
                definitionReviewProvenance: provenance,
                codexRegistrationKey: provenance == .semanticOnly ? nil : profile.codexRegistrationKey,
                isEnabled: profile.isEnabled
            )
        }
        try await catalog.register(projects: [], agents: reviewedProfiles)
    }
}

public struct PreviewAgentRestructureUseCase: Sendable {
    private let restructurer: any AgentDefinitionRestructuring

    public init(restructurer: any AgentDefinitionRestructuring) {
        self.restructurer = restructurer
    }

    public func callAsFunction(candidates: [AgentImportCandidate]) async throws -> [AgentDefinitionChangePreview] {
        try await restructurer.preview(candidates: candidates)
    }
}

public struct ApplyAgentRestructureUseCase: Sendable {
    private let restructurer: any AgentDefinitionRestructuring

    public init(restructurer: any AgentDefinitionRestructuring) {
        self.restructurer = restructurer
    }

    public func callAsFunction(_ changes: [AgentDefinitionChangePreview]) async throws {
        try await restructurer.apply(changes)
    }
}

public struct UndoAgentRestructureUseCase: Sendable {
    private let restructurer: any AgentDefinitionRestructuring

    public init(restructurer: any AgentDefinitionRestructuring) {
        self.restructurer = restructurer
    }

    public func callAsFunction(_ changes: [AgentDefinitionChangePreview]) async throws {
        try await restructurer.undo(changes)
    }
}

public struct LoadAgentRestructureHistoryUseCase: Sendable {
    private let repository: any AgentRestructureHistoryRepository

    public init(repository: any AgentRestructureHistoryRepository) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> [AgentDefinitionChangePreview] {
        try await repository.lastAgentRestructure()
    }
}

public struct SaveAgentRestructureHistoryUseCase: Sendable {
    private let repository: any AgentRestructureHistoryRepository

    public init(repository: any AgentRestructureHistoryRepository) {
        self.repository = repository
    }

    public func callAsFunction(_ changes: [AgentDefinitionChangePreview]) async throws {
        try await repository.saveLastAgentRestructure(changes)
    }
}

public struct PrepareRoutingPlanUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let router: any Routing

    public init(catalog: any LabCatalogRepository, router: any Routing) {
        self.catalog = catalog
        self.router = router
    }

    public func callAsFunction(_ request: RouteRequest) async throws -> RoutingPlan {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GobyApplicationError.emptyPrompt
        }

        let lab = try await catalog.snapshot()
        guard !lab.projects.isEmpty else {
            throw GobyApplicationError.emptyCatalog
        }

        try validate(request, against: lab)
        let plan = try await router.plan(for: request, in: lab)
        try validate(plan, requestedProviderID: request.providerID, against: lab)
        try validateExecutableScope(plan)
        try validateDeliveryPipeline(plan)
        return plan
    }

    private func validate(_ request: RouteRequest, against lab: LabSnapshot) throws {
        let projects = Dictionary(uniqueKeysWithValues: lab.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: lab.agents.map { ($0.id, $0) })

        if request.agentTargets.isEmpty {
            let reusableAgentIDs = Set(lab.agents.filter { !$0.isTemporary }.map(\.id))
            guard lab.providerBindings.contains(where: {
                $0.providerID == request.providerID
                    && $0.state == .configured
                    && reusableAgentIDs.contains($0.agentID)
            }) else {
                throw GobyApplicationError.providerUnavailable(request.providerID)
            }
            return
        }

        for target in request.agentTargets {
            guard target.providerID == request.providerID else {
                throw GobyApplicationError.providerRouteMismatch(
                    expected: request.providerID,
                    actual: target.providerID
                )
            }
            guard projects[target.projectID] != nil else {
                throw GobyApplicationError.unknownProject(target.projectID)
            }
            try validate(
                agentID: target.agentID,
                providerID: target.providerID,
                projectID: target.projectID,
                agents: agents,
                bindings: lab.providerBindings
            )
        }
    }

    private func validate(
        _ plan: RoutingPlan,
        requestedProviderID: AgentProviderID,
        against lab: LabSnapshot
    ) throws {
        let projects = Dictionary(uniqueKeysWithValues: lab.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: lab.agents.map { ($0.id, $0) })

        for route in plan.routes {
            guard route.providerID == requestedProviderID else {
                throw GobyApplicationError.providerRouteMismatch(
                    expected: requestedProviderID,
                    actual: route.providerID
                )
            }
            guard projects[route.projectID] != nil else {
                throw GobyApplicationError.unknownProject(route.projectID)
            }
            let reviewedAgentIDs = route.providerBindings.map(\.agentID)
            guard route.providerBindings.isEmpty || (
                Set(reviewedAgentIDs).count == reviewedAgentIDs.count
                    && Set(reviewedAgentIDs) == Set(route.agentIDs)
            ) else {
                throw GobyApplicationError.incompleteApproval
            }
            for id in route.agentIDs {
                try validate(
                    agentID: id,
                    providerID: route.providerID,
                    projectID: route.projectID,
                    bindingID: route.providerBindings.first { $0.agentID == id }?.bindingID,
                    agents: agents,
                    bindings: lab.providerBindings
                )
            }
        }
    }

    private func validate(
        agentID: AgentID,
        providerID: AgentProviderID,
        projectID: ProjectID,
        bindingID: ProviderAgentBindingID? = nil,
        agents: [AgentID: AgentProfile],
        bindings: [ProviderAgentBinding]
    ) throws {
        guard let agent = agents[agentID] else {
            throw GobyApplicationError.unknownAgent(agentID)
        }
        guard agent.isEnabled else {
            throw GobyApplicationError.agentUnavailable(agentID)
        }
        if case let .project(scopedProjectID) = agent.scope,
           scopedProjectID != projectID {
            throw GobyApplicationError.agentOutsideProject(agentID, projectID)
        }
        _ = try ProviderBindingResolver.resolve(
            agentID: agentID,
            providerID: providerID,
            projectID: projectID,
            bindingID: bindingID,
            in: bindings
        )
    }
}

public struct BuildGraphUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let layout: any GraphLayoutProviding

    public init(catalog: any LabCatalogRepository, layout: any GraphLayoutProviding) {
        self.catalog = catalog
        self.layout = layout
    }

    public func callAsFunction(
        assignments: [AgentAssignment],
        codexTasks: [CodexTaskActivity] = [],
        providerID: AgentProviderID? = nil
    ) async throws -> GraphLayoutSnapshot {
        let lab = try await catalog.snapshot()
        let scope = ProviderGraphScope(
            lab: lab, assignments: assignments, codexTasks: codexTasks, providerID: providerID
        )
        return await layout.layout(
            lab: scope.lab,
            assignments: scope.assignments,
            codexTasks: scope.codexTasks
        )
    }
}

public struct LoadMapLayoutUseCase: Sendable {
    private let repository: any MapLayoutRepository

    public init(repository: any MapLayoutRepository) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> MapLayoutOverrides {
        try await repository.loadMapLayout()
    }
}

public struct SaveMapLayoutUseCase: Sendable {
    private let repository: any MapLayoutRepository

    public init(repository: any MapLayoutRepository) {
        self.repository = repository
    }

    public func callAsFunction(_ layout: MapLayoutOverrides) async throws {
        try await repository.saveMapLayout(layout)
    }
}

public struct InspectCodexUseCase: Sendable {
    private let codex: any CodexServing

    public init(codex: any CodexServing) {
        self.codex = codex
    }

    public func callAsFunction() async -> (CodexConnectionState, CodexAccountSnapshot?) {
        do {
            let state = try await codex.connect()
            let account = try await codex.accountSnapshot()
            return (account.authenticated ? state : .needsAuthentication, account)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }
}

public struct StageRunUseCase: Sendable {
    private let repository: any RunRepository
    private let catalog: any LabCatalogRepository
    private let instructions: any InstructionRepository
    private let resources: any SharedResourceRepository
    private let approvals: any ApprovalChecking
    private let automationAuthority: (any AutomationExecutionAuthorityProviding)?

    public init(
        repository: any RunRepository,
        catalog: any LabCatalogRepository,
        instructions: any InstructionRepository,
        resources: any SharedResourceRepository,
        approvals: any ApprovalChecking,
        automationAuthority: (any AutomationExecutionAuthorityProviding)? = nil
    ) {
        self.repository = repository
        self.catalog = catalog
        self.instructions = instructions
        self.resources = resources
        self.approvals = approvals
        self.automationAuthority = automationAuthority
    }

    public func callAsFunction(
        plan: RoutingPlan,
        receipt: ApprovalReceipt?,
        selectedResourceIDs: Set<SharedResourceID> = [],
        requiredAutomationAuthorityDigest: Data? = nil,
        automaticallyApproveRuntimeRequests: Bool = false
    ) async throws -> RunRecord {
        try validateExecutableScope(plan)
        try validateDeliveryPipeline(plan)
        try await approvals.validate(plan: plan, receipt: receipt)
        try await validateAutomationAuthority(requiredAutomationAuthorityDigest)

        let lab = try await catalog.snapshot()
        let routedAgentIDs = Set(plan.routes.flatMap(\.agentIDs))
        let temporaryAgentIDs = Set(lab.agents.filter {
            $0.isTemporary && routedAgentIDs.contains($0.id)
        }.map(\.id))
        if !temporaryAgentIDs.isEmpty {
            let previousRuns = try await repository.allRuns()
            let previouslyUsedIDs = Set(previousRuns.filter { $0.id != plan.id }.flatMap { run in
                run.agentSnapshot.filter(\.isTemporary).map(\.id)
            })
            if let reusedID = temporaryAgentIDs.intersection(previouslyUsedIDs).first {
                throw GobyApplicationError.agentUnavailable(reusedID)
            }
        }
        var assignments: [AgentAssignment] = []
        var providerBindingSnapshot: [ProviderAgentBinding] = []
        for route in plan.routes {
            guard lab.projects.contains(where: { $0.id == route.projectID }) else {
                throw GobyApplicationError.unknownProject(route.projectID)
            }
            let reviewedAgentIDs = route.providerBindings.map(\.agentID)
            guard route.providerBindings.isEmpty || (
                Set(reviewedAgentIDs).count == reviewedAgentIDs.count
                    && Set(reviewedAgentIDs) == Set(route.agentIDs)
            ) else {
                throw GobyApplicationError.incompleteApproval
            }
            for agentID in route.agentIDs {
                guard let agent = lab.agents.first(where: { $0.id == agentID }) else {
                    throw GobyApplicationError.unknownAgent(agentID)
                }
                guard agent.isEnabled else {
                    throw GobyApplicationError.agentUnavailable(agentID)
                }
                if case let .project(scopedProjectID) = agent.scope,
                   scopedProjectID != route.projectID {
                    throw GobyApplicationError.agentOutsideProject(agentID, route.projectID)
                }
                let reviewedBindingID = route.providerBindings.first {
                    $0.agentID == agentID
                }?.bindingID
                let binding = try ProviderBindingResolver.resolve(
                    agentID: agentID,
                    providerID: route.providerID,
                    projectID: route.projectID,
                    bindingID: reviewedBindingID,
                    in: lab.providerBindings
                )
                assignments.append(AgentAssignment(
                    runID: plan.id,
                    projectID: route.projectID,
                    agentID: agentID,
                    status: .queued,
                    currentTask: plan.interpretedGoal,
                    attachments: plan.attachments,
                    providerID: route.providerID,
                    providerBindingID: binding.id,
                    model: route.model
                ))
                if !providerBindingSnapshot.contains(where: { $0.id == binding.id }) {
                    providerBindingSnapshot.append(binding)
                }
            }
        }
        if let pipeline = plan.deliveryPipeline {
            // One attempt per stage, in stage order. The orchestrator runs them
            // one at a time and appends rework attempts after a failed check.
            assignments = try pipeline.stages.map { stage in
                guard let route = plan.routes.first(where: {
                    $0.projectID == stage.target.projectID && $0.providerID == stage.target.providerID
                }), route.agentIDs.contains(stage.target.agentID),
                      providerBindingSnapshot.contains(where: { $0.id == stage.target.bindingID }) else {
                    throw GobyApplicationError.invalidDeliveryPipeline(
                        "the \(stage.kind.displayName) owner is not part of the reviewed routes."
                    )
                }
                return AgentAssignment(
                    runID: plan.id,
                    projectID: stage.target.projectID,
                    agentID: stage.target.agentID,
                    status: .queued,
                    currentTask: plan.interpretedGoal,
                    attachments: plan.attachments,
                    providerID: stage.target.providerID,
                    providerBindingID: stage.target.bindingID,
                    model: route.model,
                    deliveryStageID: stage.id
                )
            }
        }
        let routedProjectIDs = Set(plan.routes.map(\.projectID))
        let routedProjects = lab.projects.filter { routedProjectIDs.contains($0.id) }
        for project in routedProjects {
            guard project.fileSystemIdentity?.kind == .directory,
                  project.fileSystemIdentity?.matchesCurrentObject(at: project.rootURL) == true else {
                throw GobyApplicationError.projectAuthorizationChanged(project.id)
            }
        }
        let applicableInstructions = try await instructions.allInstructionPacks().filter { pack in
            pack.isEnabled && routedProjects.contains(where: pack.scope.includes)
        }
        let allResources = try await resources.allResources()
        for resourceID in selectedResourceIDs {
            guard let resource = allResources.first(where: { $0.id == resourceID }) else {
                throw GobyApplicationError.unknownSharedResource(resourceID)
            }
            guard resource.isEnabled else {
                throw GobyApplicationError.sharedResourceUnavailable(resourceID)
            }
            guard resource.fileSystemIdentity?.kind == .directory,
                  resource.fileSystemIdentity?.matchesCurrentObject(at: resource.url) == true else {
                throw GobyApplicationError.sharedResourceAuthorizationChanged(resourceID)
            }
        }
        let enabledResources = allResources.filter { selectedResourceIDs.contains($0.id) }
        let selectedAgentIDs = Set(plan.routes.flatMap(\.agentIDs))
        let selectedAgents = lab.agents.filter { selectedAgentIDs.contains($0.id) }
        try await validateAutomationAuthority(requiredAutomationAuthorityDigest)
        let automaticRuntimeApprovalEnabled = automaticallyApproveRuntimeRequests
            && plan.routes.allSatisfy { $0.providerID == .codex }
            && (requiredAutomationAuthorityDigest != nil || (
                plan.risk != .high
                    && !plan.gitOperations.contains(where: { $0.kind.alwaysRequiresSeparateApproval })
            ))
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: assignments,
            approvalReceipts: receipt.map { [$0] } ?? [],
            instructionSnapshot: applicableInstructions,
            agentSnapshot: selectedAgents,
            providerBindingSnapshot: providerBindingSnapshot,
            projectSnapshot: routedProjects,
            automationExecutionAuthorityDigest: requiredAutomationAuthorityDigest,
            automaticallyApproveRuntimeRequests: automaticRuntimeApprovalEnabled,
            journal: [RunJournalEntry(
                kind: .created,
                message: "Run staged with \(assignments.count) assignments. Runtime approvals: \(automaticRuntimeApprovalEnabled ? (requiredAutomationAuthorityDigest == nil ? "eligible requests allowed within reviewed scope" : "all complete Codex requests allowed by the automation grant") : "ask for each request")."
            )],
            resourceSnapshot: enabledResources
        )
        try await repository.save(run)
        return run
    }

    private func validateAutomationAuthority(_ requiredDigest: Data?) async throws {
        guard let requiredDigest else { return }
        guard let automationAuthority,
              try await automationAuthority.automationExecutionAuthorityDigest() == requiredDigest else {
            throw GobyApplicationError.invalidAutomation(
                "This automation's project, agent, provider, or instruction authority changed. Review the paused schedule before running it."
            )
        }
    }
}

/// Planning and admission share the same minimum execution invariants.
/// Provider identity remains part of the target so distinct planes stay distinct.
private func validateExecutableScope(_ plan: RoutingPlan) throws {
    guard !plan.routes.isEmpty, plan.routes.allSatisfy({ !$0.agentIDs.isEmpty }) else {
        throw GobyApplicationError.noRoute
    }
    var targets = Set<AgentRouteTarget>()
    for route in plan.routes {
        for agentID in route.agentIDs {
            let target = AgentRouteTarget(
                providerID: route.providerID, agentID: agentID, projectID: route.projectID
            )
            guard targets.insert(target).inserted else {
                throw GobyApplicationError.incompleteApproval
            }
        }
    }
}

/// A staged plan runs on one provider in this release; cross-provider stage
/// continuation must use reviewed handoff bundles instead.
private func validateDeliveryPipeline(_ plan: RoutingPlan) throws {
    guard let pipeline = plan.deliveryPipeline else { return }
    if let issue = pipeline.issues.first {
        let reason = switch issue {
        case .empty: "no stages were proposed."
        case let .outOfOrder(kind): "\(kind.displayName) is out of order."
        case let .duplicateStage(kind, _): "\(kind.displayName) appears twice for one project."
        case .releaseWithoutVerification: "Release needs a QA, stress, or security stage first."
        }
        throw GobyApplicationError.invalidDeliveryPipeline(reason)
    }
    let routeProviders = Set(plan.routes.map(\.providerID))
    for stage in pipeline.stages {
        guard routeProviders.contains(stage.target.providerID),
              plan.routes.contains(where: {
                  $0.projectID == stage.target.projectID
                      && $0.providerID == stage.target.providerID
                      && $0.agentIDs.contains(stage.target.agentID)
                      && ($0.providerBindings.isEmpty || $0.providerBindings.contains {
                          $0.agentID == stage.target.agentID && $0.bindingID == stage.target.bindingID
                      })
              }) else {
            throw GobyApplicationError.invalidDeliveryPipeline(
                "the \(stage.kind.displayName) owner is not part of the reviewed routes."
            )
        }
    }
}

public struct RegisterSharedResourcesUseCase: Sendable {
    private let repository: any SharedResourceRepository

    public init(repository: any SharedResourceRepository) {
        self.repository = repository
    }

    public func callAsFunction(urls: [URL]) async throws {
        for url in urls {
            let resource = SharedResource(
                name: url.lastPathComponent,
                url: url.standardizedFileURL
            )
            guard resource.fileSystemIdentity?.kind == .directory else {
                throw GobyApplicationError.sharedResourceAuthorizationChanged(resource.id)
            }
            try await repository.saveResource(resource)
        }
    }
}

public struct LoadSharedResourcesUseCase: Sendable {
    private let repository: any SharedResourceRepository

    public init(repository: any SharedResourceRepository) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> [SharedResource] {
        try await repository.allResources()
    }
}

public struct SetSharedResourceEnabledUseCase: Sendable {
    private let repository: any SharedResourceRepository

    public init(repository: any SharedResourceRepository) {
        self.repository = repository
    }

    public func callAsFunction(id: SharedResourceID, enabled: Bool) async throws {
        try await repository.setResourceEnabled(id: id, enabled: enabled)
    }
}

public struct SetSharedResourceAccessUseCase: Sendable {
    private let repository: any SharedResourceRepository

    public init(repository: any SharedResourceRepository) {
        self.repository = repository
    }

    public func callAsFunction(_ resource: SharedResource, access: SharedResourceAccess) async throws {
        try await repository.saveResource(SharedResource(
            id: resource.id,
            name: resource.name,
            url: resource.url,
            access: access,
            isEnabled: resource.isEnabled,
            registeredAt: resource.registeredAt,
            fileSystemIdentity: resource.fileSystemIdentity
        ))
    }
}

public struct SetSharedResourceSettingsUseCase: Sendable {
    private let repository: any SharedResourceRepository

    public init(repository: any SharedResourceRepository) {
        self.repository = repository
    }

    public func callAsFunction(
        id: SharedResourceID,
        access: SharedResourceAccess,
        enabled: Bool
    ) async throws {
        guard let resource = try await repository.allResources().first(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownSharedResource(id)
        }
        try await repository.saveResource(SharedResource(
            id: resource.id,
            name: resource.name,
            url: resource.url,
            access: access,
            isEnabled: enabled,
            registeredAt: resource.registeredAt,
            fileSystemIdentity: resource.fileSystemIdentity
        ))
    }
}

public struct CreateAgentUseCase: Sendable {
    private let repository: any AgentCatalogManaging
    private let catalog: any LabCatalogRepository
    private let definitions: any CodexAgentDefinitionManaging

    public init(
        repository: any AgentCatalogManaging,
        catalog: any LabCatalogRepository,
        definitions: any CodexAgentDefinitionManaging
    ) {
        self.repository = repository
        self.catalog = catalog
        self.definitions = definitions
    }

    public func callAsFunction(
        name: String,
        summary: String,
        instructions: String? = nil,
        capabilities: Set<AgentCapability>,
        scope: AgentScope,
        toolPreset: AgentToolPreset? = nil
    ) async throws -> AgentProfile {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanSummary.isEmpty, !capabilities.isEmpty else {
            throw GobyApplicationError.emptyPrompt
        }
        if toolPreset != nil {
            guard case .project = scope else {
                throw GobyApplicationError.agentTemplateRequiresProject
            }
        }
        let project = try await project(for: scope)
        let migratedProject = project?.migratingLegacyMountIdentity()
        let authorizedProject = migratedProject ?? project
        let projectRootURL = authorizedProject?.rootURL
        let draft = AgentDefinitionDraft(
            name: cleanName,
            summary: cleanSummary,
            instructions: cleanInstructions.flatMap { $0.isEmpty ? nil : $0 } ?? cleanSummary,
            capabilities: capabilities,
            scope: scope,
            toolPreset: toolPreset
        )
        let agent = try await definitions.createDefinition(
            from: draft,
            projectRootURL: projectRootURL,
            expectedProjectIdentity: authorizedProject?.fileSystemIdentity
        )
        do {
            if let migratedProject {
                try await catalog.register(projects: [migratedProject], agents: [])
            }
            try await repository.saveAgent(agent)
        } catch {
            try? await definitions.undoCreatedDefinition(
                agent,
                expectedProjectIdentity: authorizedProject?.fileSystemIdentity
            )
            throw error
        }
        return agent
    }

    private func project(for scope: AgentScope) async throws -> LabProject? {
        guard case let .project(projectID) = scope else { return nil }
        let snapshot = try await catalog.snapshot()
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw GobyApplicationError.unknownProject(projectID)
        }
        return project
    }
}

/// A quick task gets a project-scoped logical role and one provider binding.
/// It has no provider-native definition file: the run snapshot supplies its
/// instructions to the provider runtime, and retirement removes only Goby's
/// temporary catalog records. The role and instructions are derived from the
/// task and carry forward notes left by earlier temporary agents.
public struct CreateTemporaryAgentUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let agents: any AgentCatalogManaging
    private let providers: any ProviderConfigurationCatalogManaging
    private let notes: (any TemporaryAgentNotesStoring)?

    public init(
        catalog: any LabCatalogRepository,
        agents: any AgentCatalogManaging,
        providers: any ProviderConfigurationCatalogManaging,
        notes: (any TemporaryAgentNotesStoring)? = nil
    ) {
        self.catalog = catalog
        self.agents = agents
        self.providers = providers
        self.notes = notes
    }

    public func callAsFunction(
        id: AgentID,
        projectID: ProjectID,
        providerID: AgentProviderID,
        task: String,
        basedOn templateID: AgentID? = nil
    ) async throws -> AgentProfile {
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.rawValue.hasPrefix("temporary-agent-"), !goal.isEmpty else {
            throw GobyApplicationError.emptyPrompt
        }
        let snapshot = try await catalog.snapshot()
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw GobyApplicationError.unknownProject(projectID)
        }
        guard !snapshot.agents.contains(where: { $0.id == id }) else {
            throw GobyApplicationError.agentUnavailable(id)
        }
        // Choosing a temporary agent for a provider is an explicit request to
        // use that provider in this project; the host preview discloses it.
        let existingConfiguration = snapshot.projectProviderConfigurations.first { $0.projectID == projectID }
        if existingConfiguration?.providerIDs.contains(providerID) != true {
            try await providers.saveProjectProviderConfiguration(ProjectProviderConfiguration(
                projectID: projectID,
                providerIDs: (existingConfiguration?.providerIDs ?? []).union([providerID])
            ))
        }
        let earlierNotes = (try? await notes?.notes(for: projectID)) ?? nil
        let agent: AgentProfile
        if let templateID, let template = snapshot.agents.first(where: { $0.id == templateID && !$0.isTemporary }) {
            // A parallel copy: the same role and instructions as the busy
            // agent, for one request that runs alongside its current work.
            agent = AgentProfile(
                id: id,
                name: TemporaryAgentBlueprint.parallelCopyName(of: template.name),
                summary: template.summary,
                instructions: TemporaryAgentBlueprint.parallelCopyInstructions(
                    template: template, goal: goal, continuationNotes: earlierNotes
                ),
                capabilities: template.capabilities,
                scope: .project(projectID),
                toolPreset: template.toolPreset
            )
        } else {
            let blueprint = TemporaryAgentBlueprint.make(
                goal: goal,
                project: project,
                continuationNotes: earlierNotes
            )
            agent = AgentProfile(
                id: id,
                name: blueprint.name,
                summary: blueprint.summary,
                instructions: blueprint.instructions,
                capabilities: blueprint.capabilities,
                scope: .project(projectID)
            )
        }
        let capabilities = agent.capabilities
        try await agents.saveAgent(agent)
        if providerID != .codex {
            do {
                try await providers.removeProviderBinding(
                    id: ProviderAgentBinding.migratedCodexBinding(for: agent).id
                )
                try await providers.saveProviderBinding(ProviderAgentBinding(
                    providerID: providerID,
                    agentID: id,
                    projectID: projectID,
                    nativeID: id.rawValue,
                    capabilities: capabilities
                ))
            } catch {
                try? await agents.removeAgent(id: id)
                throw error
            }
        }
        return agent
    }
}

public struct RetireTemporaryAgentUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let agents: any AgentCatalogManaging

    public init(catalog: any LabCatalogRepository, agents: any AgentCatalogManaging) {
        self.catalog = catalog
        self.agents = agents
    }

    public func callAsFunction(id: AgentID) async throws {
        guard id.rawValue.hasPrefix("temporary-agent-") else {
            throw GobyApplicationError.agentUnavailable(id)
        }
        let snapshot = try await catalog.snapshot()
        guard snapshot.agents.contains(where: { $0.id == id && $0.isTemporary }) else { return }
        try await agents.removeAgent(id: id)
    }
}

public struct SetAgentEnabledUseCase: Sendable {
    private let repository: any AgentCatalogManaging

    public init(repository: any AgentCatalogManaging) {
        self.repository = repository
    }

    public func callAsFunction(id: AgentID, enabled: Bool) async throws {
        try await repository.setAgentEnabled(id: id, enabled: enabled)
    }
}

public struct UpdateProviderBindingInstructionsUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let providerConfigurations: any ProviderConfigurationCatalogManaging

    public init(
        catalog: any LabCatalogRepository,
        providerConfigurations: any ProviderConfigurationCatalogManaging
    ) {
        self.catalog = catalog
        self.providerConfigurations = providerConfigurations
    }

    public func callAsFunction(
        bindingID: ProviderAgentBindingID,
        instructions: String?
    ) async throws -> ProviderAgentBinding {
        let snapshot = try await catalog.snapshot()
        guard let binding = snapshot.providerBindings.first(where: { $0.id == bindingID }) else {
            throw GobyApplicationError.unknownProviderBinding(bindingID)
        }
        let trimmedInstructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedInstructions: String? = if let trimmedInstructions, !trimmedInstructions.isEmpty {
            trimmedInstructions
        } else {
            nil
        }
        let updated = ProviderAgentBinding(
            id: binding.id,
            providerID: binding.providerID,
            agentID: binding.agentID,
            projectID: binding.projectID,
            nativeID: binding.nativeID,
            nativeDefinitionURL: binding.nativeDefinitionURL,
            capabilities: binding.capabilities,
            state: binding.state,
            instructionsOverride: cleanedInstructions
        )
        try await providerConfigurations.saveProviderBinding(updated)
        return updated
    }
}

public struct InspectProviderCredentialUseCase: Sendable {
    private let repository: any ProviderCredentialRepository

    public init(repository: any ProviderCredentialRepository) {
        self.repository = repository
    }

    public func callAsFunction(
        providerID: AgentProviderID,
        kind: ProviderCredentialKind = .apiKey
    ) async throws -> Bool {
        try await repository.credential(for: providerID, kind: kind) != nil
    }
}

public struct SaveProviderCredentialUseCase: Sendable {
    private let repository: any ProviderCredentialRepository

    public init(repository: any ProviderCredentialRepository) {
        self.repository = repository
    }

    public func callAsFunction(
        providerID: AgentProviderID,
        credential: String,
        kind: ProviderCredentialKind = .apiKey
    ) async throws {
        let cleaned = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 20,
              !cleaned.contains(where: \.isWhitespace) else {
            throw GobyApplicationError.invalidProviderCredential(providerID)
        }
        if providerID == .claude {
            let isSubscriptionToken = ProviderCredentialKind.isClaudeSubscriptionToken(cleaned)
            switch kind {
            case .subscriptionToken where !isSubscriptionToken:
                throw GobyApplicationError.misplacedProviderCredential(providerID, expected: kind)
            case .apiKey where isSubscriptionToken:
                throw GobyApplicationError.misplacedProviderCredential(providerID, expected: kind)
            default:
                break
            }
        } else if kind == .subscriptionToken {
            throw GobyApplicationError.invalidProviderCredential(providerID)
        }
        try await repository.saveCredential(cleaned, for: providerID, kind: kind)
    }
}

public struct RemoveProviderCredentialUseCase: Sendable {
    private let repository: any ProviderCredentialRepository

    public init(repository: any ProviderCredentialRepository) {
        self.repository = repository
    }

    public func callAsFunction(
        providerID: AgentProviderID,
        kind: ProviderCredentialKind = .apiKey
    ) async throws {
        try await repository.removeCredential(for: providerID, kind: kind)
    }
}

public struct PublishAgentToCodexUseCase: Sendable {
    private let repository: any AgentCatalogManaging
    private let catalog: any LabCatalogRepository
    private let definitions: any CodexAgentDefinitionManaging

    public init(
        repository: any AgentCatalogManaging,
        catalog: any LabCatalogRepository,
        definitions: any CodexAgentDefinitionManaging
    ) {
        self.repository = repository
        self.catalog = catalog
        self.definitions = definitions
    }

    public func callAsFunction(id: AgentID) async throws -> AgentProfile {
        let snapshot = try await catalog.snapshot()
        guard let current = snapshot.agents.first(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAgent(id)
        }
        if current.codexRegistrationKey != nil { return current }
        let project = try project(for: current.scope, in: snapshot)
        let migratedProject = project?.migratingLegacyMountIdentity()
        let authorizedProject = migratedProject ?? project
        let projectRootURL = authorizedProject?.rootURL
        let published: AgentProfile
        let createdDefinition: Bool
        let createdRegistration: Bool
        if current.sourceURL == nil {
            let draft = AgentDefinitionDraft(
                name: current.name,
                summary: current.summary,
                instructions: current.instructions ?? current.summary,
                capabilities: current.capabilities,
                scope: current.scope,
                toolPreset: current.toolPreset
            )
            published = try await definitions.createDefinition(
                from: draft,
                projectRootURL: projectRootURL,
                expectedProjectIdentity: authorizedProject?.fileSystemIdentity
            )
            createdDefinition = true
            createdRegistration = true
        } else {
            let activation = try await definitions.activateDefinition(
                for: current,
                projectRootURL: projectRootURL
            )
            published = activation.agent
            createdDefinition = false
            createdRegistration = activation.createdRegistration
        }
        let preserved = AgentProfile(
            id: published.id,
            name: published.name,
            summary: published.summary,
            instructions: published.instructions,
            capabilities: published.capabilities,
            scope: published.scope,
            sourceURL: published.sourceURL,
            toolPreset: published.toolPreset,
            reviewedDefinitionDigest: published.reviewedDefinitionDigest,
            definitionReviewProvenance: published.definitionReviewProvenance,
            codexRegistrationKey: published.codexRegistrationKey,
            isEnabled: current.isEnabled
        )
        do {
            if let migratedProject {
                try await catalog.register(projects: [migratedProject], agents: [])
            }
            try await repository.replaceAgent(id: current.id, with: preserved)
        } catch {
            if createdDefinition {
                try? await definitions.undoCreatedDefinition(
                    published,
                    expectedProjectIdentity: authorizedProject?.fileSystemIdentity
                )
            } else if createdRegistration {
                try? await definitions.undoActivatedDefinition(published)
            }
            throw error
        }
        return preserved
    }

    private func project(for scope: AgentScope, in snapshot: LabSnapshot) throws -> LabProject? {
        guard case let .project(projectID) = scope else { return nil }
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw GobyApplicationError.unknownProject(projectID)
        }
        return project
    }
}

private extension LabProject {
    func migratingLegacyMountIdentity() -> LabProject? {
        guard let migratedIdentity = fileSystemIdentity?.migratedMountStableIdentity(at: rootURL) else {
            return nil
        }
        return LabProject(
            id: id,
            name: name,
            rootURL: rootURL,
            platforms: platforms,
            frameworks: frameworks,
            testCommands: testCommands,
            instructionFiles: instructionFiles,
            isGitRepository: isGitRepository,
            registeredAt: registeredAt,
            fileSystemIdentity: migratedIdentity,
            template: template
        )
    }
}

public struct DeleteAgentUseCase: Sendable {
    private let repository: any AgentCatalogManaging
    private let catalog: any LabCatalogRepository
    private let definitions: any CodexAgentDefinitionManaging
    private let history: any DeletedAgentHistoryRepository

    public init(
        repository: any AgentCatalogManaging,
        catalog: any LabCatalogRepository,
        definitions: any CodexAgentDefinitionManaging,
        history: any DeletedAgentHistoryRepository
    ) {
        self.repository = repository
        self.catalog = catalog
        self.definitions = definitions
        self.history = history
    }

    public func callAsFunction(id: AgentID) async throws -> DeletedAgentRecord {
        let snapshot = try await catalog.snapshot()
        guard let agent = snapshot.agents.first(where: { $0.id == id }) else {
            throw GobyApplicationError.unknownAgent(id)
        }
        let projectRootURL = try projectRoot(for: agent.scope, in: snapshot)
        let record = try await definitions.archiveDefinition(for: agent, projectRootURL: projectRootURL)
        do {
            try await repository.removeAgent(id: id)
            try await history.saveLastDeletedAgent(record)
        } catch {
            try? await definitions.restoreDefinition(from: record)
            try? await repository.saveAgent(agent)
            throw error
        }
        return record
    }

    private func projectRoot(for scope: AgentScope, in snapshot: LabSnapshot) throws -> URL? {
        guard case let .project(projectID) = scope else { return nil }
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw GobyApplicationError.unknownProject(projectID)
        }
        return project.rootURL
    }
}

public struct LoadDeletedAgentHistoryUseCase: Sendable {
    private let history: any DeletedAgentHistoryRepository

    public init(history: any DeletedAgentHistoryRepository) {
        self.history = history
    }

    public func callAsFunction() async throws -> DeletedAgentRecord? {
        try await history.lastDeletedAgent()
    }
}

public struct RestoreDeletedAgentUseCase: Sendable {
    private let repository: any AgentCatalogManaging
    private let definitions: any CodexAgentDefinitionManaging
    private let history: any DeletedAgentHistoryRepository

    public init(
        repository: any AgentCatalogManaging,
        definitions: any CodexAgentDefinitionManaging,
        history: any DeletedAgentHistoryRepository
    ) {
        self.repository = repository
        self.definitions = definitions
        self.history = history
    }

    public func callAsFunction() async throws -> AgentProfile? {
        guard let record = try await history.lastDeletedAgent() else { return nil }
        try await definitions.restoreDefinition(from: record)
        do {
            try await repository.saveAgent(record.agent)
            try await history.saveLastDeletedAgent(nil)
        } catch {
            try? await definitions.undoRestoredDefinition(from: record)
            try? await repository.removeAgent(id: record.agent.id)
            throw error
        }
        return record.agent
    }
}

public struct LoadInstructionsUseCase: Sendable {
    private let repository: any InstructionRepository

    public init(repository: any InstructionRepository) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> [InstructionPack] {
        try await repository.allInstructionPacks()
    }
}

public struct SaveInstructionUseCase: Sendable {
    private let repository: any InstructionRepository

    public init(repository: any InstructionRepository) {
        self.repository = repository
    }

    public func callAsFunction(_ pack: InstructionPack) async throws {
        try InstructionCatalogPolicy.validate(pack)
        try await repository.save(pack)
    }
}


public struct ExecuteRunUseCase: Sendable {
    private let orchestrator: any RunOrchestrating

    public init(orchestrator: any RunOrchestrating) {
        self.orchestrator = orchestrator
    }

    public func callAsFunction(runID: RunID) async throws {
        try await orchestrator.execute(runID: runID)
    }
}

public struct ControlRunUseCase: Sendable {
    /// `startNow` starts a request that is waiting for a conflicting one
    /// (Run Anyway).
    public enum Action: Sendable { case pause, resume, cancel, startNow }
    private let orchestrator: any RunOrchestrating

    public init(orchestrator: any RunOrchestrating) {
        self.orchestrator = orchestrator
    }

    public func callAsFunction(runID: RunID, action: Action, modelChange: RunModelChange? = nil) async throws {
        if let modelChange {
            guard case .resume = action else {
                throw GobyApplicationError.invalidRunModelChange("A model change requires a fresh run attempt.")
            }
            try await orchestrator.resume(runID: runID, modelChange: modelChange)
            return
        }
        switch action {
        case .pause: try await orchestrator.pause(runID: runID)
        case .resume: try await orchestrator.resume(runID: runID)
        case .cancel: try await orchestrator.cancel(runID: runID)
        case .startNow: try await orchestrator.startWithoutWaiting(runID: runID)
        }
    }
}

public struct FollowUpRunUseCase: Sendable {
    private let orchestrator: any RunOrchestrating

    public init(orchestrator: any RunOrchestrating) {
        self.orchestrator = orchestrator
    }

    public func callAsFunction(runID: RunID, text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GobyApplicationError.emptyPrompt }
        try await orchestrator.followUp(
            runID: runID,
            text: String(normalized.prefix(32_000))
        )
    }
}

public struct ObserveRunsUseCase: Sendable {
    private let orchestrator: any RunOrchestrating

    public init(orchestrator: any RunOrchestrating) {
        self.orchestrator = orchestrator
    }

    public func callAsFunction() async -> AsyncStream<RunRecord> {
        await orchestrator.updates()
    }
}

public struct ManageProviderApprovalUseCase: Sendable {
    private let orchestrator: any RunOrchestrating

    public init(orchestrator: any RunOrchestrating) {
        self.orchestrator = orchestrator
    }

    public func canRemember(_ request: ProviderApprovalRequest) async -> Bool {
        await orchestrator.canRememberCommand(request)
    }

    public func remembered() async throws -> [RememberedCommandApproval] {
        try await orchestrator.rememberedCommandApprovals()
    }

    public func revoke(_ id: UUID) async throws {
        try await orchestrator.revokeRememberedCommandApproval(id)
    }

    public func setProjectEnabled(_ projectID: ProjectID, enabled: Bool) async throws {
        try await orchestrator.setRememberedApprovalProjectEnabled(projectID, enabled: enabled)
    }

    public func pending() async -> [ProviderApprovalRequest] {
        await orchestrator.pendingApprovals()
    }

    public func respond(
        to approval: ProviderApprovalRequest,
        decision: ProviderApprovalDecision
    ) async throws {
        try await orchestrator.respond(to: approval, decision: decision)
    }
}

@available(*, deprecated, renamed: "ManageProviderApprovalUseCase")
public typealias ManageCodexApprovalUseCase = ManageProviderApprovalUseCase

public struct RecoverInterruptedRunsUseCase: Sendable {
    private let runs: (any RunRepository)?
    private let orchestrator: (any RunOrchestrating)?

    public init(runs: any RunRepository) {
        self.runs = runs
        self.orchestrator = nil
    }

    public init(orchestrator: any RunOrchestrating) {
        self.runs = nil
        self.orchestrator = orchestrator
    }

    @discardableResult
    public func callAsFunction() async throws -> [RunRecord] {
        if let orchestrator {
            return try await orchestrator.recoverInterruptedRuns()
        }
        guard let runs else { return [] }
        let records = try await runs.allRuns()
        var recovered: [RunRecord] = []
        for run in records where run.status == .running || (
            run.status == .needsAttention && run.assignments.contains {
                $0.status == .queued
                    || $0.status == .working
                    || $0.status == .waitingForApproval
            }
        ) {
            let assignments = run.assignments.map { assignment in
                guard assignment.status == .working
                        || assignment.status == .queued
                        || assignment.status == .waitingForApproval else {
                    return assignment
                }
                return AgentAssignment(
                    id: assignment.id,
                    runID: assignment.runID,
                    projectID: assignment.projectID,
                    agentID: assignment.agentID,
                    status: .paused,
                    currentTask: assignment.currentTask,
                    attachments: assignment.attachments,
                    progress: assignment.progress,
                    startedAt: assignment.startedAt,
                    statusReason: "Interrupted when Goby stopped; review and resume when ready.",
                    workingDirectory: assignment.workingDirectory,
                    workingDirectoryIdentity: assignment.workingDirectoryIdentity,
                    codexThreadID: assignment.codexThreadID,
                    codexTurnID: assignment.codexTurnID,
                    providerID: assignment.providerID,
                    providerBindingID: assignment.providerBindingID,
                    model: assignment.model,
                    providerTaskID: assignment.providerTaskID,
                    providerTurnID: assignment.providerTurnID,
                    handoffID: assignment.handoffID,
                    deliveryStageID: assignment.deliveryStageID
                )
            }
            let record = RunRecord(
                id: run.id,
                plan: run.plan,
                status: .needsAttention,
                assignments: assignments,
                helperTasks: run.helperTasks,
                outcome: "Interrupted run recovered safely. No action was replayed automatically.",
                approvalReceipts: run.approvalReceipts,
                instructionSnapshot: run.instructionSnapshot,
                agentSnapshot: run.agentSnapshot,
                providerBindingSnapshot: run.providerBindingSnapshot,
                projectSnapshot: run.projectSnapshot,
                automationExecutionAuthorityDigest: run.automationExecutionAuthorityDigest,
                automaticallyApproveRuntimeRequests: run.automaticallyApproveRuntimeRequests,
                journal: run.journal + [RunJournalEntry(kind: .recovery, message: "Interrupted work recovered and paused without replaying actions.")],
                resourceSnapshot: run.resourceSnapshot,
                activity: run.activity,
                createdAt: run.createdAt,
                updatedAt: .now
            )
            try await runs.save(record)
            recovered.append(record)
        }
        return recovered
    }
}

public struct CheckSystemHealthUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let checker: any SystemHealthChecking

    public init(catalog: any LabCatalogRepository, checker: any SystemHealthChecking) {
        self.catalog = catalog
        self.checker = checker
    }

    public func callAsFunction() async -> SystemHealthSnapshot {
        let projects = (try? await catalog.snapshot().projects) ?? []
        return await checker.check(projects: projects)
    }
}

public struct GenerateDiagnosticsUseCase: Sendable {
    private let exporter: any DiagnosticExporting

    public init(exporter: any DiagnosticExporting) {
        self.exporter = exporter
    }

    public func callAsFunction(
        lab: LabSnapshot,
        runs: [RunRecord],
        health: SystemHealthSnapshot
    ) async throws -> String {
        try await exporter.report(lab: lab, runs: runs, health: health)
    }
}
