import Dispatch
import Foundation
import GobyCLIKit
import GobyHostCore
import GobyDomain
import GobyApplication
import GobyInfrastructure

@main
enum GobyCLIHostFixture {
    static func main() {
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count == 2, let executable = Bundle.main.executableURL else { exit(1) }
                let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                let defaultsName = "com.goby.cli.spike.signal.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: defaultsName) else { exit(1) }
                defer { defaults.removePersistentDomain(forName: defaultsName) }
#if DEBUG
                let authenticator: (any GADAutomationDocumentAuthenticating)? = UITestFileAutomationDocumentAuthenticator(directoryURL: root)
#else
                let authenticator: (any GADAutomationDocumentAuthenticating)? = nil
#endif
                let runtime = try GADFreshStandaloneRuntime(storeDirectory: root, notifier: SilentNotifier(),
                    keychainNamespace: .spike, localDefaults: defaults,
                    identifierAliasCodec: RemoteIdentifierAliasCodec(keyData: Data(repeating: 3, count: 32)), automationAuthenticator: authenticator)
                let configuration = GobyCLIConfiguration(storeDirectory: root, executableURL: executable,
                                                        hostVersion: "signal-fixture")
                try await GobyCLIHostService(configuration: configuration, runtime: runtime).run()
                exit(0)
            } catch { exit(1) }
        }
        dispatchMain()
    }
}
private actor SilentNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {}
    func notify(for occurrence: AutomationOccurrence) async {}
}
