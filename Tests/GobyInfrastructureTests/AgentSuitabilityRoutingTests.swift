import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

/// Regression tests for September 2026 misroutes: a growth plan and UI fixes
/// were assigned to Android specialists because generic requests tied on the
/// neutral `routing` capability and catalog order broke the tie.
struct AgentSuitabilityRoutingTests {
    private func project(_ id: String, _ platforms: Set<ProjectPlatform>) -> LabProject {
        LabProject(
            id: ProjectID(rawValue: id), name: id.capitalized,
            rootURL: FileManager.default.temporaryDirectory.appending(path: id),
            platforms: platforms, isGitRepository: false
        )
    }

    private func agent(_ id: String, _ name: String, _ capabilities: Set<AgentCapability>, in project: LabProject) -> AgentProfile {
        AgentProfile(id: AgentID(rawValue: id), name: name, summary: name, capabilities: capabilities, scope: .project(project.id))
    }

    private let growthPlan = "the analytics are terrible. make a plan to gain more users"

    @Test("A general request in a multi-platform project with only specialists asks for a suitable agent")
    func generalRequestNeedsSuitableAgent() async throws {
        let pharmacies = project("pharmacies", [.android, .iOS, .web, .backend])
        let lab = LabSnapshot(projects: [pharmacies], agents: [
            agent("android", "Android Agent", [.android, .routing], in: pharmacies),
            agent("ios", "iOS Agent", [.iOS, .routing], in: pharmacies),
            agent("web", "Web Agent", [.web, .routing], in: pharmacies),
        ])
        await #expect(throws: GobyApplicationError.self) {
            _ = try await DeterministicRouter().plan(
                for: RouteRequest(prompt: growthPlan, scope: .projects([pharmacies.id])), in: lab
            )
        }
        // Without an explicit project scope, Goby still routes, but says why.
        let fallback = try await DeterministicRouter().plan(for: RouteRequest(prompt: growthPlan), in: lab)
        #expect(fallback.warnings.contains { $0.contains("only specialists") })
    }

    @Test("A general-purpose agent wins over platform specialists")
    func generalistPreferred() async throws {
        let pharmacies = project("pharmacies", [.android, .iOS, .web])
        let lab = LabSnapshot(projects: [pharmacies], agents: [
            agent("android", "Android Agent", [.android, .routing], in: pharmacies),
            agent("project", "Project Agent", [.routing], in: pharmacies),
        ])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: growthPlan, scope: .projects([pharmacies.id])), in: lab
        )
        #expect(plan.routes.first?.agentIDs == ["project"])
    }

    @Test("A single-platform project uses its own platform specialist, never another platform's")
    func singlePlatformSpecialist() async throws {
        let dashboard = project("dashboard", [.macOS])
        let lab = LabSnapshot(projects: [dashboard], agents: [
            agent("android", "Automation Android Specialist", [.android], in: dashboard),
            agent("macos", "Automation macOS Specialist", [.macOS], in: dashboard),
        ])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "fix all loading indicators", scope: .all), in: lab
        )
        #expect(plan.routes.first?.agentIDs == ["macos"])
    }

    @Test("A change request matched to several specialists runs one owner, not parallel copies")
    func changeRequestHasSingleOwner() async throws {
        let dashboard = project("dashboard", [.macOS])
        let lab = LabSnapshot(projects: [dashboard], agents: [
            agent("docs", "Automation Documentation Specialist", [.documentation], in: dashboard),
            agent("testing", "Automation Testing Specialist", [.testing], in: dashboard),
            agent("macos", "Automation macOS Specialist", [.macOS], in: dashboard),
        ])
        let prompt = """
        Add a "Copy Branch Name" item to the project right-click menu, add Swift Testing tests \
        for it, run swift test, and add one line to the documentation describing the new action.
        """
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: prompt, scope: .projects([dashboard.id])), in: lab
        )
        if plan.deliveryPipeline == nil {
            #expect(plan.routes.first?.agentIDs == ["macos"])
        } else {
            // A staged plan runs its agents one after another, never in parallel.
            #expect(plan.deliveryPipeline?.stages.isEmpty == false)
        }
    }

    @Test("Git requests are change-making, and a push is never implied to happen")
    func gitRequestsAreChanges() async throws {
        #expect(RouteMutationIntent.impliesMutation("commit and push"))
        #expect(RouteMutationIntent.impliesMutation("rebase onto main and delete the old branch"))
        #expect(!RouteMutationIntent.impliesMutation("explain the release process"))
        #expect(!RouteMutationIntent.impliesMutation("what format does the config use?"))

        let siry = LabProject(
            id: "siry", name: "Siry", rootURL: FileManager.default.temporaryDirectory.appending(path: "siry"),
            platforms: [.iOS], isGitRepository: true
        )
        let lab = LabSnapshot(projects: [siry], agents: [
            agent("ios", "iOS Agent", [.iOS, .routing], in: siry),
        ])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "commit and push", scope: .projects([siry.id])), in: lab
        )
        #expect(plan.risk != .readOnly)
        // Commit-only: Goby commits the folder's changes and offers a push.
        #expect(plan.commitsWorkingCopy)
        #expect(!plan.warnings.contains { $0.contains("never push") })

        let editAndCommit = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "fix the login screen, commit and push", scope: .projects([siry.id])), in: lab
        )
        #expect(editAndCommit.warnings.contains { $0.contains("never push") })
        #expect(editAndCommit.warnings.contains { $0.contains("uncommitted changes in your project folder are not included") })

        let edit = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "fix the login screen", scope: .projects([siry.id])), in: lab
        )
        #expect(!edit.warnings.contains { $0.contains("uncommitted changes") })
    }

    @Test("A request that names a platform still goes to that specialist")
    func namedPlatformStillRoutes() async throws {
        let pharmacies = project("pharmacies", [.android, .iOS, .web])
        let lab = LabSnapshot(projects: [pharmacies], agents: [
            agent("android", "Android Agent", [.android, .routing], in: pharmacies),
            agent("ios", "iOS Agent", [.iOS, .routing], in: pharmacies),
        ])
        let plan = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "fix the crash in the iOS widget", scope: .projects([pharmacies.id])), in: lab
        )
        #expect(plan.routes.first?.agentIDs == ["ios"])
    }

    @Test("A general request skips functional specialists that it did not ask for")
    func functionalSpecialistsNeedTheirFunction() async throws {
        let dashboard = project("dashboard", [.macOS, .iOS, .android])
        let lab = LabSnapshot(projects: [dashboard], agents: [
            agent("testing", "Automation Testing Specialist", [.testing], in: dashboard),
            agent("docs", "Automation Documentation Specialist", [.documentation], in: dashboard),
            agent("macos", "Automation macOS Specialist", [.macOS], in: dashboard),
        ])
        await #expect(throws: GobyApplicationError.self) {
            _ = try await DeterministicRouter().plan(
                for: RouteRequest(prompt: "fix all loading indicators", scope: .projects([dashboard.id])), in: lab
            )
        }
        let docs = try await DeterministicRouter().plan(
            for: RouteRequest(prompt: "update the readme", scope: .projects([dashboard.id])), in: lab
        )
        #expect(docs.routes.first?.agentIDs == ["docs"])
    }
}
