import CryptoKit
import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyInfrastructure
import Testing
@testable import GobyCLIKit

@Suite("CLI beta delivery and setup", .timeLimit(.minutes(1)))
struct CLIBetaTests {
    @Test("Standalone Claude setup rejects subscription tokens and whitespace", arguments: ["sk-ant-oat-example", "", "key with spaces"])
    func rejectedCredential(_ value: String) {
        #expect(throws: GobyTerminalError.self) { try GobyCLIEnvironment.validateAPIKey(value) }
    }
    @Test("API key setup never emits the credential, and logout removes only injected CLI copies")
    func credentials() async throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = BetaCredentials()
        let output = OutputRecorder()
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: root.appending(path: "goby"), hostVersion: "fixture")
        let io = GobyTerminalIO(interactive: true, write: { line in output.io.write(line) }, read: { _ in nil }, readSecret: { _ in "sk-ant-api-fixture-secret" })
        #expect(try await GobyCLISetupCommands(configuration: config, options: GobyCLIOptions(["login", "claude"]), io: io, credentials: repository).execute() == 0)
        #expect(await repository.values[.apiKey] == "sk-ant-api-fixture-secret")
        #expect(!output.lines.contains { $0.contains("fixture-secret") })
        #expect(try await GobyCLISetupCommands(configuration: config, options: GobyCLIOptions(["logout", "claude", "--json"]), io: output.io, credentials: repository).execute() == 0)
        #expect(await repository.values.isEmpty)
        #expect(await repository.removals.suffix(2) == [.apiKey, .subscriptionToken])
    }
    @Test("One Claude paste accepts a plan token or an API key, and flags pin the type")
    func claudeCredentialKinds() throws {
        #expect(try GobyCLIEnvironment.validateClaudeCredential("sk-ant-oat01-plan", method: nil) == (.subscriptionToken, "sk-ant-oat01-plan"))
        #expect(try GobyCLIEnvironment.validateClaudeCredential(" sk-ant-api03-key\n", method: nil) == (.apiKey, "sk-ant-api03-key"))
        #expect(try GobyCLIEnvironment.validateClaudeCredential("sk-ant-oat01-plan", method: "plan").0 == .subscriptionToken)
        #expect(throws: GobyTerminalError.self) { try GobyCLIEnvironment.validateClaudeCredential("sk-ant-api03-key", method: "plan") }
        #expect(throws: GobyTerminalError.self) { try GobyCLIEnvironment.validateClaudeCredential("sk-ant-oat01-plan", method: "api-key") }
        #expect(throws: GobyTerminalError.self) { try GobyCLIEnvironment.validateClaudeCredential("two words", method: nil) }
        #expect(throws: GobyTerminalError.self) { try GobyCLIOptions(["status", "--plan"]) }
        #expect(try GobyCLIOptions(["login", "claude", "--plan"]).loginMethod == "plan")
    }
    @Test("Pasting a Claude plan token saves only that credential and never echoes it")
    func claudePlanLogin() async throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = BetaCredentials()
        await repository.saveCredential("sk-ant-api-old-key", for: .claude, kind: .apiKey)
        let output = OutputRecorder()
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: root.appending(path: "goby"), hostVersion: "fixture")
        let io = GobyTerminalIO(interactive: true, write: { line in output.io.write(line) }, read: { _ in nil }, readSecret: { _ in "sk-ant-oat01-plan-fixture" })
        #expect(try await GobyCLISetupCommands(configuration: config, options: GobyCLIOptions(["login", "claude"]), io: io, credentials: repository).execute() == 0)
        #expect(await repository.values[.subscriptionToken] == "sk-ant-oat01-plan-fixture")
        #expect(await repository.values[.apiKey] == nil)
        #expect(!output.lines.contains { $0.contains("plan-fixture") })
        #expect(output.lines.contains { $0.contains("Claude plan token") })
    }
    @Test("The standalone host ignores inherited Claude sign-ins and asks for goby login")
    func claudeSavedCredentialsOnly() async throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let node = root.appending(path: "node"), bridge = root.appending(path: "entry.js")
        let bytes = Data("not an executable".utf8)
        try bytes.write(to: node); try bytes.write(to: bridge)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let adapter = ClaudeAgentSDKRuntimeAdapter(nodeExecutableURL: node, bridgeEntryURL: bridge,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-ambient"],
            credentialRepository: BetaCredentials(), integrityBundleURL: root,
            trustPolicy: StandaloneProviderRuntimeTrustPolicy(manifest: ["node": digest, "entry.js": digest]),
            usesSavedCredentialsOnly: true)
        do { _ = try await adapter.connect(); Issue.record("An inherited Claude sign-in was used") }
        catch let failure as GADCommandFailure { #expect(failure.message.contains("goby login claude")) }
    }
    @Test("Login from a pipe needs a decision before reading secrets")
    func pipedLogin() async throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = BetaCredentials()
        let config = GobyCLIConfiguration(storeDirectory: root, executableURL: root.appending(path: "goby"), hostVersion: "fixture")
        await #expect(throws: GobyTerminalError.self) {
            try await GobyCLISetupCommands(configuration: config, options: GobyCLIOptions(["login", "claude", "--json"]), io: OutputRecorder().io, credentials: repository).execute()
        }
        #expect(await repository.values.isEmpty)
    }
    @Test("Stay-alive is restricted to a foreground service host")
    func stayAlive() throws {
        #expect(try GobyCLIOptions(["host", "run", "--stay-alive"]).stayAlive)
        #expect(throws: GobyTerminalError.self) { try GobyCLIOptions(["status", "--stay-alive"]) }
        #expect(try GobyCLIOptions(["--version", "--json"]).arguments == ["version"])
    }
    @Test("Codex discovery resolves installer aliases but keeps native npm payloads and numeric release order")
    func codexDiscovery() throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "brew")
        let native = prefix.appending(path: "Caskroom/codex/1.0/codex-aarch64-apple-darwin")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("native fixture".utf8).write(to: native)
        let bin = prefix.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "codex"), withDestinationURL: native)
        for version in ["0.9.0", "0.10.0"] {
            try FileManager.default.createDirectory(at: root.appending(path: ".codex/packages/standalone/releases/\(version)"), withIntermediateDirectories: true)
        }
        let paths = StandaloneCodexLocator.installationCandidates(home: root, prefixes: [prefix])
        #expect(paths[0].path.contains("0.10.0"))
        #expect(paths.contains(native.resolvingSymlinksInPath()))
        #expect(paths.contains { $0.path.contains("codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex") })
        #expect(!paths.contains { $0.lastPathComponent == "codex.js" })
    }
    @Test("Standalone Claude refuses a saved subscription token before launching a process")
    func claudeAPIOnly() async throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let node = root.appending(path: "node"), bridge = root.appending(path: "entry.js")
        let bytes = Data("not an executable".utf8)
        try bytes.write(to: node); try bytes.write(to: bridge)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let credentials = BetaCredentials()
        await credentials.saveCredential("sk-ant-oat-subscription", for: .claude, kind: .apiKey)
        let adapter = ClaudeAgentSDKRuntimeAdapter(nodeExecutableURL: node, bridgeEntryURL: bridge,
            credentialRepository: credentials, integrityBundleURL: root,
            trustPolicy: StandaloneProviderRuntimeTrustPolicy(manifest: ["node": digest, "entry.js": digest]), allowsSubscriptionCredentials: false)
        do { _ = try await adapter.connect(); Issue.record("Subscription credentials unexpectedly accepted") }
        catch let failure as GADCommandFailure { #expect(failure.message.contains("Anthropic API key")) }
    }
    @Test("Reviewed commits use the completed run's linked working copy; receipts cannot replay")
    func commit() async throws {
        let fixture = try DeliveryFixture(linked: true)
        defer { fixture.remove() }
        try Data("Reviewed change\n".utf8).write(to: fixture.workspace.appending(path: "README.md"))
        let service = RunDeliveryService()
        let preview = try await service.preview(run: fixture.run, projects: [fixture.project], kind: .commit)
        #expect(preview.summary.contains("README.md"))
        #expect(!preview.summary.contains(fixture.root.path))
        let result = try await service.execute(previewID: preview.id, digest: preview.digest)
        #expect(result.contains("Committed"))
        #expect(try fixture.git(["status", "--porcelain"], at: fixture.workspace).isEmpty)
        #expect(try String(contentsOf: fixture.project.rootURL.appending(path: "README.md"), encoding: .utf8) == "Original\n")
        await #expect(throws: GADCommandFailure.self) { try await service.execute(previewID: preview.id, digest: preview.digest) }
    }
    @Test("Delivery binds changed files, untracked bytes, HEAD, index and remote", arguments: ["tracked", "untracked", "head", "index", "remote"])
    func changedReview(_ mutation: String) async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.remove() }
        try Data("Original untracked\n".utf8).write(to: fixture.workspace.appending(path: "new.txt"))
        let service = RunDeliveryService()
        let kind: GADRunDeliveryKind = mutation == "remote" ? .push : .commit
        let preview = try await service.preview(run: fixture.run, projects: [fixture.project], kind: kind)
        switch mutation {
        case "tracked": try Data("Changed\n".utf8).write(to: fixture.workspace.appending(path: "README.md"))
        case "untracked": try Data("Changed\n".utf8).write(to: fixture.workspace.appending(path: "new.txt"))
        case "head": _ = try fixture.git(["commit", "--allow-empty", "-qm", "Other change"])
        case "index": _ = try fixture.git(["add", "new.txt"])
        case "remote": _ = try fixture.git(["remote", "set-url", "origin", fixture.root.appending(path: "different.git").path])
        default: break
        }
        await #expect(throws: GADCommandFailure.self) { try await service.execute(previewID: preview.id, digest: preview.digest) }
        #expect(try fixture.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines) != "Goby change")
    }
    @Test("A separate push review delivers only its named branch to a local fixture remote")
    func push() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.remove() }
        let service = RunDeliveryService()
        let preview = try await service.preview(run: fixture.run, projects: [fixture.project], kind: .push)
        #expect(preview.remote == "origin")
        #expect(preview.branch == "main")
        #expect(try await service.execute(previewID: preview.id, digest: preview.digest).contains("Pushed main to origin"))
        #expect(try fixture.git(["--git-dir", fixture.remote.path, "rev-parse", "refs/heads/main"]) == fixture.git(["rev-parse", "HEAD"]))
    }
    @Test("A bad digest cannot mutate or later reuse the same preview")
    func wrongDigest() async throws {
        let fixture = try DeliveryFixture(); defer { fixture.remove() }
        let service = RunDeliveryService()
        let preview = try await service.preview(run: fixture.run, projects: [fixture.project], kind: .commit)
        await #expect(throws: GADCommandFailure.self) { try await service.execute(previewID: preview.id, digest: "wrong") }
        await #expect(throws: GADCommandFailure.self) { try await service.execute(previewID: preview.id, digest: preview.digest) }
    }
    @Test("Manifest validation handles canonical system-temp directory URLs and trailing slashes")
    func systemTempManifest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-manifest-" + UUID().uuidString, directoryHint: .isDirectory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("pinned bytes".utf8)
        let entry = root.appending(path: "entry.js")
        try bytes.write(to: entry)
        let nested = root.appending(path: "Helper.app/Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: nested)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try StandaloneProviderRuntimeTrustPolicy(manifest: ["entry.js": digest, "Helper.app/Contents/_CodeSignature/CodeResources": digest]).validateProviderRuntime(bundleURL: root, runtimeURLs: [entry])
    }
    @Test("Distribution generation rejects symlinks and binds every runtime file")
    func generatedManifest() throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("pinned bytes".utf8).write(to: runtime.appending(path: "entry.js"))
        let script = repositoryRoot.appending(path: "Scripts/generate-cli-manifest.py")
        let arguments = [script.path, runtime.path, root.appending(path: "generated.swift").path, root.appending(path: "manifest.json").path, "--version", "0.2.0-beta.1", "--commit", String(repeating: "a", count: 40)]
        #expect(try tool("/usr/bin/python3", arguments) == 0)
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        #expect(manifest.count == 1)
        try StandaloneProviderRuntimeTrustPolicy(manifest: manifest).validateProviderRuntime(bundleURL: runtime, runtimeURLs: [runtime.appending(path: "entry.js")])
        try FileManager.default.createSymbolicLink(at: runtime.appending(path: "link.js"), withDestinationURL: runtime.appending(path: "entry.js"))
        #expect(try tool("/usr/bin/python3", arguments) != 0)
    }
    @Test("Formula rendering requires a real digest, and shell artifacts parse")
    func packaging() throws {
        let root = try socketRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let script = repositoryRoot.appending(path: "Scripts/render-cli-formula.py")
        let template = repositoryRoot.appending(path: "Packaging/CLI/homebrew-goby/Formula/goby.rb.in")
        let formula = root.appending(path: "goby.rb")
        #expect(try tool("/usr/bin/python3", [script.path, template.path, formula.path, "0.2.0-beta.1", String(repeating: "b", count: 64)]) == 0)
        #expect(try tool("/usr/bin/ruby", ["-c", formula.path]) == 0)
        #expect(try tool("/usr/bin/python3", [script.path, template.path, formula.path, "0.2.0-beta.1", "placeholder"]) != 0)
        #expect(try tool("/bin/zsh", ["-n", repositoryRoot.appending(path: "Scripts/release-cli.sh").path]) == 0)
        #expect(try tool("/bin/bash", ["-n", repositoryRoot.appending(path: "Packaging/CLI/completions/goby.bash").path]) == 0)
        #expect(try tool("/bin/zsh", ["-n", repositoryRoot.appending(path: "Packaging/CLI/completions/_goby").path]) == 0)
    }
}

private actor BetaCredentials: ProviderCredentialRepository {
    private(set) var values: [ProviderCredentialKind: String] = [:]
    private(set) var removals: [ProviderCredentialKind] = []
    func credential(for providerID: AgentProviderID, kind: ProviderCredentialKind) -> String? { values[kind] }
    func saveCredential(_ credential: String, for providerID: AgentProviderID, kind: ProviderCredentialKind) { values[kind] = credential }
    func removeCredential(for providerID: AgentProviderID, kind: ProviderCredentialKind) { values[kind] = nil; removals.append(kind) }
}
private var repositoryRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
private func tool(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
private struct DeliveryFixture {
    let root: URL
    let workspace: URL
    let remote: URL
    let project: LabProject
    let run: RunRecord
    init(linked: Bool = false) throws {
        root = try socketRoot()
        let source = root.appending(path: "source")
        workspace = linked ? root.appending(path: "worktree") : source
        remote = root.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Original\n".utf8).write(to: source.appending(path: "README.md"))
        func git(_ args: [String]) throws {
            guard try tool("/usr/bin/git", ["-C", source.path] + args) == 0 else { throw GobyTerminalError("Git fixture failed.") }
        }
        try git(["init", "-qb", "main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["add", "README.md"])
        try git(["-c", "commit.gpgSign=false", "commit", "-qm", "Original"])
        #expect(try tool("/usr/bin/git", ["init", "--bare", "-q", remote.path]) == 0)
        try git(["remote", "add", "origin", remote.path])
        if linked { try git(["worktree", "add", "-qb", "reviewed", workspace.path]) }
        project = LabProject(id: "project", name: "Fixture", rootURL: source, platforms: [], isGitRepository: true)
        let id = RunID(rawValue: "verified-run")
        let plan = RoutingPlan(id: id, interpretedGoal: "Verified change", routes: [], risk: .readOnly, confidence: 1)
        run = RunRecord(id: id, plan: plan, status: .completed, assignments: [.init(runID: id, projectID: project.id, agentID: "agent",
            status: .completed, currentTask: "Verified", workingDirectory: workspace, workingDirectoryIdentity: GADFileSystemIdentity.capture(workspace))])
    }
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", (directory ?? workspace).path] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GobyTerminalError("Git fixture failed.") }
        return String(decoding: data, as: UTF8.self)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
