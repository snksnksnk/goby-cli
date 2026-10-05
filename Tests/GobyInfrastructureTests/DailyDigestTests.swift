import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

@Suite("DailyDigestTests")
struct DailyDigestTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Nicosia")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func run(_ id: String, _ status: RunStatus, at updatedAt: Date) -> RunRecord {
        let runID = RunID(rawValue: id)
        return RunRecord(
            id: runID,
            plan: RoutingPlan(id: runID, interpretedGoal: "Goal", routes: [], risk: .readOnly, confidence: 1),
            status: status,
            assignments: [],
            updatedAt: updatedAt
        )
    }

    @Test("Counts today's finished and blocked runs only")
    func countsToday() {
        let runs = [
            run("a", .completed, at: date(3, 10)),
            run("b", .completed, at: date(3, 17)),
            run("c", .failed, at: date(3, 12)),
            run("d", .completed, at: date(2, 12)),
            run("e", .running, at: date(3, 11)),
        ]
        let digest = DailyDigest.make(for: runs, on: date(3, 18), calendar: calendar)
        #expect(digest == DailyDigest(finished: 2, needsAttention: 1))
        #expect(digest?.body == "2 finished · 1 needs attention")
    }

    @Test("A quiet day has no digest")
    func quietDay() {
        let runs = [run("a", .completed, at: date(2, 10)), run("b", .running, at: date(3, 10))]
        #expect(DailyDigest.make(for: runs, on: date(3, 18), calendar: calendar) == nil)
    }

    @Test("Next fire is today at 18:00, or tomorrow once it has passed")
    func nextFire() async {
        let scheduler = DailyDigestScheduler(
            defaultsSuiteName: "goby-digest-test-\(UUID().uuidString)",
            calendar: calendar,
            runs: { [] },
            post: { _ in }
        )
        #expect(await scheduler.secondsUntilNextFire(after: date(3, 17)) == 3_600)
        #expect(await scheduler.secondsUntilNextFire(after: date(3, 19)) == 23 * 3_600)
    }

    @Test("Posts at most once per day")
    func oncePerDay() async {
        let posted = Counter()
        let runs = [run("a", .completed, at: date(3, 10))]
        let scheduler = DailyDigestScheduler(
            defaultsSuiteName: "goby-digest-test-\(UUID().uuidString)",
            calendar: calendar,
            runs: { runs },
            post: { _ in await posted.increment() }
        )
        await scheduler.fire(at: date(3, 18))
        await scheduler.fire(at: date(3, 18, 5))
        #expect(await posted.value == 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
