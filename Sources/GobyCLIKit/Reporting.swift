import Darwin
import Foundation
import GobyApplication
import Synchronization

/// Where error reports go. Set after deploying Reporting/ (see its README).
/// GOBY_REPORT_URL overrides the endpoint for testing.
public enum GobyReportingConfiguration {
    public static let endpoint: String? = nil
    /// Identifies goby builds to the endpoint. Not a secret: it ships in
    /// every binary and only lets reports in, never out.
    public static let ingestKey = "goby-cli-ingest-v1"
}

/// One local log line, and, for failures, one report.
public struct GobyReportEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command, error, runFailed = "run-failed"
    }
    public let id: String
    public let installationID: String
    public let timestamp: Date
    public let version: String
    public let macOS: String
    public let architecture: String
    public let kind: Kind
    /// The subcommand only, such as "map" or "request". Never its arguments.
    public let command: String
    public let exitCode: Int32?
    public let durationMilliseconds: Int?
    public let provider: String?
    /// Redacted: no paths, keys, tokens or prompts.
    public let message: String?
}

/// Detailed local log, plus opt-in error reports sent to the maintainer.
/// Reporting never blocks or fails a command.
public final class GobyReporter: Sendable {
    public enum Consent: String, Sendable { case on, off }

    public static let consentKey = "GobyReportsConsent"
    static let installationKey = "GobyReportsInstallationID"
    static let maximumLogBytes = 5 * 1_024 * 1_024
    static let maximumPending = 200

    public let logDirectory: URL
    private let defaultsSuite: String
    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite) ?? .standard }
    private let endpoint: URL?
    private let session: URLSession
    private let lock = Mutex(())

    public init(logDirectory: URL = GobyReporter.defaultLogDirectory(),
                defaultsSuite: String = "com.goby.cli",
                environment: [String: String] = ProcessInfo.processInfo.environment,
                session: URLSession = .shared) {
        self.logDirectory = logDirectory
        self.defaultsSuite = defaultsSuite
        let configured = environment["GOBY_REPORT_URL"] ?? GobyReportingConfiguration.endpoint
        endpoint = configured.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" || $0.host == "127.0.0.1" ? $0 : nil }
        self.session = session
    }

    public static func defaultLogDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Goby CLI", directoryHint: .isDirectory)
    }

    public var logURL: URL { logDirectory.appending(path: "goby.log") }
    var pendingURL: URL { logDirectory.appending(path: "pending-reports.jsonl") }

    // MARK: Consent

    public var consent: Consent? {
        defaults.string(forKey: Self.consentKey).flatMap(Consent.init(rawValue:))
    }

    public func setConsent(_ consent: Consent) {
        defaults.set(consent.rawValue, forKey: Self.consentKey)
        if consent == .off { try? FileManager.default.removeItem(at: pendingURL) }
    }

    public var isConfigured: Bool { endpoint != nil }

    private var installationID: String {
        if let existing = defaults.string(forKey: Self.installationKey) { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Self.installationKey)
        return created
    }

    // MARK: Recording

    public func event(_ kind: GobyReportEvent.Kind, command: String, exitCode: Int32? = nil,
                      duration: Duration? = nil, provider: String? = nil, message: String? = nil) -> GobyReportEvent {
        GobyReportEvent(
            id: UUID().uuidString.lowercased(), installationID: installationID, timestamp: .now,
            version: GobyCLIEnvironment.version, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture, kind: kind, command: Self.safeCommand(command), exitCode: exitCode,
            durationMilliseconds: duration.map { Int($0.components.seconds * 1_000 + $0.components.attoseconds / 1_000_000_000_000_000) },
            provider: provider, message: message.map(Self.redact))
    }

    /// Always writes the local log. Failures are also queued for sending
    /// when the person agreed to reports.
    public func record(_ event: GobyReportEvent) {
        lock.withLock { _ in
            append(event, to: logURL, rotateAt: Self.maximumLogBytes)
            if event.kind != .command, consent == .on, endpoint != nil {
                append(event, to: pendingURL, rotateAt: nil)
                trimPending()
            }
        }
    }

    /// Sends queued reports. Bounded; failures keep them for next time.
    public func flush(timeout: TimeInterval = 3) async {
        guard consent == .on, let endpoint else { return }
        let lines = lock.withLock { _ in (try? String(contentsOf: pendingURL, encoding: .utf8)) ?? "" }
            .split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return }
        let batch = Array(lines.prefix(50))
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GobyReportingConfiguration.ingestKey, forHTTPHeaderField: "X-Goby-Key")
        request.httpBody = Data(("[" + batch.joined(separator: ",") + "]").utf8)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        lock.withLock { _ in
            let remaining = ((try? String(contentsOf: pendingURL, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !batch.contains($0) }
            if remaining.isEmpty { try? FileManager.default.removeItem(at: pendingURL) }
            else { try? Data((remaining.joined(separator: "\n") + "\n").utf8).write(to: pendingURL, options: .atomic) }
        }
    }

    /// The newest local log lines, for goby logs.
    public func recentLog(lines count: Int = 40) -> [String] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }

    // MARK: Internals

    private func append(_ event: GobyReportEvent, to url: URL, rotateAt limit: Int?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let limit, let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }

    private func trimPending() {
        guard let text = try? String(contentsOf: pendingURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > Self.maximumPending else { return }
        try? Data((lines.suffix(Self.maximumPending).joined(separator: "\n") + "\n").utf8).write(to: pendingURL, options: .atomic)
    }

    static func redact(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let withoutHome = text.replacingOccurrences(of: home, with: "~")
        // Credentials first, then any remaining absolute path.
        let credentialsRemoved = SensitiveTextRedactor.redactCredentials(withoutHome, limit: 2_000)
        return credentialsRemoved.replacingOccurrences(of: #"(?<![\w~])/(?:[^\s/:"']+/)+[^\s/:"']*"#, with: "[path]", options: .regularExpression)
            .replacingOccurrences(of: #"~/(?:[^\s/:"']+/)*[^\s/:"']*"#, with: "[path]", options: .regularExpression)
    }

    /// Commands are a fixed vocabulary; free text becomes "request".
    static func safeCommand(_ command: String) -> String {
        let known: Set<String> = ["status", "home", "projects", "add", "map", "tree", "agents", "runs", "show", "providers", "models",
            "branches", "instructions", "resources", "groups", "handoffs", "health", "run", "watch", "result", "diff", "log",
            "approve", "deny", "pause", "resume", "cancel", "follow-up", "host", "doctor", "login", "logout", "diagnostics",
            "ask", "commit", "push", "import-agents", "use", "uninstall", "automations", "automation", "session", "config", "logs",
            "version", "help"]
        return known.contains(command) ? command : "request"
    }

    private static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
