import CryptoKit
import Darwin
import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyInfrastructure
import LocalAuthentication

public enum GobyCLIEnvironment {
    public static func keychainNamespace(store: URL) -> GADHostKeychainNamespace {
        let canonical = GobySocketIO.canonicalLocation(store)
        if canonical == GobySocketIO.canonicalLocation(GADHostComposition.cliStoreDirectory()) { return .cli }
        let digest = SHA256.hash(data: Data(canonical.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return .isolatedCLI(scopeDigest: digest)
    }
    public static func runtimeRoot(executable: URL) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appending(path: "libexec/provider-runtime")
    }
    public static var version: String {
#if GOBY_CLI_DISTRIBUTION
        GobyCLICompiledRuntime.version
#else
        "0.2.0-cli-development"
#endif
    }
    /// Native owner authentication follows the existing host-admin policy.
    @MainActor
    public static func authenticateOwner() async throws -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw GobyTerminalError("Device-owner authentication is unavailable. No agent instructions were imported.", code: 4)
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authorize the reviewed Goby CLI operation.") else {
                throw GobyTerminalError("Device-owner authentication was declined.", code: 4)
            }
        } catch { throw GobyTerminalError("Device-owner authentication was declined or unavailable.", code: 4) }
        return "cli-device-owner-confirmed"
    }
    public static func validateAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8_192, !key.contains(where: { $0.isWhitespace }),
              !ProviderCredentialKind.isClaudeSubscriptionToken(key) else {
            throw GobyTerminalError("Enter an Anthropic API key. Subscription tokens are unavailable in the CLI.", code: 4)
        }
        return key
    }
}

public struct GobyDoctorCheck: Codable, Sendable {
    public let name: String
    public let passed: Bool
    public let action: String
}

/// Setup runs before host connection. Credential bytes remain in the client
/// and the CLI's Keychain; only a changed-state notification reaches the host.
public actor GobyCLISetupCommands {
    private let configuration: GobyCLIConfiguration
    private let options: GobyCLIOptions
    private let io: GobyTerminalIO
    private let credentials: any ProviderCredentialRepository
    public init(configuration: GobyCLIConfiguration, options: GobyCLIOptions, io: GobyTerminalIO,
                credentials: (any ProviderCredentialRepository)? = nil) {
        self.configuration = configuration; self.options = options; self.io = io
        self.credentials = credentials ?? KeychainProviderCredentialStore(
            service: GobyCLIEnvironment.keychainNamespace(store: configuration.storeDirectory).providerCredentials, accessGroup: nil)
    }
    public func execute() async throws -> Int32 {
        switch options.arguments.first {
        case "uninstall":
            guard options.arguments.count == 1 else { throw GobyTerminalError("Usage: goby uninstall [--yes]") }
            try emit("uninstall-review", "CLI data retained", "Uninstall the Homebrew goby package and stop its service. Retain CLI storage and all CLI Keychain items. Data: ~/Library/Application Support/Goby CLI/ (or the selected --store).")
            if !options.yes {
                guard io.interactive, !options.json, let answer = await io.read("Uninstall this CLI package and retain its data? [y/N] "), ["y", "yes"].contains(answer.lowercased()) else { throw GobyTerminalError("Uninstall needs a decision. Review it and rerun with --yes.") }
            }
            let transport = GobyUnixSocketTransport(socketURL: configuration.socketURL)
            if (try? await transport.exchange(.init(operation: .ping))) != nil {
                _ = try await transport.exchange(.init(operation: .localAdministration(.preparePermanentHostShutdown)))
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while ContinuousClock.now < deadline, (try? await transport.exchange(.init(operation: .ping))) != nil { try await Task.sleep(for: .milliseconds(100)) }
                guard (try? await transport.exchange(.init(operation: .ping))) == nil else { throw GobyTerminalError("Finish or cancel active work and approvals before uninstalling. The CLI host is draining.") }
            }
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map({ URL(fileURLWithPath: $0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw GobyTerminalError("Homebrew is unavailable. Remove the installed CLI package manually; retain its store and Keychain items.", code: 4) }
            _ = try await GobySocketIO.offload { try Self.run(brew, arguments: ["services", "stop", "goby"]) }
            let status = try await GobySocketIO.offload { try Self.run(brew, arguments: ["uninstall", "goby"]) }
            guard status == 0 else { throw GobyTerminalError("Homebrew did not finish uninstalling. CLI data remains retained.", code: 1) }
            try emit("uninstalled", "CLI data retained", "Uninstalled Goby CLI. Retained data: ~/Library/Application Support/Goby CLI/ (or the selected --store). Reinstall and use that same store to recover.")
            return 0
        case "doctor":
            guard options.arguments.count == 1 else { throw GobyTerminalError("Usage: goby doctor [--json]") }
            let policy = StandaloneProviderRuntimeTrustPolicy()
            let codex = policy.codexExecutableURL()
            let signed = (try? policy.codexValidator().validate(executableURL: codex)) != nil
            let root = GobyCLIEnvironment.runtimeRoot(executable: configuration.executableURL)
            let node = root.appending(path: "ClaudeAgentSDKBridge/bin/node")
            let bridge = root.appending(path: "ClaudeAgentSDKBridge/index.js")
            let runtime = (try? policy.validateProviderRuntime(bundleURL: root, runtimeURLs: [node, bridge])) != nil
            let check = [GobyDoctorCheck(name: "macOS 26+", passed: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26, action: "Use macOS 26 or later."),
                .init(name: "Signed Codex", passed: signed, action: "Install Codex: brew install --cask codex; then codex login. The installed executable must pass the OpenAI signature check."),
                .init(name: "Pinned provider runtime", passed: runtime, action: "Install the signed Goby CLI release to enable Claude and Copilot."),
                .init(name: "CLI namespace", passed: true, action: "The CLI has separate storage and login-Keychain items."),
                .init(name: "Provider terms", passed: false, action: "Claude uses API keys only. ADR-024 question 1 remains a friends-beta release gate.")]
            try emit("doctor", check, check.map { "\($0.passed ? "✓" : "!") \($0.name) · \($0.action)" }.joined(separator: "\n"))
            return runtime ? 0 : 4
        case "logout":
            let provider = try providerArgument()
            for kind in ProviderCredentialKind.allCases { try await credentials.removeCredential(for: provider, kind: kind) }
            await notify(provider)
            try emit("logout", provider.rawValue, "Removed only Goby's \(provider.displayName) credential copies. The provider's own login remains unchanged.")
            return 0
        case "login":
            let provider = try providerArgument()
            guard io.interactive, !options.json else { throw GobyTerminalError("Provider sign-in needs an interactive terminal. Credentials are never accepted in command arguments.") }
            switch provider {
            case .claude:
                guard let value = await io.readSecret("Anthropic API key (hidden): ") else { throw GobyTerminalError("Sign-in cancelled.") }
                try await credentials.saveCredential(GobyCLIEnvironment.validateAPIKey(value), for: .claude, kind: .apiKey)
            case .codex:
                let policy = StandaloneProviderRuntimeTrustPolicy()
                let executable = policy.codexExecutableURL()
                let validator = policy.codexValidator()
                try validator.validate(executableURL: executable)
                let status = try await GobySocketIO.offload { try Self.run(executable, arguments: ["login"], validator: validator) }
                guard status == 0 else { throw GobyTerminalError("Codex sign-in did not finish.", code: 1) }
            case .githubCopilot:
                // The SDK supports gh's OAuth device credentials. Do not
                // invent a third-party OAuth client registration or dump tokens.
                let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
                guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                    throw GobyTerminalError("Install GitHub CLI: brew install gh. Then rerun goby login copilot.", code: 4)
                }
                let status = try await GobySocketIO.offload { try Self.run(gh, arguments: ["auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "https"]) }
                guard status == 0 else { throw GobyTerminalError("GitHub device sign-in did not finish.", code: 1) }
                let token = try await GobySocketIO.offload { try Self.captureToken(gh) }
                try await credentials.saveCredential(token, for: .githubCopilot, kind: .apiKey)
            default: throw GobyTerminalError("Choose codex, claude or copilot.", code: 4)
            }
            await notify(provider)
            try emit("login", provider.rawValue, "Provider sign-in completed.")
            return 0
        default: throw GobyTerminalError("Unknown setup command.")
        }
    }
    private func providerArgument() throws -> AgentProviderID {
        guard options.arguments.count == 2 else { throw GobyTerminalError("Usage: goby login|logout codex|claude|copilot") }
        let provider = options.arguments[1] == "copilot" ? AgentProviderID.githubCopilot : AgentProviderID(rawValue: options.arguments[1])
        guard AgentProviderID.builtIn.contains(provider) else { throw GobyTerminalError("Choose codex, claude or copilot.", code: 4) }
        return provider
    }
    private func notify(_ provider: AgentProviderID) async {
        _ = try? await GobyUnixSocketTransport(socketURL: configuration.socketURL).exchange(.init(operation: .localAdministration(.providerCredentialChanged(providerID: provider))))
    }
    private func emit<T: Codable & Sendable>(_ kind: String, _ value: T, _ text: String) throws {
        if options.json { io.write(String(decoding: try JSONEncoder().encode(GobyCLIOutput(type: kind, data: value)), as: UTF8.self)) }
        else { io.write(text) }
    }
    private static func run(_ executable: URL, arguments: [String], validator: (any CodexRuntimeValidating)? = nil) throws -> Int32 {
        try validator?.validate(executableURL: executable)
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        do { try validator?.validateRunningProcess(processIdentifier: process.processIdentifier, executableURL: executable) }
        catch { process.terminate(); process.waitUntilExit(); throw error }
        process.waitUntilExit()
        return process.terminationStatus
    }
    private static func captureToken(_ gh: URL) throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = gh; process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 8_193 - data.count), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 8_192 { process.terminate(); process.waitUntilExit(); throw GobyTerminalError("GitHub returned an oversized credential.", code: 4) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 8_192,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw GobyTerminalError("GitHub sign-in completed but Goby's credential copy could not be saved.", code: 1)
        }
        return value
    }
}
