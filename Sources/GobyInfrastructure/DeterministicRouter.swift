import Foundation
import GobyApplication
import GobyDomain

public struct DeterministicRouter: Routing {
    public init() {}

    public func plan(for request: RouteRequest, in lab: LabSnapshot) async throws -> RoutingPlan {
        let planID = RunID.make()
        let normalized = request.prompt.lowercased()
        let capabilities = AgentRoutingMatcher.inferredCapabilities(from: normalized)
        let targetPlatforms = Set(capabilities.compactMap(projectPlatform))
        let mutatesCode = RouteMutationIntent.impliesMutation(normalized)
        let directTargets = request.agentTargets
        let requiresExactCoverage: Bool = if case .projects = request.scope { true } else { false }
        let explicitlyNamedProjectIDs = Set(
            explicitlyNamedProjects(in: normalized, projects: lab.projects).map(\.id)
        )
        let projects = scopedProjects(for: request, in: lab).filter { project in
            if !directTargets.isEmpty { return true }
            guard case .all = request.scope else { return true }
            if !explicitlyNamedProjectIDs.isEmpty {
                return explicitlyNamedProjectIDs.contains(project.id)
            }
            guard !targetPlatforms.isEmpty else { return true }
            return !project.platforms.isDisjoint(with: targetPlatforms)
        }

        var warnings: [String] = []
        var routes = try projects.compactMap { project -> ProjectRoute? in
            let requestedAgentIDs = Set(directTargets.compactMap { target in
                target.providerID == request.providerID && target.projectID == project.id
                    ? target.agentID
                    : nil
            })
            let eligible = AgentRoutingMatcher.eligibleAgents(
                for: project.id,
                providerID: request.providerID,
                in: lab,
                includingTemporary: requestedAgentIDs
            )

            if !requestedAgentIDs.isEmpty {
                let selected = eligible.filter { requestedAgentIDs.contains($0.id) }
                guard !selected.isEmpty else { return nil }
                if selected.count != requestedAgentIDs.count {
                    warnings.append(
                        "One or more map-selected agents are no longer available for \(project.name)."
                    )
                }
                let names = selected.map(\.name).joined(separator: ", ")
                let selectedIDs = selected.map(\.id)
                return ProjectRoute(
                    projectID: project.id,
                    providerID: request.providerID,
                    model: request.model,
                    agentIDs: selectedIDs,
                    providerBindings: try ProviderBindingResolver.routeBindings(
                        agentIDs: selectedIDs,
                        providerID: request.providerID,
                        projectID: project.id,
                        in: lab.providerBindings
                    ),
                    reason: "Directly assigned to \(names)."
                )
            }

            // Prefer agents that suit this request in this project; fall back to
            // any eligible agent only when exact coverage is not required.
            let suited = AgentRoutingMatcher.suitableAgents(eligible, for: project, required: capabilities)
            let onlyUnrelatedSpecialists = suited.isEmpty && !eligible.isEmpty
            let selected = minimalAgentSet(
                from: onlyUnrelatedSpecialists && !requiresExactCoverage ? eligible : suited,
                covering: capabilities
            )
            let uncovered = AgentRoutingMatcher.missingCapabilities(
                required: capabilities,
                among: selected
            )
            if requiresExactCoverage, !uncovered.isEmpty {
                throw GobyApplicationError.noAppropriateAgent(
                    projectID: project.id,
                    projectName: project.name,
                    providerID: request.providerID,
                    capabilities: uncovered
                )
            }
            guard !selected.isEmpty else {
                warnings.append("\(project.name) has no enabled agent authorized for this project.")
                return nil
            }
            if onlyUnrelatedSpecialists, uncovered.isEmpty {
                warnings.append(
                    "\(project.name) has only specialists; Goby assigned \(selected.map(\.name).joined(separator: ", ")) as a fallback. A temporary agent suits general requests better."
                )
            } else if !uncovered.isEmpty {
                warnings.append(
                    "\(project.name) has no exact specialist covering \(uncovered.map(\.displayName).sorted().joined(separator: ", ")); Goby selected an enabled fallback agent."
                )
            }
            let names = selected.map(\.name).joined(separator: ", ")
            let reason: String
            if uncovered.isEmpty {
                reason = "\(project.name) matches \(capabilities.map(\.displayName).sorted().joined(separator: ", ")); assigned \(names)."
            } else {
                reason = "No exact \(uncovered.map(\.displayName).sorted().joined(separator: ", ")) specialist is registered for \(project.name); assigned \(names) as the enabled fallback."
            }
            let selectedIDs = selected.map(\.id)
            return ProjectRoute(
                projectID: project.id,
                providerID: request.providerID,
                model: request.model,
                agentIDs: selectedIDs,
                providerBindings: try ProviderBindingResolver.routeBindings(
                    agentIDs: selectedIDs,
                    providerID: request.providerID,
                    projectID: project.id,
                    in: lab.providerBindings
                ),
                reason: reason
            )
        }

        let deliveryPipeline = directTargets.isEmpty
            ? try deliveryPipeline(
                prompt: normalized,
                mutatesCode: mutatesCode,
                routes: &routes,
                lab: lab,
                warnings: &warnings
            )
            : nil

        let projectByID = Dictionary(uniqueKeysWithValues: lab.projects.map { ($0.id, $0) })
        if mutatesCode, deliveryPipeline == nil, directTargets.isEmpty {
            routes = routes.map { singleOwnerRoute($0, lab: lab, projectByID: projectByID) }
        }
        if mutatesCode {
            for route in routes where projectByID[route.projectID]?.isGitRepository == false {
                let projectName = projectByID[route.projectID]?.name ?? "This project"
                warnings.append(
                    "\(projectName) is not a Git repository. Approved changes will be made in its registered folder without an isolated worktree or automatic rollback."
                )
            }
        }
        let commitsWorkingCopy = mutatesCode && RouteMutationIntent.isCommitOnly(normalized)
        let unsupportedGit = RouteMutationIntent.requestedUnsupportedGitOperations(normalized)
            .filter { !(commitsWorkingCopy && $0 == "push") }
        if mutatesCode, !unsupportedGit.isEmpty {
            warnings.append(
                "Goby commits in an isolated worktree and never \(unsupportedGit.joined(separator: ", ")) during a run. Review the result, then do that yourself."
            )
        }
        // A run that edits starts from the last commit, so "fix it and
        // commit" cannot reach edits that exist only in the user's folder.
        let requestWords = Set(normalized.lowercased().split { !$0.isLetter }.map(String.init))
        if mutatesCode, !commitsWorkingCopy, requestWords.contains("commit"),
           routes.contains(where: { projectByID[$0.projectID]?.isGitRepository == true }) {
            warnings.append(
                "Goby works in an isolated copy that starts from the last commit, so uncommitted changes in your project folder are not included and will not be committed. Commit those yourself."
            )
        }
        let requestsPush = RouteMutationIntent.requestsPush(normalized)
        let gitOperations = mutatesCode ? routes.filter { route in
            projectByID[route.projectID]?.isGitRepository == true
        }.flatMap { route -> [PlannedGitOperation] in
            if commitsWorkingCopy {
                // The host fills in the current branch and its remote before
                // the plan is shown.
                return [PlannedGitOperation(projectID: route.projectID, kind: .commit)]
                    + (requestsPush ? [PlannedGitOperation(projectID: route.projectID, kind: .push)] : [])
            }
            return [
                PlannedGitOperation(projectID: route.projectID, kind: .createWorktree),
                PlannedGitOperation(projectID: route.projectID, kind: .createBranch, branch: "codex/goby-\(planID.rawValue.prefix(12))"),
                PlannedGitOperation(projectID: route.projectID, kind: .commit)
            ]
        } : []

        let risk: PlanRisk = mutatesCode ? (routes.count > 5 ? .high : .medium) : .readOnly
        let routedDirectAgentCount = routes.reduce(0) { $0 + $1.agentIDs.count }
        let directlyRoutedProjectIDs = Set(directTargets.map(\.projectID))
        let hasAutomaticallyRoutedProject = routes.contains { !directlyRoutedProjectIDs.contains($0.projectID) }
        let confidence = directTargets.isEmpty || hasAutomaticallyRoutedProject
            ? confidenceFor(routes: routes, capabilities: capabilities, warnings: warnings)
            : (routedDirectAgentCount == directTargets.count ? 1 : 0.2)
        return RoutingPlan(
            id: planID,
            interpretedGoal: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: request.attachments,
            routes: routes,
            risk: risk,
            confidence: confidence,
            gitOperations: gitOperations,
            warnings: warnings,
            deliveryPipeline: deliveryPipeline
        )
    }

    /// Adds an ordered stage chain when the request needs more than one
    /// responsibility. Stage owners join their project's route so review,
    /// binding validation, and snapshots cover every agent that will run.
    private func deliveryPipeline(
        prompt: String,
        mutatesCode: Bool,
        routes: inout [ProjectRoute],
        lab: LabSnapshot,
        warnings: inout [String]
    ) throws -> DeliveryPipeline? {
        let requested = DeliveryStageSelection.requestedKinds(for: prompt, mutatesCode: mutatesCode)
        var stages: [DeliveryStage] = []
        var revisedRoutes: [ProjectRoute] = []
        var stageWarnings: [String] = []
        var hasMultiStageProject = false
        for route in routes {
            let eligible = AgentRoutingMatcher.eligibleAgents(
                for: route.projectID,
                providerID: route.providerID,
                in: lab
            )
            guard let project = lab.projects.first(where: { $0.id == route.projectID }),
                  let primary = DeliveryStageSelection.implementationOwner(
                      routedAgentIDs: route.agentIDs,
                      among: eligible,
                      project: project
                  ) else { return nil }
            let projectName = project.name
            // A stage needs its own owner. Without a separate specialist the
            // Engineer covers it inside implementation, so labs without
            // specialists keep single-step execution.
            var kinds = requested
            var folded: [DeliveryStageKind] = []
            var owners: [DeliveryStageKind: AgentProfile] = [:]
            for kind in requested where kind != .implement {
                if let specialist = DeliveryStageSelection.owner(for: kind, among: eligible),
                   specialist.id != primary.id {
                    owners[kind] = specialist
                } else if requested.contains(.implement) {
                    folded.append(kind)
                }
            }
            kinds.removeAll(where: folded.contains)
            if kinds.contains(.release),
               kinds.allSatisfy({ !$0.isVerification }) {
                kinds.removeAll { $0 == .release }
                folded.append(.release)
            }
            if kinds.contains(.implement), !kinds.contains(.qualityAssurance),
               !primary.capabilities.isSubset(of: DeliveryStageSelection.stageOnlyCapabilities.union([.documentation, .design])),
               let tester = DeliveryStageSelection.owner(for: .qualityAssurance, among: eligible),
               tester.id != primary.id {
                owners[.qualityAssurance] = tester
                folded.removeAll { $0 == .qualityAssurance }
                kinds = DeliveryStageKind.allCases.filter { Set(kinds + [.qualityAssurance]).contains($0) }
            }
            // Every routed project must be covered by a stage, or staging would
            // silently drop its work; otherwise keep single-step execution.
            guard !kinds.isEmpty else { return nil }
            if kinds.count > 1 { hasMultiStageProject = true }
            var agentIDs: [AgentID] = []
            var stageNames: [String] = []
            for kind in kinds {
                let owner: AgentProfile
                let reason: String
                var passCriteria = DeliveryStageSelection.passCriteria(for: kind)
                if kind == .implement {
                    owner = primary
                    if folded.isEmpty {
                        reason = "\(owner.name) was routed to make the change in \(projectName)."
                    } else {
                        let names = folded.map(\.displayName).joined(separator: ", ")
                        reason = "\(owner.name) makes the change in \(projectName) and also covers \(names), because no separate specialist is registered."
                        passCriteria += " Also: " + folded.map(DeliveryStageSelection.passCriteria).joined(separator: " ")
                        stageWarnings.append(
                            "\(projectName) has no separate \(names) specialist; \(owner.name) covers it while making the change."
                        )
                    }
                } else if let specialist = owners[kind]
                    ?? (kind.requiredCapabilities.isSubset(of: primary.capabilities) ? primary : nil) {
                    owner = specialist
                    reason = "\(owner.name) covers \(kind.requiredCapabilities.map(\.displayName).sorted().joined(separator: ", ")) in \(projectName)."
                } else {
                    owner = primary
                    reason = "No \(kind.displayName) specialist is registered for \(projectName); \(owner.name) performs this stage."
                    stageWarnings.append(
                        "\(projectName) has no \(kind.displayName) specialist; \(owner.name) will perform that stage."
                    )
                }
                let binding = try ProviderBindingResolver.resolve(
                    agentID: owner.id,
                    providerID: route.providerID,
                    projectID: route.projectID,
                    bindingID: route.providerBindings.first { $0.agentID == owner.id }?.bindingID,
                    in: lab.providerBindings
                )
                stages.append(DeliveryStage(
                    kind: kind,
                    target: AgentHandoffEndpoint(
                        providerID: route.providerID,
                        bindingID: binding.id,
                        agentID: owner.id,
                        projectID: route.projectID
                    ),
                    reason: reason,
                    passCriteria: passCriteria
                ))
                if !agentIDs.contains(owner.id) { agentIDs.append(owner.id) }
                stageNames.append(kind.displayName)
            }
            revisedRoutes.append(ProjectRoute(
                projectID: route.projectID,
                providerID: route.providerID,
                model: route.model,
                agentIDs: agentIDs,
                providerBindings: try ProviderBindingResolver.routeBindings(
                    agentIDs: agentIDs,
                    providerID: route.providerID,
                    projectID: route.projectID,
                    in: lab.providerBindings
                ),
                reason: route.reason + " Stages: " + stageNames.joined(separator: " → ") + "."
            ))
        }
        guard hasMultiStageProject else { return nil }
        routes = revisedRoutes
        warnings.append(contentsOf: stageWarnings)
        let ordered = stages.enumerated().sorted { lhs, rhs in
            if lhs.element.kind.order != rhs.element.kind.order {
                return lhs.element.kind.order < rhs.element.kind.order
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return DeliveryPipeline(stages: ordered)
    }

    /// Without a staged pipeline every routed agent receives the whole
    /// request at once. For change-making work that duplicates effort and
    /// lets agents edit the same files, so one owner makes the change: a
    /// routed agent that builds for the project's platform, otherwise the
    /// project's best platform builder, otherwise the first routed agent.
    private func singleOwnerRoute(
        _ route: ProjectRoute,
        lab: LabSnapshot,
        projectByID: [ProjectID: LabProject]
    ) -> ProjectRoute {
        guard route.agentIDs.count > 1, let project = projectByID[route.projectID] else { return route }
        let eligible = AgentRoutingMatcher.eligibleAgents(
            for: route.projectID,
            providerID: route.providerID,
            in: lab
        )
        let routed = route.agentIDs.compactMap { id in eligible.first { $0.id == id } }
        let platform = Set(project.platforms.compactMap(AgentRoutingMatcher.platformCapability))
        let owner = routed.first { !$0.capabilities.isDisjoint(with: platform) }
            ?? DeliveryStageSelection.implementationOwner(routedAgentIDs: [], among: eligible, project: project)
            ?? routed.first
        guard let owner,
              let bindings = try? ProviderBindingResolver.routeBindings(
                  agentIDs: [owner.id],
                  providerID: route.providerID,
                  projectID: route.projectID,
                  in: lab.providerBindings
              ) else { return route }
        return ProjectRoute(
            projectID: route.projectID,
            providerID: route.providerID,
            model: route.model,
            agentIDs: [owner.id],
            providerBindings: bindings,
            reason: "\(owner.name) makes the change in \(project.name) as the single owner, so agents do not edit the same files in parallel."
        )
    }

    private func scopedProjects(for request: RouteRequest, in lab: LabSnapshot) -> [LabProject] {
        if case let .projects(ids) = request.scope {
            return lab.projects.filter { ids.contains($0.id) }
        }
        if !request.agentTargets.isEmpty {
            let projectIDs = Set(request.agentTargets.map(\.projectID))
            return lab.projects.filter { projectIDs.contains($0.id) }
        }
        return switch request.scope {
        case .all:
            lab.projects
        case let .platform(platform):
            lab.projects.filter { $0.platforms.contains(platform) }
        case let .projects(ids):
            lab.projects.filter { ids.contains($0.id) }
        }
    }

    private func projectPlatform(for capability: AgentCapability) -> ProjectPlatform? {
        switch capability {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .backend: .backend
        case .research: .research
        default: nil
        }
    }

    private func minimalAgentSet(from agents: [AgentProfile], covering capabilities: Set<AgentCapability>) -> [AgentProfile] {
        var uncovered = capabilities
        var remaining = agents
        var selected: [AgentProfile] = []

        while !uncovered.isEmpty {
            // Most coverage first, then the fewest unrequested capabilities (a
            // generalist over a specialist), then name, so ties never depend
            // on catalog order.
            let ranked = remaining.sorted { lhs, rhs in
                let lhsCover = lhs.capabilities.intersection(uncovered).count
                let rhsCover = rhs.capabilities.intersection(uncovered).count
                if lhsCover != rhsCover { return lhsCover > rhsCover }
                let lhsExtra = lhs.capabilities.subtracting(capabilities).count
                let rhsExtra = rhs.capabilities.subtracting(capabilities).count
                if lhsExtra != rhsExtra { return lhsExtra < rhsExtra }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            guard let best = ranked.first, !best.capabilities.intersection(uncovered).isEmpty else { break }
            selected.append(best)
            uncovered.subtract(best.capabilities)
            remaining.removeAll { $0.id == best.id }
        }

        if selected.isEmpty, let router = agents.first(where: { $0.capabilities.contains(.routing) }) ?? agents.first {
            selected = [router]
        }
        return selected
    }

    private func explicitlyNamedProjects(
        in prompt: String,
        projects: [LabProject]
    ) -> [LabProject] {
        let normalizedPrompt = " " + tokens(in: prompt).joined(separator: " ") + " "
        let genericNames: Set<String> = [
            "app", "application", "backend", "dashboard", "project", "site", "web", "website"
        ]
        return projects.filter { project in
            let nameTokens = tokens(in: project.name)
            guard !nameTokens.isEmpty else { return false }
            let normalizedName = nameTokens.joined(separator: " ")
            guard !genericNames.contains(normalizedName) else { return false }
            return normalizedPrompt.contains(" \(normalizedName) ")
        }
    }

    private func tokens(in value: String) -> [String] {
        value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func confidenceFor(routes: [ProjectRoute], capabilities: Set<AgentCapability>, warnings: [String]) -> Double {
        guard !routes.isEmpty else { return 0.2 }
        var value = capabilities == [.routing] ? 0.65 : 0.86
        value -= Double(warnings.count) * 0.08
        return min(max(value, 0), 1)
    }

}
