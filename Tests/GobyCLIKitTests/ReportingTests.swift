import Foundation
import Synchronization
import Testing
@testable import GobyCLIKit

@Suite("Error reports and the local log", .serialized)
struct ReportingTests {
    private func makeReporter(endpoint: String? = "https://reports.example.invalid/api/report", session: URLSession = .shared) -> (GobyReporter, URL, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-reports-\(UUID().uuidString)")
        let suite = "com.goby.cli.test.reports.\(UUID().uuidString)"
        let reporter = GobyReporter(logDirectory: root, defaultsSuite: suite,
                                    environment: endpoint.map { ["GOBY_REPORT_URL": $0] } ?? [:], session: session)
        return (reporter, root, suite)
    }

    @Test("Without consent, everything is logged locally and nothing is queued to send")
    func noConsentKeepsReportsLocal() throws {
        let (reporter, root, suite) = makeReporter()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        reporter.record(reporter.event(.error, command: "request", exitCode: 1, message: "Codex closed unexpectedly."))
        #expect(reporter.recentLog().count == 1)
        #expect(!FileManager.default.fileExists(atPath: reporter.pendingURL.path))
        reporter.setConsent(.off)
        reporter.record(reporter.event(.error, command: "request", exitCode: 1, message: "Again."))
        #expect(!FileManager.default.fileExists(atPath: reporter.pendingURL.path))
    }

    @Test("With consent, failures are queued and successful commands are not")
    func consentQueuesFailuresOnly() throws {
        let (reporter, root, suite) = makeReporter()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        reporter.setConsent(.on)
        reporter.record(reporter.event(.command, command: "map", exitCode: 0, duration: .milliseconds(120)))
        reporter.record(reporter.event(.runFailed, command: "request", provider: "codex", message: "Verification failed."))
        let pending = try String(contentsOf: reporter.pendingURL, encoding: .utf8).split(separator: "\n")
        #expect(pending.count == 1)
        #expect(pending[0].contains("\"run-failed\""))
        #expect(reporter.recentLog().count == 2)
    }

    @Test("Reports never carry paths, keys or free-text commands")
    func redaction() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let message = GobyReporter.redact("Failed in \(home)/code/secret-app/main.swift and /private/var/folders/x/y.log using sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        #expect(!message.contains(home))
        #expect(!message.contains("secret-app"))
        #expect(!message.contains("/private/var"))
        #expect(!message.contains("ABCDEFGHIJKLMNOP"))
        #expect(GobyReporter.safeCommand("fix the login bug in my app") == "request")
        #expect(GobyReporter.safeCommand("map") == "map")
        #expect(GobyReporter.safeCommand("version") == "version")
    }

    @Test("Flush sends queued reports with the build key and clears them on success")
    func flushSendsAndClears() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubReportEndpoint.self]
        let (reporter, root, suite) = makeReporter(session: URLSession(configuration: configuration))
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        reporter.setConsent(.on)
        reporter.record(reporter.event(.error, command: "login", exitCode: 1, message: "Codex sign-in did not finish."))
        StubReportEndpoint.reset(status: 202)
        await reporter.flush()
        let request = try #require(StubReportEndpoint.captured)
        #expect(request.key == GobyReportingConfiguration.ingestKey)
        #expect(request.body.contains("Codex sign-in did not finish."))
        #expect(!FileManager.default.fileExists(atPath: reporter.pendingURL.path))
    }

    @Test("A failed send keeps reports queued for next time")
    func flushFailureKeepsQueue() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubReportEndpoint.self]
        let (reporter, root, suite) = makeReporter(session: URLSession(configuration: configuration))
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        reporter.setConsent(.on)
        reporter.record(reporter.event(.error, command: "request", exitCode: 3, message: "Host unavailable."))
        StubReportEndpoint.reset(status: 503)
        await reporter.flush()
        #expect(FileManager.default.fileExists(atPath: reporter.pendingURL.path))
    }

    @Test("Only https endpoints are used")
    func httpsOnly() {
        let (reporter, root, suite) = makeReporter(endpoint: "http://reports.example.invalid/api/report")
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        #expect(!reporter.isConfigured)
    }
}

@Suite("Slash command suggestions")
struct LineEditorTests {
    private let editor = GobyLineEditor(style: .plain, commands: [
        .init(name: "map", usage: "/map", summary: "tree"),
        .init(name: "model", usage: "/model [name|default]", summary: "models"),
        .init(name: "automations", usage: "/automations", summary: "schedules"),
        .init(name: "agents", usage: "/agents [project]", summary: "agents"),
        .init(name: "exit", usage: "/exit", summary: "leave"),
    ])

    @Test("A bare slash lists commands; typing narrows by prefix, then by contains")
    func suggestions() {
        #expect(editor.suggestions(for: "/").count == 5)
        #expect(editor.suggestions(for: "/ma").map(\.name) == ["map", "automations"])
        #expect(editor.suggestions(for: "/m").map(\.name) == ["map", "model", "automations"])
        #expect(editor.suggestions(for: "/ex").map(\.name) == ["exit"])
    }

    @Test("No suggestions once arguments start, or for ordinary requests")
    func noSuggestions() {
        #expect(editor.suggestions(for: "/agents web").isEmpty)
        #expect(editor.suggestions(for: "fix the /login route").isEmpty)
        #expect(editor.suggestions(for: "").isEmpty)
    }

    @Test("Completing a command that takes arguments leaves room to type them")
    func completion() {
        #expect(GobyLineEditor.completion(for: .init(name: "map", usage: "/map", summary: "")) == "/map")
        #expect(GobyLineEditor.completion(for: .init(name: "agents", usage: "/agents [project]", summary: "")) == "/agents ")
    }
}

final class StubReportEndpoint: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { let key: String?; let body: String }
    private static let state = Mutex<(status: Int, captured: Captured?)>((202, nil))
    static var captured: Captured? { state.withLock { $0.captured } }
    static func reset(status: Int) { state.withLock { $0 = (status, nil) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        let status = Self.state.withLock { state in
            state.captured = Captured(key: request.value(forHTTPHeaderField: "X-Goby-Key"), body: String(decoding: body, as: UTF8.self))
            return state.status
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
