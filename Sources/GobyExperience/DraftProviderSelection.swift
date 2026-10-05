import GobyApplication
import GobyDomain

public extension GADDraftProjection {
    /// Device-local provider selection keeps project scope but never carries an
    /// exact binding or model from a different provider. This is a proposed
    /// routing context; the canonical draft changes only after a host save.
    func selectingProvider(_ providerID: AgentProviderID) -> Self {
        .init(
            revision: revision,
            text: text,
            attachments: attachments,
            providerID: providerID,
            model: self.providerID == providerID ? model : nil,
            platform: platform,
            projectIDs: self.providerID == providerID ? projectIDs
                : Set(projectIDs).union(agentTargets.map(\.projectID)).sorted { $0.rawValue < $1.rawValue },
            agentTargets: agentTargets.filter { $0.providerID == providerID },
            groupID: groupID
        )
    }
}
