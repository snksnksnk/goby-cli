import Foundation
import GobyDomain

/// Canonical, local-only work that has not yet become a durable run.
///
/// The Mac app and background host use this checkpoint when transferring the
/// single-writer lease. It is intentionally richer than the sanitized remote
/// projection and must never be sent to a relay as storage or protocol state.
public struct GADOperationalContinuityState: Codable, Equatable, Sendable {
    public let draftText: String
    public let draftAttachments: [PromptAttachment]
    public let providerID: AgentProviderID
    public let model: String?
    public let platform: ProjectPlatform?
    public let projectIDs: Set<ProjectID>
    public let agentTargets: Set<AgentRouteTarget>
    public let groupID: ProjectGroupID?
    public let proposedPlan: RoutingPlan?
    public let selectedResourceIDs: Set<SharedResourceID>

    public init(
        draftText: String = "",
        draftAttachments: [PromptAttachment] = [],
        providerID: AgentProviderID = .codex,
        model: String? = nil,
        platform: ProjectPlatform? = nil,
        projectIDs: Set<ProjectID> = [],
        agentTargets: Set<AgentRouteTarget> = [],
        groupID: ProjectGroupID? = nil,
        proposedPlan: RoutingPlan? = nil,
        selectedResourceIDs: Set<SharedResourceID> = []
    ) {
        self.draftText = draftText
        self.draftAttachments = draftAttachments
        self.providerID = providerID
        self.model = model
        self.platform = platform
        self.projectIDs = projectIDs
        self.agentTargets = agentTargets
        self.groupID = groupID
        self.proposedPlan = proposedPlan
        self.selectedResourceIDs = selectedResourceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case draftText, draftAttachments, providerID, model, platform, projectIDs
        case agentTargets, groupID, proposedPlan, selectedResourceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draftText = try container.decodeIfPresent(String.self, forKey: .draftText) ?? ""
        draftAttachments = try container.decodeIfPresent(
            [PromptAttachment].self,
            forKey: .draftAttachments
        ) ?? []
        providerID = try container.decodeIfPresent(AgentProviderID.self, forKey: .providerID) ?? .codex
        model = try container.decodeIfPresent(String.self, forKey: .model)
        platform = try container.decodeIfPresent(ProjectPlatform.self, forKey: .platform)
        projectIDs = try container.decodeIfPresent(Set<ProjectID>.self, forKey: .projectIDs) ?? []
        agentTargets = try container.decodeIfPresent(
            Set<AgentRouteTarget>.self,
            forKey: .agentTargets
        ) ?? []
        groupID = try container.decodeIfPresent(ProjectGroupID.self, forKey: .groupID)
        proposedPlan = try container.decodeIfPresent(RoutingPlan.self, forKey: .proposedPlan)
        selectedResourceIDs = try container.decodeIfPresent(
            Set<SharedResourceID>.self,
            forKey: .selectedResourceIDs
        ) ?? []
    }

    public static let empty = GADOperationalContinuityState()
}

public protocol GADOperationalContinuityRepository: Sendable {
    func loadOperationalContinuity() async throws -> GADOperationalContinuityState
    func saveOperationalContinuity(_ state: GADOperationalContinuityState) async throws
}
