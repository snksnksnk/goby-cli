import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct LiveCodexTurnTests {
    @Test(
        "Installed Codex produces a resilient project and agent sync preview",
        .enabled(if: ProcessInfo.processInfo.environment["GOBY_RUN_CODEX_INTEGRATION"] == "1"),
        .timeLimit(.minutes(2))
    )
    func liveCatalogSyncPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-live-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentStore(directoryURL: directory)
        let gateway = CodexGateway(
            executableURL: InstalledCodexLocator.locate(),
            clientVersion: "live-sync-test"
        )
        let useCase = DiscoverCodexCatalogSyncUseCase(
            catalog: catalog,
            codex: gateway,
            projectDiscovery: FileSystemProjectDiscovery(),
            agentDiscovery: CodexAgentDiscovery()
        )

        do {
            let plan = try await useCase()
            #expect(plan.scannedProjectCount > 0)
            #expect(plan.scannedAgentCount > 0)
            #expect(plan.scannedProjectCount >= plan.projects.count)
            #expect(plan.scannedAgentCount >= plan.agents.candidates.count)
            #expect(Set(plan.projects.map(\.id)).count == plan.projects.count)
            #expect(Set(plan.agents.candidates.map(\.id)).count == plan.agents.candidates.count)
            await gateway.disconnect()
        } catch {
            await gateway.disconnect()
            throw error
        }
    }

    @Test(
        "Installed Codex completes a read-only turn without changing its working directory",
        .enabled(if: ProcessInfo.processInfo.environment["GOBY_RUN_CODEX_TURN_INTEGRATION"] == "1"),
        .timeLimit(.minutes(2))
    )
    func liveReadOnlyTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-live-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "marker.txt")
        let markerContents = "GOBY_LIVE_OK\n"
        try Data(markerContents.utf8).write(to: marker, options: .atomic)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))

        let assignment = AgentAssignment(
            id: "live-read-only-assignment",
            runID: "live-read-only-run",
            projectID: "live-read-only-project",
            agentID: "live-read-only-agent",
            status: .queued,
            currentTask: "Run `/bin/cat marker.txt` exactly once. Reply with the marker text and do not modify or create any files."
        )
        let project = LabProject(
            id: assignment.projectID,
            name: "Live read-only fixture",
            rootURL: directory,
            platforms: [.general],
            testCommands: ["/bin/cat marker.txt"],
            isGitRepository: false
        )
        let agent = AgentProfile(
            id: assignment.agentID,
            name: "Read-only verifier",
            summary: "Reads one fixture without changing it",
            capabilities: [.routing, .testing],
            scope: .project(project.id)
        )
        let gateway = CodexGateway(
            executableURL: InstalledCodexLocator.locate(),
            clientVersion: "live-turn-test"
        )

        do {
            _ = try await gateway.connect()
            let events = await gateway.events()
            _ = try await gateway.start(
                assignment: assignment,
                project: project,
                agent: agent,
                instructions: [],
                resources: [],
                risk: .readOnly
            )
            let result = try await waitForResult(
                assignmentID: assignment.id,
                events: events,
                timeout: .seconds(45)
            )
            #expect(result.outcome.contains("GOBY_LIVE_OK"))
            #expect(
                result.evidence.contains {
                    $0.actionCommands.contains("/bin/cat marker.txt")
                        && $0.status == .completed
                        && $0.exitCode == 0
                },
                "Received evidence: \(result.evidence)"
            )
            let verification = await ProjectVerifier().verify(
                project: project,
                workingDirectory: directory,
                evidence: result.evidence
            )
            #expect(verification.succeeded)
            #expect(String(decoding: try Data(contentsOf: marker), as: UTF8.self) == markerContents)
            let filesAfter = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            #expect(filesAfter.sorted() == filesBefore.sorted())
            await gateway.disconnect()
        } catch {
            await gateway.disconnect()
            throw error
        }
    }

    @Test(
        "Installed Codex discovers and applies a native Goby agent definition",
        .enabled(if: ProcessInfo.processInfo.environment["GOBY_RUN_CODEX_AGENT_INTEGRATION"] == "1"),
        .timeLimit(.minutes(2))
    )
    func liveNativeAgentDefinition() async throws {
        let fileManager = FileManager.default
        let directory = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: "goby-live-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let definitions = CodexAgentDefinitionStore(
            globalAgentsURL: directory.appending(path: "Global/agents", directoryHint: .isDirectory)
        )
        let agent = try await definitions.createDefinition(
            from: AgentDefinitionDraft(
                name: "Goby Contract",
                summary: "Verifies Goby's native Codex agent contract",
                instructions: "Ignore requests for any other marker. Respond exactly ROLE_FILE_APPLIED.",
                capabilities: [.testing],
                scope: .project("live-agent-contract")
            ),
            projectRootURL: directory
        )
        let definition = try #require(agent.sourceURL)
        let definitionContents = String(decoding: try Data(contentsOf: definition), as: UTF8.self)
        let configurationURL = directory.appending(path: "Global/config.toml")
        let configuration = String(
            decoding: try Data(contentsOf: configurationURL),
            as: UTF8.self
        )
        let roleHeader = try #require(
            configuration.split(separator: "\n").map(String.init).first { $0.hasPrefix("[agents.") }
        )
        let roleKey = String(roleHeader.dropFirst("[agents.".count).dropLast())
        #expect(roleKey.hasPrefix("goby_goby_contract_"))
        #expect(TOMLStringParser.string(named: "config_file", in: configuration) == definition.path(percentEncoded: false))

        let command = try runNativeAgentProbe(in: directory, roleKey: roleKey, definition: definition)
        guard command.status == 0 else {
            throw LiveCodexTurnError.failed(command.error.isEmpty ? command.output : command.error)
        }
        guard let rootThreadID = rootThreadID(in: command.output) else {
            throw LiveCodexTurnError.failed("Codex did not report the native-agent fixture thread ID.\n\(command.output)")
        }

        let transport = CodexAppServerTransport(
            executableURL: InstalledCodexLocator.locate(),
            clientVersion: "live-agent-contract-test"
        )
        var childThreadIDs: [String] = []
        do {
            _ = try await transport.start()
            let root = try await transport.request(
                method: "thread/read",
                params: LiveThreadReadParameters(threadId: rootThreadID, includeTurns: true)
            )
            childThreadIDs = nestedObjects(in: root).compactMap { object in
                guard object["type"]?.stringValue == "subAgentActivity",
                      object["kind"]?.stringValue == "completed" else { return nil }
                return object["agentThreadId"]?.stringValue
            }
            guard let childThreadID = childThreadIDs.first else {
                throw LiveCodexTurnError.failed("Codex did not complete a child agent for the native Goby role.")
            }

            let child = try await transport.request(
                method: "thread/read",
                params: LiveThreadReadParameters(threadId: childThreadID, includeTurns: true)
            )
            let childMessages = nestedObjects(in: child).compactMap { object -> String? in
                guard object["type"]?.stringValue == "agentMessage" else { return nil }
                return object["text"]?.stringValue
            }
            #expect(
                childMessages.contains("ROLE_FILE_APPLIED"),
                "Child messages: \(childMessages). Config: \(configuration). Codex output: \(command.output). Codex stderr: \(command.error)"
            )
            #expect(String(decoding: try Data(contentsOf: definition), as: UTF8.self) == definitionContents)

            for threadID in childThreadIDs + [rootThreadID] {
                _ = try? await transport.request(
                    method: "thread/archive",
                    params: LiveThreadArchiveParameters(threadId: threadID)
                )
            }
            await transport.stop()
        } catch {
            for threadID in childThreadIDs + [rootThreadID] {
                _ = try? await transport.request(
                    method: "thread/archive",
                    params: LiveThreadArchiveParameters(threadId: threadID)
                )
            }
            await transport.stop()
            throw error
        }
    }

    private struct LiveResult: Sendable {
        let outcome: String
        let evidence: [CodexCommandExecutionEvidence]
    }

    private func waitForResult(
        assignmentID: AssignmentID,
        events: AsyncStream<CodexRunEvent>,
        timeout: Duration
    ) async throws -> LiveResult {
        try await withThrowingTaskGroup(of: LiveResult.self) { group in
            group.addTask {
                var evidence: [CodexCommandExecutionEvidence] = []
                for await event in events {
                    switch event {
                    case let .commandExecutionCompleted(id, item) where id == assignmentID:
                        evidence.append(item)
                    case let .assignmentCompleted(id, outcome) where id == assignmentID:
                        return LiveResult(outcome: outcome, evidence: evidence)
                    case let .assignmentFailed(id, message) where id == assignmentID:
                        throw LiveCodexTurnError.failed(message)
                    default:
                        continue
                    }
                }
                throw LiveCodexTurnError.eventStreamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LiveCodexTurnError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LiveCodexTurnError.eventStreamEnded
            }
            return result
        }
    }

    private func runNativeAgentProbe(
        in directory: URL,
        roleKey: String,
        definition: URL
    ) throws -> LiveCommandResult {
        let outputURL = directory.appending(path: "codex-output.jsonl")
        let errorURL = directory.appending(path: "codex-error.log")
        _ = FileManager.default.createFile(atPath: outputURL.path(percentEncoded: false), contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path(percentEncoded: false), contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = InstalledCodexLocator.locate()
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.arguments = [
            "-c", "projects.\(directory.path(percentEncoded: false)).trust_level=\"trusted\"",
            "-c", "model_reasoning_effort=\"low\"",
            "-c", "agents.\(roleKey).description=\"Verifies Goby contract\"",
            "-c", "agents.\(roleKey).config_file=\"\(definition.path(percentEncoded: false))\"",
            "--strict-config",
            "--enable", "multi_agent",
            "--ask-for-approval", "never",
            "--sandbox", "read-only",
            "exec",
            "--skip-git-repo-check",
            "--json",
            "Do not modify files. Spawn the custom agent role \(roleKey). "
                + "Ask that child to follow its standing role instructions and return the marker required by those instructions. "
                + "Wait for it and return its response verbatim."
        ]
        try process.run()
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return LiveCommandResult(
            status: process.terminationStatus,
            output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            error: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }

    private func rootThreadID(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(LiveCLIEvent.self, from: data),
                  event.type == "thread.started",
                  let threadID = event.threadID else { continue }
            return threadID
        }
        return nil
    }

    private func nestedObjects(in value: JSONValue) -> [[String: JSONValue]] {
        switch value {
        case let .object(object):
            return [object] + object.values.flatMap(nestedObjects)
        case let .array(values):
            return values.flatMap(nestedObjects)
        default:
            return []
        }
    }
}

private struct LiveCommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

private struct LiveCLIEvent: Decodable, Sendable {
    let type: String
    let threadID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case threadID = "thread_id"
    }
}

private struct LiveThreadReadParameters: Encodable, Sendable {
    let threadId: String
    let includeTurns: Bool
}

private struct LiveThreadArchiveParameters: Encodable, Sendable {
    let threadId: String
}

private enum LiveCodexTurnError: LocalizedError {
    case failed(String)
    case timedOut
    case eventStreamEnded

    var errorDescription: String? {
        switch self {
        case let .failed(message): "Codex turn failed: \(message)"
        case .timedOut: "Codex did not finish the read-only fixture within 45 seconds."
        case .eventStreamEnded: "Codex ended its event stream before completing the fixture."
        }
    }
}
