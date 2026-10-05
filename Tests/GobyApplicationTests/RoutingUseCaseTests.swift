import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

struct RoutingUseCaseTests {
    @Test("Direct assignment eligibility requires the exact configured provider binding")
    func directAssignmentEligibilityUsesExactBinding() {
        let target = AgentRouteTarget(
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id
        )
        let configured = ProviderAgentBinding(
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let unavailable = ProviderAgentBinding(
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "web-agent",
            capabilities: Fixtures.webAgent.capabilities,
            state: .unavailable
        )

        #expect(AgentRoutingMatcher.isEligible(target, in: LabSnapshot(
            projects: [Fixtures.webProject],
            agents: [Fixtures.webAgent],
            providerBindings: [configured]
        )))
        #expect(!AgentRoutingMatcher.isEligible(target, in: LabSnapshot(
            projects: [Fixtures.webProject],
            agents: [Fixtures.webAgent],
            providerBindings: [unavailable]
        )))
        #expect(!AgentRoutingMatcher.isEligible(target, in: LabSnapshot(
            projects: [Fixtures.webProject],
            agents: [Fixtures.webAgent],
            providerBindings: []
        )))
    }

    @Test("macOS prompts infer desktop capability without being relabeled as iOS")
    func infersMacOSCapability() {
        let capabilities = AgentRoutingMatcher.inferredCapabilities(
            from: "Fix the macOS AppKit window"
        )

        #expect(capabilities.contains(.macOS))
        #expect(!capabilities.contains(.iOS))
    }

    @Test("Unregistered project IDs are rejected")
    func rejectsUnknownProject() async throws {
        let catalog = CatalogStub(snapshot: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]))
        let router = RouterStub(plan: RoutingPlan(
            interpretedGoal: "Update sites",
            routes: [ProjectRoute(projectID: "missing", agentIDs: [Fixtures.webAgent.id], reason: "test")],
            risk: .readOnly,
            confidence: 1
        ))
        let useCase = PrepareRoutingPlanUseCase(catalog: catalog, router: router)

        await #expect(throws: GobyApplicationError.unknownProject("missing")) {
            _ = try await useCase(RouteRequest(prompt: "Update sites"))
        }
    }

    @Test("Project-scoped agents cannot be routed into another project")
    func rejectsAgentOutsideProject() async throws {
        let otherProject = LabProject(
            id: "other-project",
            name: "Other",
            rootURL: URL(fileURLWithPath: "/tmp/other"),
            platforms: [.web],
            isGitRepository: true
        )
        let catalog = CatalogStub(
            snapshot: LabSnapshot(
                projects: [Fixtures.webProject, otherProject],
                agents: [Fixtures.webAgent]
            )
        )
        let router = RouterStub(plan: RoutingPlan(
            interpretedGoal: "Update other site",
            routes: [
                ProjectRoute(
                    projectID: otherProject.id,
                    agentIDs: [Fixtures.webAgent.id],
                    reason: "test"
                )
            ],
            risk: .readOnly,
            confidence: 1
        ))

        await #expect(throws: GobyApplicationError.agentOutsideProject(Fixtures.webAgent.id, otherProject.id)) {
            _ = try await PrepareRoutingPlanUseCase(catalog: catalog, router: router)(
                RouteRequest(prompt: "Update other site")
            )
        }
    }

    @Test("Empty prompts fail before routing")
    func rejectsEmptyPrompt() async {
        let useCase = PrepareRoutingPlanUseCase(
            catalog: CatalogStub(snapshot: .empty),
            router: RouterStub(plan: RoutingPlan(interpretedGoal: "", routes: [], risk: .readOnly, confidence: 0))
        )
        await #expect(throws: GobyApplicationError.emptyPrompt) {
            _ = try await useCase(RouteRequest(prompt: "   "))
        }
    }

    @Test("A request cannot mix direct targets from another provider plane")
    func rejectsMixedProviderTargets() async throws {
        let claudeBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let catalog = CatalogStub(snapshot: LabSnapshot(
            projects: [Fixtures.webProject],
            agents: [Fixtures.webAgent],
            providerBindings: [claudeBinding]
        ))
        let useCase = PrepareRoutingPlanUseCase(
            catalog: catalog,
            router: RouterStub(plan: RoutingPlan(
                interpretedGoal: "Inspect",
                routes: [],
                risk: .readOnly,
                confidence: 1
            ))
        )

        await #expect(throws: GobyApplicationError.providerRouteMismatch(
            expected: .claude,
            actual: .codex
        )) {
            _ = try await useCase(RouteRequest(
                prompt: "Inspect",
                providerID: .claude,
                agentTarget: AgentRouteTarget(
                    providerID: .codex,
                    agentID: Fixtures.webAgent.id,
                    projectID: Fixtures.webProject.id
                )
            ))
        }
    }

    @Test("A direct target requires an exact configured provider binding")
    func rejectsMissingProviderBinding() async throws {
        let catalog = CatalogStub(snapshot: LabSnapshot(
            projects: [Fixtures.webProject],
            agents: [Fixtures.webAgent]
        ))
        let useCase = PrepareRoutingPlanUseCase(
            catalog: catalog,
            router: RouterStub(plan: RoutingPlan(
                interpretedGoal: "Inspect",
                routes: [],
                risk: .readOnly,
                confidence: 1
            ))
        )

        await #expect(throws: GobyApplicationError.missingProviderBinding(
            agentID: Fixtures.webAgent.id,
            providerID: .claude,
            projectID: Fixtures.webProject.id
        )) {
            _ = try await useCase(RouteRequest(
                prompt: "Inspect",
                providerID: .claude,
                agentTarget: AgentRouteTarget(
                    providerID: .claude,
                    agentID: Fixtures.webAgent.id,
                    projectID: Fixtures.webProject.id
                )
            ))
        }
    }

    @Test("Recovery pauses interrupted work without replaying it")
    func recoveryPausesRunningAssignments() async throws {
        let plan = RoutingPlan(
            id: "run",
            interpretedGoal: "Task",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "assignment",
            runID: plan.id,
            projectID: "project",
            agentID: "agent",
            status: .working,
            currentTask: "Working"
        )
        let repository = RecoveryRunRepository(records: [
            RunRecord(id: plan.id, plan: plan, status: .running, assignments: [assignment])
        ])

        let recovered = try await RecoverInterruptedRunsUseCase(runs: repository)()
        #expect(recovered.first?.status == .needsAttention)
        #expect(recovered.first?.assignments.first?.status == .paused)
        #expect(await repository.records.first?.status == .needsAttention)
    }

    @Test("Recovery reconciles an orphaned approval inside a needs-attention run")
    func recoveryPausesNeedsAttentionApproval() async throws {
        let plan = RoutingPlan(
            id: "approval-run",
            interpretedGoal: "Task",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let assignment = AgentAssignment(
            id: "approval-assignment",
            runID: plan.id,
            projectID: "project",
            agentID: "agent",
            status: .waitingForApproval,
            currentTask: "Waiting for approval",
            providerID: .codex,
            providerTaskID: "prior-provider-task"
        )
        let repository = RecoveryRunRepository(records: [
            RunRecord(
                id: plan.id,
                plan: plan,
                status: .needsAttention,
                assignments: [assignment]
            ),
        ])

        let recovered = try await RecoverInterruptedRunsUseCase(runs: repository)()

        #expect(recovered.count == 1)
        #expect(recovered.first?.assignments.first?.status == .paused)
        #expect(await repository.records.first?.assignments.first?.status == .paused)
    }

    @Test("Staging revalidates catalog changes made after planning", arguments: ["removed project", "removed agent", "disabled agent", "moved agent"])
    func stagingRejectsChangedCatalog(change: String) async throws {
        let original = LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent])
        let agent = AgentProfile(
            id: Fixtures.webAgent.id, name: "Web Agent", summary: "Updates websites",
            capabilities: [.web],
            scope: .project(change == "moved agent" ? "other-project" : Fixtures.webProject.id),
            isEnabled: change != "disabled agent"
        )
        let repository = StagingRepository(
            lab: LabSnapshot(
                projects: change == "removed project" ? [] : original.projects,
                agents: change == "removed agent" ? [] : [agent],
                providerBindings: original.providerBindings
            ),
            instructions: [], resources: []
        )
        let plan = RoutingPlan(
            interpretedGoal: "Review the website",
            routes: [.init(projectID: Fixtures.webProject.id, agentIDs: [Fixtures.webAgent.id], reason: "Reviewed scope")],
            risk: .readOnly, confidence: 1
        )
        let expected: GobyApplicationError = switch change {
        case "removed project": .unknownProject(Fixtures.webProject.id)
        case "removed agent": .unknownAgent(Fixtures.webAgent.id)
        case "disabled agent": .agentUnavailable(Fixtures.webAgent.id)
        default: .agentOutsideProject(Fixtures.webAgent.id, Fixtures.webProject.id)
        }
        await #expect(throws: expected) {
            try await StageRunUseCase(
                repository: repository, catalog: repository,
                instructions: repository, resources: repository, approvals: AllowingApproval()
            )(plan: plan, receipt: nil)
        }
        #expect(await repository.records.isEmpty)
    }

    @Test("Planning and staging reject scopes that cannot produce distinct work", arguments: ["no routes", "empty route", "duplicate agent", "duplicate route"])
    func rejectsNonExecutableScopes(shape: String) async throws {
        let repository = StagingRepository(
            lab: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]),
            instructions: [], resources: []
        )
        let route = ProjectRoute(
            projectID: Fixtures.webProject.id,
            agentIDs: shape == "empty route" ? [] : (
                shape == "duplicate agent" ? [Fixtures.webAgent.id, Fixtures.webAgent.id] : [Fixtures.webAgent.id]
            ),
            reason: "Reviewed scope"
        )
        let plan = RoutingPlan(
            interpretedGoal: "Review the website",
            routes: shape == "no routes" ? [] : (shape == "duplicate route" ? [route, route] : [route]),
            risk: .readOnly, confidence: 1
        )
        let expected: GobyApplicationError = shape.hasPrefix("duplicate") ? .incompleteApproval : .noRoute
        await #expect(throws: expected) {
            try await StageRunUseCase(
                repository: repository, catalog: repository, instructions: repository,
                resources: repository, approvals: AllowingApproval()
            )(plan: plan, receipt: nil)
        }
        #expect(await repository.records.isEmpty)
        await #expect(throws: expected) {
            try await PrepareRoutingPlanUseCase(catalog: repository, router: RouterStub(plan: plan))(
                RouteRequest(prompt: "Review the website")
            )
        }
    }

    @Test("Staging snapshots agents, enabled instructions, explicitly selected resources, and approval")
    func stagingSnapshotsExecutionContext() async throws {
        let disabledPack = InstructionPack(name: "Old", body: "Ignore", scope: .allProjects, isEnabled: false)
        let enabledPack = InstructionPack(name: "Current", body: "Use preferred sources", scope: .platform(.web))
        let unrelatedPack = InstructionPack(name: "iOS only", body: "Use SwiftUI", scope: .platform(.iOS))
        let resource = SharedResource(name: "Research", url: FileManager.default.temporaryDirectory)
        let repository = StagingRepository(
            lab: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]),
            instructions: [disabledPack, enabledPack, unrelatedPack],
            resources: [resource]
        )
        let attachment = PromptAttachment(
            kind: .image,
            displayName: "reference.png",
            source: .localFile(URL(fileURLWithPath: "/tmp/reference.png"))
        )
        let plan = RoutingPlan(
            id: "snapshot-run",
            interpretedGoal: "Update site",
            attachments: [attachment],
            routes: [ProjectRoute(projectID: Fixtures.webProject.id, agentIDs: [Fixtures.webAgent.id], reason: "Web match")],
            risk: .readOnly,
            confidence: 1
        )
        let run = try await StageRunUseCase(
            repository: repository,
            catalog: repository,
            instructions: repository,
            resources: repository,
            approvals: AllowingApproval()
        )(plan: plan, receipt: nil, selectedResourceIDs: [resource.id])

        #expect(run.agentSnapshot == [Fixtures.webAgent])
        #expect(run.instructionSnapshot == [enabledPack])
        #expect(run.resourceSnapshot == [resource])
        #expect(run.assignments.first?.attachments == [attachment])
        #expect(run.journal.first?.kind == .created)
        #expect(await repository.records.first?.id == run.id)
    }

    @Test("Shared iOS guidance reaches every assigned role across providers", arguments: AgentProviderID.builtIn)
    func stagingSharedIOSInstructions(provider: AgentProviderID) async throws {
        let project = LabProject(
            id: "ios-guidance-project",
            name: "New iOS project",
            rootURL: FileManager.default.temporaryDirectory,
            platforms: [.iOS, .macOS],
            isGitRepository: false
        )
        let agents = [AgentCapability.iOS, .review].map { capability in
            AgentProfile(
                id: .make(),
                name: capability.displayName,
                summary: "Work on the mobile app",
                capabilities: [capability],
                scope: .project(project.id)
            )
        }
        let shared = InstructionPack(name: "Shared standards", body: "Report verification.", scope: .allProjects)
        let device = InstructionPack(name: "Device guidance", body: "Follow the supplied device layout requirements.", scope: .platform(.iOS), version: 3)
        let excluded = [
            InstructionPack(name: "Web", body: "Web only", scope: .platform(.web)),
            InstructionPack(name: "Other project", body: "Other only", scope: .projects([Fixtures.webProject.id])),
            InstructionPack(name: "Disabled", body: "Do not include", scope: .platform(.iOS), isEnabled: false)
        ]
        let repository = StagingRepository(
            lab: LabSnapshot(
                projects: [project],
                agents: agents,
                providerBindings: agents.map {
                    ProviderAgentBinding(providerID: provider, agentID: $0.id, projectID: project.id, nativeID: $0.name, capabilities: $0.capabilities)
                }
            ),
            instructions: [shared, device] + excluded,
            resources: []
        )
        let plan = RoutingPlan(
            interpretedGoal: "Review the mobile layout",
            routes: [ProjectRoute(projectID: project.id, providerID: provider, agentIDs: agents.map(\.id), reason: "iOS guidance")],
            risk: .readOnly,
            confidence: 1
        )
        let run = try await StageRunUseCase(
            repository: repository, catalog: repository, instructions: repository,
            resources: repository, approvals: AllowingApproval()
        )(plan: plan, receipt: nil)

        #expect(run.assignments.count == 2)
        #expect(run.assignments.allSatisfy { $0.providerID == provider })
        #expect(run.instructionSnapshot == [shared, device])
    }

    @Test("Staging does not disclose enabled resources that were not selected for the run")
    func stagingExcludesUnselectedResources() async throws {
        let resource = SharedResource(name: "Private Research", url: URL(fileURLWithPath: "/tmp/private-research"))
        let repository = StagingRepository(
            lab: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]),
            instructions: [],
            resources: [resource]
        )
        let plan = RoutingPlan(
            id: "least-privilege-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(projectID: Fixtures.webProject.id, agentIDs: [Fixtures.webAgent.id], reason: "Web match")],
            risk: .readOnly,
            confidence: 1
        )

        let run = try await StageRunUseCase(
            repository: repository,
            catalog: repository,
            instructions: repository,
            resources: repository,
            approvals: AllowingApproval()
        )(plan: plan, receipt: nil)

        #expect(run.resourceSnapshot.isEmpty)
    }

    @Test("Staging fails closed when a reviewed resource is no longer enabled")
    func stagingRejectsDisabledSelectedResource() async throws {
        let resource = SharedResource(
            id: "disabled-resource",
            name: "Private Research",
            url: URL(fileURLWithPath: "/tmp/private-research"),
            isEnabled: false
        )
        let repository = StagingRepository(
            lab: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]),
            instructions: [],
            resources: [resource]
        )
        let plan = RoutingPlan(
            id: "stale-resource-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(
                projectID: Fixtures.webProject.id,
                agentIDs: [Fixtures.webAgent.id],
                reason: "Web match"
            )],
            risk: .readOnly,
            confidence: 1
        )

        await #expect(throws: GobyApplicationError.sharedResourceUnavailable(resource.id)) {
            try await StageRunUseCase(
                repository: repository,
                catalog: repository,
                instructions: repository,
                resources: repository,
                approvals: AllowingApproval()
            )(plan: plan, receipt: nil, selectedResourceIDs: [resource.id])
        }
    }

    @Test("Staging fails closed when a reviewed resource was removed")
    func stagingRejectsRemovedSelectedResource() async throws {
        let repository = StagingRepository(
            lab: LabSnapshot(projects: [Fixtures.webProject], agents: [Fixtures.webAgent]),
            instructions: [],
            resources: []
        )
        let plan = RoutingPlan(
            id: "removed-resource-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(
                projectID: Fixtures.webProject.id,
                agentIDs: [Fixtures.webAgent.id],
                reason: "Web match"
            )],
            risk: .readOnly,
            confidence: 1
        )

        await #expect(throws: GobyApplicationError.unknownSharedResource("removed-resource")) {
            try await StageRunUseCase(
                repository: repository,
                catalog: repository,
                instructions: repository,
                resources: repository,
                approvals: AllowingApproval()
            )(
                plan: plan,
                receipt: nil,
                selectedResourceIDs: ["removed-resource"]
            )
        }
    }

    @Test("Staging preserves the provider selected by each route")
    func stagingPreservesRouteProvider() async throws {
        let claudeBinding = ProviderAgentBinding(
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let repository = StagingRepository(
            lab: LabSnapshot(
                projects: [Fixtures.webProject],
                agents: [Fixtures.webAgent],
                providerBindings: [claudeBinding]
            ),
            instructions: [],
            resources: []
        )
        let plan = RoutingPlan(
            id: "claude-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(
                projectID: Fixtures.webProject.id,
                providerID: .claude,
                model: "claude-sonnet-4-5",
                agentIDs: [Fixtures.webAgent.id],
                reason: "Claude selected"
            )],
            risk: .readOnly,
            confidence: 1
        )

        let run = try await StageRunUseCase(
            repository: repository,
            catalog: repository,
            instructions: repository,
            resources: repository,
            approvals: AllowingApproval()
        )(plan: plan, receipt: nil)

        #expect(run.assignments.first?.providerID == .claude)
        #expect(run.assignments.first?.model == "claude-sonnet-4-5")
        #expect(run.providerBindingSnapshot == [claudeBinding])
    }

    @Test("Staging preserves one reviewed binding when global and project bindings overlap")
    func stagingPreservesExactProviderBinding() async throws {
        let global = ProviderAgentBinding(
            id: "claude-global",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: nil,
            nativeID: "global-web-agent",
            capabilities: Fixtures.webAgent.capabilities,
            instructionsOverride: "Global instructions"
        )
        let project = ProviderAgentBinding(
            id: "claude-project",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "project-web-agent",
            capabilities: Fixtures.webAgent.capabilities,
            instructionsOverride: "Project instructions"
        )
        let repository = StagingRepository(
            lab: LabSnapshot(
                projects: [Fixtures.webProject],
                agents: [Fixtures.webAgent],
                providerBindings: [global, project]
            ),
            instructions: [],
            resources: []
        )
        let plan = RoutingPlan(
            id: "exact-binding-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(
                projectID: Fixtures.webProject.id,
                providerID: .claude,
                agentIDs: [Fixtures.webAgent.id],
                providerBindings: [ProviderRouteBinding(
                    agentID: Fixtures.webAgent.id,
                    bindingID: project.id
                )],
                reason: "Project binding reviewed"
            )],
            risk: .readOnly,
            confidence: 1
        )

        let run = try await StageRunUseCase(
            repository: repository,
            catalog: repository,
            instructions: repository,
            resources: repository,
            approvals: AllowingApproval()
        )(plan: plan, receipt: nil)

        #expect(run.assignments.first?.providerBindingID == project.id)
        #expect(run.providerBindingSnapshot == [project])
    }

    @Test("Legacy routes fail closed when more than one provider binding is eligible")
    func stagingRejectsAmbiguousLegacyProviderBinding() async throws {
        let global = ProviderAgentBinding(
            id: "claude-global",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: nil,
            nativeID: "global-web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let project = ProviderAgentBinding(
            id: "claude-project",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "project-web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let repository = StagingRepository(
            lab: LabSnapshot(
                projects: [Fixtures.webProject],
                agents: [Fixtures.webAgent],
                providerBindings: [project, global]
            ),
            instructions: [],
            resources: []
        )
        let plan = RoutingPlan(
            id: "ambiguous-legacy-run",
            interpretedGoal: "Inspect the website",
            routes: [ProjectRoute(
                projectID: Fixtures.webProject.id,
                providerID: .claude,
                agentIDs: [Fixtures.webAgent.id],
                reason: "Legacy route without exact binding"
            )],
            risk: .readOnly,
            confidence: 1
        )

        await #expect(throws: GobyApplicationError.ambiguousProviderBinding(
            agentID: Fixtures.webAgent.id,
            providerID: .claude,
            projectID: Fixtures.webProject.id
        )) {
            try await StageRunUseCase(
                repository: repository,
                catalog: repository,
                instructions: repository,
                resources: repository,
                approvals: AllowingApproval()
            )(plan: plan, receipt: nil)
        }
    }

    @Test("Exact provider binding resolution is independent of catalog order")
    func exactBindingResolutionIgnoresCatalogOrder() throws {
        let global = ProviderAgentBinding(
            id: "claude-global",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: nil,
            nativeID: "global-web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )
        let project = ProviderAgentBinding(
            id: "claude-project",
            providerID: .claude,
            agentID: Fixtures.webAgent.id,
            projectID: Fixtures.webProject.id,
            nativeID: "project-web-agent",
            capabilities: Fixtures.webAgent.capabilities
        )

        for bindings in [[global, project], [project, global]] {
            let resolved = try ProviderBindingResolver.resolve(
                agentID: Fixtures.webAgent.id,
                providerID: .claude,
                projectID: Fixtures.webProject.id,
                bindingID: project.id,
                in: bindings
            )
            #expect(resolved == project)
        }
    }
}

private actor CatalogStub: LabCatalogRepository {
    let value: LabSnapshot
    init(snapshot: LabSnapshot) { value = snapshot }
    func snapshot() -> LabSnapshot { value }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
}

private struct RouterStub: Routing {
    let value: RoutingPlan
    init(plan: RoutingPlan) { value = plan }
    func plan(for request: RouteRequest, in lab: LabSnapshot) async throws -> RoutingPlan { value }
}

private enum Fixtures {
    static let webProject = LabProject(
        id: "web-project",
        name: "Website",
        rootURL: FileManager.default.temporaryDirectory,
        platforms: [.web],
        isGitRepository: true
    )
    static let webAgent = AgentProfile(
        id: "web-agent",
        name: "Web Agent",
        summary: "Updates websites",
        capabilities: [.web],
        scope: .project(webProject.id)
    )
}

private actor RecoveryRunRepository: RunRepository {
    var records: [RunRecord]
    init(records: [RunRecord]) { self.records = records }
    func allRuns() -> [RunRecord] { records }
    func save(_ run: RunRecord) {
        records.removeAll { $0.id == run.id }
        records.append(run)
    }
}

private actor StagingRepository: LabCatalogRepository, RunRepository, InstructionRepository, SharedResourceRepository {
    let lab: LabSnapshot
    let instructions: [InstructionPack]
    let resources: [SharedResource]
    var records: [RunRecord] = []

    init(lab: LabSnapshot, instructions: [InstructionPack], resources: [SharedResource]) {
        self.lab = lab
        self.instructions = instructions
        self.resources = resources
    }

    func snapshot() -> LabSnapshot { lab }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func allRuns() -> [RunRecord] { records }
    func save(_ run: RunRecord) { records = [run] }
    func allInstructionPacks() -> [InstructionPack] { instructions }
    func save(_ pack: InstructionPack) {}
    func allResources() -> [SharedResource] { resources }
    func saveResource(_ resource: SharedResource) {}
    func setResourceEnabled(id: SharedResourceID, enabled: Bool) {}
}

private struct AllowingApproval: ApprovalChecking {
    func validate(plan: RoutingPlan, receipt: ApprovalReceipt?) async throws {}
}
