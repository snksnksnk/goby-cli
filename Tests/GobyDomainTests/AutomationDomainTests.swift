import Foundation
import Testing
@testable import GobyDomain

struct AutomationDomainTests {
    @Test("Daily schedules retain their named time zone across a daylight-saving change")
    func dailyScheduleHandlesDaylightSavingTime() throws {
        let schedule = AutomationSchedule(
            cadence: .daily(hour: 9, minute: 30),
            timeZoneIdentifier: "Europe/Nicosia"
        )
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-03-28T08:00:00Z"))
        let next = try #require(schedule.nextDate(after: reference))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Nicosia"))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)

        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 29)
        #expect(parts.hour == 9)
        #expect(parts.minute == 30)
    }

    @Test("Agent targets create an exact provider route request")
    func agentTargetCreatesExactRoute() {
        let target = AgentRouteTarget(
            providerID: .claude,
            agentID: "research-agent",
            projectID: "website"
        )

        let request = AutomationTarget.agent(target).routeRequest(for: "Review sources")

        #expect(request.providerID == .claude)
        #expect(request.scope == .projects(["website"]))
        #expect(request.agentTargets == [target])
    }

    @Test("An occurrence keeps an immutable action snapshot")
    func occurrenceKeepsActionSnapshot() {
        let original = AutomationAction(
            id: "first",
            instruction: "Research the change",
            target: .project(providerID: .codex, projectID: "project")
        )
        let occurrence = AutomationOccurrence(
            automationID: "automation",
            definitionRevision: 1,
            actions: [original],
            trigger: .scheduled,
            scheduledAt: .now
        )

        #expect(occurrence.actions == [original])
        #expect(occurrence.currentActionIndex == 0)
        #expect(occurrence.status == .queued)
    }

    @Test("Occurrences written before name snapshots remain decodable")
    func legacyOccurrenceDecodesWithoutName() throws {
        let occurrence = AutomationOccurrence(
            automationID: "automation",
            automationName: "Research",
            definitionRevision: 1,
            actions: [],
            trigger: .manual,
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try JSONEncoder().encode(occurrence)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "automationName")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AutomationOccurrence.self, from: legacy)

        #expect(decoded.automationName == nil)
        #expect(decoded.automationID == occurrence.automationID)
    }
}
