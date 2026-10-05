import Foundation
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure
import Testing

struct PersistentOwnershipTests {
    @Test("A retired repository cannot change live state or its backup generations")
    func retiredRepositoryRejectsWrites() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        try await store.saveOperationalContinuity(.init(draftText: "Before"))
        try await store.saveOperationalContinuity(.init(draftText: "Final checkpoint"))
        let checkpoint = try files(in: directory)
        await store.suspendWrites()

        await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
            try await store.saveOperationalContinuity(.init(draftText: "Late save"))
        }
        await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
            try await store.saveMapLayout(.empty)
        }
        let plan = RoutingPlan(interpretedGoal: "Late run", routes: [], risk: .readOnly, confidence: 1)
        await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
            try await store.save(RunRecord(id: plan.id, plan: plan, status: .ready, assignments: []))
        }
        #expect(try files(in: directory) == checkpoint)
        #expect(try await store.loadOperationalContinuity().draftText == "Final checkpoint")

        await store.resumeWrites()
        try await store.saveOperationalContinuity(.init(draftText: "Recovered foreground owner"))
        #expect(try await PersistentStore(directoryURL: directory).loadOperationalContinuity().draftText == "Recovered foreground owner")
    }

    @Test("Suspending ownership drains an automation authentication transaction", .timeLimit(.minutes(1)))
    func suspensionDrainsAsynchronousWrites() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestAutomationDocumentAuthenticator()
        let store = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        await authenticator.suspendNextIssue()
        let definition = AutomationDefinition(
            id: "definition", name: "Retained schedule",
            schedule: .init(cadence: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC"),
            actions: [.init(id: "action", instruction: "Inspect", target: .project(providerID: .codex, projectID: "project"))]
        )
        let write = Task { try await store.saveAutomation(definition, replacing: nil) }
        for _ in 0..<200 {
            if await authenticator.isIssueSuspended { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await authenticator.isIssueSuspended)
        let completion = OwnershipCompletionProbe()
        let suspend = Task {
            await completion.markStarted()
            await store.suspendWrites()
            await completion.markFinished()
        }
        for _ in 0..<200 {
            if await completion.started { break }
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.finished == false)
        await authenticator.releaseIssue()
        try await write.value
        await suspend.value
        #expect(await completion.finished)
        let checkpoint = try files(in: directory)
        await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
            try await store.removeAutomation(id: definition.id, replacing: definition)
        }
        #expect(try files(in: directory) == checkpoint)
        let fresh = PersistentStore(directoryURL: directory, automationAuthenticator: authenticator)
        #expect(try await fresh.automationSnapshot().definitions.map(\.id) == [definition.id])
    }

    @Test("A retired repository cannot repair a corrupt file while another owner validates backup")
    func retiredReadsCannotRepairState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PersistentStore(directoryURL: directory)
        try await writer.saveOperationalContinuity(.init(draftText: "Previous"))
        try await writer.saveOperationalContinuity(.init(draftText: "Latest"))
        let url = directory.appending(path: "operational-continuity.json")
        try Data("corrupt".utf8).write(to: url)
        let retired = PersistentStore(directoryURL: directory)
        await retired.suspendWrites()
        let before = try files(in: directory)
        await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
            _ = try await retired.loadOperationalContinuity()
        }
        #expect(try files(in: directory) == before)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "goby-ownership-fence-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

private actor OwnershipCompletionProbe {
    private(set) var started = false
    private(set) var finished = false
    func markStarted() { started = true }
    func markFinished() { finished = true }
}
