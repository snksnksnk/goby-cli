import Foundation
import GobyApplication
import GobyDomain
import GobyInfrastructure
import Testing

@Suite("Operational continuity persistence")
struct OperationalContinuityPersistenceTests {
    @Test("Draft, exact reviewed plan and resource selection survive process recreation")
    func exactStateRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-operational-continuity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectID = ProjectID(rawValue: "project-1")
        let agentID = AgentID(rawValue: "agent-1")
        let resourceID = SharedResourceID(rawValue: "resource-1")
        let route = ProjectRoute(
            projectID: projectID,
            providerID: .codex,
            agentIDs: [agentID],
            reason: "Reviewed on iPhone"
        )
        let plan = RoutingPlan(
            id: RunID(rawValue: "plan-1"),
            interpretedGoal: "Continue the reviewed change",
            routes: [route],
            risk: .medium,
            confidence: 0.91,
            gitOperations: [
                PlannedGitOperation(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    projectID: projectID,
                    kind: .createWorktree
                )
            ],
            warnings: ["Confirm the disclosed scope"],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let expected = GADOperationalContinuityState(
            draftText: "Continue the reviewed change",
            providerID: .codex,
            platform: .iOS,
            projectIDs: [projectID],
            agentTargets: [
                AgentRouteTarget(
                    providerID: .codex,
                    agentID: agentID,
                    projectID: projectID
                )
            ],
            proposedPlan: plan,
            selectedResourceIDs: [resourceID]
        )

        try await PersistentStore(directoryURL: directory).saveOperationalContinuity(expected)
        let restored = try await PersistentStore(directoryURL: directory).loadOperationalContinuity()

        #expect(restored == expected)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "operational-continuity.json").path(percentEncoded: false)
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A missing checkpoint restores as empty state")
    func missingCheckpointIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-operational-continuity-empty-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let restored = try await PersistentStore(directoryURL: directory).loadOperationalContinuity()

        #expect(restored == .empty)
    }

    @Test("Coordinator epoch, revision and journal survive process recreation")
    func coordinatorCheckpointRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-coordinator-checkpoint-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = HostID(rawValue: "host")
        let epoch = HostEpoch(rawValue: "epoch")
        let projection = DashboardProjection(
            revision: StateRevision(rawValue: 4),
            generatedAt: Date(timeIntervalSince1970: 20),
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: Date(timeIntervalSince1970: 20)
            ),
            draft: .init(
                revision: EntityRevision(rawValue: 2),
                text: "Continue from the phone"
            )
        )
        let delta = GADStateDelta(
            hostEpoch: epoch,
            revision: StateRevision(rawValue: 4),
            occurredAt: Date(timeIntervalSince1970: 20),
            originatingCommandID: nil,
            changes: [.draft(projection.draft)]
        )
        let expected = GADCoordinatorCheckpoint(
            hostID: hostID,
            hostEpoch: epoch,
            protocolVersion: .current,
            projection: projection,
            journal: [delta],
            idempotency: [],
            savedAt: Date(timeIntervalSince1970: 20)
        )

        try await PersistentStore(directoryURL: directory).saveCoordinatorCheckpoint(expected)
        let restored = try await PersistentStore(directoryURL: directory)
            .loadCoordinatorCheckpoint(hostID: hostID)

        #expect(restored == expected)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "coordinator-checkpoint.json").path(percentEncoded: false)
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
