import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyInfrastructure
import Testing

@Suite("Fresh standalone activation")
struct FreshStandaloneRuntimeTests {
    @Test("Fresh CLI activation owns a separate store and shuts down with a checkpoint")
    @MainActor
    func freshActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "goby-fresh-host-\(UUID())", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "com.goby.cli.spike.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(["cli-only-project"], forKey: "GobyTrustedProjectIDs")
        let runtime = try GADFreshStandaloneRuntime(
            storeDirectory: root,
            notifier: SilentStandaloneNotifier(),
            keychainNamespace: .spike,
            localDefaults: defaults,
            identifierAliasCodec: try RemoteIdentifierAliasCodec(keyData: Data(repeating: 7, count: 32)),
            automationAuthenticator: UITestFileAutomationDocumentAuthenticator(directoryURL: root)
        )
        _ = try await runtime.start(hostVersion: "test")
        #expect(runtime.store != nil)
        #expect(runtime.store?.trustedProjectIDs == [ProjectID(rawValue: "cli-only-project")])
        #expect(runtime.handler != nil)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: GADHostOwnershipLease.lockFileName).path))
        try await runtime.stop()
        #expect(runtime.store == nil)
        let restarted = try GADFreshStandaloneRuntime(
            storeDirectory: root,
            notifier: SilentStandaloneNotifier(),
            keychainNamespace: .spike,
            localDefaults: defaults,
            identifierAliasCodec: try RemoteIdentifierAliasCodec(keyData: Data(repeating: 7, count: 32)),
            automationAuthenticator: UITestFileAutomationDocumentAuthenticator(directoryURL: root)
        )
        _ = try await restarted.start(hostVersion: "test")
        #expect(restarted.handler != nil)
        try await restarted.stop()
    }
}

private actor SilentStandaloneNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {}
    func notify(for occurrence: AutomationOccurrence) async {}
}
