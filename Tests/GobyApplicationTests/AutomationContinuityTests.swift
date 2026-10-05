import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct AutomationContinuityTests {
    @Test("Older automation definitions decode without an automatic approval grant")
    func legacyAutomationApprovalDefaultsOff() throws {
        let definition = AutomationDefinition(
            id: "legacy",
            name: "Daily",
            schedule: AutomationSchedule(cadence: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC"),
            actions: [AutomationAction(
                id: "action", instruction: "Inspect",
                target: .project(providerID: .codex, projectID: "project")
            )],
            automaticallyApproveRuntimeRequests: true
        )
        let data = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(AutomationDefinition.self, from: data).automaticallyApproveRuntimeRequests)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "automaticallyApproveRuntimeRequests")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(!(try JSONDecoder().decode(AutomationDefinition.self, from: legacy)).automaticallyApproveRuntimeRequests)
    }

    @Test("Older host sessions do not claim exact automation review support")
    func legacySessionReviewSupport() throws {
        let session = ClientSession(hostID: .init(rawValue: "host"), hostEpoch: .init(rawValue: "epoch"), protocolVersion: .current, revision: .zero, capabilities: [.automations])
        let encoded = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(ClientSession.self, from: encoded).supportsBoundAutomationReviews)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "supportsBoundAutomationReviews")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(!(try JSONDecoder().decode(ClientSession.self, from: legacy)).supportsBoundAutomationReviews)
        let review = GADAutomationOccurrenceReview(
            id: "occurrence",
            reviewBinding: nil,
            authorizationAssertion: nil
        )
        #expect(try JSONDecoder().decode(GADAutomationOccurrenceReview.self, from: JSONEncoder().encode(review)).reviewBinding == nil)
    }

    @Test("Automation state participates in section deltas and round-trips through the projection")
    func projectionDeltaRoundTrip() throws {
        let base = projection(automations: .empty)
        let automation = AutomationDefinition(
            id: "daily",
            name: "Daily research",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "Europe/Nicosia"
            ),
            actions: [AutomationAction(
                id: "research",
                instruction: "Research current changes",
                target: .project(providerID: .codex, projectID: "project")
            )]
        )
        let replacement = projection(automations: AutomationSnapshot(definitions: [automation]))

        let changes = base.changes(replacingWith: replacement)
        #expect(changes == [.automations(replacement.automations)])
        let applied = base.applying(changes, revision: .init(rawValue: 2), generatedAt: replacement.generatedAt)
        #expect(applied.automations == replacement.automations)

        let data = try JSONEncoder().encode(applied)
        #expect(try JSONDecoder().decode(DashboardProjection.self, from: data) == applied)
    }

    @Test("Remote automation projection redacts path and token-shaped text")
    func builderRedactsAutomationInstructions() {
        let action = AutomationAction(
            id: "research",
            instruction: "Inspect /Users/example/private and ghp_abcdefghijklmnopqrstuvwxyz123456",
            target: .project(providerID: .codex, projectID: "project")
        )
        let automation = AutomationDefinition(
            id: "daily",
            name: "Research",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "UTC"
            ),
            actions: [action]
        )
        let built = RemoteProjectionBuilder().build(
            host: host,
            revision: .zero,
            lab: .empty,
            runs: [],
            automations: AutomationSnapshot(definitions: [automation]),
            approvals: [],
            resources: [],
            codexTasks: [],
            account: nil,
            health: SystemHealthSnapshot(checks: []),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let projected = built.automations.definitions.first?.actions.first?.instruction ?? ""
        #expect(!projected.contains("/Users/example/private"))
        #expect(!projected.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        #expect(projected.contains("[redacted"))
    }

    @Test("Remote projection bounds run and occurrence history while prioritizing unfinished work")
    func builderBoundsHistory() {
        let terminalRuns = (0..<260).map { index in
            projectedRun(index: index, status: .completed)
        }
        let activeRun = projectedRun(index: 999, status: .running)
        let terminalOccurrences = (0..<510).map { index in
            AutomationOccurrence(
                id: AutomationOccurrenceID(rawValue: "occurrence-\(index)"),
                automationID: "automation",
                definitionRevision: 1,
                actions: [],
                trigger: .manual,
                scheduledAt: Date(timeIntervalSince1970: TimeInterval(index)),
                status: .completed,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let activeOccurrence = AutomationOccurrence(
            id: "active-occurrence",
            automationID: "automation",
            definitionRevision: 1,
            actions: [],
            trigger: .manual,
            scheduledAt: .now,
            status: .running
        )

        let built = RemoteProjectionBuilder().build(
            host: host,
            revision: .zero,
            lab: .empty,
            runs: terminalRuns + [activeRun],
            automations: AutomationSnapshot(occurrences: terminalOccurrences + [activeOccurrence]),
            approvals: [],
            resources: [],
            codexTasks: [],
            account: nil,
            health: SystemHealthSnapshot(checks: []),
            generatedAt: .now
        )

        #expect(built.runs.count == 250)
        #expect(built.runs.contains(where: { $0.id == activeRun.id }))
        #expect(built.automations.occurrences.count == 500)
        #expect(built.automations.occurrences.contains(where: { $0.id == activeOccurrence.id }))
    }

    @Test("Automation control commands round-trip on protocol 3.5")
    func commandsRoundTrip() throws {
        let definition = AutomationDefinition(
            id: "daily",
            name: "Daily",
            schedule: AutomationSchedule(cadence: .daily(hour: 8, minute: 0), timeZoneIdentifier: "UTC"),
            actions: [AutomationAction(
                id: "action",
                instruction: "Inspect",
                target: .project(providerID: .claude, projectID: "project")
            )]
        )
        let payloads: [GADCommandPayload] = [
            .saveAutomation(.init(automation: definition, expectedRevision: nil)),
            .setAutomationState(.init(id: definition.id, expectedRevision: 1, state: .paused)),
            .deleteAutomation(definition.id, expectedRevision: 1),
            .runAutomationNow(definition.id),
            .runAutomationNowChecked(.init(id: definition.id, expectedRevision: 1)),
            .reviewAndRunAutomationOccurrence(.init(
                id: "occurrence",
                reviewBinding: .init(actionID: "action", planID: "plan"),
                authorizationAssertion: "confirmed",
                selectedResourceIDs: ["research"]
            )),
            .cancelAutomationOccurrence("occurrence"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for payload in payloads {
            #expect(try decoder.decode(GADCommandPayload.self, from: encoder.encode(payload)) == payload)
        }
        let legacyReview = try decoder.decode(
            GADAutomationOccurrenceReview.self,
            from: Data(#"{"id":"occurrence","authorizationAssertion":"confirmed"}"#.utf8)
        )
        #expect(legacyReview.selectedResourceIDs.isEmpty)
        #expect(legacyReview.reviewBinding == nil)
        #expect(GADProtocolVersion.current == .init(major: 3, minor: 13))
    }

    private var host: GADHostProjection {
        GADHostProjection(
            id: HostID(rawValue: "host"),
            displayName: "Mac",
            reachability: .online,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func projection(automations: AutomationSnapshot) -> DashboardProjection {
        DashboardProjection(
            revision: .init(rawValue: 1),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            host: host,
            automations: automations
        )
    }
}

private func projectedRun(index: Int, status: RunStatus) -> RunRecord {
    let id = RunID(rawValue: "run-\(index)")
    let date = Date(timeIntervalSince1970: TimeInterval(index))
    return RunRecord(
        id: id,
        plan: RoutingPlan(
            id: id,
            interpretedGoal: "Projection fixture",
            routes: [],
            risk: .readOnly,
            confidence: 1,
            createdAt: date
        ),
        status: status,
        assignments: [],
        createdAt: date,
        updatedAt: date
    )
}
