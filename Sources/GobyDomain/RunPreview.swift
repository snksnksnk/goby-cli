import Foundation

/// Something a run produced that the Mac can show live beside its
/// conversation. Previews never leave the Mac.
public enum RunPreviewTarget: Hashable, Identifiable, Sendable {
    /// A page served on this Mac's loopback interface.
    case web(URL)
    /// The iOS Simulator, once the run has used it.
    case simulator
    /// The Android emulator, once the run has used it.
    case emulator
    /// A browser window an agent drives, for example from Playwright.
    case automationBrowser

    public var id: String {
        switch self {
        case let .web(url): "web:\(url.absoluteString)"
        case .simulator: "simulator"
        case .emulator: "emulator"
        case .automationBrowser: "automation-browser"
        }
    }
}

/// Finds preview targets in a run's typed activity. It reads only command
/// steps, accepts only loopback web addresses, and offers devices only when
/// the run itself used them, so an unrelated booted simulator never appears.
public enum RunPreviewDetector {
    public static let webLimit = 3

    public static func targets(in activity: [RunActivityStep]) -> [RunPreviewTarget] {
        let commands = activity.filter { $0.kind == .command || $0.kind == .tool }
        var targets = webURLs(in: commands).map(RunPreviewTarget.web)
        let text = commands.map { "\($0.title)\n\($0.detail ?? "")" }.joined(separator: "\n").lowercased()
        if usesSimulator(text) { targets.append(.simulator) }
        if usesEmulator(text) { targets.append(.emulator) }
        if usesAutomationBrowser(text) { targets.append(.automationBrowser) }
        return targets
    }

    /// Loopback URLs with a port, newest step first, without duplicates.
    public static func webURLs(in steps: [RunActivityStep]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for step in steps.reversed() {
            // Output lines are newest last; prefer the latest address a step printed.
            let text = "\(step.title)\n\(step.detail ?? "")"
            for url in loopbackURLs(in: text).reversed() where seen.insert(url.absoluteString).inserted {
                urls.append(url)
                if urls.count == webLimit { return urls }
            }
        }
        return urls
    }

    static func loopbackURLs(in text: String) -> [URL] {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{2,5}(?:/[^\s"'<>`)\]]*)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return normalized(String(text[matchRange]))
        }
    }

    /// Strips trailing punctuation from log text and maps the wildcard address,
    /// which servers print but browsers cannot open, to `localhost`.
    static func normalized(_ raw: String) -> URL? {
        var candidate = raw
        while let last = candidate.last, ".,;:".contains(last) { candidate.removeLast() }
        guard var components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              let port = components.port, (1...65_535).contains(port) else { return nil }
        guard ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) else { return nil }
        if host == "0.0.0.0" { components.host = "localhost" }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// Whether a preview may load this address: http(s) on this Mac only.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func usesSimulator(_ text: String) -> Bool {
        ["simctl boot", "simctl install", "simctl launch", "platform=ios simulator", "open -a simulator"]
            .contains { text.contains($0) }
    }

    static func usesEmulator(_ text: String) -> Bool {
        ["emulator -avd", "emulator @", "adb install", "adb shell am start", "installdebug"]
            .contains { text.contains($0) }
    }

    static func usesAutomationBrowser(_ text: String) -> Bool {
        ["playwright", "puppeteer", "selenium", "chromedriver", "webdriver"]
            .contains { text.contains($0) }
    }
}

/// A booted iOS Simulator or running Android emulator found on this Mac.
public struct RunPreviewDevice: Hashable, Identifiable, Sendable {
    public enum Platform: String, Hashable, Sendable {
        case iOSSimulator
        case androidEmulator
    }

    public let id: String
    public let name: String
    public let platform: Platform

    public init(id: String, name: String, platform: Platform) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}
