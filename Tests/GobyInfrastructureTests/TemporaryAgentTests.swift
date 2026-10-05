import Foundation
import Testing
@testable import GobyApplication
@testable import GobyDomain
@testable import GobyInfrastructure

@Suite("Temporary agents")
struct TemporaryAgentTests {
    private let project = LabProject(
        id: "pharmacies",
        name: "Pharmacies",
        rootURL: FileManager.default.temporaryDirectory,
        platforms: [.web, .iOS],
        isGitRepository: false
    )

    @Test("The temporary agent's role follows the request")
    func roleFollowsRequest() {
        let growth = TemporaryAgentBlueprint.make(
            goal: "the analytics are terrible. we need to get users asap. make a plan",
            project: project
        )
        #expect(growth.name == "Temporary Growth Strategist")
        #expect(growth.instructions.contains("Pharmacies"))
        #expect(growth.instructions.contains("without modifying project files"))
        #expect(growth.instructions.contains(TemporaryAgentBlueprint.handoffHeading))

        #expect(TemporaryAgentBlueprint.make(goal: "fix the crash on launch", project: project).name
            == "Temporary Debugging Engineer")
        #expect(TemporaryAgentBlueprint.make(goal: "update the iOS widget", project: project).name
            == "Temporary iOS Engineer")
        // Whole-word matching: "build" must not match the "ui" design keyword.
        #expect(TemporaryAgentBlueprint.make(goal: "speed up the build", project: project).name
            == "Temporary Task Specialist")
    }

    @Test("Earlier notes reach the next temporary agent, newest kept when long")
    func continuationNotesAreBounded() {
        let old = "## old\n" + String(repeating: "a", count: TemporaryAgentBlueprint.continuationNotesLimit)
        let blueprint = TemporaryAgentBlueprint.make(
            goal: "continue the growth plan",
            project: project,
            continuationNotes: old + "\n\n## newest entry\nDone: audit"
        )
        #expect(blueprint.instructions.contains("## newest entry"))
        #expect(blueprint.instructions.contains("(Earlier notes omitted.)"))
    }

    @Test("Handoff sections are extracted from the final answer")
    func extractsHandoff() {
        let outcome = "Plan…\n\n## Handoff notes\n- Did: audit\n- Next: GA4"
        #expect(TemporaryAgentBlueprint.handoffSection(in: outcome) == "- Did: audit\n- Next: GA4")
        #expect(TemporaryAgentBlueprint.handoffSection(in: "No section") == nil)
    }

    @Test("Notes are recorded once per run, redacted, and split reliably")
    func notesStoreIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalTemporaryAgentNotesStore(directoryURL: directory)
        let entry = TemporaryAgentNoteEntry(
            runID: "run-1",
            agentName: "Temporary Growth Strategist",
            status: "completed",
            request: "make a plan",
            body: "## Plan\nUse token sk-ant-api03-abcdefghijklmnop\n## Handoff notes\nNext: GA4",
            recordedAt: .now
        )
        try await store.append(entry, projectID: project.id, projectName: project.name)
        try await store.append(entry, projectID: project.id, projectName: project.name)

        let notes = try #require(try await store.notes(for: project.id))
        #expect(notes.components(separatedBy: entry.marker).count == 2)
        #expect(!notes.contains("sk-ant-api03-abcdefghijklmnop"))
        #expect(LocalTemporaryAgentNotesStore.entries(in: notes).count == 1)
    }

    @Test("A Claude subscription token is kept apart from the API key it falls back to")
    func claudeCredentialSlots() {
        let both = ClaudeSavedCredentials(subscriptionSlot: "sk-ant-oat01-abc", apiKeySlot: "sk-ant-api03-abc")
        #expect(both.subscriptionToken == "sk-ant-oat01-abc" && both.apiKey == "sk-ant-api03-abc")
        // A token saved in the API key field before the subscription slot existed.
        let legacy = ClaudeSavedCredentials(subscriptionSlot: nil, apiKeySlot: "sk-ant-oat01-old")
        #expect(legacy.subscriptionToken == "sk-ant-oat01-old" && legacy.apiKey == nil)
        let apiOnly = ClaudeSavedCredentials(subscriptionSlot: nil, apiKeySlot: "sk-ant-api03-abc")
        #expect(apiOnly.subscriptionToken == nil && apiOnly.apiKey == "sk-ant-api03-abc")
    }

    @Test("Claude limit failures name the credential that ran out")
    func claudeCredentialFailures() {
        let none = ClaudeSavedCredentials(subscriptionToken: nil, apiKey: nil)
        let apiKey = ClaudeSavedCredentials(subscriptionToken: nil, apiKey: "sk-ant-api03-abc")
        let subscription = ClaudeSavedCredentials(subscriptionToken: "sk-ant-oat01-abc", apiKey: nil)
        let saved = ClaudeAgentSDKRuntimeAdapter.actionableFailureMessage(
            "Credit balance is too low", savedCredentials: apiKey
        )
        #expect(saved.contains("API key saved in Goby") && saved.contains("claude setup-token"))
        let signIn = ClaudeAgentSDKRuntimeAdapter.actionableFailureMessage(
            "Credit balance is too low", savedCredentials: none
        )
        #expect(signIn.contains("Claude Code sign-in") && signIn.contains("/login"))
        let limit = ClaudeAgentSDKRuntimeAdapter.actionableFailureMessage(
            "Claude AI usage limit reached", savedCredentials: subscription
        )
        #expect(limit.contains("Save an Anthropic API key"))
        #expect(ClaudeAgentSDKRuntimeAdapter.actionableFailureMessage(
            "Other failure", savedCredentials: none
        ) == "Other failure")
    }

    @Test("The Claude account names the credential new work bills")
    func claudeCredentialPlanName() {
        #expect(ClaudeAgentSDKRuntimeAdapter.credentialPlanName(route: "subscription", subscriptionPausedUntil: nil)
            == "Claude subscription")
        #expect(ClaudeAgentSDKRuntimeAdapter.credentialPlanName(route: "apiKey", subscriptionPausedUntil: nil)
            == "Anthropic API key")
        #expect(ClaudeAgentSDKRuntimeAdapter.credentialPlanName(route: "apiKey", subscriptionPausedUntil: .now)?
            .contains("subscription resumes") == true)
        #expect(ClaudeAgentSDKRuntimeAdapter.credentialPlanName(route: nil, subscriptionPausedUntil: nil) == nil)
        #expect(ClaudeAgentSDKRuntimeAdapter.credentialPlanName(
            route: "subscription", subscriptionType: "max", subscriptionPausedUntil: nil
        ) == "Claude Max subscription")
    }
}

@Suite("Developer toolchain environment")
struct DeveloperToolchainEnvironmentTests {
    @Test("A registered JDK wins, then Android Studio, then Homebrew")
    func javaHomePreference() {
        let installed: Set<String> = [
            "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin/java",
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java",
        ]
        #expect(DeveloperToolchainEnvironment.javaHome(
            systemJavaHome: { nil }, isExecutable: installed.contains
        ) == "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        #expect(DeveloperToolchainEnvironment.javaHome(
            systemJavaHome: { "/jdk/Home" }, isExecutable: { installed.contains($0) || $0 == "/jdk/Home/bin/java" }
        ) == "/jdk/Home")
        #expect(DeveloperToolchainEnvironment.javaHome(systemJavaHome: { nil }, isExecutable: { _ in false }) == nil)
    }

    @Test("Codex agent shells receive JAVA_HOME alongside the cache paths")
    func codexShellReceivesJavaHome() {
        let config = CodexGateway.shellCacheConfiguration(
            cacheDirectory: URL(fileURLWithPath: "/tmp/cache", isDirectory: true),
            toolchainVariables: ["JAVA_HOME": "/jdk/Home"]
        )
        let variables = config["shell_environment_policy"]?["set"]
        #expect(variables?["JAVA_HOME"]?.stringValue == "/jdk/Home")
        #expect(variables?["XDG_CACHE_HOME"]?.stringValue?.hasPrefix("/tmp/cache") == true)
    }

    @Test("Codex agent shells cannot push, even when the user's Codex rules allow it")
    func codexShellCannotPush() throws {
        let config = CodexGateway.shellCacheConfiguration(
            cacheDirectory: URL(fileURLWithPath: "/tmp/cache", isDirectory: true), toolchainVariables: [:]
        )
        let variables = try #require(config["shell_environment_policy"]?["set"])
        #expect(variables["GIT_OPTIONAL_LOCKS"]?.stringValue == "0")
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in CodexGateway.pushBlockingGitConfiguration {
            #expect(variables[name]?.stringValue == value)
            environment[name] = value
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "goby-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        @discardableResult
        func git(_ arguments: [String], in directory: URL, environment: [String: String]? = nil) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        try git(["init", "-q", "--bare", "remote.git"], in: root)
        try git(["init", "-q", "work"], in: root)
        let work = root.appending(path: "work")
        try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "x"], in: work)
        try git(["remote", "add", "origin", "../remote.git"], in: work)

        #expect(try git(["push", "-q", "origin", "HEAD:main"], in: work, environment: environment) != 0)
        #expect(try git(["fetch", "-q", "origin"], in: work, environment: environment) == 0)
        #expect(try git(["push", "-q", "origin", "HEAD:main"], in: work) == 0)
    }
}

@Suite("Read-only check instructions")
struct ReadOnlyCheckInstructionTests {
    @Test("Read-only requests are told to skip checks unless they change files")
    func readOnlyInstructions() {
        let project = LabProject(
            id: "p", name: "P", rootURL: FileManager.default.temporaryDirectory,
            platforms: [.android], testCommands: ["./gradlew test"], isGitRepository: false
        )
        let agent = AgentProfile(id: "a", name: "A", summary: "S", capabilities: [.routing], scope: .project(project.id))
        let readOnly = CodexGateway.makeDeveloperInstructions(
            agent: agent, project: project, instructions: [], resources: [], risk: .readOnly
        )
        #expect(readOnly.contains("do not run the project checks below"))
        #expect(!readOnly.contains("Verification requirement"))
        let changing = CodexGateway.makeDeveloperInstructions(
            agent: agent, project: project, instructions: [], resources: [], risk: .low
        )
        #expect(changing.contains("Verification requirement"))
    }
}
