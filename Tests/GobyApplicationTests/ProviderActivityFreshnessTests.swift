import Foundation
import GobyApplication
import GobyDomain
import Testing

@Suite("Provider activity freshness projection")
struct ProviderActivityFreshnessTests {
    @Test("Large provider history still produces a redacted host projection")
    func projectsLargeTaskHistory() {
        let now = Date(timeIntervalSince1970: 1_789_500_000)
        let projectID = ProjectID(rawValue: "project")
        let forbidden = "/Users/test/Private Project"
        let tasks = (0..<703).map { index in
            CodexTaskActivity(
                id: "task-\(index)", projectID: projectID,
                title: "Task \(index) in \(forbidden)", summary: "Saved provider result",
                status: .completed, updatedAt: now
            )
        }
        let providerTasks = (0..<703).map { index in
            ProviderTaskActivity(
                identity: .init(providerID: .codex, nativeID: "task-\(index)"),
                projectID: projectID, title: "Task \(index) in \(forbidden)",
                summary: "Saved provider result", status: .completed, updatedAt: now
            )
        }
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero, lab: .empty, runs: [], approvals: [], resources: [],
            codexTasks: tasks, account: nil, providerTasks: providerTasks,
            health: .init(checks: []),
            exactForbiddenValues: [forbidden] + (0..<200).map { "/Users/test/Other Project \($0)" },
            generatedAt: now
        )
        #expect(projection.codexTasks.count == 703)
        #expect(projection.providerTasks.count == 703)
        #expect(projection.codexTasks.allSatisfy { !$0.title.contains(forbidden) })
        #expect(projection.providerTasks.allSatisfy { !$0.title.contains(forbidden) })
    }

    @Test("Host task freshness is projected independently of account observation time")
    func projectsAuthoritativeFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_789_500_000)
        let freshness = ProviderActivityFreshness.unavailable(
            since: now, lastSuccessfulAt: now.addingTimeInterval(-60)
        )
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero,
            draft: .init(revision: .zero, text: "", projectIDs: [], agentTargets: [], groupID: nil),
            lab: .empty, runs: [], approvals: [], resources: [], codexTasks: [], account: nil,
            providerAccounts: [.init(providerID: .codex, connectionState: .connected(version: "test"), observedAt: now)],
            providerActivityFreshness: [.codex: freshness],
            health: .init(checks: []), generatedAt: now.addingTimeInterval(120)
        )
        let encoded = try JSONEncoder().encode(projection)
        let restored = try JSONDecoder().decode(DashboardProjection.self, from: encoded)
        #expect(restored.providerAccounts.first?.activityFreshness == freshness)
    }

    @Test("Older account projections decode without task freshness metadata")
    func acceptsLegacyAccountProjection() throws {
        let account = GADProviderAccountProjection(
            providerID: .codex, connectionState: .connected(version: "test"), planName: nil,
            selectedModel: nil, availableModels: [], usage: [], observedAt: .distantPast
        )
        let encoded = try JSONEncoder().encode(account)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["activityFreshness"] == nil)
        #expect(try JSONDecoder().decode(GADProviderAccountProjection.self, from: encoded).activityFreshness == nil)
        #expect(try JSONDecoder().decode(GADProviderAccountProjection.self, from: encoded).credentialConfigured == nil)
    }

    @Test("Saved credential presence is projected independently of connection failure", arguments: [true, false])
    func projectsCredentialPresence(configured: Bool) throws {
        let now = Date.now
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero, lab: .empty, runs: [], approvals: [], resources: [], codexTasks: [], account: nil,
            providerAccounts: [AgentProviderID.claude, .githubCopilot].map {
                .init(providerID: $0, connectionState: .failed(message: "Offline"), observedAt: now)
            },
            providerCredentialConfigured: [.claude: configured, .githubCopilot: configured],
            health: .init(checks: []), generatedAt: now
        )
        let restored = try JSONDecoder().decode(DashboardProjection.self, from: JSONEncoder().encode(projection))
        #expect(restored.providerAccounts.count == 2)
        #expect(restored.providerAccounts.allSatisfy { $0.credentialConfigured == configured })
    }
}
