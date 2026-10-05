import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct ParallelRequestPolicyTests {
    private let projectID: ProjectID = "app"

    private func plan(_ goal: String, risk: PlanRisk, worktree: Bool = false) -> RoutingPlan {
        RoutingPlan(
            interpretedGoal: goal,
            routes: [ProjectRoute(projectID: projectID, agentIDs: ["agent"], reason: "Test")],
            risk: risk,
            confidence: 1,
            gitOperations: worktree ? [
                .init(projectID: projectID, kind: .createBranch, branch: "goby/x"),
                .init(projectID: projectID, kind: .createWorktree, branch: "goby/x"),
            ] : []
        )
    }

    @Test("Two writers in the same folder conflict")
    func sharedWorkingCopy() {
        let conflict = ParallelRequestPolicy.conflict(
            later: plan("Redesign settings", risk: .low), earlier: plan("Fix checkout", risk: .medium), in: projectID
        )
        #expect(conflict?.kind == .sharedWorkingCopy)
    }

    @Test("Writers in separate worktrees run in parallel unless they name the same file")
    func isolatedWorktrees() {
        #expect(ParallelRequestPolicy.conflict(
            later: plan("Redesign settings", risk: .low, worktree: true),
            earlier: plan("Fix checkout", risk: .low, worktree: true), in: projectID
        ) == nil)
        let conflict = ParallelRequestPolicy.conflict(
            later: plan("Rename the button in Sources/App/Settings.swift", risk: .low, worktree: true),
            earlier: plan("Fix layout in `Sources/App/Settings.swift`.", risk: .low, worktree: true), in: projectID
        )
        #expect(conflict?.kind == .sameFiles(["sources/app/settings.swift"]))
        #expect(conflict?.reason.contains("sources/app/settings.swift") == true)
    }

    @Test("Read-only requests never block or wait for file reasons")
    func readOnly() {
        #expect(ParallelRequestPolicy.conflict(
            later: plan("Explain README.md", risk: .readOnly), earlier: plan("Edit README.md", risk: .low), in: projectID
        ) == nil)
    }

    @Test("A request that builds on the running one waits for it")
    func buildsOn() {
        let conflict = ParallelRequestPolicy.conflict(
            later: plan("After that, add tests for it", risk: .readOnly),
            earlier: plan("Fix checkout", risk: .low, worktree: true), in: projectID
        )
        #expect(conflict?.kind == .buildsOnEarlierRequest)
    }

    @Test("Different projects never conflict")
    func otherProject() {
        let other = RoutingPlan(interpretedGoal: "Fix checkout",
                                routes: [ProjectRoute(projectID: "web", agentIDs: ["agent"], reason: "Test")],
                                risk: .low, confidence: 1)
        #expect(ParallelRequestPolicy.conflict(later: plan("Fix", risk: .low), earlier: other, in: projectID) == nil)
    }

    @Test("Only real file names and paths count as mentioned files")
    func fileMentions() {
        let files = ParallelRequestPolicy.mentionedFiles(
            in: "Update README.md and src/checkout/, e.g. the .env file, not v1.2 or https://example.com/a.html. Done."
        )
        #expect(files == ["readme.md", "src/checkout/", ".env"])
    }

    @Test("A parallel copy keeps the busy agent's role and instructions")
    func parallelCopy() async throws {
        let project = LabProject(id: projectID, name: "App", rootURL: FileManager.default.temporaryDirectory,
                                 platforms: [.web], isGitRepository: false)
        let original = AgentProfile(id: "web", name: "Web Agent", summary: "Web work",
                                    instructions: "Use the design system.", capabilities: [.web], scope: .project(projectID))
        let directory = FileManager.default.temporaryDirectory.appending(path: "parallel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(directoryURL: directory)
        try await store.register(projects: [project], agents: [original])
        let copy = try await CreateTemporaryAgentUseCase(catalog: store, agents: store, providers: store)(
            id: "temporary-agent-copy", projectID: projectID, providerID: .codex,
            task: "Add a pricing page", basedOn: original.id
        )
        #expect(copy.name == "Web Agent · parallel")
        #expect(copy.capabilities == original.capabilities)
        #expect(copy.instructions?.contains("Use the design system.") == true)
        #expect(copy.instructions?.contains("Add a pricing page") == true)
        #expect(copy.isTemporary)
    }
}
