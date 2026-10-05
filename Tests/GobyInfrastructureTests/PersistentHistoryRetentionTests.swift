import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

@Suite("Persistent history retention", .serialized)
struct PersistentHistoryRetentionTests {
    @Test("Run history keeps unfinished work and newest terminal records within its cap")
    func runRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-run-retention-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            maximumStoredRuns: 2,
            maximumActiveRuns: 1
        )

        try await store.save(run(id: "terminal-1", status: .completed, timestamp: 1))
        try await store.save(run(id: "terminal-2", status: .failed, timestamp: 2))
        try await store.save(run(id: "terminal-3", status: .cancelled, timestamp: 3))
        #expect(try await store.allRuns().map(\.id) == ["terminal-3", "terminal-2"])

        try await store.save(run(id: "active-1", status: .ready, timestamp: 4))
        let retained = try await store.allRuns()
        #expect(Set(retained.map(\.id)) == Set(["active-1", "terminal-3"]))
        await #expect(throws: (any Error).self) {
            try await store.save(self.run(id: "active-2", status: .running, timestamp: 5))
        }
    }

    @Test("Automation history keeps unfinished work and newest terminal occurrences within its cap")
    func automationRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-automation-retention-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            maximumStoredOccurrences: 2,
            maximumActiveOccurrences: 1,
            automationAuthenticator: TestAutomationDocumentAuthenticator()
        )

        try await store.saveAutomationOccurrence(occurrence(id: "terminal-1", status: .completed, timestamp: 1), replacing: nil)
        try await store.saveAutomationOccurrence(occurrence(id: "terminal-2", status: .failed, timestamp: 2), replacing: nil)
        try await store.saveAutomationOccurrence(occurrence(id: "terminal-3", status: .cancelled, timestamp: 3), replacing: nil)
        #expect(try await store.automationSnapshot().occurrences.map(\.id) == ["terminal-3", "terminal-2"])

        try await store.saveAutomationOccurrence(occurrence(id: "active-1", status: .running, timestamp: 4), replacing: nil)
        let retained = try await store.automationSnapshot().occurrences
        #expect(Set(retained.map(\.id)) == Set(["active-1", "terminal-3"]))
        await #expect(throws: (any Error).self) {
            try await store.saveAutomationOccurrence(
                self.occurrence(id: "active-2", status: .queued, timestamp: 5),
                replacing: nil
            )
        }
    }

    private func run(id: RunID, status: RunStatus, timestamp: TimeInterval) -> RunRecord {
        let date = Date(timeIntervalSince1970: timestamp)
        return RunRecord(
            id: id,
            plan: RoutingPlan(
                id: id,
                interpretedGoal: "Retention fixture",
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

    private func occurrence(
        id: AutomationOccurrenceID,
        status: AutomationOccurrenceStatus,
        timestamp: TimeInterval
    ) -> AutomationOccurrence {
        let date = Date(timeIntervalSince1970: timestamp)
        return AutomationOccurrence(
            id: id,
            automationID: "automation",
            automationName: "Automation",
            definitionRevision: 1,
            actions: [],
            trigger: .manual,
            scheduledAt: date,
            status: status,
            createdAt: date,
            updatedAt: date
        )
    }
}
