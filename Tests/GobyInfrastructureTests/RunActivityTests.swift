import Foundation
import Testing
@testable import GobyApplication
@testable import GobyDomain
@testable import GobyInfrastructure

@Suite("Run activity steps")
struct RunActivityTests {
    private let assignment: AssignmentID = "assignment"

    @Test("Codex commands become steps with the unwrapped command and exit status")
    func codexCommandStep() throws {
        let item = JSONValue.object([
            "type": .string("commandExecution"),
            "id": .string("item-1"),
            "command": .string("/bin/zsh -lc 'npm --prefix web test'"),
            "status": .string("completed"),
            "exitCode": .integer(1),
            "aggregatedOutput": .string("1 failing\nERROR token=sk-ant-api03-abcdefghijklmnop"),
        ])
        let step = try #require(CodexGateway.activityStep(from: item, assignmentID: assignment, completed: true))
        #expect(step.kind == .command)
        #expect(step.title == "npm --prefix web test")
        #expect(step.status == .failed)
        #expect(step.exitCode == 1)
        #expect(step.detail?.contains("sk-ant-api03") == false)
    }

    @Test("Codex file changes, searches, tools and messages map to their kinds")
    func codexOtherSteps() throws {
        let files = try #require(CodexGateway.activityStep(from: .object([
            "type": .string("fileChange"), "id": .string("f"),
            "changes": .array([.object(["path": .string("/repo/web/src/App.tsx")])]),
        ]), assignmentID: assignment, completed: false))
        #expect(files.kind == .fileChange && files.title == "Edited App.tsx" && files.status == .running)

        let search = try #require(CodexGateway.activityStep(from: .object([
            "type": .string("webSearch"), "id": .string("w"), "query": .string("GA4 retention"),
        ]), assignmentID: assignment, completed: true))
        #expect(search.kind == .webSearch && search.title == "Searched “GA4 retention”")

        let message = try #require(CodexGateway.activityStep(from: .object([
            "type": .string("agentMessage"), "id": .string("m"), "text": .string("I'll check the analytics first."),
        ]), assignmentID: assignment, completed: true))
        #expect(message.kind == .message && message.title == "I'll check the analytics first.")
        #expect(CodexGateway.activityStep(from: .object([
            "type": .string("agentMessage"), "id": .string("m"), "text": .string("partial"),
        ]), assignmentID: assignment, completed: false) == nil)
        #expect(CodexGateway.activityStep(from: .object([
            "type": .string("reasoning"), "id": .string("r"),
        ]), assignmentID: assignment, completed: true) == nil)
    }

    @Test("Claude and Copilot tool calls map to readable steps")
    func bridgedToolSteps() {
        let edit = BridgedRunActivity.toolStep(
            assignmentID: assignment, evidenceID: "e1",
            command: #"Edit {"file_path":"/repo/README.md","old_string":"a","new_string":"b"}"#,
            actionCommands: ["Edit"], succeeded: true, exitCode: 0, output: nil
        )
        #expect(edit.kind == .fileChange && edit.title == "Edited README.md")
        let shell = BridgedRunActivity.toolStep(
            assignmentID: assignment, evidenceID: "e2", command: "swift test",
            actionCommands: [], succeeded: false, exitCode: 1, output: "failed"
        )
        #expect(shell.kind == .command && shell.status == .failed && shell.detail == "failed")
        let fetch = BridgedRunActivity.toolStep(
            assignmentID: assignment, evidenceID: "e3", command: #"WebFetch {"url":"https://efimeria.app"}"#,
            actionCommands: ["WebFetch"], succeeded: true, exitCode: 0, output: nil
        )
        #expect(fetch.kind == .webSearch && fetch.title == "Opened https://efimeria.app")
    }

    @Test("Steps upsert by id, keep their start and stay bounded")
    func activityLogUpsertAndCap() {
        let start = Date(timeIntervalSince1970: 100)
        let running = RunActivityStep(id: "c", assignmentID: assignment, kind: .command, title: "npm test", status: .running, startedAt: start)
        let done = RunActivityStep(id: "c", assignmentID: assignment, kind: .command, title: "npm test", status: .succeeded, exitCode: 0)
        let log = RunActivityLog.upserting(done, into: [running])
        #expect(log.count == 1 && log[0].status == .succeeded && log[0].startedAt == start)

        var many: [RunActivityStep] = []
        for index in 0..<(RunActivityLog.limit + 5) {
            many = RunActivityLog.upserting(
                RunActivityStep(id: "s\(index)", assignmentID: assignment, kind: .tool, title: "t", status: .succeeded),
                into: many
            )
        }
        #expect(many.count == RunActivityLog.limit && many.first?.id == "s5")
    }

    @Test("Runs saved before activity existed still decode")
    func runDecodesWithoutActivity() throws {
        let run = RunRecord(
            id: "run",
            plan: RoutingPlan(id: "run", interpretedGoal: "g", routes: [], risk: .readOnly, confidence: 1),
            status: .completed,
            assignments: []
        )
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        object.removeValue(forKey: "activity")
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.activity.isEmpty)
    }
}

@Suite("Codex command descriptions")
struct CodexCommandDescriptionTests {
    @Test("Parsed read, search and list actions name the step")
    func describedCommands() {
        let read = CodexGateway.describedCommand(actions: .array([
            .object(["type": .string("read"), "command": .string("cat a"), "name": .string("SEO_OPERATIONS.md"), "path": .string("/repo/web/docs/SEO_OPERATIONS.md")]),
        ]))
        #expect(read?.kind == .read && read?.title == "Read SEO_OPERATIONS.md")
        let search = CodexGateway.describedCommand(actions: .array([
            .object(["type": .string("search"), "command": .string("rg analytics"), "query": .string("analytics"), "path": .string("/repo/web")]),
        ]))
        #expect(search?.kind == .search && search?.title == "Searched “analytics” in web")
        #expect(CodexGateway.describedCommand(actions: .array([
            .object(["type": .string("unknown"), "command": .string("npm test")]),
        ])) == nil)
        #expect(CodexGateway.toolDisplayName(server: "cua_repl", tool: "js") == "Used the browser")
    }
}
