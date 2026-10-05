import Foundation
import GobyApplication
import GobyDomain
import Testing

@Suite("Codex catalog review vault")
struct CodexCatalogReviewVaultTests {
    @Test("A paired device cannot use another device's discovery")
    func isolatesReviewsByDevice() async throws {
        let vault = GADCodexCatalogReviewVault()
        let owner = DeviceID(rawValue: "owner")
        let other = DeviceID(rawValue: "other")
        let plan = makePlan()
        await vault.issue(plan, deviceID: owner, expiresAt: Date(timeIntervalSince1970: 200))

        await #expect(throws: GADCommandFailure.self) {
            _ = try await vault.validate(
                projectIDs: [plan.projects[0].id],
                agentIDs: [],
                against: plan,
                registeredProjectIDs: [],
                deviceID: other,
                now: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test("Changed candidate content invalidates a reviewed selection")
    func rejectsChangedContent() async throws {
        let vault = GADCodexCatalogReviewVault()
        let device = DeviceID(rawValue: "phone")
        let reviewed = makePlan()
        let changedProject = LabProject(
            id: reviewed.projects[0].id,
            name: "Changed Name",
            rootURL: reviewed.projects[0].project.rootURL,
            platforms: [.iOS],
            isGitRepository: true
        )
        let current = CodexCatalogSyncPlan(
            projects: [ProjectCandidate(project: changedProject, evidence: ["changed"])],
            agents: reviewed.agents,
            scannedProjectCount: 1,
            scannedAgentCount: 1
        )
        await vault.issue(reviewed, deviceID: device, expiresAt: Date(timeIntervalSince1970: 200))

        await #expect(throws: GADCommandFailure.self) {
            _ = try await vault.validate(
                projectIDs: [reviewed.projects[0].id],
                agentIDs: [],
                against: current,
                registeredProjectIDs: [],
                deviceID: device,
                now: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test("An exact selection can be validated again for commit")
    func validatesPreviewAndCommit() async throws {
        let vault = GADCodexCatalogReviewVault()
        let device = DeviceID(rawValue: "phone")
        let plan = makePlan()
        await vault.issue(plan, deviceID: device, expiresAt: Date(timeIntervalSince1970: 200))

        for _ in 0..<2 {
            let selection = try await vault.validate(
                projectIDs: [plan.projects[0].id],
                agentIDs: [plan.agents.candidates[0].id],
                against: plan,
                registeredProjectIDs: [],
                deviceID: device,
                now: Date(timeIntervalSince1970: 100)
            )
            #expect(selection.projectIDs == [plan.projects[0].id])
            #expect(selection.agentIDs == [plan.agents.candidates[0].id])
        }
    }

    private func makePlan() -> CodexCatalogSyncPlan {
        let projectID = ProjectID(rawValue: "project")
        let project = LabProject(
            id: projectID,
            name: "Mobile App",
            rootURL: URL(fileURLWithPath: "/private/tmp/mobile-app", isDirectory: true),
            platforms: [.iOS],
            isGitRepository: true
        )
        let agent = AgentImportCandidate(
            profile: AgentProfile(
                id: AgentID(rawValue: "ios-agent"),
                name: "iOS Agent",
                summary: "Owns iOS work",
                capabilities: [.iOS],
                scope: .project(projectID)
            ),
            configurationPreview: "role = ios",
            evidence: ["inferred"]
        )
        return CodexCatalogSyncPlan(
            projects: [ProjectCandidate(project: project, evidence: ["inspected"])],
            agents: AgentImportPlan(candidates: [agent], suggestions: []),
            scannedProjectCount: 1,
            scannedAgentCount: 1
        )
    }
}
