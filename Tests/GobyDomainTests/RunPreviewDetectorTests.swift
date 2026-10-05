import Foundation
import Testing
@testable import GobyDomain

@Suite("Run preview detection")
struct RunPreviewDetectorTests {
    private func step(
        _ title: String,
        detail: String? = nil,
        kind: RunActivityStep.Kind = .command,
        id: String = UUID().uuidString
    ) -> RunActivityStep {
        RunActivityStep(id: id, assignmentID: "assignment", kind: kind, title: title, detail: detail, status: .running)
    }

    @Test("Dev server output from common tools yields openable loopback pages")
    func devServerShapes() {
        let steps = [
            step("npm run dev", detail: "  VITE v6.0.0  ready in 312 ms\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose"),
            step("npx next dev", detail: "- Local:        http://localhost:3000"),
            step("python3 -m http.server 8000", detail: "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ..."),
        ]
        let urls = RunPreviewDetector.webURLs(in: steps).map(\.absoluteString)
        #expect(urls == ["http://localhost:8000/", "http://localhost:3000/", "http://localhost:5173/"])
    }

    @Test("Only loopback addresses with a port are offered")
    func loopbackOnly() {
        let steps = [step("curl", detail: """
            https://example.com:8443/ http://192.168.1.4:3000/ http://localhost/ \
            http://127.0.0.1:4173/app?x=1 http://[::1]:9000/ http://localhost.evil.com:80/
            """)]
        let urls = RunPreviewDetector.webURLs(in: steps).map(\.absoluteString)
        #expect(urls.contains("http://127.0.0.1:4173/app?x=1"))
        #expect(urls.contains { $0.contains("::1") })
        #expect(!urls.contains { $0.contains("example.com") || $0.contains("192.168") || $0.contains("evil") })
        #expect(!urls.contains("http://localhost/"))
    }

    @Test("Trailing punctuation from log lines is dropped and duplicates collapse")
    func normalization() {
        let steps = [
            step("serve", detail: "Ready at http://localhost:5173/."),
            step("serve again", detail: "Listening on http://localhost:5173/, press q to quit"),
        ]
        #expect(RunPreviewDetector.webURLs(in: steps).map(\.absoluteString) == ["http://localhost:5173/"])
    }

    @Test("At most three pages, newest first")
    func limit() {
        let steps = (1...5).map { step("serve", detail: "http://localhost:300\($0)") }
        #expect(RunPreviewDetector.webURLs(in: steps).map(\.absoluteString)
            == ["http://localhost:3005/", "http://localhost:3004/", "http://localhost:3003/"])
    }

    @Test("Devices and agent browsers appear only when the run used them")
    func deviceEvidence() {
        #expect(RunPreviewDetector.targets(in: [step("swift build")]).isEmpty)
        #expect(RunPreviewDetector.targets(in: [
            step("xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' build")
        ]) == [.simulator])
        #expect(RunPreviewDetector.targets(in: [step("./gradlew installDebug")]) == [.emulator])
        #expect(RunPreviewDetector.targets(in: [step("npx playwright test --headed")]) == [.automationBrowser])
    }

    @Test("Agent messages that mention addresses are not treated as servers")
    func messagesIgnored() {
        let steps = [step("Open http://localhost:5173 to check it", kind: .message)]
        #expect(RunPreviewDetector.targets(in: steps).isEmpty)
    }
}
