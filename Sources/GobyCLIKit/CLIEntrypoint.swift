import Darwin
import Dispatch
import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyExperience
import CryptoKit
import GobyInfrastructure

public enum GobyCLIEntrypoint {
    public static let help = """
    goby "<request>"              review scope → run → consolidated result
    goby                         interactive session with Goby (type /help inside)
    goby run <plan> [--yes]       approve the displayed plan
    goby status | home | projects | add [path]
    goby map | agents [project] | runs [project] | show [run]
    goby providers | models [provider] | branches [project]
    goby instructions | resources | groups | handoffs | health
    goby watch [run] | result <run> | diff <run> | log <run>
    goby approve <id> [--yes] | deny <id>
    goby pause [run] | resume [run] | cancel [run]
    goby follow-up <run> "<text>"
    goby host run [--stay-alive] | host status | host stop
    goby doctor | logout <provider>
    goby login claude [--plan|--api-key]    paste a Claude plan token or API key
    goby login codex [--device|--api-key]   reuses an existing Codex login
    goby login copilot [--token]            reuses an existing gh login
    goby diagnostics | ask "<question>" | ask end
    goby commit <run> | push <run> [--yes]
    goby import-agents | use <project-id>... | use cwd
    goby uninstall [--yes] | --version
    goby automations | automation add <name> <HH:MM> "<request>"
    goby automation pause|resume|run|delete|review|cancel <id>

    Options: --json, --verbose, --yes, --provider codex|claude|copilot
    --yes accepts the current command's displayed review. Runtime
    approvals still require goby approve <id> --yes after full disclosure.
    Ctrl-C detaches. Use goby cancel <run> to cancel.
    Exit codes: 0 ok, 1 failed, 2 decision needed, 3 host unavailable, 4 policy rejected.
    """
    @MainActor
    public static func run(arguments: [String]) async -> Int32 {
        let json = arguments.contains("--json")
        do {
            let options = try GobyCLIOptions(arguments)
            if options.arguments == ["version"] {
                try printValue(type: "version", value: GobyCLIEnvironment.version, json: options.json)
                return 0
            }
            if options.arguments == ["help"] {
                try printValue(type: "help", value: help, json: options.json)
                return 0
            }
            guard let executable = Bundle.main.executableURL,
                  let identity = GADFileSystemIdentity.contentSHA256(at: executable, maximumBytes: 256 * 1_024 * 1_024) else {
                throw GobyTerminalError("The CLI could not identify its executable.", code: 3)
            }
            let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let directory = repositoryDirectory(from: currentDirectory)
            let store = options.storePath.map { URL(fileURLWithPath: $0, relativeTo: currentDirectory) }
                ?? GADHostComposition.cliStoreDirectory()
            let configuration = GobyCLIConfiguration(storeDirectory: store, executableURL: executable,
                                                     hostVersion: "\(GobyCLIEnvironment.version)-\(identity.prefix(16))", idleTimeout: options.stayAlive ? .infinity : 300)
            try validateStoreNamespace(configuration.storeDirectory, appStore: GADHostComposition.storeDirectory())
            if options.arguments == ["host", "run"] {
                let namespace = GobyCLIEnvironment.keychainNamespace(store: configuration.storeDirectory)
                let scope = SHA256.hash(data: Data(configuration.storeDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined()
                let isAlternateStore = namespace.providerCredentials != GADHostKeychainNamespace.cli.providerCredentials
                let runtime = try GADFreshStandaloneRuntime(storeDirectory: configuration.storeDirectory,
                                                            notifier: GobyCLISilentNotifier(), keychainNamespace: namespace,
                                                            localDefaults: UserDefaults(suiteName: isAlternateStore ? "com.goby.cli.store.\(scope)" : "com.goby.cli"))
                let service = GobyCLIHostService(configuration: configuration, runtime: runtime)
                try await service.run()
                return 0
            }
            if ["doctor", "login", "logout", "uninstall"].contains(options.arguments.first ?? "") {
                return try await GobyCLISetupCommands(configuration: configuration, options: options, io: .standard()).execute()
            }
            signal(SIGINT, SIG_IGN)
            // Ctrl-C detaches; it never cancels host work. Inside an interactive
            // session it returns to Goby's prompt instead of leaving.
            let router = GobyInterruptRouter()
            let detach = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            detach.setEventHandler {
                Task { @MainActor in
                    let outcome = await router.workflow?.interrupt() ?? .detach
                    if outcome == .handled { return }
                    if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
                    if json {
                        FileHandle.standardOutput.write(Data("{\"data\":\"Detached; the host keeps running.\",\"schemaVersion\":1,\"type\":\"detached\"}\n".utf8))
                    } else if case let .leave(farewell) = outcome {
                        FileHandle.standardOutput.write(Data(("\n" + farewell + "\n").utf8))
                    } else {
                        FileHandle.standardError.write(Data("\nDetached; the host keeps running. Use goby watch or goby cancel.\n".utf8))
                    }
                    exit(0)
                }
            }
            detach.resume()
            defer { detach.cancel() }
            let transport: GobyUnixSocketTransport
            if options.arguments.first == "host" {
                // Inspection or stop should report an absent host, not start one.
                transport = GobyUnixSocketTransport(socketURL: configuration.socketURL)
            } else {
                transport = try await GobyLazyHostConnection(configuration: configuration).connect()
            }
            let workflow = GobyTerminalWorkflow(transport: transport, options: options, directory: directory,
                                                io: .standard(), preferences: try GobyCLIProjectPreferences(store: configuration.storeDirectory))
            router.workflow = workflow
            return await workflow.execute()
        } catch {
            let code = GobyCLIExitCode.forError(error)
            if json {
                try? printValue(type: "error", value: EntryError(message: error.localizedDescription, exitCode: code), json: true)
            } else {
                FileHandle.standardError.write(Data((WorkflowTextFormatter.terminalSafe(error.localizedDescription) + "\n").utf8))
            }
            return code
        }
    }
    private static func printValue<T: Codable & Sendable>(type: String, value: T, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(GobyCLIOutput(type: type, data: value))
            FileHandle.standardOutput.write(data + Data([10]))
        } else {
            FileHandle.standardOutput.write(Data((String(describing: value) + "\n").utf8))
        }
    }

    public static func repositoryDirectory(from current: URL) -> URL {
        var root = current
        while root.path != "/" {
            var info = stat()
            let marker = root.appending(path: ".git")
            if lstat(marker.path, &info) == 0,
               info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG { return root }
            root.deleteLastPathComponent()
        }
        return current
    }

    public static func validateStoreNamespace(_ store: URL, appStore: URL) throws {
        let path = GobySocketIO.canonicalLocation(store).path
        let appPath = GobySocketIO.canonicalLocation(appStore).path
        guard path != appPath, !path.hasPrefix(appPath + "/") else {
            throw GobyTerminalError("The standalone CLI cannot open the app's store. Use the separate CLI store.", code: 4)
        }
    }
}

@MainActor
private final class GobyInterruptRouter {
    var workflow: GobyTerminalWorkflow?
}

private struct EntryError: Codable, Sendable { let message: String; let exitCode: Int32 }
private actor GobyCLISilentNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {}
    func notify(for occurrence: AutomationOccurrence) async {}
}
