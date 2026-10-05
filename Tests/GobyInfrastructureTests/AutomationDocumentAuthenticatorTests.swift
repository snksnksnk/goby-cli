import Foundation
import Testing
@testable import GobyInfrastructure

private final class ThreadRecordingAutomationStateIO:
    GADAutomationAuthenticationStateIO,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedData: Data?
    private var mainThreadObservations: [Bool] = []

    func load() throws -> Data? {
        lock.withLock {
            mainThreadObservations.append(Thread.isMainThread)
            return storedData
        }
    }

    func save(_ data: Data) throws {
        lock.withLock {
            mainThreadObservations.append(Thread.isMainThread)
            storedData = data
        }
    }

    func observations() -> [Bool] {
        lock.withLock { mainThreadObservations }
    }
}

@Suite("Automation document authenticator")
struct AutomationDocumentAuthenticatorTests {
    @Test("Runs authenticity state I/O away from the main thread")
    @MainActor
    func stateIORunsAwayFromMainThread() async throws {
        let stateIO = ThreadRecordingAutomationStateIO()
        let authenticator = KeychainAutomationDocumentAuthenticator(stateIO: stateIO)
        let payload = Data("scheduled work".utf8)

        let authentication = try await authenticator.issue(for: payload)
        try await authenticator.commit(authentication, payload: payload)
        let freshness = try await authenticator.verify(authentication, payload: payload)

        #expect(freshness == .current)
        #expect(!stateIO.observations().isEmpty)
        #expect(stateIO.observations().allSatisfy { !$0 })
    }

#if DEBUG
    @Test("Isolated UI-test authenticity state survives a new authenticator instance")
    func isolatedStateSurvivesNewInstance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "goby-ui-authenticator-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("cross-process fixture".utf8)
        let writer = UITestFileAutomationDocumentAuthenticator(directoryURL: directory)

        let authentication = try await writer.issue(for: payload)
        try await writer.commit(authentication, payload: payload)

        let reader = UITestFileAutomationDocumentAuthenticator(directoryURL: directory)
        #expect(try await reader.verify(authentication, payload: payload) == .current)

        let stateURL = directory.appending(
            path: ".goby-ui-test-automation-authenticity.json"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
#endif
}
