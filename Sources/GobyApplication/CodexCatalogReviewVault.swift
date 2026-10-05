import Foundation
import GobyDomain

/// Keeps short-lived Codex discovery state isolated per paired device and
/// compares selected candidates with a fresh host discovery before preview and
/// commit. Local paths and definition content remain inside the host process.
public actor GADCodexCatalogReviewVault {
    private struct Entry: Sendable {
        let plan: CodexCatalogSyncPlan
        let expiresAt: Date
    }

    private var entries: [DeviceID: Entry] = [:]

    public init() {}

    public func issue(
        _ plan: CodexCatalogSyncPlan,
        deviceID: DeviceID,
        expiresAt: Date
    ) {
        entries[deviceID] = Entry(plan: plan, expiresAt: expiresAt)
    }

    public func validate(
        projectIDs: [ProjectID],
        agentIDs: [AgentID],
        against current: CodexCatalogSyncPlan,
        registeredProjectIDs: Set<ProjectID>,
        deviceID: DeviceID,
        now: Date = .now
    ) throws -> (projectIDs: Set<ProjectID>, agentIDs: Set<AgentID>) {
        let selectedProjects = Set(projectIDs)
        let selectedAgents = Set(agentIDs)
        guard selectedProjects.count == projectIDs.count,
              selectedAgents.count == agentIDs.count,
              !selectedProjects.isEmpty || !selectedAgents.isEmpty else {
            throw GADCommandFailure(
                .rejectedPolicy,
                "Select each available Codex catalog change at most once."
            )
        }
        guard let review = entries[deviceID], review.expiresAt >= now else {
            entries.removeValue(forKey: deviceID)
            throw GADCommandFailure(
                .rejectedExpired,
                "This Codex discovery expired. Discover and review it again."
            )
        }

        let reviewedProjects = Dictionary(uniqueKeysWithValues: review.plan.projects.map { ($0.id, $0) })
        let reviewedAgents = Dictionary(uniqueKeysWithValues: review.plan.agents.candidates.compactMap { candidate in
            candidate.profile.sourceURL == nil ? (candidate.id, candidate) : nil
        })
        guard selectedProjects.allSatisfy({ reviewedProjects[$0] != nil }),
              selectedAgents.allSatisfy({ reviewedAgents[$0] != nil }) else {
            throw GADCommandFailure(
                .rejectedStale,
                "The selected Codex changes were not part of this device's review."
            )
        }

        let currentProjects = Dictionary(uniqueKeysWithValues: current.projects.map { ($0.id, $0) })
        let currentAgents = Dictionary(uniqueKeysWithValues: current.agents.candidates.compactMap { candidate in
            candidate.profile.sourceURL == nil ? (candidate.id, candidate) : nil
        })
        guard selectedProjects.allSatisfy({ currentProjects[$0] == reviewedProjects[$0] }),
              selectedAgents.allSatisfy({ currentAgents[$0] == reviewedAgents[$0] }) else {
            entries.removeValue(forKey: deviceID)
            throw GADCommandFailure(
                .rejectedStale,
                "A selected Codex project or inferred role changed after mobile review. Discover and review it again."
            )
        }

        let allowedProjects = registeredProjectIDs.union(selectedProjects)
        guard selectedAgents.compactMap({ currentAgents[$0] }).allSatisfy({ candidate in
            switch candidate.profile.scope {
            case .global, .union: true
            case let .project(projectID): allowedProjects.contains(projectID)
            }
        }) else {
            throw GADCommandFailure(
                .rejectedPolicy,
                "Select the project required by each project-scoped agent."
            )
        }

        entries[deviceID] = Entry(plan: current, expiresAt: review.expiresAt)
        return (selectedProjects, selectedAgents)
    }

    public func remove(deviceID: DeviceID) {
        entries.removeValue(forKey: deviceID)
    }
}
