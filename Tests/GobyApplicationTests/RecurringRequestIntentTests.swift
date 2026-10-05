import Testing
@testable import GobyApplication

@Suite("Recurring request intent")
struct RecurringRequestIntentTests {
    @Test("Recognizes recurring requests, including the common misspelling")
    func recognizesRecurrence() {
        #expect(RecurringRequestIntent.requestsSchedule("make a recurring self improvement run"))
        #expect(RecurringRequestIntent.requestsSchedule("make a recuring self improvement run"))
        #expect(RecurringRequestIntent.requestsSchedule("Run a periodic UI audit"))
    }

    @Test("Leaves one-time improvements in the regular plan flow")
    func leavesOneTimeWorkAlone() {
        #expect(!RecurringRequestIntent.requestsSchedule("Improve the iOS UI once"))
        #expect(!RecurringRequestIntent.requestsSchedule("Review the dashboard and report findings"))
    }
}
