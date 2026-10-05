import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

@Suite("JSON-RPC framing")
struct JSONRPCLineBufferTests {
    @Test("Frames split and combined messages without retaining completed bytes")
    func framesMessages() throws {
        var buffer = JSONRPCLineBuffer(maximumFrameBytes: 32)

        #expect(try buffer.append(Data("first".utf8)).isEmpty)
        #expect(try buffer.append(Data(" line\nsecond\nthird".utf8)) == [
            Data("first line".utf8),
            Data("second".utf8),
        ])
        #expect(buffer.bufferedByteCount == 5)
        #expect(try buffer.finish() == Data("third".utf8))
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test("Rejects an unterminated frame at the configured byte limit")
    func rejectsOversizedFrame() throws {
        var buffer = JSONRPCLineBuffer(maximumFrameBytes: 8)

        #expect(try buffer.append(Data("12345678".utf8)).isEmpty)
        #expect(throws: JSONRPCLineFramingError.frameTooLarge(maximumBytes: 8)) {
            try buffer.append(Data("9".utf8))
        }
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test("Rejects an oversized complete frame")
    func rejectsOversizedCompleteFrame() {
        var buffer = JSONRPCLineBuffer(maximumFrameBytes: 4)

        #expect(throws: JSONRPCLineFramingError.frameTooLarge(maximumBytes: 4)) {
            try buffer.append(Data("12345\n".utf8))
        }
        #expect(buffer.bufferedByteCount == 0)
    }
}

struct InfrastructureTests {
    @Test("Startup preflight defers protected user-folder access")
    func preflightDefersProtectedUserFolders() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        for folder in ["Desktop", "Documents", "Downloads"] {
            let project = home.appending(path: "\(folder)/Project", directoryHint: .isDirectory)
            #expect(SystemPreflight.defersAutomaticAccessCheck(for: project, homeDirectory: home))
        }
        #expect(!SystemPreflight.defersAutomaticAccessCheck(
            for: home.appending(path: "Developer/Project", directoryHint: .isDirectory),
            homeDirectory: home
        ))
        #expect(!SystemPreflight.defersAutomaticAccessCheck(
            for: home.appending(path: "Desktop Archive/Project", directoryHint: .isDirectory),
            homeDirectory: home
        ))
    }

    @Test(
        "Installed Codex App Server completes the initialize handshake",
        .enabled(if: ProcessInfo.processInfo.environment["GOBY_RUN_CODEX_INTEGRATION"] == "1"),
        .timeLimit(.minutes(1))
    )
    func codexInitializeHandshake() async throws {
        let executable = InstalledCodexLocator.locate()
        let transport = CodexAppServerTransport(executableURL: executable, clientVersion: "test")
        let response = try await transport.start()
        #expect(response["platformOs"]?.stringValue == "macos")
        #expect(response["codexHome"]?.stringValue != nil)
        let account = try await transport.request(method: "account/read", params: GetAccountParameters())
        #expect(account["account"] != nil)
        let threads = try await transport.request(method: "thread/list", params: ThreadListParameters(limit: 1))
        if case .array = threads["data"] {
            // Expected response shape from the installed App Server.
        } else {
            Issue.record("thread/list did not return a data array.")
        }
        await transport.stop()

        let health = await SystemPreflight(
            codexURL: executable,
            storageURL: FileManager.default.temporaryDirectory
        ).check(projects: [])
        let protocolCheck = try #require(health.checks.first { $0.kind == .appServerProtocol })
        #expect(protocolCheck.status == .passed)
    }

    @Test("An unresponsive App Server request times out and can be stopped", .timeLimit(.minutes(1)))
    func appServerRequestTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-silent-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "silent-server")
        let script = "#!/bin/zsh\nwhile IFS= read -r line; do :; done\n"
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path(percentEncoded: false))
        let transport = CodexAppServerTransport(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 0.1,
            runtimeValidator: AllowingCodexRuntimeValidator()
        )

        do {
            _ = try await transport.start()
            Issue.record("The silent server unexpectedly answered initialize.")
        } catch let error as CodexTransportError {
            if case let .requestTimedOut(method) = error {
                #expect(method == "initialize")
            } else {
                Issue.record("Unexpected transport error: \(error.localizedDescription)")
            }
        }
        await transport.stop()
    }

    @Test("Codex account snapshot preserves both live usage windows", .timeLimit(.minutes(1)))
    func codexAccountUsageWindows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-usage-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "usage-server")
        let requestLog = directory.appending(path: "requests.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(requestLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"usage-test\"}}"
          elif [[ "$line" == *'account'* && "$line" == *'rateLimits'* && "$line" == *'read'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":71,\"resetsAt\":1788600000,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":22,\"resetsAt\":1789200000,\"windowDurationMins\":10080}}}}}"
          elif [[ "$line" == *'account'* && "$line" == *'read'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"account\":{\"email\":\"user@example.com\",\"planType\":\"pro\"}}}"
          elif [[ "$line" == *'config'* && "$line" == *'read'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"config\":{\"model\":\"gpt-6-astra\"},\"origins\":{}}}"
          elif [[ "$line" == *'model'* && "$line" == *'list'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"model\":\"gpt-6-astra\",\"isDefault\":true},{\"model\":\"gpt-5.6-sol\",\"isDefault\":false}]}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )

        do {
            _ = try await gateway.connect()
        } catch {
            let requests = (try? String(contentsOf: requestLog, encoding: .utf8)) ?? "No requests captured"
            Issue.record("Usage mock failed: \(error.localizedDescription)\nRequests:\n\(requests)")
            return
        }
        let account = try await gateway.accountSnapshot()
        await gateway.disconnect()

        #expect(account.authenticated)
        #expect(account.planName == "pro")
        #expect(account.selectedModel == "gpt-6-astra")
        #expect(account.availableModels == ["gpt-6-astra", "gpt-5.6-sol"])
        #expect(account.usedPercent == 71)
        #expect(account.primaryWindowDurationMinutes == 300)
        #expect(account.resetsAt == Date(timeIntervalSince1970: 1_788_600_000))
        #expect(account.secondaryUsedPercent == 22)
        #expect(account.secondaryWindowDurationMinutes == 10_080)
        #expect(account.secondaryResetsAt == Date(timeIntervalSince1970: 1_789_200_000))
    }

    @Test("Codex relaunch recovery rejoins the exact persisted thread and turn", .timeLimit(.minutes(1)))
    func codexRecoveryRejoinsPersistedExecution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-recovery-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "recovery-server")
        let requestLog = directory.appending(path: "requests.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(requestLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"recovery-test\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'resume'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-live\",\"cwd\":\"/tmp/recovery-project\",\"status\":{\"type\":\"active\",\"activeFlags\":[]},\"turns\":[{\"id\":\"turn-live\",\"status\":\"inProgress\",\"items\":[{\"id\":\"message-1\",\"type\":\"agentMessage\",\"text\":\"Still working after relaunch\"},{\"id\":\"command-1\",\"type\":\"commandExecution\",\"command\":\"swift test\",\"cwd\":\"/tmp/recovery-project\",\"status\":\"completed\",\"exitCode\":0}] }]}}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let project = LabProject(
            id: "recovery-project",
            name: "Recovery Project",
            rootURL: URL(fileURLWithPath: "/tmp/recovery-project", isDirectory: true),
            platforms: [.general],
            isGitRepository: false
        )
        let assignment = AgentAssignment(
            id: "recovery-assignment",
            runID: "recovery-run",
            projectID: project.id,
            agentID: "recovery-agent",
            status: .working,
            currentTask: "Continue",
            workingDirectory: project.rootURL,
            providerID: .codex,
            providerTaskID: "thread-live",
            providerTurnID: "turn-live"
        )

        _ = try await gateway.connect()
        let recovery = try #require(try await gateway.recover(
            assignment: assignment,
            project: project,
            resources: []
        ))
        await gateway.disconnect()

        #expect(recovery.status == .working)
        #expect(recovery.handle.taskID == "thread-live")
        #expect(recovery.handle.turnID == "turn-live")
        #expect(recovery.message == "Still working after relaunch")
        #expect(recovery.evidence.map(\.id) == ["command-1"])
        let requests = try String(contentsOf: requestLog, encoding: .utf8)
        #expect(requests.contains("\"method\":\"thread\\/resume\""))
        #expect(requests.contains("\"threadId\":\"thread-live\""))
    }

    @Test("Codex project discovery follows every thread-list page and deduplicates roots", .timeLimit(.minutes(1)))
    func codexProjectDiscoveryPaginates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-paged-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "paged-server")
        let requestLog = directory.appending(path: "requests.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(requestLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"paged-test\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* && "$line" == *'"cursor":"page-2"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"cwd\":\"/tmp/shared\"},{\"cwd\":\"/tmp/beta\"}],\"nextCursor\":null}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"cwd\":\"/tmp/alpha\"},{\"cwd\":\"/tmp/shared\"}],\"nextCursor\":\"page-2\"}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )

        _ = try await gateway.connect()
        let snapshot: CodexProjectRootsSnapshot
        do {
            snapshot = try await gateway.recentProjectRoots()
        } catch {
            let requests = (try? String(contentsOf: requestLog, encoding: .utf8)) ?? "No requests captured"
            Issue.record("Paged mock failed: \(error.localizedDescription)\nRequests:\n\(requests)")
            await gateway.disconnect()
            return
        }
        await gateway.disconnect()

        #expect(snapshot.roots.map { $0.path(percentEncoded: false) } == ["/tmp/alpha/", "/tmp/shared/", "/tmp/beta/"])
        #expect(snapshot.warnings.isEmpty)
    }

    @Test("Codex project discovery preserves every task thread and its status", .timeLimit(.minutes(1)))
    func codexProjectDiscoveryPreservesTaskActivity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-task-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "task-server")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"task-test\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"id\":\"build\",\"cwd\":\"/tmp/copilot\",\"name\":\"Build context index\",\"preview\":\"Create the index\",\"status\":{\"type\":\"notLoaded\"},\"updatedAt\":30},{\"id\":\"benchmark\",\"cwd\":\"/tmp/copilot\",\"name\":\"Evaluate benchmarks\",\"preview\":\"\",\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\"]},\"updatedAt\":20},{\"id\":\"github\",\"cwd\":\"/tmp/copilot\",\"name\":\"Assess GitHub AI\",\"preview\":\"Check applicability\",\"parentThreadId\":\"parent\",\"agentRole\":\"researcher\",\"status\":{\"type\":\"active\",\"activeFlags\":[]},\"updatedAt\":10}],\"nextCursor\":null}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )

        _ = try await gateway.connect()
        let snapshot = try await gateway.recentProjectRoots()
        await gateway.disconnect()

        #expect(snapshot.tasks.map(\.title) == [
            "Build context index", "Evaluate benchmarks", "Assess GitHub AI",
        ])
        #expect(snapshot.tasks.map(\.status) == [.idle, .waitingForApproval, .active])
        #expect(snapshot.tasks.last?.isSubagent == true)
        #expect(Set(snapshot.tasks.map(\.projectID)).count == 1)
    }

    @Test("Codex project discovery includes the saved project registry and excludes managed worktrees")
    func codexProjectDiscoveryReadsSavedProjects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-registry-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "registry-server")
        let globalState = directory.appending(path: "global-state.json")
        let managedWorktree = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/worktrees/transient", directoryHint: .isDirectory)
            .path(percentEncoded: false)
        let state: [String: Any] = [
            "local-projects": [
                "local-saved": ["name": "Saved", "rootPaths": ["/tmp/saved-project"]]
            ],
            "electron-saved-workspace-roots": ["/tmp/legacy-project"],
            "active-workspace-roots": ["/tmp/saved-project"]
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: globalState, options: .atomic)
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"registry-test\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"id\":\"history\",\"cwd\":\"/tmp/history-project\"},{\"id\":\"worktree\",\"cwd\":\"\#(managedWorktree)\"}],\"nextCursor\":null}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: globalState
        )

        _ = try await gateway.connect()
        let snapshot = try await gateway.recentProjectRoots()
        await gateway.disconnect()

        #expect(snapshot.roots.map { $0.path(percentEncoded: false) } == [
            "/tmp/saved-project/",
            "/tmp/legacy-project/",
            "/tmp/history-project/"
        ])
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.savedProjects == [
            CodexSavedProjectReference(
                name: "Saved",
                rootURL: URL(fileURLWithPath: "/tmp/saved-project", isDirectory: true)
            )
        ])
    }

    @Test("Codex project discovery keeps readable roots when one history item times out", .timeLimit(.minutes(1)))
    func codexProjectDiscoveryReturnsPartialResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-partial-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "partial-server")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"partial-test\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* && "$line" != *'"cursor"'* && "$line" == *'"sortDirection":"desc"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"id\":\"new-thread\",\"cwd\":\"/tmp/new\"}],\"nextCursor\":\"blocked-new\"}}"
          elif [[ "$line" == *'thread'* && "$line" == *'list'* && "$line" != *'"cursor"'* && "$line" == *'"sortDirection":"asc"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"data\":[{\"id\":\"old-thread\",\"cwd\":\"/tmp/old\"}],\"nextCursor\":\"blocked-old\"}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 1,
            projectDiscoveryPageTimeout: 0.5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )

        _ = try await gateway.connect()
        let snapshot = try await gateway.recentProjectRoots()
        await gateway.disconnect()

        #expect(snapshot.roots.map { $0.path(percentEncoded: false) } == ["/tmp/new/", "/tmp/old/"])
        #expect(snapshot.warnings.count == 1)
        #expect(snapshot.warnings.first?.contains("every readable project") == true)
    }

    @Test("JSON-RPC codec preserves typed request fields")
    func jsonRPCCodec() throws {
        let request = JSONRPCRequest(
            id: JSONRPCID.integer(7),
            method: "turn/start",
            params: TurnStartParameters(threadID: "thread-1", prompt: "Hello")
        )
        let data = try JSONRPCCodec.encodeLine(request)
        let object = try #require(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "turn/start")
        #expect(object["id"] as? Int == 7)
    }

    @Test("Codex turn inputs preserve native images, file mentions, and code snippets")
    func codexAttachmentInputs() throws {
        let parameters = TurnStartParameters(
            threadID: "thread-attachments",
            prompt: "Review these items",
            attachments: [
                PromptAttachment(
                    kind: .image,
                    displayName: "layout.png",
                    source: .localFile(URL(fileURLWithPath: "/tmp/layout.png"))
                ),
                PromptAttachment(
                    kind: .file,
                    displayName: "Widget.swift",
                    source: .localFile(URL(fileURLWithPath: "/tmp/Widget.swift"))
                ),
                PromptAttachment(
                    kind: .snippet,
                    displayName: "Swift snippet",
                    source: .text("let answer = 42"),
                    typeHint: "Swift"
                ),
            ]
        )
        let data = try JSONEncoder().encode(parameters)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])

        #expect(input.map { $0["type"] as? String } == ["text", "localImage", "mention", "text"])
        #expect(input[1]["path"] as? String == "/tmp/layout.png")
        #expect(input[2]["name"] as? String == "Widget.swift")
        #expect((input[3]["text"] as? String)?.contains("let answer = 42") == true)
    }

    @Test("Codex steering binds follow-up text to the exact active turn")
    func codexSteerCodec() throws {
        let request = JSONRPCRequest(
            id: JSONRPCID.integer(8),
            method: "turn/steer",
            params: TurnSteerParameters(
                threadID: "thread-1",
                expectedTurnID: "turn-2",
                text: "Focus on the reconnect failure."
            )
        )
        let data = try JSONRPCCodec.encodeLine(request)
        let object = try #require(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])

        #expect(object["method"] as? String == "turn/steer")
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["expectedTurnId"] as? String == "turn-2")
        #expect(input.first?["type"] as? String == "text")
        #expect(input.first?["text"] as? String == "Focus on the reconnect failure.")
    }

    @Test("Codex shell commands use writable temporary compiler caches")
    func codexShellCacheConfiguration() throws {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/goby-cache-test", isDirectory: true)
        let cacheDirectory = CodexGateway.shellCacheDirectory(
            for: "assignment/with unsafe characters",
            under: temporaryDirectory
        )
        let request = JSONRPCRequest(
            id: JSONRPCID.integer(8),
            method: "thread/start",
            params: ThreadStartParameters(
                config: CodexGateway.shellCacheConfiguration(cacheDirectory: cacheDirectory),
                cwd: "/tmp/project",
                model: "gpt-6-astra"
            )
        )
        let data = try JSONRPCCodec.encodeLine(request)
        let object = try #require(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let config = try #require(params["config"] as? [String: Any])
        let policy = try #require(config["shell_environment_policy"] as? [String: Any])
        let environment = try #require(policy["set"] as? [String: String])

        #expect(cacheDirectory.path(percentEncoded: false) == "/tmp/goby-cache-test/GobyAgentCaches/assignment_with_unsafe_characters/")
        #expect(policy["inherit"] as? String == "core")
        #expect(policy["ignore_default_excludes"] as? Bool == false)
        #expect((policy["exclude"] as? [String])?.contains("*PASSWORD*") == true)
        #expect(environment["XDG_CACHE_HOME"] == cacheDirectory.path(percentEncoded: false))
        #expect(environment["CLANG_MODULE_CACHE_PATH"]?.hasSuffix("/clang-module-cache/") == true)
        #expect(environment["SWIFTPM_MODULECACHE_OVERRIDE"] == environment["CLANG_MODULE_CACHE_PATH"])
        #expect(params["model"] as? String == "gpt-6-astra")
    }

    @Test("Codex turn failures report the protocol reason instead of agent narration")
    func codexTurnFailureMessage() {
        let failedTurn: JSONValue = .object([
            "status": .string("failed"),
            "error": .object([
                "message": .string("Model provider disconnected."),
                "additionalDetails": .string("Request ID: abc"),
            ]),
        ])

        #expect(CodexGateway.turnFailureMessage(status: "interrupted", turn: nil).contains("interrupted before completion"))
        #expect(
            CodexGateway.turnFailureMessage(status: "failed", turn: failedTurn)
                == "Codex turn failed: Model provider disconnected.\nRequest ID: abc"
        )
        #expect(
            !CodexGateway.turnFailureMessage(status: "failed", turn: failedTurn)
                .contains("last progress narration")
        )
    }

    @Test("Swift package checks avoid a nested sandbox inside Codex")
    func sandboxCompatibleSwiftChecks() {
        #expect(CodexRunOrchestrator.sandboxCompatibleTestCommands([
            "swift test",
            "swift test --package-path backend",
            "npm test",
            "swift test --disable-sandbox",
        ]) == [
            "swift test --disable-sandbox",
            "swift test --package-path backend --disable-sandbox",
            "npm test",
            "swift test --disable-sandbox",
        ])
        #expect(CodexRunOrchestrator.sandboxCompatibleTestCommands(
            ["swift test", "npm test"], runID: "run-1"
        ) == [
            "swift test --disable-sandbox --scratch-path /private/tmp/goby-swift-verification-run-1",
            "npm test",
        ])
    }

    @Test("Resource approval responses preserve the requested permission profile")
    func resourceApprovalResponseShape() throws {
        let permissions: JSONValue = .object([
            "network": .object(["enabled": .bool(true)])
        ])
        let response = JSONRPCResponse(
            id: JSONRPCID.string("permission-1"),
            result: CodexPermissionsApprovalResponse(permissions: permissions, scope: "turn")
        )
        let data = try JSONRPCCodec.encodeLine(response)
        let object = try #require(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["scope"] as? String == "turn")
        #expect(result["permissions"] as? [String: Any] != nil)
        #expect(result["decision"] == nil)
    }

    @Test("Codex sandbox follows the reviewed plan risk")
    func sandboxPolicy() {
        #expect(CodexGateway.sandbox(for: .readOnly) == "read-only")
        #expect(CodexGateway.sandbox(for: .low) == "workspace-write")
        #expect(CodexGateway.sandbox(for: .medium) == "workspace-write")
        #expect(CodexGateway.sandbox(for: .high) == "workspace-write")
    }

    @Test("Web broadcast selects every matching project")
    func webBroadcastRouting() async throws {
        let projects = ["Alpha", "Beta"].map { name in
            LabProject(
                id: ProjectID(rawValue: name.lowercased()),
                name: name,
                rootURL: URL(fileURLWithPath: "/tmp/\(name)"),
                platforms: [.web],
                isGitRepository: true
            )
        }
        let agents = projects.map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "Web Agent",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "All websites adopt the new Google preferred sources functionality"),
            in: LabSnapshot(projects: projects, agents: agents)
        )

        #expect(plan.routes.count == 2)
        #expect(plan.gitOperations.count == 6)
        #expect(plan.requiresApproval)
        let branches = plan.gitOperations.compactMap(\.branch)
        #expect(Set(branches) == ["codex/goby-\(plan.id.rawValue.prefix(12))"])
        #expect(branches.allSatisfy { !$0.contains("google") && !$0.contains("website") })
    }

    @Test("An explicitly named project and read-only instruction do not broaden or create Git work")
    func namedReadOnlyRouting() async throws {
        let dashboard = LabProject(
            id: "dashboard",
            name: "Agentic Dashboard",
            rootURL: URL(fileURLWithPath: "/tmp/dashboard"),
            platforms: [.iOS],
            isGitRepository: true
        )
        let website = LabProject(
            id: "website",
            name: "Marketing Website",
            rootURL: URL(fileURLWithPath: "/tmp/website"),
            platforms: [.web],
            isGitRepository: true
        )
        let agents = [dashboard, website].map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "Test Agent",
                summary: "Launch verification",
                capabilities: [.testing],
                scope: .project(project.id)
            )
        }

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Check whether the Agentic Dashboard app launches and report errors. Do not change files."
            ),
            in: LabSnapshot(projects: [dashboard, website], agents: agents)
        )

        #expect(plan.routes.map(\.projectID) == [dashboard.id])
        #expect(plan.risk == .readOnly)
        #expect(plan.gitOperations.isEmpty)
        #expect(!plan.requiresApproval)
    }

    @Test("A mutation after a read-only contrast remains a change request")
    func contrastingMutationRouting() async throws {
        let project = LabProject(
            id: "app",
            name: "Customer App",
            rootURL: URL(fileURLWithPath: "/tmp/app"),
            platforms: [.iOS],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "agent",
            name: "iOS Agent",
            summary: "Implementation",
            capabilities: [.iOS],
            scope: .project(project.id)
        )

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Do not change the docs, but fix the Customer App launch"),
            in: LabSnapshot(projects: [project], agents: [agent])
        )

        #expect(plan.risk == .medium)
        #expect(plan.gitOperations.count == 3)
        #expect(plan.requiresApproval)
    }

    @Test("A recurring self improvement run requires change review")
    func selfImprovementRunRequiresChangeReview() async throws {
        let project = LabProject(
            id: "dashboard", name: "Agentic Dashboard",
            rootURL: URL(fileURLWithPath: "/tmp/dashboard"),
            platforms: [.iOS], isGitRepository: true
        )
        let agent = AgentProfile(
            id: "ios-agent", name: "iOS Agent", summary: "Improve the iOS UI",
            capabilities: [.iOS], scope: .project(project.id)
        )
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "make a recurring self improvement run focused on ui clarity, simplicity and minimality",
                scope: .projects([project.id]),
                agentTargets: [.init(providerID: .codex, agentID: agent.id, projectID: project.id)]
            ),
            in: LabSnapshot(projects: [project], agents: [agent])
        )

        #expect(plan.risk == .medium)
        #expect(plan.gitOperations.count == 3)
        #expect(plan.requiresApproval)
    }

    @Test("An explicit report-only self improvement request stays read only")
    func reportOnlySelfImprovementStaysReadOnly() async throws {
        let project = LabProject(
            id: "dashboard", name: "Agentic Dashboard",
            rootURL: URL(fileURLWithPath: "/tmp/dashboard"),
            platforms: [.iOS], isGitRepository: true
        )
        let agent = AgentProfile(
            id: "ios-agent", name: "iOS Agent", summary: "Review the iOS UI",
            capabilities: [.iOS], scope: .project(project.id)
        )
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Review a self improvement run and report ideas; do not edit files.",
                scope: .projects([project.id]),
                agentTargets: [.init(providerID: .codex, agentID: agent.id, projectID: project.id)]
            ),
            in: LabSnapshot(projects: [project], agents: [agent])
        )

        #expect(plan.risk == .readOnly)
        #expect(plan.gitOperations.isEmpty)
    }

    @Test("An audit-only first phase does not make later implementation read only")
    func phasedImprovementNeedsChangeReview() async throws {
        let project = LabProject(
            id: "dashboard", name: "Agentic Dashboard",
            rootURL: URL(fileURLWithPath: "/tmp/dashboard"),
            platforms: [.macOS], isGitRepository: true
        )
        let agent = AgentProfile(
            id: "mac-agent", name: "macOS Agent", summary: "Improve the Mac UI",
            capabilities: [.macOS], scope: .project(project.id)
        )
        let request = """
        CYCLE 1 — AUDIT
        Do not change code during this phase.
        CYCLE 2 — IMPLEMENT
        Edit project files for the selected improvements and run verification.
        """
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: request, scope: .projects([project.id]),
                agentTargets: [.init(providerID: .codex, agentID: agent.id, projectID: project.id)]
            ),
            in: LabSnapshot(projects: [project], agents: [agent])
        )
        #expect(plan.risk == .medium)
        #expect(plan.gitOperations.count == 3)
        let oldPlan = RoutingPlan(
            id: "old-plan", interpretedGoal: request,
            routes: plan.routes, risk: .readOnly, confidence: 1
        )
        #expect(RouteMutationIntent.needsFreshChangePlan(oldPlan))
    }

    @Test("Imported Codex transcript scaffolding is not exposed as task copy")
    func codexTaskCopySanitization() {
        let copy = CodexTaskCopySanitizer.copy(
            id: "1234567890",
            name: ">>> TRANSCRIPT START <<< [tool] assistant to=functions.exec",
            preview: "The following is the Codex agent history with a tool call",
            isSubagent: false
        )

        #expect(copy.title == "Imported Codex task · 12345678")
        #expect(copy.summary == nil)
    }

    @Test("Broad requests use authorized fallback agents when no exact specialist is registered")
    func broadRequestFallbackRouting() async throws {
        let projects = [
            LabProject(
                id: "site",
                name: "Site",
                rootURL: URL(fileURLWithPath: "/tmp/site"),
                platforms: [.web],
                isGitRepository: true
            ),
            LabProject(
                id: "app",
                name: "App",
                rootURL: URL(fileURLWithPath: "/tmp/app"),
                platforms: [.iOS],
                isGitRepository: true
            ),
        ]
        let agents = [
            AgentProfile(
                id: "site-agent",
                name: "Site Agent",
                summary: "Maintains the website",
                capabilities: [.web],
                scope: .project("site")
            ),
            AgentProfile(
                id: "app-agent",
                name: "App Agent",
                summary: "Maintains the app",
                capabilities: [.iOS],
                scope: .project("app")
            ),
        ]

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Add the appropriate logo.png to each project"),
            in: LabSnapshot(projects: projects, agents: agents)
        )

        #expect(plan.routes.map(\.projectID) == ["site", "app"])
        #expect(plan.routes.map(\.agentIDs) == [["site-agent"], ["app-agent"]])
        #expect(plan.routes.allSatisfy { $0.reason.contains("enabled fallback") })
        #expect(plan.warnings.count == 2)
        #expect(plan.warnings.allSatisfy { $0.contains("no exact specialist covering Visual Design") })
    }

    @Test("A map-selected agent is the only direct route")
    func directAgentRouting() async throws {
        let projects = ["Alpha", "Beta"].map { name in
            LabProject(
                id: ProjectID(rawValue: name.lowercased()),
                name: name,
                rootURL: URL(fileURLWithPath: "/tmp/\(name)"),
                platforms: [.web],
                isGitRepository: true
            )
        }
        let agents = projects.map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "\(project.name) Web Agent",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }
        let selectedAgent = agents[1]
        let selectedProject = projects[1]

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Update all websites",
                scope: .all,
                agentTarget: AgentRouteTarget(
                    agentID: selectedAgent.id,
                    projectID: selectedProject.id
                )
            ),
            in: LabSnapshot(projects: projects, agents: agents)
        )

        #expect(plan.routes == [
            ProjectRoute(
                projectID: selectedProject.id,
                agentIDs: [selectedAgent.id],
                providerBindings: [ProviderRouteBinding(
                    agentID: selectedAgent.id,
                    bindingID: ProviderAgentBinding.migratedCodexBinding(for: selectedAgent).id
                )],
                reason: "Directly assigned to Beta Web Agent from the map selection."
            )
        ])
        #expect(plan.confidence == 1)
        #expect(plan.gitOperations.count == 3)
    }

    @Test("Command-selected map agents are the exact direct routes")
    func multipleDirectAgentRouting() async throws {
        let alpha = LabProject(
            id: "alpha",
            name: "Alpha",
            rootURL: URL(fileURLWithPath: "/tmp/Alpha"),
            platforms: [.web],
            isGitRepository: true
        )
        let beta = LabProject(
            id: "beta",
            name: "Beta",
            rootURL: URL(fileURLWithPath: "/tmp/Beta"),
            platforms: [.web],
            isGitRepository: true
        )
        let gamma = LabProject(
            id: "gamma",
            name: "Gamma",
            rootURL: URL(fileURLWithPath: "/tmp/Gamma"),
            platforms: [.web],
            isGitRepository: true
        )
        let agents = [
            AgentProfile(
                id: "alpha-research",
                name: "Alpha Research",
                summary: "Research",
                capabilities: [.research],
                scope: .project(alpha.id)
            ),
            AgentProfile(
                id: "alpha-web",
                name: "Alpha Web",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(alpha.id)
            ),
            AgentProfile(
                id: "beta-web",
                name: "Beta Web",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(beta.id)
            ),
            AgentProfile(
                id: "gamma-web",
                name: "Gamma Web",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(gamma.id)
            ),
        ]
        let selectedTargets: Set<AgentRouteTarget> = [
            AgentRouteTarget(agentID: "alpha-research", projectID: alpha.id),
            AgentRouteTarget(agentID: "alpha-web", projectID: alpha.id),
            AgentRouteTarget(agentID: "beta-web", projectID: beta.id),
        ]

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Update every website",
                agentTargets: selectedTargets
            ),
            in: LabSnapshot(projects: [alpha, beta, gamma], agents: agents)
        )

        #expect(plan.routes.map(\.projectID) == [alpha.id, beta.id])
        #expect(plan.routes[0].agentIDs == ["alpha-research", "alpha-web"])
        #expect(plan.routes[1].agentIDs == ["beta-web"])
        #expect(Set(plan.routes.flatMap(\.agentIDs)) == Set(selectedTargets.map(\.agentID)))
        #expect(plan.confidence == 1)
        #expect(plan.gitOperations.count == 6)
    }

    @Test("Command-selected map projects are the exact automatic routing scope")
    func multipleDirectProjectRouting() async throws {
        let projects = ["Alpha", "Beta", "Gamma"].map { name in
            LabProject(
                id: ProjectID(rawValue: name.lowercased()),
                name: name,
                rootURL: URL(fileURLWithPath: "/tmp/\(name)"),
                platforms: [.web],
                isGitRepository: true
            )
        }
        let agents = projects.map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "\(project.name) Web Agent",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }
        let selectedProjectIDs: Set<ProjectID> = [projects[0].id, projects[2].id]

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Update every selected website",
                scope: .projects(selectedProjectIDs)
            ),
            in: LabSnapshot(projects: projects, agents: agents)
        )

        #expect(Set(plan.routes.map(\.projectID)) == selectedProjectIDs)
        #expect(!plan.routes.contains(where: { $0.projectID == projects[1].id }))
        #expect(Set(plan.routes.flatMap(\.agentIDs)) == [agents[0].id, agents[2].id])
        #expect(plan.gitOperations.count == 6)
    }

    @Test("Explicit projects route capable agents and reject unrelated fallbacks")
    func explicitProjectRequiresAppropriateAgent() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.web],
            isGitRepository: true
        )
        let webAgent = AgentProfile(
            id: "web-agent",
            name: "Web Agent",
            summary: "Builds websites",
            capabilities: [.web],
            scope: .project(project.id)
        )

        await #expect(throws: GobyApplicationError.noAppropriateAgent(
            projectID: project.id,
            projectName: project.name,
            providerID: .codex,
            capabilities: [.research]
        )) {
            _ = try await DeterministicRouter().plan(
                for: RouteRequest(
                    prompt: "Research and compare sources",
                    scope: .projects([project.id])
                ),
                in: LabSnapshot(projects: [project], agents: [webAgent])
            )
        }
    }

    @Test("Mixed project and agent scope keeps automatic routing for projects without an explicit agent")
    func mixedExplicitAndAutomaticProjectRouting() async throws {
        let projects = ["Alpha", "Beta"].map { name in
            LabProject(
                id: ProjectID(rawValue: name.lowercased()),
                name: name,
                rootURL: URL(fileURLWithPath: "/tmp/\(name)"),
                platforms: [.web],
                isGitRepository: true
            )
        }
        let agents = projects.map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "\(project.name) Web Agent",
                summary: "Web implementation",
                capabilities: [.web],
                scope: .project(project.id)
            )
        }

        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(
                prompt: "Update the selected websites",
                scope: .projects(Set(projects.map(\.id))),
                agentTarget: AgentRouteTarget(
                    agentID: agents[0].id,
                    projectID: projects[0].id
                )
            ),
            in: LabSnapshot(projects: projects, agents: agents)
        )

        #expect(plan.routes.map(\.projectID) == projects.map(\.id))
        #expect(plan.routes[0].reason.contains("Directly assigned"))
        #expect(plan.routes[1].agentIDs == [agents[1].id])
    }

    @Test("A non-Git project receives no invented Git operations and discloses in-place edits")
    func nonGitProjectHasNoGitPlan() async throws {
        let project = LabProject(
            id: "notes",
            name: "Notes",
            rootURL: URL(fileURLWithPath: "/tmp/notes"),
            platforms: [.web],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "notes-agent",
            name: "Web Agent",
            summary: "Web implementation",
            capabilities: [.web],
            scope: .project(project.id)
        )
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "Update the website"),
            in: LabSnapshot(projects: [project], agents: [agent])
        )
        #expect(plan.gitOperations.isEmpty)
        #expect(plan.risk == .medium)
        #expect(plan.requiresApproval)
        #expect(plan.warnings == [
            "Notes is not a Git repository. Approved changes will be made in its registered folder without an isolated worktree or automatic rollback."
        ])
    }

    @Test("Graph layout is stable when only status changes")
    func stableGraphLayout() async {
        let project = LabProject(
            id: "p1",
            name: "Site",
            rootURL: URL(fileURLWithPath: "/tmp/site"),
            platforms: [.web],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "a1",
            name: "Web",
            summary: "Web",
            capabilities: [.web],
            scope: .project(project.id)
        )
        let lab = LabSnapshot(projects: [project], agents: [agent])
        let runID = RunID(rawValue: "run")
        let queued = AgentAssignment(runID: runID, projectID: project.id, agentID: agent.id, status: .queued, currentTask: "Task")
        let working = AgentAssignment(id: queued.id, runID: runID, projectID: project.id, agentID: agent.id, status: .working, currentTask: "Task", progress: 0.4)
        let layout = RadialGraphLayout()

        let first = await layout.layout(lab: lab, assignments: [queued])
        let second = await layout.layout(lab: lab, assignments: [working])
        let firstPositions = Dictionary(uniqueKeysWithValues: first.nodes.map { ($0.id, $0.position) })
        let secondPositions = Dictionary(uniqueKeysWithValues: second.nodes.map { ($0.id, $0.position) })
        #expect(firstPositions == secondPositions)
        let projectPosition = firstPositions[.project(project.id)]
        let clusterPosition = firstPositions[.cluster(.web)]
        #expect(projectPosition == clusterPosition)
        #expect(projectPosition?.x == 302)
        #expect(projectPosition?.y == 0)
    }

    @Test("Graph keeps Codex tasks separate from reusable agent profiles")
    func graphIncludesCodexTaskActivity() async throws {
        let project = LabProject(
            id: "copilot",
            name: "Copilot Optimization",
            rootURL: URL(fileURLWithPath: "/tmp/copilot"),
            platforms: [.research],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "research-agent",
            name: "Research Agent",
            summary: "Reusable research role",
            capabilities: [.research],
            scope: .project(project.id)
        )
        let tasks = ["Build context index", "Evaluate benchmarks", "Assess GitHub AI"].enumerated().map { index, title in
            CodexTaskActivity(
                id: "task-\(index)",
                projectID: project.id,
                title: title,
                status: .idle,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            assignments: [],
            codexTasks: tasks
        )

        #expect(graph.nodes.filter { if case .agent = $0.kind { true } else { false } }.count == 1)
        #expect(graph.nodes.filter { if case .codexTask = $0.kind { true } else { false } }.count == 3)
        #expect(graph.edges.filter { $0.kind == .activity }.count == 3)
        #expect(Set(graph.nodes.map(\.position)).count == graph.nodes.count - 1)
    }

    @Test("Invoked Codex helpers attach beneath their parent assignment")
    func graphAttachesHelperToParentAssignment() async throws {
        let project = LabProject(
            id: "helper-project",
            name: "Helper Project",
            rootURL: URL(fileURLWithPath: "/tmp/helper-project"),
            platforms: [.research],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "primary-agent",
            name: "Primary Agent",
            summary: "Delegates bounded research",
            capabilities: [.research],
            scope: .project(project.id)
        )
        let assignment = AgentAssignment(
            id: "helper-assignment",
            runID: "helper-run",
            projectID: project.id,
            agentID: agent.id,
            status: .working,
            currentTask: "Research the change",
            providerTaskID: "parent-thread"
        )
        let helper = CodexTaskActivity(
            id: "helper-thread",
            projectID: project.id,
            title: "Security Baseline",
            summary: "Baseline complete",
            status: .completed,
            updatedAt: .now,
            isSubagent: true,
            agentRole: "security_baseline",
            parentThreadID: "parent-thread"
        )

        let graph = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            assignments: [assignment],
            codexTasks: [helper]
        )
        let edge = try #require(graph.edges.first(where: {
            $0.destination == .codexTask(helper.id, project: project.id)
        }))

        #expect(edge.source == .agent(agent.id, project: project.id))
        #expect(edge.kind == .activity)
    }

    @Test("Codex helper lifecycle values retain readable titles and terminal states")
    func codexHelperLifecycleNormalization() {
        #expect(CodexGateway.helperTitle(
            agentPath: "/root/security_baseline",
            threadID: "thread-123"
        ) == "Security Baseline")
        #expect(CodexGateway.helperStatus(activityKind: "completed") == .completed)
        #expect(CodexGateway.helperStatus(activityKind: "interrupted") == .cancelled)
        #expect(CodexGateway.helperStatus(
            agentStatus: "errored",
            tool: "wait",
            toolStatus: "completed",
            existing: .active
        ) == .failed)
        #expect(CodexGateway.helperStatus(
            agentStatus: "completed",
            tool: "wait",
            toolStatus: "completed",
            existing: .active
        ) == .completed)
    }

    @Test("Codex work items provide safe live inspector progress")
    func codexWorkProgressMessages() {
        let command = JSONValue.object([
            "type": .string("commandExecution"),
            "command": .string("print-secret --token private-value"),
            "cwd": .string("/private/project")
        ])
        #expect(CodexGateway.workProgressMessage(
            item: command,
            completed: false
        ) == "Running a command")
        #expect(CodexGateway.workProgressMessage(
            item: command,
            completed: true
        ) == "Command finished")
        #expect(CodexGateway.workProgressMessage(
            item: .object(["type": .string("fileChange")]),
            completed: false
        ) == "Preparing file changes")
        #expect(CodexGateway.workProgressMessage(
            item: .object(["type": .string("agentMessage")]),
            completed: false
        ) == nil)
    }

    @Test("Orchestrator completes only after Codex and verification")
    func orchestratorLifecycle() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "General work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "run",
            interpretedGoal: "Inspect the project",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .low,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run])
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: FakeCodex(),
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier(),
            maximumConcurrentAssignments: 2
        )

        try await orchestrator.execute(runID: run.id)
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
        #expect(completed.outcome?.contains("Verified") == true)
        #expect(completed.journal.contains { $0.message.contains("Completed") })
    }

    @Test("A read-only answer with no approved writes completes without project checks")
    func readOnlyAnswerSkipsProjectChecks() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            testCommands: ["./gradlew test"],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "General work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "run",
            interpretedGoal: "Make a growth plan",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run])
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: FakeCodex(),
            workspaces: FakeWorkspace(),
            verifier: FailingVerifier()
        )

        try await orchestrator.execute(runID: run.id)
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.outcome?.contains("Codex completed") == true)
        #expect(completed.outcome?.contains("project checks were not required") == true)
    }

    @Test("Only read-only assignments watched from start without approved writes skip checks")
    func readOnlySkipRule() {
        #expect(CodexRunOrchestrator.readOnlyAssignmentSkipsProjectChecks(
            risk: .readOnly, observedFromStart: true, approvedWrites: false))
        #expect(!CodexRunOrchestrator.readOnlyAssignmentSkipsProjectChecks(
            risk: .readOnly, observedFromStart: true, approvedWrites: true))
        #expect(!CodexRunOrchestrator.readOnlyAssignmentSkipsProjectChecks(
            risk: .readOnly, observedFromStart: false, approvedWrites: false))
        #expect(!CodexRunOrchestrator.readOnlyAssignmentSkipsProjectChecks(
            risk: .low, observedFromStart: true, approvedWrites: false))
    }

    @Test("Provider activity steps are saved on the run, merged by id")
    func activityStepsAreSaved() async throws {
        let project = LabProject(
            id: "project", name: "Project", rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general], isGitRepository: false
        )
        let agent = AgentProfile(id: "agent", name: "Agent", summary: "General work", capabilities: [.routing], scope: .project(project.id))
        let plan = RoutingPlan(
            id: "run", interpretedGoal: "Plan growth",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly, confidence: 1
        )
        let assignment = AgentAssignment(
            id: "assignment", runID: plan.id, projectID: project.id, agentID: agent.id,
            status: .queued, currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id, plan: plan, status: .ready, assignments: [assignment], agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)], projectSnapshot: [project]
        )
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run])
        let orchestrator = CodexRunOrchestrator(
            catalog: repository, runs: repository, codex: ActivityFakeCodex(),
            workspaces: FakeWorkspace(), verifier: FakeVerifier()
        )

        try await orchestrator.execute(runID: run.id)
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.activity.map(\.id) == ["c1", "m1"])
        #expect(completed.activity.first?.status == .succeeded)
        #expect(completed.activity.first?.exitCode == 0)
    }

    @Test("A failed verification keeps the agent's result, marked unverified")
    func failedVerificationKeepsAgentResult() async throws {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "General work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "run",
            interpretedGoal: "Make a growth plan",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .low,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run])
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: FakeCodex(),
            workspaces: FakeWorkspace(),
            verifier: FailingVerifier()
        )

        try? await orchestrator.execute(runID: run.id)
        let failed = try #require(await repository.allRuns().first)
        #expect(failed.status == .failed)
        let reason = try #require(failed.assignments.first?.statusReason)
        #expect(reason.contains("Checks failed"))
        #expect(reason.contains("Agent result (not verified):\nCodex completed"))
    }

    @Test("Orchestrator does not finalize a project when required verification evidence is missing")
    func orchestratorBlocksFinalizationWithoutVerificationEvidence() async throws {
        let project = LabProject(
            id: "verification-gate-project",
            name: "Verification Gate Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            testCommands: ["swift test"],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "verification-gate-agent",
            name: "Verification Gate Agent",
            summary: "Exercises the completion gate",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "verification-gate-run",
            interpretedGoal: "Inspect verification evidence",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .low,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "verification-gate-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run])
        let workspace = RecordingWorkspace()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: FakeCodex(),
            workspaces: workspace,
            verifier: ProjectVerifier()
        )

        try await orchestrator.execute(runID: run.id)

        let failed = try #require(await repository.allRuns().first)
        #expect(failed.status == .failed)
        #expect(failed.assignments.first?.status == .failed)
        #expect(failed.outcome?.contains("Missing structured execution evidence") == true)
        #expect(await workspace.finalizationCount() == 0)
    }

    @Test("Retry recovers a run that lacked structured verification evidence")
    func retryRecoversMissingVerificationEvidence() async throws {
        let project = LabProject(
            id: "verification-retry-project",
            name: "Verification Retry Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            testCommands: ["swift test"],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "verification-retry-agent",
            name: "Verification Retry Agent",
            summary: "Supplies verification evidence on a fresh attempt",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "verification-retry-run",
            interpretedGoal: "Retry with complete verification evidence",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .low,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "verification-retry-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [run]
        )
        let runtime = RetryEvidenceCodex()
        let workspace = RecordingWorkspace()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: runtime,
            workspaces: workspace,
            verifier: ProjectVerifier()
        )

        try await orchestrator.execute(runID: run.id)
        let failed = try #require(await repository.allRuns().first)
        #expect(failed.status == .failed)
        #expect(failed.outcome?.contains("Missing structured execution evidence") == true)

        try await orchestrator.resume(runID: run.id)

        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
        #expect(completed.outcome?.contains("Verified from Codex App Server") == true)
        #expect(await runtime.startCount == 2)
        #expect(await runtime.startedTasks == [plan.interpretedGoal, plan.interpretedGoal])
        #expect(await runtime.startedWithPriorProviderTask == [false, false])
        #expect(await workspace.finalizationCount() == 1)
    }

    @Test("A policy-blocked accept is rejected without declining the pending approval", .timeLimit(.minutes(1)))
    func orchestratorRejectsPolicyBlockedAcceptWithoutDeclining() async throws {
        let project = LabProject(
            id: "policy-project",
            name: "Policy Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "policy-agent",
            name: "Policy Agent",
            summary: "Exercises the approval boundary",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "policy-run",
            interpretedGoal: "Inspect",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "policy-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = ApprovalFakeCodex()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        var approval: ProviderApprovalRequest?
        for _ in 0..<100 where approval == nil {
            approval = await orchestrator.pendingApprovals().first
            if approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let blocked = try #require(approval)
        #expect(!blocked.canAccept)

        await #expect(throws: ProviderApprovalBindingError.missingOrChangedOperationDigest) {
            try await orchestrator.respond(to: blocked, decision: .acceptForSession)
        }

        #expect(await codex.receivedDecision == nil)
        #expect(await orchestrator.pendingApprovals() == [blocked])

        try await orchestrator.respond(to: blocked, decision: .decline)
        try await execution.value

        #expect(await codex.receivedDecision == .decline)
        #expect(await orchestrator.pendingApprovals().isEmpty)
    }

    @Test("Only one concurrent response can claim a pending approval", .timeLimit(.minutes(1)))
    func orchestratorSerializesConcurrentApprovalResponses() async throws {
        let project = LabProject(
            id: "response-race-project",
            name: "Response Race Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "response-race-agent",
            name: "Response Race Agent",
            summary: "Exercises concurrent approval responses",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "response-race-run",
            interpretedGoal: "Approve once",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "response-race-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = ApprovalFakeCodex(
            canAccept: true,
            responseDelay: .milliseconds(100)
        )
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        var approval: ProviderApprovalRequest?
        for _ in 0..<100 where approval == nil {
            approval = await orchestrator.pendingApprovals().first
            if approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pending = try #require(approval)
        let accepted = Task { try await orchestrator.respond(to: pending, decision: .accept) }
        for _ in 0..<100 where await codex.responseAttempts == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        await #expect(throws: ProviderApprovalBindingError.missingOrChangedOperationDigest) {
            try await orchestrator.respond(to: pending, decision: .decline)
        }
        try await accepted.value
        try await execution.value

        #expect(await codex.responseAttempts == 1)
        #expect(await codex.receivedDecision == .accept)
    }

    @Test("A declined approval releases a silent provider attempt and Retry starts fresh", .timeLimit(.minutes(1)))
    func declinedApprovalCanBeRetriedWhenProviderSendsNoTerminalEvent() async throws {
        let project = LabProject(
            id: "silent-decline-project",
            name: "Silent Decline Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "silent-decline-agent",
            name: "Silent Decline Agent",
            summary: "Exercises retry after a declined approval",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "silent-decline-run",
            interpretedGoal: "Retry after declining the operation",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "silent-decline-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = ApprovalFakeCodex(
            emitsTerminalResponse: false,
            completesOnRetry: true
        )
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        var approval: ProviderApprovalRequest?
        for _ in 0..<100 where approval == nil {
            approval = await orchestrator.pendingApprovals().first
            if approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pending = try #require(approval)
        try await orchestrator.respond(to: pending, decision: .decline)
        try await execution.value

        let awaitingRetry = try #require(await repository.allRuns().first)
        #expect(awaitingRetry.status == .needsAttention)
        #expect(awaitingRetry.assignments.first?.status == .failed)

        try await orchestrator.resume(runID: plan.id)

        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
        #expect(await codex.startCount == 2)
    }

    @Test("A provider session approval is reduced to one eligible assignment", .timeLimit(.minutes(1)))
    func orchestratorAcceptsEligibleApprovalForSession() async throws {
        let project = LabProject(
            id: "session-policy-project",
            name: "Session Policy Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "session-policy-agent",
            name: "Session Policy Agent",
            summary: "Exercises session approval",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "session-policy-run",
            interpretedGoal: "Inspect",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "session-policy-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = ApprovalFakeCodex(canAccept: true)
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        var approval: ProviderApprovalRequest?
        for _ in 0..<100 where approval == nil {
            approval = await orchestrator.pendingApprovals().first
            if approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pending = try #require(approval)
        #expect(pending.canAccept)

        let changedAfterReview = ProviderApprovalRequest(
            id: pending.id,
            providerID: pending.providerID,
            assignmentID: pending.assignmentID,
            kind: pending.kind,
            summary: "A different operation",
            details: pending.details,
            canAccept: pending.canAccept,
            approvalSessionID: pending.approvalSessionID,
            operationDigest: String(repeating: "b", count: 64),
            disclosureComplete: pending.disclosureComplete
        )
        await #expect(throws: ProviderApprovalBindingError.missingOrChangedOperationDigest) {
            try await orchestrator.respond(to: changedAfterReview, decision: .accept)
        }
        #expect(await codex.receivedDecision == nil)

        try await orchestrator.respond(to: pending, decision: .acceptForSession)
        try await execution.value

        #expect(await codex.receivedDecision == .accept)
        #expect(await codex.receivedOperationDigest == String(repeating: "a", count: 64))
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
    }

    @Test("Wider approval choices require a fresh decision for every request", .timeLimit(.minutes(1)))
    func orchestratorAcceptsAllLaterApprovalTypesForRun() async throws {
        let project = LabProject(
            id: "all-approval-types-project",
            name: "All Approval Types Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "all-approval-types-agent",
            name: "All Approval Types Agent",
            summary: "Exercises run-wide approval",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "all-approval-types-run",
            interpretedGoal: "Exercise every approval type",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "all-approval-types-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = RunWideApprovalFakeCodex()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        var approval: ProviderApprovalRequest?
        for _ in 0..<100 where approval == nil {
            approval = await orchestrator.pendingApprovals().first
            if approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pending = try #require(approval)
        #expect(pending.kind == .command)

        try await orchestrator.respond(to: pending, decision: .acceptAllForRun)

        var repeated: ProviderApprovalRequest?
        for _ in 0..<100 where repeated == nil {
            repeated = await orchestrator.pendingApprovals().first
            if repeated == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let repeatedCommand = try #require(repeated)
        #expect(repeatedCommand.id == "approval-command-repeat")
        #expect(await codex.responses.map(\.approvalID) == ["approval-command"])
        #expect(await codex.responses.map(\.decision) == [.accept])

        try await orchestrator.respond(to: repeatedCommand, decision: .acceptForSession)

        var separatelyScoped: ProviderApprovalRequest?
        for _ in 0..<100 where separatelyScoped == nil {
            separatelyScoped = await orchestrator.pendingApprovals().first
            if separatelyScoped == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let permission = try #require(separatelyScoped)
        #expect(permission.kind == .permissions)
        #expect(await codex.responses.map(\.approvalID) == ["approval-command", "approval-command-repeat"])
        #expect(await codex.responses.map(\.decision) == [.accept, .accept])

        try await orchestrator.respond(to: permission, decision: .accept)
        try await execution.value

        let responses = await codex.responses
        #expect(responses.map(\.approvalID) == ["approval-command", "approval-command-repeat", "approval-permissions"])
        #expect(responses.map(\.decision) == [.accept, .accept, .accept])
        #expect(responses.map(\.operationDigest) == [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            String(repeating: "c", count: 64),
        ])
        #expect(await orchestrator.pendingApprovals().isEmpty)
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.assignments.first?.status == .completed)
    }

    @Test("Pausing an interrupted Codex turn preserves its paused state", .timeLimit(.minutes(1)))
    func pausePreservesAssignmentState() async throws {
        let project = LabProject(
            id: "pause-project",
            name: "Pause Project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "pause-agent",
            name: "Pause Agent",
            summary: "Waits for interruption",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "pause-run",
            interpretedGoal: "Wait until paused",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "pause-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let codex = InterruptingFakeCodex()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: codex,
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier()
        )
        let execution = Task { try await orchestrator.execute(runID: plan.id) }

        for _ in 0..<100 {
            if await repository.allRuns().first?.assignments.first?.status == .working { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await repository.allRuns().first?.assignments.first?.status == .working)

        try await orchestrator.pause(runID: plan.id)
        try await execution.value

        let paused = try #require(await repository.allRuns().first)
        #expect(paused.status == .needsAttention)
        #expect(paused.assignments.first?.status == .paused)
        #expect(paused.assignments.first?.statusReason == "Paused by user")
    }

    @Test("Agent archive is reversible and keeps the same stable identity")
    func reversibleAgentArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-agent-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let agent = AgentProfile(
            id: "stable-agent",
            name: "Web Agent",
            summary: "Owns web implementation",
            capabilities: [.web],
            scope: .global
        )

        try await store.saveAgent(agent)
        try await store.setAgentEnabled(id: agent.id, enabled: false)
        #expect(try await store.snapshot().agents.first?.isEnabled == false)
        try await store.setAgentEnabled(id: agent.id, enabled: true)
        let restored = try #require(try await store.snapshot().agents.first)
        #expect(restored.id == agent.id)
        #expect(restored.isEnabled)
    }

    @Test("Catalog refresh preserves registration history and archived agent state")
    func catalogRefreshPreservesUserState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-refresh-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let project = LabProject(
            id: "refresh-project",
            name: "Website",
            rootURL: URL(fileURLWithPath: "/tmp/refresh-project"),
            platforms: [.web],
            frameworks: ["React"],
            isGitRepository: true,
            registeredAt: originalDate
        )
        let agent = AgentProfile(
            id: "refresh-agent",
            name: "Web Agent",
            summary: "Original instructions",
            capabilities: [.web],
            scope: .project(project.id)
        )
        try await store.register(projects: [project], agents: [agent])
        try await store.setAgentEnabled(id: agent.id, enabled: false)

        let refreshedProject = LabProject(
            id: project.id,
            name: project.name,
            rootURL: project.rootURL,
            platforms: project.platforms,
            frameworks: ["Next.js"],
            testCommands: ["npm test"],
            isGitRepository: project.isGitRepository
        )
        let refreshedAgent = AgentProfile(
            id: agent.id,
            name: agent.name,
            summary: "Updated instructions",
            capabilities: [.web, .testing],
            scope: agent.scope,
            isEnabled: true
        )
        try await store.register(projects: [refreshedProject], agents: [refreshedAgent])

        let snapshot = try await store.snapshot()
        let savedProject = try #require(snapshot.projects.first)
        let savedAgent = try #require(snapshot.agents.first)
        #expect(savedProject.registeredAt == originalDate)
        #expect(savedProject.frameworks == ["Next.js"])
        #expect(savedAgent.summary == "Updated instructions")
        #expect(savedAgent.capabilities == [.web, .testing])
        #expect(savedAgent.isEnabled == false)
    }

    @Test("An imported catalog survives a new persistent store instance")
    func importedCatalogSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-relaunch-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = LabProject(
            id: "remembered-project",
            name: "Remembered Project",
            rootURL: URL(fileURLWithPath: "/tmp/remembered-project"),
            platforms: [.web],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "remembered-agent",
            name: "Remembered Agent",
            summary: "Restored with the imported project",
            capabilities: [.web],
            scope: .project(project.id)
        )

        let importer = PersistentStore(directoryURL: directory)
        try await importer.register(projects: [project], agents: [agent])

        let relaunchedStore = PersistentStore(directoryURL: directory)
        let restored = try await relaunchedStore.snapshot()

        #expect(restored.projects.map(\.id) == [project.id])
        #expect(restored.agents.map(\.id) == [agent.id])
    }

    @Test("Removing a project changes only Goby's catalog and preserves the directory")
    func projectRemovalPreservesDirectoryAndUnrelatedAgents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-project-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appending(path: "Workspace", directoryHint: .isDirectory)
        let marker = projectRoot.appending(path: "keep-me.txt")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: marker, options: .atomic)

        let store = PersistentStore(directoryURL: root.appending(path: "Goby State", directoryHint: .isDirectory))
        let project = LabProject(
            id: "catalog-only-project",
            name: "Catalog Only",
            rootURL: projectRoot,
            platforms: [.web],
            isGitRepository: true
        )
        let scopedAgent = AgentProfile(
            id: "catalog-only-agent",
            name: "Project Agent",
            summary: "Scoped to the removed project",
            capabilities: [.web],
            scope: .project(project.id),
            sourceURL: projectRoot.appending(path: ".codex/agents/web.toml")
        )
        let globalAgent = AgentProfile(
            id: "global-agent",
            name: "Global Agent",
            summary: "Must remain registered",
            capabilities: [.routing],
            scope: .global
        )
        try await store.register(projects: [project], agents: [scopedAgent, globalAgent])

        try await store.removeProject(id: project.id)

        let snapshot = try await store.snapshot()
        #expect(snapshot.projects.isEmpty)
        #expect(snapshot.agents.map(\.id) == [globalAgent.id])
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "untouched")
    }

    @Test("Changing shared-folder access does not silently re-enable it")
    func sharedResourceAccessPreservesDisabledState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-resource-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let resource = SharedResource(
            id: "shared-folder",
            name: "Reference",
            url: URL(fileURLWithPath: "/tmp/reference"),
            access: .readOnly,
            isEnabled: false
        )

        try await store.saveResource(resource)
        try await SetSharedResourceAccessUseCase(repository: store)(resource, access: .readWrite)

        let saved = try #require(try await store.allResources().first)
        #expect(saved.access == .readWrite)
        #expect(saved.isEnabled == false)
    }

    @Test("Reviewed shared-folder settings update access and availability in one persisted document")
    func sharedResourceSettingsAreAppliedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-resource-settings-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let resource = SharedResource(
            id: "reviewed-folder",
            name: "Reference",
            url: URL(fileURLWithPath: "/tmp/reference"),
            access: .readOnly,
            isEnabled: false
        )
        try await store.saveResource(resource)

        try await SetSharedResourceSettingsUseCase(repository: store)(
            id: resource.id,
            access: .readWrite,
            enabled: true
        )

        let saved = try #require(try await store.allResources().first)
        #expect(saved.access == .readWrite)
        #expect(saved.isEnabled)
        #expect(saved.registeredAt == resource.registeredAt)
        await #expect(throws: GobyApplicationError.unknownSharedResource("missing")) {
            try await SetSharedResourceSettingsUseCase(repository: store)(
                id: "missing",
                access: .readOnly,
                enabled: false
            )
        }
    }

    @Test("A corrupted primary store recovers from the previous atomic snapshot")
    func persistentStoreRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-recovery-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LabProject(
            id: "first",
            name: "First",
            rootURL: URL(fileURLWithPath: "/tmp/first"),
            platforms: [.general],
            isGitRepository: false
        )
        let second = LabProject(
            id: "second",
            name: "Second",
            rootURL: URL(fileURLWithPath: "/tmp/second"),
            platforms: [.general],
            isGitRepository: false
        )
        let writer = PersistentStore(directoryURL: directory)
        try await writer.register(projects: [first], agents: [])
        try await writer.register(projects: [second], agents: [])
        try Data("not-json".utf8).write(to: directory.appending(path: "catalog.json"), options: .atomic)

        let recovered = try await PersistentStore(directoryURL: directory).snapshot()
        #expect(recovered.projects.map(\.id) == [first.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files.contains { $0.contains("catalog.json.corrupt-") })
    }

    @Test("A semantically corrupt catalog recovers before duplicate identities can trap")
    func persistentStoreSemanticRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-semantic-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LabProject(
            id: "semantic-first",
            name: "First",
            rootURL: URL(fileURLWithPath: "/tmp/semantic-first"),
            platforms: [.general],
            isGitRepository: false
        )
        let second = LabProject(
            id: "semantic-second",
            name: "Second",
            rootURL: URL(fileURLWithPath: "/tmp/semantic-second"),
            platforms: [.general],
            isGitRepository: false
        )
        let writer = PersistentStore(directoryURL: directory)
        try await writer.register(projects: [first], agents: [])
        try await writer.register(projects: [second], agents: [])

        let catalogURL = directory.appending(path: "catalog.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let projects = try #require(object["projects"] as? [[String: Any]])
        object["projects"] = projects + [try #require(projects.first)]
        try JSONSerialization.data(withJSONObject: object).write(to: catalogURL, options: .atomic)

        let recovered = try await PersistentStore(directoryURL: directory).snapshot()
        #expect(recovered.projects.map(\.id) == [first.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files.contains { $0.contains("catalog.json.corrupt-") })
    }

    @Test("Persistent state and backups are readable only by the current user")
    func persistentStoreUsesOwnerOnlyPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-private-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        let first = LabProject(
            id: "private-first",
            name: "Private First",
            rootURL: URL(fileURLWithPath: "/tmp/private-first"),
            platforms: [.general],
            isGitRepository: false
        )
        let second = LabProject(
            id: "private-second",
            name: "Private Second",
            rootURL: URL(fileURLWithPath: "/tmp/private-second"),
            platforms: [.general],
            isGitRepository: false
        )

        try await store.register(projects: [first], agents: [])
        try await store.register(projects: [second], agents: [])

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        #expect(directoryMode == 0o700)
        for name in ["catalog.json", "catalog.json.previous"] {
            let path = directory.appending(path: name).path(percentEncoded: false)
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            ).intValue & 0o777
            #expect(mode == 0o600)
        }
    }

    @Test("A newer store schema is refused without overwriting or quarantining it")
    func futurePersistentStoreVersionIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-future-store-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appending(path: "catalog.json")
        let original = Data(#"{"version":999,"projects":[],"agents":[]}"#.utf8)
        try original.write(to: catalogURL, options: .atomic)

        do {
            _ = try await PersistentStore(directoryURL: directory).snapshot()
            Issue.record("A newer incompatible schema was accepted.")
        } catch {
            #expect(error.localizedDescription.contains("data version 999"))
        }

        #expect(try Data(contentsOf: catalogURL) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(!files.contains { $0.contains(".corrupt-") })
    }

    @Test("Diagnostic export omits free-form paths, account identifiers, and run text")
    func diagnosticRedaction() async throws {
        let secret = "sk-abcdefghijklmnop"
        let email = "person@example.com"
        let project = LabProject(
            id: "project",
            name: "Project for \(email)",
            rootURL: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "SecretProject"),
            platforms: [.general],
            isGitRepository: false
        )
        let plan = RoutingPlan(interpretedGoal: "Use token=\(secret)", routes: [], risk: .readOnly, confidence: 1)
        let run = RunRecord(id: plan.id, plan: plan, status: .failed, assignments: [], outcome: "Bearer \(secret)")
        let report = try await RedactedDiagnosticExporter().report(
            lab: LabSnapshot(projects: [project], agents: []),
            runs: [run],
            health: SystemHealthSnapshot(checks: [])
        )

        #expect(!report.contains(secret))
        #expect(!report.contains(email))
        #expect(!report.contains(NSHomeDirectory()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let runObjects = try #require(object["runs"] as? [[String: Any]])
        let runObject = try #require(runObjects.first)
        #expect(runObject["goal"] == nil)
        #expect(runObject["outcome"] == nil)
        #expect(runObject["hasOutcome"] as? Bool == true)
    }

    @Test("Project verifier never executes detected project commands on the host and fails without evidence")
    func projectVerifierDoesNotLaunchHostCommands() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-verifier-safety-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "should-not-exist")
        let project = LabProject(
            id: "safe-verifier",
            name: "Safe Verifier",
            rootURL: directory,
            platforms: [.general],
            testCommands: ["touch \(marker.path(percentEncoded: false))"],
            isGitRepository: false
        )

        let result = await ProjectVerifier().verify(
            project: project,
            workingDirectory: directory,
            evidence: [ProviderCommandExecutionEvidence]()
        )

        #expect(!result.succeeded)
        #expect(result.summary.contains("Missing structured execution evidence"))
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test("Project verifier accepts successful App Server evidence inside the prepared workspace")
    func projectVerifierAcceptsSuccessfulEvidence() async {
        let directory = URL(fileURLWithPath: "/tmp/goby-verifier-success", isDirectory: true)
        let project = LabProject(
            id: "verified-project",
            name: "Verified Project",
            rootURL: directory,
            platforms: [.general],
            testCommands: ["swift   test"],
            isGitRepository: false
        )
        let evidence = CodexCommandExecutionEvidence(
            id: "command-1",
            command: "swift test",
            workingDirectory: directory,
            status: .completed,
            exitCode: 0,
            durationMilliseconds: 125
        )

        let result = await ProjectVerifier().verify(
            project: project,
            workingDirectory: directory,
            evidence: [evidence]
        )

        #expect(result.succeeded)
        #expect(result.summary.contains("exit 0 in 125 ms"))
        #expect(result.summary.contains("did not re-execute project code on the host"))
    }

    @Test("Project verifier accepts unquoted execution of simple shell-safe arguments")
    func projectVerifierAcceptsEquivalentSimpleQuotes() async {
        let directory = URL(fileURLWithPath: "/tmp/goby-verifier-quoted", isDirectory: true)
        let project = LabProject(
            id: "quoted-project", name: "Quoted Project", rootURL: directory,
            platforms: [.general], testCommands: ["'./android/gradlew' -p 'android' test"],
            isGitRepository: false
        )
        let evidence = CodexCommandExecutionEvidence(
            id: "command-1", command: "./android/gradlew -p android test",
            workingDirectory: directory, status: .completed, exitCode: 0
        )
        let result = await ProjectVerifier().verify(
            project: project, workingDirectory: directory, evidence: [evidence]
        )
        #expect(result.succeeded)
    }

    @Test("Project verifier rejects failed or out-of-workspace execution evidence")
    func projectVerifierRejectsInvalidEvidence() async {
        let directory = URL(fileURLWithPath: "/tmp/goby-verifier-workspace", isDirectory: true)
        let project = LabProject(
            id: "invalid-evidence-project",
            name: "Invalid Evidence Project",
            rootURL: directory,
            platforms: [.general],
            testCommands: ["swift test"],
            isGitRepository: false
        )
        let failed = CodexCommandExecutionEvidence(
            id: "command-failed",
            command: "swift test",
            workingDirectory: directory,
            status: .failed,
            exitCode: 1
        )
        let outside = CodexCommandExecutionEvidence(
            id: "command-outside",
            command: "swift test",
            workingDirectory: URL(fileURLWithPath: "/tmp/another-workspace", isDirectory: true),
            status: .completed,
            exitCode: 0
        )

        let failedResult = await ProjectVerifier().verify(
            project: project,
            workingDirectory: directory,
            evidence: [failed]
        )
        let outsideResult = await ProjectVerifier().verify(
            project: project,
            workingDirectory: directory,
            evidence: [outside]
        )

        #expect(!failedResult.succeeded)
        #expect(failedResult.summary.contains("exit code 1"))
        #expect(!outsideResult.succeeded)
        #expect(outsideResult.summary.contains("Missing structured execution evidence"))
    }

    @Test("Codex gateway parses completed command execution evidence")
    func codexGatewayParsesCommandEvidence() throws {
        let data = Data(#"{"item":{"id":"cmd-7","type":"commandExecution","command":"/bin/zsh -lc 'swift test'","commandActions":[{"type":"unknown","command":"swift test"}],"cwd":"/tmp/project","status":"completed","exitCode":0,"durationMs":42,"source":"unifiedExecStartup"},"threadId":"thread","turnId":"turn","completedAtMs":1}"#.utf8)
        let params = try JSONDecoder().decode(JSONValue.self, from: data)
        let evidence = try #require(CodexGateway.commandExecutionEvidence(from: params))

        #expect(evidence.id == "cmd-7")
        #expect(evidence.command == "/bin/zsh -lc 'swift test'")
        #expect(evidence.actionCommands == ["swift test"])
        #expect(
            evidence.workingDirectory.standardizedFileURL
                == URL(fileURLWithPath: "/tmp/project", isDirectory: true).standardizedFileURL
        )
        #expect(evidence.status == .completed)
        #expect(evidence.exitCode == 0)
        #expect(evidence.durationMilliseconds == 42)
        #expect(evidence.source == "unifiedExecStartup")
    }

    @Test("Permission details disclose the exact canonical grant")
    func permissionDetailsAreCanonical() throws {
        let permissions: JSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
            "path": .string("/tmp/reference")
        ])
        let details = try #require(CodexGateway.permissionDetails(for: permissions))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8))

        #expect(decoded == permissions)
        #expect(details.first == "{")
    }

    @Test("Codex command approvals bind every current app-server field")
    func codexCommandApprovalBindingIsComplete() throws {
        let params: JSONValue = .object([
            "additionalPermissions": .object(["network": .bool(true)]),
            "approvalId": .string("approval-1"),
            "command": .string("swift test"),
            "commandActions": .array([.object([
                "command": .string("swift test"),
                "type": .string("unknown"),
            ])]),
            "cwd": .string("/tmp/project"),
            "environmentId": .string("environment-1"),
            "itemId": .string("item-1"),
            "kind": .string("command"),
            "networkApprovalContext": .object(["host": .string("example.test")]),
            "proposedExecpolicyAmendment": .array([.string("swift")]),
            "proposedNetworkPolicyAmendments": .array([.string("example.test")]),
            "reason": .string("Run the tests"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])

        let binding = CodexGateway.approvalOperationBinding(
            method: "item/commandExecution/requestApproval",
            params: params
        )
        let details = try #require(binding.details)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8))

        #expect(binding.disclosureComplete)
        #expect(binding.operationDigest?.count == 64)
        #expect(decoded["request"]?["cwd"]?.stringValue == "/tmp/project")
        #expect(decoded["request"]?["itemId"]?.stringValue == "item-1")
    }

    @Test("Codex approval schema drift and missing file diffs fail closed")
    func codexApprovalBindingFailsClosed() {
        let base: [String: JSONValue] = [
            "itemId": .string("item-1"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ]
        var drifted = base
        drifted["newExecutableField"] = .string("not disclosed by this client version")

        let driftedBinding = CodexGateway.approvalOperationBinding(
            method: "item/commandExecution/requestApproval",
            params: .object(drifted)
        )
        let missingDiff = CodexGateway.approvalOperationBinding(
            method: "item/fileChange/requestApproval",
            params: .object(base)
        )

        #expect(!driftedBinding.disclosureComplete)
        #expect(driftedBinding.operationDigest == nil)
        #expect(!missingDiff.disclosureComplete)
        #expect(missingDiff.operationDigest == nil)
    }

    @Test("Codex command approvals require a disclosed operation and working directory")
    func codexCommandApprovalRequiresOperationAndWorkingDirectory() {
        let metadata: [String: JSONValue] = [
            "itemId": .string("item-1"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ]
        var missingOperation = metadata
        missingOperation["cwd"] = .string("/tmp/project")
        var missingWorkingDirectory = metadata
        missingWorkingDirectory["command"] = .string("swift test")
        var emptyActions = missingOperation
        emptyActions["commandActions"] = .array([])
        var malformedActions = missingOperation
        malformedActions["commandActions"] = .array([.object(["command": .string("   ")])])
        var writeStdin = metadata
        writeStdin["kind"] = .string("writeStdin")
        writeStdin["command"] = .string("stale parent command")
        writeStdin["cwd"] = .string("/tmp/project")
        var unknownKind = writeStdin
        unknownKind["kind"] = .string("futureExecutableKind")
        var nullKind = writeStdin
        nullKind["kind"] = .null
        var nonStringKind = writeStdin
        nonStringKind["kind"] = .integer(1)

        for request in [
            metadata, missingOperation, missingWorkingDirectory, emptyActions,
            malformedActions, writeStdin, unknownKind, nullKind, nonStringKind,
        ] {
            let binding = CodexGateway.approvalOperationBinding(
                method: "item/commandExecution/requestApproval",
                params: .object(request)
            )
            #expect(!binding.disclosureComplete)
            #expect(binding.operationDigest == nil)
        }
    }

    @Test("Codex command approvals accept either complete command representation")
    func codexCommandApprovalAcceptsCompleteRepresentations() {
        let metadata: [String: JSONValue] = [
            "cwd": .string("/tmp/project"),
            "itemId": .string("item-1"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ]
        var command = metadata
        command["command"] = .string("swift test")
        var actions = metadata
        actions["commandActions"] = .array([.object([
            "command": .string("swift test"),
            "type": .string("unknown"),
        ])])

        for request in [command, actions] {
            let binding = CodexGateway.approvalOperationBinding(
                method: "item/commandExecution/requestApproval",
                params: .object(request)
            )
            #expect(binding.disclosureComplete)
            #expect(binding.operationDigest?.count == 64)
        }
    }

    @Test("Codex command approvals bind best-effort parsed actions without equating them to the authoritative command")
    func codexCommandApprovalBindsParsedActionMetadata() throws {
        let metadata: [String: JSONValue] = [
            "command": .string("/bin/zsh -lc \"'./android/gradlew' -p 'android' test\""),
            "cwd": .string("/tmp/project"),
            "itemId": .string("item-1"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ]
        var parsedWrapper = metadata
        parsedWrapper["commandActions"] = .array([
            .object([
                "command": .string("'./android/gradlew' -p 'android' test"),
                "type": .string("unknown"),
            ]),
        ])
        var multipleActions = metadata
        multipleActions["commandActions"] = .array([
            .object([
                "command": .string("'./android/gradlew' -p 'android' test"),
                "type": .string("unknown"),
            ]),
            .object([
                "command": .string("echo done"),
                "type": .string("unknown"),
            ]),
        ])

        for request in [parsedWrapper, multipleActions] {
            let binding = CodexGateway.approvalOperationBinding(
                method: "item/commandExecution/requestApproval",
                params: .object(request)
            )
            let details = try #require(binding.details)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8))

            #expect(binding.disclosureComplete)
            #expect(binding.operationDigest?.count == 64)
            #expect(decoded["request"] == .object(request))
        }

        #expect(
            CodexGateway.approvalOperationBinding(
                method: "item/commandExecution/requestApproval",
                params: .object(parsedWrapper)
            ).operationDigest
                != CodexGateway.approvalOperationBinding(
                    method: "item/commandExecution/requestApproval",
                    params: .object(multipleActions)
                ).operationDigest
        )
    }

    @Test("Codex command approvals reject malformed secondary action metadata")
    func codexCommandApprovalRejectsMalformedActionMetadata() {
        let request: JSONValue = .object([
            "command": .string("swift test"),
            "commandActions": .array([.object([
                "command": .string("   "),
                "type": .string("unknown"),
            ])]),
            "cwd": .string("/tmp/project"),
            "itemId": .string("item-1"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])

        let binding = CodexGateway.approvalOperationBinding(
            method: "item/commandExecution/requestApproval",
            params: request
        )

        #expect(!binding.disclosureComplete)
        #expect(binding.operationDigest == nil)

        var missingType = request.objectValue ?? [:]
        missingType["commandActions"] = .array([.object(["command": .string("swift test")])])
        var unknownField = request.objectValue ?? [:]
        unknownField["commandActions"] = .array([.object([
            "command": .string("swift test"),
            "futureExecutableField": .string("unexpected"),
            "type": .string("unknown"),
        ])])

        for malformed in [missingType, unknownField] {
            let malformedBinding = CodexGateway.approvalOperationBinding(
                method: "item/commandExecution/requestApproval",
                params: .object(malformed)
            )
            #expect(!malformedBinding.disclosureComplete)
            #expect(malformedBinding.operationDigest == nil)
        }
    }

    @Test("Codex file approvals include exact paths and diffs in the binding")
    func codexFileApprovalBindingIncludesDiff() throws {
        let params: JSONValue = .object([
            "grantRoot": .string("/tmp/project"),
            "itemId": .string("item-1"),
            "reason": .string("Apply the requested change"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])
        let review: JSONValue = .object([
            "changes": .array([.object([
                "diff": .string("@@ -1 +1 @@\\n-old\\n+new"),
                "kind": .object(["type": .string("update")]),
                "path": .string("Sources/App.swift"),
            ])]),
            "itemId": .string("item-1"),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])

        let binding = CodexGateway.approvalOperationBinding(
            method: "item/fileChange/requestApproval",
            params: params,
            fileChangeReview: review
        )
        let details = try #require(binding.details)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8))
        let disclosedPath: String? = if case let .array(changes)? = decoded["changes"] {
            changes.first?["path"]?.stringValue
        } else {
            nil
        }

        #expect(binding.disclosureComplete)
        #expect(binding.operationDigest?.count == 64)
        #expect(disclosedPath == "Sources/App.swift")
    }

    @Test("Codex file approvals retain practical patches beyond the paired-device limit")
    func codexFileApprovalBindingRetainsLargePatch() {
        let params: JSONValue = .object([
            "itemId": .string("item-large"),
            "startedAtMs": .integer(1),
            "threadId": .string("thread-large"),
            "turnId": .string("turn-large"),
        ])
        let diff = String(repeating: "+let reviewed = true\n", count: 1_000)
        let review: JSONValue = .object([
            "changes": .array([.object([
                "diff": .string(diff),
                "kind": .object(["type": .string("update")]),
                "path": .string("Sources/Large.swift"),
            ])]),
            "itemId": .string("item-large"),
            "threadId": .string("thread-large"),
            "turnId": .string("turn-large"),
        ])

        let binding = CodexGateway.approvalOperationBinding(
            method: "item/fileChange/requestApproval",
            params: params,
            fileChangeReview: review
        )

        #expect(diff.utf8.count > MobileApprovalDisclosurePolicy.detailsUTF8Limit)
        #expect(binding.disclosureComplete)
        #expect(binding.operationDigest?.count == 64)
        #expect(binding.details?.contains("Sources/Large.swift") == true)
    }

    @Test("Codex binds a file approval when its patch notification follows the request", .timeLimit(.minutes(1)))
    func codexFileApprovalWaitsForFollowingPatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-file-approval-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "file-approval-order-server")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"file-approval-order-test\"}}"
          elif [[ "$line" == *'"method":"thread\/start"'* || "$line" == *'"method":"thread/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-file-order\"}}}"
          elif [[ "$line" == *'"method":"turn\/start"'* || "$line" == *'"method":"turn/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"turn\":{\"id\":\"turn-file-order\"}}}"
            print '{"jsonrpc":"2.0","id":903,"method":"item/fileChange/requestApproval","params":{"itemId":"item-file-order","reason":"Apply reviewed change","startedAtMs":1,"threadId":"thread-file-order","turnId":"turn-file-order"}}'
            print '{"jsonrpc":"2.0","method":"item/fileChange/patchUpdated","params":{"changes":[{"diff":"@@ -1 +1 @@\\n-old\\n+new","kind":{"type":"update"},"path":"Sources/Ordered.swift"}],"itemId":"item-file-order","threadId":"thread-file-order","turnId":"turn-file-order"}}'
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let assignment = AgentAssignment(
            id: "file-order-assignment",
            runID: "file-order-run",
            projectID: "file-order-project",
            agentID: "file-order-agent",
            status: .queued,
            currentTask: "Apply change"
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "File Order Project",
            rootURL: directory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "File Order Agent",
            summary: "Tests file approvals",
            capabilities: [.backend],
            scope: .project(project.id)
        )
        let events = await gateway.events()
        let approvalTask = Task<CodexApprovalRequest?, Never> {
            for await event in events {
                if case let .approvalRequired(request) = event { return request }
            }
            return nil
        }

        _ = try await gateway.connect()
        _ = try await gateway.start(
            assignment: assignment,
            project: project,
            agent: agent,
            instructions: [],
            resources: [],
            risk: .readOnly
        )
        let approval = try #require(await approvalTask.value)
        await gateway.disconnect()

        #expect(approval.canAccept)
        #expect(approval.disclosureComplete)
        #expect(approval.details?.contains("Sources/Ordered.swift") == true)
    }

    @Test("Codex approval acceptance requires the exact reviewed operation digest", .timeLimit(.minutes(1)))
    func codexApprovalResponseRequiresExactDigest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-approval-digest-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "approval-server")
        let responseLog = directory.appending(path: "responses.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(responseLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"approval-test\"}}"
          elif [[ "$line" == *'"method":"thread\/start"'* || "$line" == *'"method":"thread/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-approval\"}}}"
          elif [[ "$line" == *'"method":"turn\/start"'* || "$line" == *'"method":"turn/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"turn\":{\"id\":\"turn-approval\"}}}"
            print '{"jsonrpc":"2.0","id":900,"method":"item/commandExecution/requestApproval","params":{"command":"swift test","cwd":"/tmp/project","itemId":"item-1","startedAtMs":1,"threadId":"thread-approval","turnId":"turn-approval"}}'
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let assignment = AgentAssignment(
            id: "approval-assignment",
            runID: "approval-run",
            projectID: "approval-project",
            agentID: "approval-agent",
            status: .queued,
            currentTask: "Run tests"
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "Approval Project",
            rootURL: directory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "Approval Agent",
            summary: "Tests approvals",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let events = await gateway.events()
        let approvalTask = Task<CodexApprovalRequest?, Never> {
            for await event in events {
                if case let .approvalRequired(request) = event { return request }
            }
            return nil
        }

        do {
            _ = try await gateway.connect()
            _ = try await gateway.start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: [],
                resources: [],
                risk: .readOnly
            )
            await #expect(throws: CodexTransportError.assignmentAlreadyActive(assignment.id)) {
                try await gateway.start(
                    assignment: assignment,
                    project: project,
                    agent: agent,
                    instructions: [],
                    resources: [],
                    risk: .readOnly
                )
            }
        } catch {
            let responses = (try? String(contentsOf: responseLog, encoding: .utf8)) ?? "No requests captured"
            Issue.record("Approval mock failed: \(error.localizedDescription)\nRequests:\n\(responses)")
            await gateway.disconnect()
            return
        }
        let approval = try #require(await approvalTask.value)
        let reviewedDigest = try #require(approval.operationDigest)

        await #expect(throws: ProviderApprovalBindingError.missingOrChangedOperationDigest) {
            try await gateway.respond(
                to: approval.id,
                decision: .accept,
                operationDigest: String(repeating: "0", count: 64)
            )
        }
        try await gateway.respond(
            to: approval.id,
            decision: .accept,
            operationDigest: reviewedDigest
        )
        var responses = ""
        for _ in 0..<100 {
            responses = (try? String(contentsOf: responseLog, encoding: .utf8)) ?? ""
            if responses.contains("\"decision\":\"accept\"") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gateway.disconnect()

        #expect(responses.contains("\"id\":900"))
        #expect(responses.contains("\"decision\":\"accept\""))
    }

    @Test("Codex retains a pending approval when its response cannot reach App Server", .timeLimit(.minutes(1)))
    func codexApprovalResponseWriteFailureKeepsPending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-approval-write-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "approval-write-failure-server")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"approval-write-failure-test\"}}"
          elif [[ "$line" == *'"method":"thread\/start"'* || "$line" == *'"method":"thread/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-write-failure\"}}}"
          elif [[ "$line" == *'"method":"turn\/start"'* || "$line" == *'"method":"turn/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"turn\":{\"id\":\"turn-write-failure\"}}}"
            print '{"jsonrpc":"2.0","id":904,"method":"item/commandExecution/requestApproval","params":{"command":"swift test","cwd":"/tmp/project","itemId":"item-write-failure","startedAtMs":1,"threadId":"thread-write-failure","turnId":"turn-write-failure"}}'
            exec 0<&-
            sleep 3
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let assignment = AgentAssignment(
            id: "approval-write-failure-assignment",
            runID: "approval-write-failure-run",
            projectID: "approval-write-failure-project",
            agentID: "approval-write-failure-agent",
            status: .queued,
            currentTask: "Run tests"
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "Approval Write Failure Project",
            rootURL: directory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "Approval Write Failure Agent",
            summary: "Tests approval response recovery",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let events = await gateway.events()
        let approvalTask = Task<CodexApprovalRequest?, Never> {
            for await event in events {
                if case let .approvalRequired(request) = event { return request }
            }
            return nil
        }

        _ = try await gateway.connect()
        _ = try await gateway.start(
            assignment: assignment,
            project: project,
            agent: agent,
            instructions: [],
            resources: [],
            risk: .readOnly
        )
        let approval = try #require(await approvalTask.value)
        let digest = try #require(approval.operationDigest)
        try await Task.sleep(for: .milliseconds(50))

        let firstError: (any Error)?
        do {
            try await gateway.respond(to: approval.id, decision: .accept, operationDigest: digest)
            firstError = nil
        } catch {
            firstError = error
        }
        let secondError: (any Error)?
        do {
            try await gateway.respond(to: approval.id, decision: .accept, operationDigest: digest)
            secondError = nil
        } catch {
            secondError = error
        }
        await gateway.disconnect()

        #expect(firstError != nil)
        #expect(secondError != nil)
        #expect((secondError as? CodexTransportError) != .malformedResponse)
    }

    @Test("Codex quarantines an unconfirmed turn start and declines its approvals", .timeLimit(.minutes(1)))
    func codexQuarantinesIndeterminateTurnStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-indeterminate-start-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "indeterminate-start-server")
        let responseLog = directory.appending(path: "responses.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(responseLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"indeterminate-start-test\"}}"
          elif [[ "$line" == *'"method":"thread\/start"'* || "$line" == *'"method":"thread/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-indeterminate\"}}}"
          elif [[ "$line" == *'"method":"turn\/start"'* || "$line" == *'"method":"turn/start"'* ]]; then
            print '{"jsonrpc":"2.0","id":902,"method":"item/commandExecution/requestApproval","params":{"command":"swift test","cwd":"/tmp/project","itemId":"item-1","startedAtMs":1,"threadId":"thread-indeterminate","turnId":"turn-indeterminate"}}'
          elif [[ "$line" == *'"method":"turn\/interrupt"'* || "$line" == *'"method":"turn/interrupt"'* ]]; then
            print "{\"id\":${request_id},\"result\":{}}"
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 1,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let assignment = AgentAssignment(
            id: "indeterminate-assignment",
            runID: "indeterminate-run",
            projectID: "indeterminate-project",
            agentID: "indeterminate-agent",
            status: .queued,
            currentTask: "Run tests"
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "Indeterminate Project",
            rootURL: directory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "Indeterminate Agent",
            summary: "Tests failed-start quarantine",
            capabilities: [.testing],
            scope: .project(project.id)
        )

        _ = try await gateway.connect()
        await #expect(throws: CodexTransportError.indeterminateTurnStart(
            threadID: "thread-indeterminate"
        )) {
            try await gateway.start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: [],
                resources: [],
                risk: .readOnly
            )
        }
        await #expect(throws: CodexTransportError.assignmentAlreadyActive(assignment.id)) {
            try await gateway.start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: [],
                resources: [],
                risk: .readOnly
            )
        }

        var responses = ""
        for _ in 0..<100 {
            responses = (try? String(contentsOf: responseLog, encoding: .utf8)) ?? ""
            if responses.contains("\"decision\":\"decline\"")
                && (responses.contains("\"method\":\"turn/interrupt\"")
                    || responses.contains("\"method\":\"turn\\/interrupt\"")) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gateway.disconnect()

        #expect(responses.contains("\"id\":902"))
        #expect(responses.contains("\"decision\":\"decline\""))
        #expect(responses.contains("\"method\":\"turn/interrupt\"")
            || responses.contains("\"method\":\"turn\\/interrupt\""))
    }

    @Test("Codex rejects duplicate outstanding JSON-RPC approval identifiers", .timeLimit(.minutes(1)))
    func codexRejectsDuplicateApprovalIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-duplicate-approval-server-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "duplicate-approval-server")
        let responseLog = directory.appending(path: "responses.log")
        let script = #"""
        #!/bin/zsh
        while IFS= read -r line; do
          print -r -- "$line" >> "\#(responseLog.path(percentEncoded: false))"
          if [[ "$line" =~ '"id":([0-9]+)' ]]; then
            request_id=${match[1]}
          else
            continue
          fi
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"userAgent\":\"duplicate-approval-test\"}}"
          elif [[ "$line" == *'"method":"thread\/start"'* || "$line" == *'"method":"thread/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"thread\":{\"id\":\"thread-duplicate\"}}}"
          elif [[ "$line" == *'"method":"turn\/start"'* || "$line" == *'"method":"turn/start"'* ]]; then
            print "{\"id\":${request_id},\"result\":{\"turn\":{\"id\":\"turn-duplicate\"}}}"
            print '{"jsonrpc":"2.0","id":901,"method":"item/commandExecution/requestApproval","params":{"command":"swift test","cwd":"/tmp/project","itemId":"item-a","startedAtMs":1,"threadId":"thread-duplicate","turnId":"turn-duplicate"}}'
            print '{"jsonrpc":"2.0","id":901,"method":"item/commandExecution/requestApproval","params":{"command":"swift package reset","cwd":"/tmp/project","itemId":"item-b","startedAtMs":2,"threadId":"thread-duplicate","turnId":"turn-duplicate"}}'
          fi
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        let gateway = CodexGateway(
            executableURL: executable,
            clientVersion: "test",
            requestTimeout: 5,
            runtimeValidator: AllowingCodexRuntimeValidator(),
            globalStateURL: nil
        )
        let assignment = AgentAssignment(
            id: "duplicate-assignment",
            runID: "duplicate-run",
            projectID: "duplicate-project",
            agentID: "duplicate-agent",
            status: .queued,
            currentTask: "Run tests"
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "Duplicate Project",
            rootURL: directory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "Duplicate Agent",
            summary: "Tests duplicate IDs",
            capabilities: [.testing],
            scope: .project(project.id)
        )
        let events = await gateway.events()

        do {
            _ = try await gateway.connect()
            _ = try await gateway.start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: [],
                resources: [],
                risk: .readOnly
            )
        } catch let error as CodexTransportError {
            #expect(error == .duplicatePeerRequestID || error == .closed)
        } catch {
            Issue.record("Duplicate approval mock returned an unexpected error: \(error.localizedDescription)")
        }
        let failure = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await event in events {
                    if case let .assignmentFailed(_, message) = event { return message }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let failureMessage = try #require(failure)
        #expect(failureMessage == ProviderApprovalBindingError.duplicatePendingApproval.localizedDescription)

        try await Task.sleep(for: .milliseconds(50))
        let responses = (try? String(contentsOf: responseLog, encoding: .utf8)) ?? ""
        await gateway.disconnect()

        #expect(!responses.contains("\"id\":901,\"result\":{\"decision\":\"accept\""))
        await #expect(throws: CodexTransportError.self) {
            try await gateway.respond(
                to: "integer:901",
                decision: .accept,
                operationDigest: String(repeating: "0", count: 64)
            )
        }
    }

    @Test("Runtime write grants are limited to selected read-write resources")
    func permissionProfilesEnforceResourceAccess() {
        let readOnly = SharedResource(
            name: "Read Only",
            url: URL(fileURLWithPath: "/tmp/read-only"),
            access: .readOnly
        )
        let readWrite = SharedResource(
            name: "Read Write",
            url: URL(fileURLWithPath: "/tmp/read-write"),
            access: .readWrite
        )
        let requested: JSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .object([
                "entries": .array([
                    .object([
                        "access": .string("read"),
                        "path": .object(["type": .string("path"), "path": .string("/tmp/read-only/reference.md")])
                    ]),
                    .object([
                        "access": .string("write"),
                        "path": .object(["type": .string("path"), "path": .string("/tmp/read-only/changed.md")])
                    ]),
                    .object([
                        "access": .string("write"),
                        "path": .object(["type": .string("path"), "path": .string("/tmp/read-write/output.md")])
                    ]),
                    .object([
                        "access": .string("write"),
                        "path": .object(["type": .string("special"), "value": .object(["kind": .string("root")])])
                    ])
                ]),
                "write": .array([
                    .string("/tmp/read-only"),
                    .string("/tmp/read-write/subfolder"),
                    .string("/tmp/unregistered")
                ])
            ])
        ])

        let result = CodexGateway.enforcingResourceAccess(
            on: requested,
            resources: [readOnly, readWrite]
        )
        let entries = result.profile["fileSystem"]?["entries"]
        let writePaths = result.profile["fileSystem"]?["write"]

        #expect(result.removedWriteAccess)
        #expect(entries == .array([
            .object([
                "access": .string("read"),
                "path": .object(["type": .string("path"), "path": .string("/tmp/read-only/reference.md")])
            ]),
            .object([
                "access": .string("write"),
                "path": .object(["type": .string("path"), "path": .string("/tmp/read-write/output.md")])
            ])
        ]))
        #expect(writePaths == .array([.string("/tmp/read-write/subfolder")]))
        #expect(result.profile["network"]?["enabled"]?.boolValue == true)
    }

    @Test("Network layout aggregates hundreds of projects without unstable simulation", .timeLimit(.minutes(1)))
    func stressGraphLayout() async {
        let projects = (0..<300).map { index in
            LabProject(
                id: ProjectID(rawValue: "project-\(index)"),
                name: "Project \(index)",
                rootURL: URL(fileURLWithPath: "/tmp/project-\(index)"),
                platforms: [ProjectPlatform.allCases[index % ProjectPlatform.allCases.count]],
                isGitRepository: index.isMultiple(of: 2)
            )
        }
        let agents = projects.map { project in
            AgentProfile(
                id: AgentID(rawValue: "agent-\(project.id.rawValue)"),
                name: "Agent \(project.name)",
                summary: "Stress fixture",
                capabilities: [.routing],
                scope: .project(project.id)
            )
        }
        let layout = await RadialGraphLayout().layout(
            lab: LabSnapshot(projects: projects, agents: agents),
            assignments: []
        )
        let projectPoints = layout.nodes.compactMap { node -> GraphPoint? in
            guard case .project = node.kind else { return nil }
            return node.position
        }
        let maximumProjectRadius = projectPoints.map { hypot($0.x, $0.y) }.max() ?? 0
        var minimumProjectDistance = Double.greatestFiniteMagnitude
        for firstIndex in projectPoints.indices {
            for secondIndex in projectPoints.indices where secondIndex > firstIndex {
                minimumProjectDistance = min(
                    minimumProjectDistance,
                    hypot(
                        projectPoints[firstIndex].x - projectPoints[secondIndex].x,
                        projectPoints[firstIndex].y - projectPoints[secondIndex].y
                    )
                )
            }
        }

        let aggregateCount = ProjectPlatform.allCases.filter { $0 != .general }.count
        let expectedNodeCount = 1 + projects.count + agents.count + aggregateCount
        #expect(layout.nodes.count == expectedNodeCount)
        #expect(layout.edges.count == 300)
        #expect(maximumProjectRadius <= 1_800.001)
        #expect(minimumProjectDistance >= 159.5)
    }

    @Test("Rate-limited work stays queued and resumes without being lost", .timeLimit(.minutes(1)))
    func rateLimitQueueing() async throws {
        let project = LabProject(
            id: "limited-project",
            name: "Limited",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "limited-agent",
            name: "General Agent",
            summary: "General work",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let plan = RoutingPlan(
            id: "limited-run",
            interpretedGoal: "Inspect",
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "limited-assignment",
            runID: plan.id,
            projectID: project.id,
            agentID: agent.id,
            status: .queued,
            currentTask: plan.interpretedGoal
        )
        let repository = TestRepository(
            lab: LabSnapshot(projects: [project], agents: [agent]),
            runs: [RunRecord(
                id: plan.id,
                plan: plan,
                status: .ready,
                assignments: [assignment],
                agentSnapshot: [agent],
                providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
                projectSnapshot: [project]
            )]
        )
        let orchestrator = CodexRunOrchestrator(
            catalog: repository,
            runs: repository,
            codex: RateLimitedFakeCodex(),
            workspaces: FakeWorkspace(),
            verifier: FakeVerifier(),
            rateLimitPollInterval: 0.01
        )

        try await orchestrator.execute(runID: plan.id)
        let completed = try #require(await repository.allRuns().first)
        #expect(completed.status == .completed)
        #expect(completed.journal.contains { $0.message.contains("Waiting for Codex capacity") })
    }

    @Test("Agent file restructuring previews, archives, applies, and undoes exactly")
    func agentDefinitionRestructureRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-restructure-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Legacy Agent.toml")
        let original = "name = \"Web Agent\"\ndescription = \"Builds websites\"\n"
        try Data(original.utf8).write(to: source, options: .atomic)
        let profile = AgentProfile(
            id: "restructure-agent",
            name: "Web Agent",
            summary: "Builds websites",
            capabilities: [.web, .testing],
            scope: .global,
            sourceURL: source
        )
        let candidate = AgentImportCandidate(
            profile: profile,
            configurationPreview: original,
            evidence: []
        )
        let restructurer = AgentDefinitionRestructurer()
        let change = try #require(try await restructurer.preview(candidates: [candidate]).first)

        #expect(change.sourceURL == source)
        #expect(change.proposedContents.contains("Goby capability structure: testing, web"))
        try await restructurer.apply([change])
        #expect(FileManager.default.fileExists(atPath: change.archiveURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: change.targetURL.path(percentEncoded: false)))

        try await restructurer.undo([change])
        #expect(String(decoding: try Data(contentsOf: source), as: UTF8.self) == original)
        #expect(!FileManager.default.fileExists(atPath: change.targetURL.path(percentEncoded: false)) || change.targetURL == source)
    }

    @Test("File restructuring never moves an active Codex definition")
    func activeAgentDefinitionIsNotRestructured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-active-restructure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "active-agent.toml")
        let original = "name = \"Active Agent\"\ndescription = \"Must keep its registered path\"\n"
        try Data(original.utf8).write(to: source, options: .atomic)
        let candidate = AgentImportCandidate(
            profile: AgentProfile(
                id: "active-agent",
                name: "Active Agent",
                summary: "Must keep its registered path",
                capabilities: [.routing],
                scope: .global,
                sourceURL: source,
                codexRegistrationKey: "active_agent"
            ),
            configurationPreview: original,
            evidence: []
        )

        let previews = try await AgentDefinitionRestructurer().preview(candidates: [candidate])

        #expect(previews.isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == original)
    }

    @Test("Agent restructure undo preserves a normalized file changed after apply")
    func agentDefinitionUndoConflict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-restructure-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "legacy.toml")
        let original = "name = \"Web Agent\"\ndescription = \"Builds websites\"\n"
        try Data(original.utf8).write(to: source, options: .atomic)
        let candidate = AgentImportCandidate(
            profile: AgentProfile(
                id: "conflict-agent",
                name: "Web Agent",
                summary: "Builds websites",
                capabilities: [.web],
                scope: .global,
                sourceURL: source
            ),
            configurationPreview: original,
            evidence: []
        )
        let restructurer = AgentDefinitionRestructurer()
        let change = try #require(try await restructurer.preview(candidates: [candidate]).first)
        try await restructurer.apply([change])
        try Data((change.proposedContents + "# edited later\n").utf8).write(to: change.targetURL, options: .atomic)

        await #expect(throws: AgentRestructureError.self) {
            try await restructurer.undo([change])
        }
        #expect(FileManager.default.fileExists(atPath: change.targetURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: change.archiveURL.path(percentEncoded: false)))
    }

    @Test("Agent restructure stops if a reviewed source is replaced by a symlink")
    func agentDefinitionRejectsSymlinkSubstitution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-restructure-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalDirectory = FileManager.default.temporaryDirectory
            .appending(path: "goby-restructure-external-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: externalDirectory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let source = directory.appending(path: "legacy.toml")
        let external = externalDirectory.appending(path: "external.toml")
        let original = "name = \"Web Agent\"\ndescription = \"Builds websites\"\n"
        try Data(original.utf8).write(to: source, options: .atomic)
        try Data(original.utf8).write(to: external, options: .atomic)
        let candidate = AgentImportCandidate(
            profile: AgentProfile(
                id: "symlink-agent",
                name: "Web Agent",
                summary: "Builds websites",
                capabilities: [.web],
                scope: .global,
                sourceURL: source
            ),
            configurationPreview: original,
            evidence: []
        )
        let restructurer = AgentDefinitionRestructurer()
        let change = try #require(try await restructurer.preview(candidates: [candidate]).first)

        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)

        await #expect(throws: AgentRestructureError.self) {
            try await restructurer.apply([change])
        }
        #expect(String(decoding: try Data(contentsOf: external), as: UTF8.self) == original)
        #expect(!FileManager.default.fileExists(atPath: change.archiveURL.path(percentEncoded: false)))
    }

    @Test("Project-scoped Codex agent definitions are discovered from authorized roots")
    func projectAgentDiscovery() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repositoryRoot.appending(path: "Development/Fixtures/SampleWebProject", directoryHint: .isDirectory)
        let project = LabProject(
            id: "fixture-project",
            name: "SampleWebProject",
            rootURL: fixtureRoot,
            platforms: [.web],
            isGitRepository: false
        )
        let emptyGlobal = FileManager.default.temporaryDirectory
            .appending(path: "goby-no-global-agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        let plan = try await CodexAgentDiscovery(globalAgentsURL: emptyGlobal).discover(projects: [project])
        let agent = try #require(plan.candidates.first)
        #expect(agent.profile.name == "Web Implementer")
        #expect(agent.profile.capabilities.contains(.web))
        #expect(agent.profile.instructions == "Work only in the assigned fixture project and verify changes with its test command.")
    }

    @Test("Project agent discovery ignores a symlinked agent directory outside the authorized project")
    func projectAgentDiscoveryRejectsSymlinkEscape() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appending(path: "goby-agent-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRoot = FileManager.default.temporaryDirectory
            .appending(path: "goby-agent-external-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        let codexDirectory = projectRoot.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try Data("name = \"Escaped Agent\"\ndescription = \"Must not be imported\"\n".utf8)
            .write(to: externalRoot.appending(path: "escaped.toml"), options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: codexDirectory.appending(path: "agents", directoryHint: .isDirectory),
            withDestinationURL: externalRoot
        )
        let project = LabProject(
            id: "symlink-project",
            name: "Symlink Project",
            rootURL: projectRoot,
            platforms: [.web],
            isGitRepository: false
        )
        let emptyGlobal = projectRoot.appending(path: "missing-global", directoryHint: .isDirectory)

        let plan = try await CodexAgentDiscovery(globalAgentsURL: emptyGlobal).discover(projects: [project])

        #expect(plan.candidates.isEmpty)
    }

    @Test("Project discovery ignores a symlinked project outside the selected root")
    func projectDiscoveryRejectsSymlinkedProjectRoot() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "goby-project-root-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let selected = fixture.appending(path: "Selected", directoryHint: .isDirectory)
        let outside = fixture.appending(path: "OutsideProject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"test":"echo safe"}}"#.utf8)
            .write(to: outside.appending(path: "package.json"), options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: selected.appending(path: "LinkedProject"),
            withDestinationURL: outside
        )

        let discovered = try await FileSystemProjectDiscovery().discover(selectedRoots: [selected])

        #expect(discovered.isEmpty)
    }

    @Test("Web project discovery requires an actual npm test script before enforcing npm test")
    func projectDiscoveryDetectsNPMTestScript() async throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: "goby-npm-test-detection-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let manifest = project.appending(path: "package.json")
        try Data(#"{"name":"fixture"}"#.utf8).write(to: manifest, options: .atomic)
        let discovery = FileSystemProjectDiscovery()

        let withoutTest = try #require(try await discovery.discover(selectedRoots: [project]).first)
        #expect(withoutTest.project.testCommands.isEmpty)

        try Data(#"{"name":"fixture","scripts":{"test":"vitest run"}}"#.utf8)
            .write(to: manifest, options: .atomic)
        let withTest = try #require(try await discovery.discover(selectedRoots: [project]).first)
        #expect(withTest.project.testCommands == ["npm test"])
    }

    @Test("Concurrent project reviews each return their selected folders")
    func concurrentProjectReviewsKeepTheirResults() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "goby-concurrent-project-review-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var roots: [URL] = []
        for index in 0..<24 {
            let root = fixture.appending(path: "Project-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(#"{"name":"fixture"}"#.utf8)
                .write(to: root.appending(path: "package.json"), options: .atomic)
            roots.append(root)
        }
        let discovery = FileSystemProjectDiscovery(maximumConcurrentInspections: 1)
        let selectedRoots = roots

        async let first = discovery.discover(selectedRoots: selectedRoots)
        async let second = discovery.discover(selectedRoots: selectedRoots)
        let firstResult = try await first
        let secondResult = try await second

        #expect(firstResult.count == roots.count)
        #expect(secondResult.count == roots.count)
        #expect(Set(firstResult.map(\.id)) == Set(secondResult.map(\.id)))
    }

    @Test("Project discovery recognizes immediate multi-platform monorepo modules")
    func projectDiscoveryRecognizesMonorepoModules() async throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: "goby-monorepo-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Monorepo instructions".utf8).write(to: project.appending(path: "AGENTS.md"))

        let web = project.appending(path: "web", directoryHint: .isDirectory)
        let backend = project.appending(path: "backend", directoryHint: .isDirectory)
        let android = project.appending(path: "android", directoryHint: .isDirectory)
        let ios = project.appending(path: "ios", directoryHint: .isDirectory)
        for module in [web, backend, android, ios] {
            try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        }
        try Data(#"{"scripts":{"test":"vitest"},"dependencies":{"react":"latest"}}"#.utf8)
            .write(to: web.appending(path: "package.json"))
        try Data("// swift-tools-version: 6.0".utf8).write(to: backend.appending(path: "Package.swift"))
        try Data("#!/bin/sh".utf8).write(to: android.appending(path: "gradlew"))
        try FileManager.default.createDirectory(
            at: ios.appending(path: "Example.xcodeproj", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let candidate = try #require(try await FileSystemProjectDiscovery().discover(selectedRoots: [project]).first)

        #expect(candidate.project.platforms == [.android, .backend, .iOS, .web])
        #expect(candidate.project.frameworks.contains("React"))
        #expect(candidate.project.frameworks.contains("Swift Package"))
        #expect(candidate.project.frameworks.contains("Gradle"))
        #expect(candidate.project.frameworks.contains("Xcode"))
        #expect(candidate.project.testCommands.contains("npm --prefix 'web' test"))
        #expect(candidate.project.testCommands.contains("swift test --package-path 'backend'"))
        #expect(candidate.project.testCommands.contains("'./android/gradlew' -p 'android' test"))
        #expect(candidate.evidence.contains("web/package.json"))
        #expect(candidate.evidence.contains("backend/Package.swift"))
    }

    @Test("Project discovery classifies a macOS Xcode project from its build settings")
    func projectDiscoveryRecognizesMacOSXcodeTarget() async throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: "goby-macos-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        let xcodeProject = project.appending(path: "DesktopApp.xcodeproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
        try Data(
            "MACOSX_DEPLOYMENT_TARGET = 26.0;\nSDKROOT = macosx;\n".utf8
        ).write(to: xcodeProject.appending(path: "project.pbxproj"))

        let candidate = try #require(
            try await FileSystemProjectDiscovery().discover(selectedRoots: [project]).first
        )

        #expect(candidate.project.platforms == [.macOS])
        #expect(candidate.evidence.contains("Xcode target: macOS"))
        #expect(!candidate.project.platforms.contains(.iOS))
    }

    @Test("Project discovery classifies a package-only macOS target without assuming iOS")
    func projectDiscoveryRecognizesMacOSSwiftPackage() async throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: "goby-macos-package-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(
            "// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: \"DesktopCore\", platforms: [.macOS(.v26)])\n".utf8
        ).write(to: project.appending(path: "Package.swift"))

        let candidate = try #require(
            try await FileSystemProjectDiscovery().discover(selectedRoots: [project]).first
        )

        #expect(candidate.project.platforms == [.macOS])
        #expect(candidate.evidence.contains("Swift package target: macOS"))
    }

    @Test("Discovered module names are inert shell operands")
    func projectDiscoveryQuotesHostileModuleNames() async throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: "goby-hostile-module-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        let moduleName = "$(printenv DATABASE_PASSWORD)' module"
        let module = project.appending(path: moduleName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try Data().write(to: project.appending(path: "AGENTS.md"))
        try Data("// swift-tools-version: 6.0".utf8).write(to: module.appending(path: "Package.swift"))

        let candidate = try #require(
            try await FileSystemProjectDiscovery().discover(selectedRoots: [project]).first
        )
        let command = try #require(candidate.project.testCommands.first)
        #expect(command == "swift test --package-path '$(printenv DATABASE_PASSWORD)'\"'\"' module'")
        #expect(FileSystemProjectDiscovery.shellQuotedPathComponent("unsafe\nname") == nil)
    }

    @Test("Codex app-server receives only the operational environment allowlist")
    func codexAppServerEnvironmentIsSanitized() {
        let sanitized = CodexAppServerTransport.sanitizedChildEnvironment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin:/bin",
            "CODEX_HOME": "/Users/test/.codex",
            "DATABASE_PASSWORD": "must-not-cross",
            "OPENAI_API_KEY": "must-not-cross",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
        ])
        #expect(sanitized["HOME"] == "/Users/test")
        #expect(sanitized["CODEX_HOME"] == "/Users/test/.codex")
        #expect(sanitized["TERM"] == "dumb")
        #expect(sanitized["DATABASE_PASSWORD"] == nil)
        #expect(sanitized["OPENAI_API_KEY"] == nil)
        #expect(sanitized["SSH_AUTH_SOCK"] == nil)
    }

    @Test("Repeated project roles produce optional promotion and naming suggestions")
    func agentStructureSuggestions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-suggestions-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = ["one", "two"].map { name in
            LabProject(
                id: ProjectID(rawValue: name),
                name: name.capitalized,
                rootURL: directory.appending(path: name, directoryHint: .isDirectory),
                platforms: [.web],
                isGitRepository: false
            )
        }
        for project in projects {
            let agents = project.rootURL.appending(path: ".codex/agents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let source = "name = \"Agent\"\ndescription = \"Web implementation\"\n"
            try Data(source.utf8).write(to: agents.appending(path: "agent.toml"), options: .atomic)
        }
        let emptyGlobal = directory.appending(path: "global", directoryHint: .isDirectory)
        let plan = try await CodexAgentDiscovery(globalAgentsURL: emptyGlobal).discover(projects: projects)

        #expect(plan.suggestions.contains { $0.kind == .promoteToShared })
        #expect(plan.suggestions.filter { $0.kind == .rename }.count == 2)
    }

    @Test("Multiline TOML agent instructions are preserved and supplied to Codex")
    func multilineAgentInstructions() {
        let source = #"""
        name = "Researcher"
        developer_instructions = """
        Prefer primary sources.
        Cite every conclusion.
        """
        """#
        let parsed = TOMLStringParser.string(named: "developer_instructions", in: source)
        #expect(parsed == "Prefer primary sources.\nCite every conclusion.\n")

        let agent = AgentProfile(
            id: "researcher",
            name: "Researcher",
            summary: "Researches product questions",
            instructions: parsed,
            capabilities: [.research],
            scope: .global
        )
        let prompt = CodexGateway.makeDeveloperInstructions(agent: agent, instructions: [], resources: [])
        #expect(prompt.contains("Prefer primary sources.\nCite every conclusion."))
    }

    @Test("Core refers to each assigned project's workspace root")
    func coreProjectTerminology() {
        let project = LabProject(
            id: "atlas",
            name: "Atlas",
            rootURL: URL(fileURLWithPath: "/tmp/Atlas"),
            platforms: [.general],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: "builder",
            name: "Builder",
            summary: "Builds project changes",
            capabilities: [.web],
            scope: .global
        )

        let corePrompt = CodexGateway.makeDeveloperInstructions(
            agent: agent,
            project: project,
            instructions: [],
            resources: [],
            task: "Add logo.png to the core"
        )
        #expect(corePrompt.contains("“core” means the root folder of the specific assigned project, Atlas"))
        #expect(corePrompt.contains("current project workspace root (`.`)"))

        let unrelatedPrompt = CodexGateway.makeDeveloperInstructions(
            agent: agent,
            project: project,
            instructions: [],
            resources: [],
            task: "Update the score calculation"
        )
        #expect(!unrelatedPrompt.contains("Project terminology for this assignment"))
    }

    @Test("Goby creates a project linked across all providers and another project")
    func createsProjectBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-new-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let existing = LabProject(
            id: "existing",
            name: "Existing App",
            rootURL: projectsRoot.appending(path: "Existing App", directoryHint: .isDirectory),
            platforms: [.iOS],
            isGitRepository: true
        )
        try FileManager.default.createDirectory(at: existing.rootURL, withIntermediateDirectories: true)
        try await repository.register(projects: [existing], agents: [])

        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: repository,
            handoffs: repository,
            definitions: definitions,
            directories: LocalProjectDirectoryCreator(),
            configuredProviderIDs: [.codex, .claude, .githubCopilot]
        )

        let created = try await createProject(NewProjectDraft(
            name: "New Service",
            directoryName: "New Service",
            parentURL: projectsRoot,
            platforms: [.backend],
            providerIDs: [.codex, .claude, .githubCopilot],
            agents: [
                NewProjectAgentDraft(
                    name: "API Agent",
                    summary: "Owns the service API",
                    instructions: "Keep API changes backward compatible.",
                    capabilities: [.backend, .testing],
                    providerIDs: [.codex, .claude, .githubCopilot],
                    providerInstructions: [
                        .claude: "Challenge API assumptions before implementation.",
                        .githubCopilot: "Keep suggestions inside the selected files.",
                    ]
                ),
                NewProjectAgentDraft(
                    name: "Security Agent",
                    summary: "Reviews service security",
                    capabilities: [.security, .review],
                    providerIDs: [.codex, .claude, .githubCopilot]
                ),
            ],
            link: NewProjectLinkDraft(
                projectID: existing.id,
                groupName: "App Platform",
                projectRole: .backend,
                linkedProjectRole: .mobile
            ),
            collaborateAcrossProviders: true,
            handoffLinks: [
                NewProjectHandoffDraft(
                    sourceAgentIndex: 0,
                    sourceProviderID: .codex,
                    destinationAgentIndex: 1,
                    destinationProviderID: .claude,
                    purpose: "Continue implementation with an independent security review.",
                    conditions: "After the API agent reaches a reviewed checkpoint."
                ),
                NewProjectHandoffDraft(
                    sourceAgentIndex: 1,
                    sourceProviderID: .claude,
                    destinationAgentIndex: 0,
                    destinationProviderID: .githubCopilot,
                    purpose: "Suggest focused follow-up edits.",
                    conditions: "After security findings are accepted."
                ),
            ]
        ))

        let snapshot = try await repository.snapshot()
        #expect(FileManager.default.fileExists(atPath: created.project.rootURL.path(percentEncoded: false)))
        #expect(created.project.fileSystemIdentity == GADFileSystemIdentity.capture(created.project.rootURL))
        #expect(snapshot.projects.count == 2)
        #expect(Set(snapshot.agents.map(\.name)) == ["API Agent", "Security Agent"])
        #expect(snapshot.agents.allSatisfy { $0.scope == .project(created.project.id) })
        #expect(snapshot.projectGroups.count == 1)
        #expect(snapshot.projectGroups[0].name == "App Platform")
        #expect(snapshot.projectGroups[0].projectIDs == [existing.id, created.project.id])
        #expect(created.providerConfiguration.providerIDs == [.codex, .claude, .githubCopilot])
        #expect(created.providerBindings.count == 6)
        #expect(Set(created.providerBindings.map(\.providerID)) == [.codex, .claude, .githubCopilot])
        #expect(created.providerBindings.filter { $0.providerID == .claude }.allSatisfy {
            $0.state == .configured
        })
        #expect(created.providerBindings.filter { $0.providerID == .githubCopilot }.allSatisfy {
            $0.state == .configured
        })
        #expect(created.providerCollaborationSet?.providerIDs == [.codex, .claude, .githubCopilot])
        #expect(created.providerCollaborationSet?.members.count == 6)
        #expect(created.handoffLinks.count == 2)
        #expect(Set(snapshot.agentHandoffLinks.map(\.id)) == Set(created.handoffLinks.map(\.id)))
        #expect(created.handoffLinks.allSatisfy { $0.mode == .suggestOnly })
        #expect(created.providerBindings.first(where: {
            $0.providerID == .claude && $0.agentID == created.agents[0].id
        })?.instructionsOverride == "Challenge API assumptions before implementation.")
        #expect(created.projectGroup?.members == [
            ProjectGroupMember(projectID: existing.id, role: .mobile),
            ProjectGroupMember(projectID: created.project.id, role: .backend),
        ])
        #expect(
            FileManager.default.fileExists(
                atPath: created.project.rootURL
                    .appending(path: ".codex/agents/api-agent.toml")
                    .path(percentEncoded: false)
            )
        )
    }

    @Test("Project creation refuses to overwrite an existing folder")
    func projectCreationRefusesExistingFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-new-project-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        let occupied = projectsRoot.appending(path: "Taken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: repository,
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator()
        )
        let draft = NewProjectDraft(
            name: "Taken",
            directoryName: "Taken",
            parentURL: projectsRoot,
            platforms: [.general]
        )

        await #expect(throws: GobyApplicationError.projectDirectoryAlreadyExists("Taken")) {
            try await createProject(draft)
        }
        #expect(try await repository.snapshot() == .empty)
    }

    @Test("Project creation rejects a substituted reviewed parent folder")
    func projectCreationRejectsSubstitutedParent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-new-project-parent-substitution-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        let movedAuthorizedRoot = root.appending(path: "Moved Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: repository,
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator()
        )
        let draft = NewProjectDraft(
            name: "Sensitive Service",
            directoryName: "Sensitive Service",
            parentURL: projectsRoot,
            platforms: [.backend]
        )
        try FileManager.default.moveItem(at: projectsRoot, to: movedAuthorizedRoot)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: false)

        await #expect(throws: GobyApplicationError.projectParentAuthorizationChanged) {
            try await createProject(draft)
        }
        #expect(!FileManager.default.fileExists(
            atPath: projectsRoot.appending(path: "Sensitive Service").path(percentEncoded: false)
        ))
        #expect(try await repository.snapshot() == .empty)
    }

    @Test("Project creation rejects a substituted child returned by blank and clone placement")
    func projectCreationRejectsSubstitutedCreatedChild() async throws {
        for (suffix, source) in [
            ("blank", NewProjectSource.blank),
            ("clone", NewProjectSource.gitClone(repository: "https://example.test/repository.git")),
        ] {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "goby-new-project-child-substitution-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            let repository = PersistentStore(
                directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
            )
            let createProject = CreateProjectUseCase(
                catalog: repository,
                projectCatalog: repository,
                groups: repository,
                agentCatalog: repository,
                providerConfigurations: repository,
                definitions: CodexAgentDefinitionStore(
                    globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
                ),
                directories: SubstitutingProjectDirectoryCreator()
            )

            await #expect(throws: GobyApplicationError.projectDirectoryAuthorizationChanged) {
                try await createProject(NewProjectDraft(
                    name: "Substituted",
                    directoryName: "Substituted",
                    parentURL: projectsRoot,
                    source: source,
                    platforms: [.general]
                ))
            }
            #expect(try await repository.snapshot() == .empty)
        }
    }

    @Test("Project rollback removes only the captured empty directory")
    func projectRollbackUsesAtomicEmptyDirectoryRemoval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-project-atomic-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentIdentity = try #require(GADFileSystemIdentity.capture(parent))
        let creator = LocalProjectDirectoryCreator()

        let nonempty = try await creator.createProjectDirectory(
            named: "Nonempty",
            in: parent,
            expectedParentIdentity: parentIdentity
        )
        let retainedFile = nonempty.rootURL.appending(path: "retained.txt")
        try Data("keep".utf8).write(to: retainedFile)
        try await creator.removeProjectDirectoryIfEmpty(nonempty)
        #expect(FileManager.default.fileExists(atPath: retainedFile.path(percentEncoded: false)))

        let substituted = try await creator.createProjectDirectory(
            named: "Substituted",
            in: parent,
            expectedParentIdentity: parentIdentity
        )
        let retainedOriginal = parent.appending(path: "Retained Original", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: substituted.rootURL, to: retainedOriginal)
        try FileManager.default.createDirectory(at: substituted.rootURL, withIntermediateDirectories: false)
        let replacementFile = substituted.rootURL.appending(path: "replacement.txt")
        try Data("preserve replacement".utf8).write(to: replacementFile)

        await #expect(throws: GobyApplicationError.projectDirectoryAuthorizationChanged) {
            try await creator.removeProjectDirectoryIfEmpty(substituted)
        }
        #expect(FileManager.default.fileExists(atPath: replacementFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: retainedOriginal.path(percentEncoded: false)))
    }

    @Test("Project creation can clone and register a Git repository")
    func projectCreationClonesGitRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-new-project-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        let sourceRepository = root.appending(path: "Source.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try initializeBareGitRepository(at: sourceRepository)

        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: repository,
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator()
        )

        let created = try await createProject(NewProjectDraft(
            name: "Cloned Service",
            directoryName: "Cloned Service",
            parentURL: projectsRoot,
            source: .gitClone(repository: sourceRepository.path(percentEncoded: false)),
            platforms: [.backend]
        ))

        #expect(created.project.isGitRepository)
        #expect(created.project.fileSystemIdentity == GADFileSystemIdentity.capture(created.project.rootURL))
        #expect(created.project.rootURL == projectsRoot.appending(path: "Cloned Service", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(
            atPath: created.project.rootURL.appending(path: ".git", directoryHint: .isDirectory)
                .path(percentEncoded: false)
        ))
        #expect(try await repository.snapshot().projects == [created.project])
    }

    @Test("Project creation compensates agents, catalog entries, and its empty folder after a link failure")
    func projectCreationCompensatesLinkFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goby-new-project-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let existing = LabProject(
            id: "existing",
            name: "Existing",
            rootURL: projectsRoot.appending(path: "Existing", directoryHint: .isDirectory),
            platforms: [.web],
            isGitRepository: false
        )
        try FileManager.default.createDirectory(at: existing.rootURL, withIntermediateDirectories: true)
        try await repository.register(projects: [existing], agents: [])

        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: RejectingProjectGroupCatalog(),
            agentCatalog: repository,
            providerConfigurations: repository,
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator()
        )
        let projectRoot = projectsRoot.appending(path: "Rejected", directoryHint: .isDirectory)
        let draft = NewProjectDraft(
            name: "Rejected",
            directoryName: "Rejected",
            parentURL: projectsRoot,
            platforms: [.backend],
            agents: [
                NewProjectAgentDraft(
                    name: "API Agent",
                    summary: "Owns the API",
                    capabilities: [.backend]
                ),
            ],
            link: NewProjectLinkDraft(
                projectID: existing.id,
                groupName: "Rejected Group",
                projectRole: .backend
            )
        )

        await #expect(throws: ProjectCreationFailure.rejected) {
            try await createProject(draft)
        }
        let snapshot = try await repository.snapshot()
        #expect(snapshot.projects == [existing])
        #expect(snapshot.agents.isEmpty)
        #expect(snapshot.projectGroups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: projectRoot.path(percentEncoded: false)))
    }
}

private enum ProjectCreationFailure: Error, Equatable, Sendable {
    case rejected
}

private func initializeBareGitRepository(at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "commit.gpgSign=false",
        "-c", "tag.gpgSign=false",
        "init", "--bare", "--", url.path(percentEncoded: false),
    ]
    process.environment = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/var/empty",
        "LANG": "C",
        "LC_ALL": "C",
        "LOGNAME": NSUserName(),
        "PATH": "/usr/bin:/bin",
        "TMPDIR": NSTemporaryDirectory(),
        "USER": NSUserName(),
        "XDG_CONFIG_HOME": "/var/empty",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "GobyTests.Git",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
        )
    }
}

private actor RejectingProjectGroupCatalog: ProjectGroupCatalogManaging {
    func saveProjectGroup(_ group: ProjectGroup) throws {
        throw ProjectCreationFailure.rejected
    }

    func removeProjectGroup(id: ProjectGroupID) {}
}

private actor SubstitutingProjectDirectoryCreator: ProjectDirectoryCreating {
    func createProjectDirectory(
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> ProjectDirectoryPlacement {
        try createAndSubstitute(named: directoryName, in: parentURL)
    }

    func cloneProjectRepository(
        from repository: String,
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> ProjectDirectoryPlacement {
        try createAndSubstitute(named: directoryName, in: parentURL)
    }

    func removeProjectDirectoryIfEmpty(_ placement: ProjectDirectoryPlacement) {}

    private func createAndSubstitute(
        named directoryName: String,
        in parentURL: URL
    ) throws -> ProjectDirectoryPlacement {
        let root = parentURL.appending(path: directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let reviewedIdentity = try #require(GADFileSystemIdentity.capture(root))
        let placement = ProjectDirectoryPlacement(
            rootURL: root,
            fileSystemIdentity: reviewedIdentity
        )
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return placement
    }
}

private actor TestRepository: LabCatalogRepository, RunRepository {
    var lab: LabSnapshot
    var records: [RunRecord]

    init(lab: LabSnapshot, runs: [RunRecord]) {
        self.lab = lab
        self.records = runs
    }

    func snapshot() -> LabSnapshot { lab }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func allRuns() -> [RunRecord] { records }
    func save(_ run: RunRecord) {
        records.removeAll { $0.id == run.id }
        records.insert(run, at: 0)
    }
}

private actor FakeCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        continuation.yield(.assignmentStarted(assignment.id))
        continuation.yield(.assignmentCompleted(assignment.id, outcome: "Codex completed"))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor ActivityFakeCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        continuation.yield(.assignmentStarted(assignment.id))
        continuation.yield(.activity(assignment.id, step: RunActivityStep(
            id: "c1", assignmentID: assignment.id, kind: .command, title: "npm test", status: .running
        )))
        continuation.yield(.activity(assignment.id, step: RunActivityStep(
            id: "c1", assignmentID: assignment.id, kind: .command, title: "npm test", status: .succeeded, exitCode: 0
        )))
        continuation.yield(.activity(assignment.id, step: RunActivityStep(
            id: "m1", assignmentID: assignment.id, kind: .message, title: "Here is the plan.", status: .succeeded
        )))
        continuation.yield(.assignmentCompleted(assignment.id, outcome: "Codex completed"))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor RetryEvidenceCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation
    private(set) var startCount = 0
    private(set) var startedTasks: [String] = []
    private(set) var startedWithPriorProviderTask: [Bool] = []

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "retry-evidence") }
    func connect() -> CodexConnectionState { .connected(version: "retry-evidence") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        startCount += 1
        startedTasks.append(assignment.currentTask)
        startedWithPriorProviderTask.append(assignment.providerTaskID != nil)
        continuation.yield(.assignmentStarted(assignment.id))
        if startCount > 1 {
            continuation.yield(.commandExecutionCompleted(
                assignment.id,
                evidence: CodexCommandExecutionEvidence(
                    id: "retry-evidence",
                    command: project.testCommands[0],
                    workingDirectory: project.rootURL,
                    status: .completed,
                    exitCode: 0,
                    durationMilliseconds: 1
                )
            ))
        }
        continuation.yield(.assignmentCompleted(
            assignment.id,
            outcome: startCount > 1 ? "Retry supplied evidence" : "First attempt omitted evidence"
        ))
        return CodexExecutionHandle(
            threadID: startCount > 1 ? "retry-thread" : "first-thread",
            turnID: startCount > 1 ? "retry-turn" : "first-turn"
        )
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor ApprovalFakeCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation
    let canAccept: Bool
    let emitsTerminalResponse: Bool
    let completesOnRetry: Bool
    let responseDelay: Duration?
    let failsInterrupt: Bool
    private(set) var startedAssignments: [AgentAssignment] = []
    private(set) var interruptionCount = 0
    private(set) var receivedDecision: CodexApprovalDecision?
    private(set) var receivedOperationDigest: String?
    private(set) var responseAttempts = 0
    private(set) var startCount = 0
    private var assignmentID: AssignmentID?

    init(
        canAccept: Bool = false,
        emitsTerminalResponse: Bool = true,
        completesOnRetry: Bool = false,
        responseDelay: Duration? = nil,
        failsInterrupt: Bool = false
    ) {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.canAccept = canAccept
        self.emitsTerminalResponse = emitsTerminalResponse
        self.completesOnRetry = completesOnRetry
        self.responseDelay = responseDelay
        self.failsInterrupt = failsInterrupt
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", availableModels: ["model-a", "model-b"], usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        startCount += 1
        startedAssignments.append(assignment)
        assignmentID = assignment.id
        continuation.yield(.assignmentStarted(assignment.id))
        if completesOnRetry && startCount > 1 {
            continuation.yield(.assignmentCompleted(assignment.id, outcome: "Retry completed"))
            return CodexExecutionHandle(threadID: "retry-thread", turnID: "retry-turn")
        }
        continuation.yield(.approvalRequired(.init(
            id: "blocked-approval",
            assignmentID: assignment.id,
            kind: .command,
            summary: canAccept ? "Approval required" : "Blocked by resource policy",
            canAccept: canAccept,
            operationDigest: String(repeating: "a", count: 64),
            disclosureComplete: true
        )))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) throws {
        interruptionCount += 1
        if failsInterrupt { throw OrchestratorError.providerExecutionFailed("Interrupt was not confirmed") }
    }
    func respond(to approvalID: String, decision: CodexApprovalDecision) {
        record(decision: decision, operationDigest: nil)
    }
    func respond(
        to approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) async throws {
        responseAttempts += 1
        if let responseDelay {
            try await Task.sleep(for: responseDelay)
        }
        if decision == .accept {
            guard operationDigest == String(repeating: "a", count: 64) else {
                throw ProviderApprovalBindingError.missingOrChangedOperationDigest
            }
        }
        record(decision: decision, operationDigest: operationDigest)
    }
    private func record(decision: CodexApprovalDecision, operationDigest: String?) {
        receivedDecision = decision
        receivedOperationDigest = operationDigest
        guard emitsTerminalResponse else { return }
        if let assignmentID {
            switch decision {
            case .accept, .acceptForSession, .acceptAllForRun:
                continuation.yield(.assignmentCompleted(assignmentID, outcome: "Approved and completed"))
            case .decline, .cancel:
                continuation.yield(.assignmentFailed(assignmentID, message: "Approval declined"))
            }
        }
    }
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor RunWideApprovalFakeCodex: CodexServing {
    struct Response: Equatable, Sendable {
        let approvalID: String
        let decision: CodexApprovalDecision
        let operationDigest: String?
    }

    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation
    private(set) var responses: [Response] = []
    private var assignmentID: AssignmentID?

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        assignmentID = assignment.id
        continuation.yield(.assignmentStarted(assignment.id))
        continuation.yield(.approvalRequired(.init(
            id: "approval-command",
            assignmentID: assignment.id,
            kind: .command,
            summary: "Approve command",
            approvalSessionID: .init(rawValue: "exact-session"),
            operationDigest: String(repeating: "a", count: 64),
            disclosureComplete: true
        )))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {
        record(approvalID: approvalID, decision: decision, operationDigest: nil)
    }
    func respond(
        to approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) throws {
        let expectedDigest: String? = switch approvalID {
        case "approval-command": String(repeating: "a", count: 64)
        case "approval-command-repeat": String(repeating: "b", count: 64)
        case "approval-permissions": String(repeating: "c", count: 64)
        default: nil
        }
        if decision == .accept, operationDigest != expectedDigest {
            throw ProviderApprovalBindingError.missingOrChangedOperationDigest
        }
        record(approvalID: approvalID, decision: decision, operationDigest: operationDigest)
    }
    private func record(
        approvalID: String,
        decision: CodexApprovalDecision,
        operationDigest: String?
    ) {
        responses.append(.init(
            approvalID: approvalID,
            decision: decision,
            operationDigest: operationDigest
        ))
        guard let assignmentID else { return }
        guard decision == .accept || decision == .acceptForSession else {
            continuation.yield(.assignmentFailed(assignmentID, message: "Approval declined"))
            return
        }
        switch approvalID {
        case "approval-command":
            continuation.yield(.approvalRequired(.init(
                id: "approval-command-repeat",
                assignmentID: assignmentID,
                kind: .command,
                summary: "Approve command",
                approvalSessionID: .init(rawValue: "exact-session"),
                operationDigest: String(repeating: "b", count: 64),
                disclosureComplete: true
            )))
        case "approval-command-repeat":
            continuation.yield(.approvalRequired(.init(
                id: "approval-permissions",
                assignmentID: assignmentID,
                kind: .permissions,
                summary: "Approve resource permission",
                approvalSessionID: .init(rawValue: "exact-session"),
                operationDigest: String(repeating: "c", count: 64),
                disclosureComplete: true
            )))
        case "approval-permissions":
            continuation.yield(.assignmentCompleted(assignmentID, outcome: "All approval types completed"))
        default:
            continuation.yield(.assignmentFailed(assignmentID, message: "Unexpected approval"))
        }
    }
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor RateLimitedFakeCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation
    private var accountReads = 0

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        accountReads += 1
        return CodexAccountSnapshot(
            authenticated: true,
            displayName: nil,
            planName: "test",
            usedPercent: accountReads == 1 ? 99 : 0,
            resetsAt: .now
        )
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        continuation.yield(.assignmentStarted(assignment.id))
        continuation.yield(.assignmentCompleted(assignment.id, outcome: "Completed after reset"))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private actor InterruptingFakeCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        continuation.yield(.assignmentStarted(assignment.id))
        return CodexExecutionHandle(threadID: "thread", turnID: "turn")
    }
    func interrupt(assignmentID: AssignmentID) {
        continuation.yield(.assignmentFailed(assignmentID, message: "Interrupted"))
    }
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

private struct FakeWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) async throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) async throws -> String? { nil }
}

private actor RecordingWorkspace: WorkspacePreparing {
    private var finalized = 0

    func prepare(project: LabProject, for run: RunRecord) async throws -> ProjectDirectoryPlacement {
        guard let identity = project.fileSystemIdentity else {
            throw WorkspaceError.unsafeWorktree(project.rootURL)
        }
        return ProjectDirectoryPlacement(rootURL: project.rootURL, fileSystemIdentity: identity)
    }

    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) async throws -> String? {
        finalized += 1
        return "Finalized"
    }

    func finalizationCount() -> Int {
        finalized
    }
}

private struct FailingVerifier: VerificationRunning {
    func verify(
        project: LabProject,
        workingDirectory: URL,
        evidence: [ProviderCommandExecutionEvidence]
    ) async -> VerificationResult {
        VerificationResult(succeeded: false, summary: "Checks failed")
    }
}

private struct FakeVerifier: VerificationRunning {
    func verify(
        project: LabProject,
        workingDirectory: URL,
        evidence: [ProviderCommandExecutionEvidence]
    ) async -> VerificationResult {
        VerificationResult(succeeded: true, summary: "Verified")
    }
}


extension InfrastructureTests {
    @Test("Model change retires blocked approval, keeps completed results, and starts a fresh task", .timeLimit(.minutes(1)))
    func modelChangeRetiresBlockedApproval() async throws {
        let fixture = modelChangeFixture()
        let codex = ApprovalFakeCodex(emitsTerminalResponse: false, completesOnRetry: true)
        let orchestrator = CodexRunOrchestrator(catalog: fixture.repository, runs: fixture.repository,
            codex: codex, workspaces: FakeWorkspace(), verifier: FakeVerifier())
        let firstExecution = Task { try await orchestrator.execute(runID: fixture.run.id) }
        let blocked = try await waitForModelChangeApproval(orchestrator, repository: fixture.repository)
        try await orchestrator.resume(runID: blocked.id, modelChange: .init(
            providerID: .codex, model: "model-b", expectedUpdatedAt: blocked.updatedAt))
        try await firstExecution.value

        let result = try #require(await fixture.repository.allRuns().first)
        let starts = await codex.startedAssignments
        #expect(result.status == .completed)
        #expect(starts.map(\.model) == ["model-a", "model-b"])
        #expect(starts.allSatisfy { $0.providerTaskID == nil && $0.providerTurnID == nil })
        #expect(starts.allSatisfy { $0.currentTask == fixture.run.plan.interpretedGoal })
        #expect(starts[0].workingDirectory == starts[1].workingDirectory)
        #expect(result.assignments.first == fixture.run.assignments.first)
        #expect(result.plan == fixture.run.plan)
        #expect(result.journal.contains { $0.message.contains("User selected model-b") })
        #expect(await codex.receivedDecision == .cancel)
        #expect(await codex.interruptionCount == 1)
        #expect(await orchestrator.pendingApprovals().isEmpty)
    }

    @Test("Model change retires a failed provider attempt that never emitted a terminal event", .timeLimit(.minutes(1)))
    func modelChangeRetiresFailedProviderAttempt() async throws {
        let fixture = modelChangeFixture()
        let codex = ApprovalFakeCodex(emitsTerminalResponse: false, completesOnRetry: true)
        let orchestrator = CodexRunOrchestrator(catalog: fixture.repository, runs: fixture.repository,
            codex: codex, workspaces: FakeWorkspace(), verifier: FakeVerifier())
        let execution = Task { try await orchestrator.execute(runID: fixture.run.id) }
        _ = try await waitForModelChangeApproval(orchestrator, repository: fixture.repository)
        let pending = try #require(await orchestrator.pendingApprovals().first)
        try await orchestrator.respond(to: pending, decision: .decline)
        try await execution.value
        let failed = try #require(await fixture.repository.allRuns().first)
        #expect(failed.assignments.last?.status == .failed)
        try await orchestrator.resume(runID: failed.id, modelChange: .init(
            providerID: .codex, model: "model-b", expectedUpdatedAt: failed.updatedAt))
        #expect(await codex.interruptionCount == 1)
        #expect(await codex.startedAssignments.map(\.model) == ["model-a", "model-b"])
        #expect(await fixture.repository.allRuns().first?.status == .completed)
    }

    @Test("Invalid model changes do not disturb a blocked request", .timeLimit(.minutes(1)), arguments: ["stale", "unavailable", "same", "wrong-provider"])
    func invalidModelChangeKeepsApproval(reason: String) async throws {
        let fixture = modelChangeFixture()
        let codex = ApprovalFakeCodex(emitsTerminalResponse: false)
        let orchestrator = CodexRunOrchestrator(catalog: fixture.repository, runs: fixture.repository,
            codex: codex, workspaces: FakeWorkspace(), verifier: FakeVerifier())
        let execution = Task { try await orchestrator.execute(runID: fixture.run.id) }
        let blocked = try await waitForModelChangeApproval(orchestrator, repository: fixture.repository)
        await #expect(throws: GobyApplicationError.self) {
            try await orchestrator.resume(runID: blocked.id, modelChange: .init(
                providerID: reason == "wrong-provider" ? .claude : .codex,
                model: reason == "unavailable" ? "missing-model" : reason == "same" ? "model-a" : "model-b",
                expectedUpdatedAt: reason == "stale" ? .distantPast : blocked.updatedAt))
        }
        #expect(await codex.startCount == 1)
        #expect(await codex.interruptionCount == 0)
        #expect(await codex.receivedDecision == nil)
        #expect(await orchestrator.pendingApprovals().count == 1)
        try await orchestrator.cancel(runID: blocked.id)
        try await execution.value
    }

    @Test("An unconfirmed interruption cannot start the newly selected model", .timeLimit(.minutes(1)))
    func modelChangeRequiresConfirmedInterruption() async throws {
        let fixture = modelChangeFixture()
        let codex = ApprovalFakeCodex(emitsTerminalResponse: false, completesOnRetry: true, failsInterrupt: true)
        let orchestrator = CodexRunOrchestrator(catalog: fixture.repository, runs: fixture.repository,
            codex: codex, workspaces: FakeWorkspace(), verifier: FakeVerifier())
        let execution = Task { try await orchestrator.execute(runID: fixture.run.id) }
        let blocked = try await waitForModelChangeApproval(orchestrator, repository: fixture.repository)
        await #expect(throws: OrchestratorError.self) {
            try await orchestrator.resume(runID: blocked.id, modelChange: .init(
                providerID: .codex, model: "model-b", expectedUpdatedAt: blocked.updatedAt))
        }
        #expect(await codex.startCount == 1)
        #expect(await codex.receivedDecision == .cancel)
        let stopped = try #require(await fixture.repository.allRuns().first)
        #expect(stopped.assignments.last?.model == "model-a")
        #expect(stopped.status == .needsAttention)
        try await orchestrator.cancel(runID: blocked.id)
        try await execution.value
    }

    private func modelChangeFixture() -> (run: RunRecord, repository: TestRepository) {
        let project = LabProject(id: "model-change-project", name: "Model Change", rootURL: FileManager.default.temporaryDirectory,
            platforms: [.general], isGitRepository: false)
        let agent = AgentProfile(id: "model-change-agent", name: "Agent", summary: "Test", capabilities: [.routing], scope: .project(project.id))
        let plan = RoutingPlan(id: "model-change-run", interpretedGoal: "Review this project", routes: [
            ProjectRoute(projectID: project.id, model: "model-a", agentIDs: [agent.id], reason: "Test")
        ], risk: .readOnly, confidence: 1)
        let done = AgentAssignment(id: "model-change-done", runID: plan.id, projectID: project.id, agentID: agent.id,
            status: .completed, currentTask: "Verified earlier result", progress: 1, statusReason: "Keep this result",
            providerID: .claude, model: "prior-model", providerTaskID: "completed-task")
        let pending = AgentAssignment(id: "model-change-pending", runID: plan.id, projectID: project.id, agentID: agent.id,
            status: .queued, currentTask: plan.interpretedGoal, model: "model-a")
        let run = RunRecord(id: plan.id, plan: plan, status: .ready, assignments: [done, pending], agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)], projectSnapshot: [project])
        return (run, TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: [run]))
    }

    private func waitForModelChangeApproval(_ orchestrator: CodexRunOrchestrator, repository: TestRepository) async throws -> RunRecord {
        for _ in 0..<200 {
            if let run = await repository.allRuns().first, run.status == .needsAttention,
               run.assignments.last?.providerTaskID != nil, await orchestrator.pendingApprovals().count == 1 {
                return run
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OrchestratorError.providerExecutionFailed("No pending approval was published")
    }
}

// MARK: - Parallel requests in one project

/// Starts assignments and completes each only when the test releases it.
private actor GatedCodex: CodexServing {
    let stream: AsyncStream<CodexRunEvent>
    let continuation: AsyncStream<CodexRunEvent>.Continuation
    private(set) var started: [AssignmentID] = []

    init() {
        let pair = AsyncStream<CodexRunEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectionState() -> CodexConnectionState { .connected(version: "fake") }
    func connect() -> CodexConnectionState { .connected(version: "fake") }
    func accountSnapshot() -> CodexAccountSnapshot {
        CodexAccountSnapshot(authenticated: true, displayName: nil, planName: "test", usedPercent: 0)
    }
    func recentProjectRoots() -> CodexProjectRootsSnapshot { .init(roots: []) }
    func start(
        assignment: AgentAssignment,
        project: LabProject,
        agent: AgentProfile,
        instructions: [InstructionPack],
        resources: [SharedResource],
        risk: PlanRisk
    ) -> CodexExecutionHandle {
        started.append(assignment.id)
        continuation.yield(.assignmentStarted(assignment.id))
        return CodexExecutionHandle(threadID: "thread-\(assignment.id.rawValue)", turnID: "turn")
    }
    func release(_ id: AssignmentID) {
        continuation.yield(.assignmentCompleted(id, outcome: "Done"))
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: CodexApprovalDecision) {}
    func events() -> AsyncStream<CodexRunEvent> { stream }
}

@Suite("Parallel requests in one project", .timeLimit(.minutes(1)))
struct ParallelRequestOrchestrationTests {
    private let project = LabProject(
        id: "shared-project", name: "Shared", rootURL: FileManager.default.temporaryDirectory,
        platforms: [.general], isGitRepository: false
    )
    private var agent: AgentProfile {
        AgentProfile(id: "agent", name: "Agent", summary: "General", capabilities: [.routing], scope: .project(project.id))
    }

    private func run(_ id: String, goal: String, risk: PlanRisk) -> RunRecord {
        let plan = RoutingPlan(
            id: RunID(rawValue: id), interpretedGoal: goal,
            routes: [ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")],
            risk: risk, confidence: 1
        )
        return RunRecord(
            id: plan.id, plan: plan, status: .ready,
            assignments: [AgentAssignment(id: AssignmentID(rawValue: "\(id)-a"), runID: plan.id, projectID: project.id,
                                          agentID: agent.id, status: .queued, currentTask: goal)],
            agentSnapshot: [agent],
            providerBindingSnapshot: [ProviderAgentBinding.migratedCodexBinding(for: agent)],
            projectSnapshot: [project]
        )
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<500 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }

    private func setUp(_ runs: [RunRecord]) -> (TestRepository, GatedCodex, CodexRunOrchestrator) {
        let repository = TestRepository(lab: LabSnapshot(projects: [project], agents: [agent]), runs: runs)
        let codex = GatedCodex()
        let orchestrator = CodexRunOrchestrator(
            catalog: repository, runs: repository, codex: codex,
            workspaces: FakeWorkspace(), verifier: FakeVerifier()
        )
        return (repository, codex, orchestrator)
    }

    @Test("A request that changes the same project folder waits, explains why, then starts by itself")
    func conflictingRequestWaits() async throws {
        let first = run("first", goal: "Fix the checkout flow", risk: .low)
        let second = run("second", goal: "Redesign the settings page", risk: .low)
        let (repository, codex, orchestrator) = setUp([first, second])
        let firstTask = Task { try? await orchestrator.execute(runID: first.id) }
        try await waitUntil { await codex.started.count == 1 }
        let secondTask = Task { try? await orchestrator.execute(runID: second.id) }
        try await waitUntil {
            let assignment = try? await repository.allRuns().first { $0.id == second.id }?.assignments.first
            return ParallelRequestPolicy.isWaitingForConflict(status: assignment?.status ?? .available, reason: assignment?.statusReason)
        }
        let waiting = try #require(try await repository.allRuns().first { $0.id == second.id }?.assignments.first)
        #expect(waiting.statusReason?.contains("Fix the checkout flow") == true)
        #expect(waiting.statusReason?.contains("same project folder") == true)
        #expect(await codex.started == ["first-a"])

        await codex.release("first-a")
        await firstTask.value
        try await waitUntil { await codex.started.count == 2 }
        await codex.release("second-a")
        await secondTask.value
        #expect(try await repository.allRuns().first { $0.id == second.id }?.status == .completed)
    }

    @Test("Run Anyway starts a waiting request at once")
    func runAnyway() async throws {
        let first = run("first", goal: "Fix the checkout flow", risk: .low)
        let second = run("second", goal: "Update the footer", risk: .low)
        let (_, codex, orchestrator) = setUp([first, second])
        let firstTask = Task { try? await orchestrator.execute(runID: first.id) }
        try await waitUntil { await codex.started.count == 1 }
        let secondTask = Task { try? await orchestrator.execute(runID: second.id) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await codex.started.count == 1)
        try await orchestrator.startWithoutWaiting(runID: second.id)
        try await waitUntil { await codex.started.count == 2 }
        await codex.release("first-a")
        await codex.release("second-a")
        await firstTask.value
        await secondTask.value
    }

    @Test("Requests that cannot interfere run side by side")
    func independentRequestsRunInParallel() async throws {
        let first = run("first", goal: "Explain the analytics setup", risk: .readOnly)
        let second = run("second", goal: "Summarise open issues", risk: .readOnly)
        let (_, codex, orchestrator) = setUp([first, second])
        let firstTask = Task { try? await orchestrator.execute(runID: first.id) }
        try await waitUntil { await codex.started.count == 1 }
        let secondTask = Task { try? await orchestrator.execute(runID: second.id) }
        try await waitUntil { await codex.started.count == 2 }
        await codex.release("first-a")
        await codex.release("second-a")
        await firstTask.value
        await secondTask.value
    }
}
