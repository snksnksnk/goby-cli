import Foundation
import GobyDomain

public struct RemoteProjectionBuilder: Sendable {
    public init() {}

    public func build(
        host: GADHostProjection,
        revision: StateRevision,
        draft: GADDraftProjection = .init(),
        lab: LabSnapshot,
        runs: [RunRecord],
        automations: AutomationSnapshot = .empty,
        approvals: [ProviderApprovalRequest],
        resources: [SharedResource],
        instructions: [InstructionPack] = [],
        plan: RoutingPlan? = nil,
        planStartsWithoutReview: Bool = false,
        trustedProjectIDs: Set<ProjectID> = [],
        selectedResourceIDs: Set<SharedResourceID> = [],
        codexTasks: [CodexTaskActivity],
        account: CodexAccountSnapshot?,
        providerAccounts: [ProviderAccountSnapshot] = [],
        providerActivityFreshness: [AgentProviderID: ProviderActivityFreshness] = [:],
        providerCredentialConfigured: [AgentProviderID: Bool] = [:],
        providerTasks: [ProviderTaskActivity] = [],
        health: SystemHealthSnapshot,
        exactForbiddenValues: [String] = [],
        temporaryChat: TemporaryChat? = nil,
        generatedAt: Date
    ) -> DashboardProjection {
        let projectedAutomations = boundedAutomations(automations)
        let pendingAssignmentIDs = Set(approvals.map(\.assignmentID))
        var requiredRunIDs = Set(runs.filter { run in
            run.assignments.contains { pendingAssignmentIDs.contains($0.id) }
        }.map(\.id))
        requiredRunIDs.formUnion(projectedAutomations.occurrences.flatMap { $0.attempts.compactMap(\.runID) })
        for handoff in lab.handoffs where handoff.state != .completed && handoff.state != .cancelled {
            requiredRunIDs.insert(handoff.bundle.runID)
            if let destinationID = handoff.destinationRunID { requiredRunIDs.insert(destinationID) }
        }
        let projectedRuns = boundedRuns(runs, requiredRunIDs: requiredRunIDs)
        let redactor = ProjectionRedactor(forbiddenValues: forbiddenValues(
            lab: lab,
            runs: projectedRuns,
            resources: resources,
            plan: plan,
            account: account,
            exactForbiddenValues: exactForbiddenValues
        ))
        let runIDByAssignment = Dictionary(uniqueKeysWithValues: projectedRuns.flatMap { run in
            run.assignments.map { ($0.id, run.id) }
        })
        let providerIDsByProject = lab.projectProviderConfigurations.reduce(
            into: [ProjectID: Set<AgentProviderID>]()
        ) { result, configuration in
            result[configuration.projectID, default: []].formUnion(configuration.providerIDs)
        }
        let attributableProviderTasks = providerTasks + projectedRuns.flatMap(\.helperTasks)
        let providerTaskTargets = Set(attributableProviderTasks.map(\.providerID)).reduce(
            into: [ProviderTaskIdentity: AgentRouteTarget]()
        ) { targets, providerID in
            let reflection = MapActivityReflectionProjection(
                providerID: providerID,
                lab: lab,
                tasks: attributableProviderTasks
            )
            targets.merge(reflection.agentTargetsByTask) { current, _ in current }
        }
        let projectApprovalOrdinals = MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: lab.projects.map(\.id.rawValue)
        )
        let resourceApprovalOrdinals = MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: resources.map(\.id.rawValue)
        )

        let projection = DashboardProjection(
            revision: revision,
            generatedAt: generatedAt,
            host: GADHostProjection(
                id: host.id,
                displayName: host.displayName,
                reachability: host.reachability,
                lastUpdatedAt: host.lastUpdatedAt,
                omittedHistoryRunCount: host.omittedHistoryRunCount,
                omittedAutomationOccurrenceCount: host.omittedAutomationOccurrenceCount,
                temporaryChat: temporaryChat.map { chat in
                    GADTemporaryChatProjection(chat) { redactor.text($0, limit: $1) }
                } ?? host.temporaryChat
            ),
            draft: GADDraftProjection(
                revision: draft.revision,
                text: redactor.text(draft.text, limit: 32_000, preservePlanSlashCommand: true),
                attachments: draft.attachments.map {
                    GADDraftAttachmentProjection(
                        id: $0.id,
                        kind: $0.kind,
                        displayName: redactor.text($0.displayName, limit: 240),
                        byteCount: $0.byteCount,
                        typeHint: $0.typeHint.map { redactor.text($0, limit: 80) }
                    )
                },
                providerID: draft.providerID,
                model: draft.model.map { redactor.text($0, limit: 160) },
                platform: draft.platform,
                projectIDs: draft.projectIDs,
                agentTargets: draft.agentTargets,
                groupID: draft.groupID
            ),
            projects: lab.projects
                .map { project in
                    GADProjectProjection(
                        id: project.id,
                        name: redactor.text(project.name, limit: 160),
                        platforms: project.platforms.sorted { $0.rawValue < $1.rawValue },
                        frameworks: project.frameworks.map { redactor.text($0, limit: 120) },
                        isGitRepository: project.isGitRepository,
                        providerIDs: (providerIDsByProject[project.id] ?? [.codex]).sorted(),
                        template: project.template,
                        approvalOrdinal: projectApprovalOrdinals[project.id.rawValue],
                        isTrusted: trustedProjectIDs.contains(project.id)
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            agents: lab.agents
                .map { agent in
                    GADAgentProjection(
                        id: agent.id,
                        name: redactor.text(agent.name, limit: 160),
                        summary: redactor.text(agent.summary, limit: 600),
                        capabilities: agent.capabilities.sorted { $0.rawValue < $1.rawValue },
                        scope: scope(agent.scope),
                        isEnabled: agent.isEnabled,
                        isActiveInCodex: agent.codexRegistrationKey != nil,
                        hasDefinition: agent.sourceURL != nil
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            projectGroups: lab.projectGroups
                .map { group in
                    GADProjectGroupProjection(
                        id: group.id,
                        name: redactor.text(group.name, limit: 160),
                        members: group.members.sorted { $0.projectID.rawValue < $1.projectID.rawValue }
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            resources: resources
                .map { resource in
                    GADResourceProjection(
                        id: resource.id,
                        name: redactor.text(resource.name, limit: 160),
                        access: resource.access,
                        isEnabled: resource.isEnabled,
                        approvalOrdinal: resourceApprovalOrdinals[resource.id.rawValue]
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            instructions: instructions
                .map { pack in
                    GADInstructionProjection(
                        id: pack.id,
                        name: redactor.text(pack.name, limit: 160),
                        scope: pack.scope,
                        version: pack.version,
                        isEnabled: pack.isEnabled,
                        updatedAt: pack.updatedAt
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            plan: plan.map { plan in
                GADPlanProjection(
                    id: plan.id,
                    goal: redactor.text(plan.interpretedGoal, limit: 4_000),
                    attachments: plan.attachments.map {
                        GADDraftAttachmentProjection(
                            id: $0.id,
                            kind: $0.kind,
                            displayName: redactor.text($0.displayName, limit: 240),
                            byteCount: $0.byteCount,
                            typeHint: $0.typeHint.map { redactor.text($0, limit: 80) }
                        )
                    },
                    routes: plan.routes.map { route in
                        GADPlanRouteProjection(
                            projectID: route.projectID,
                            providerID: route.providerID,
                            model: route.model.map { redactor.text($0, limit: 160) },
                            agentIDs: route.agentIDs.sorted { $0.rawValue < $1.rawValue },
                            providerBindings: route.providerBindings.sorted {
                                $0.agentID.rawValue < $1.agentID.rawValue
                            },
                            reason: redactor.text(route.reason, limit: 600)
                        )
                    },
                    risk: plan.risk,
                    confidence: plan.confidence,
                    gitOperations: plan.gitOperations.map {
                        GADPlannedGitOperationProjection(
                            id: $0.id,
                            projectID: $0.projectID,
                            kind: $0.kind,
                            branch: $0.branch.map { redactor.text($0, limit: 240) },
                            remote: $0.remote.map { redactor.text($0, limit: 160) }
                        )
                    },
                    warnings: plan.warnings.map { redactor.text($0, limit: 1_000) },
                    selectedResourceIDs: selectedResourceIDs.sorted { $0.rawValue < $1.rawValue },
                    createdAt: plan.createdAt,
                    deliveryPipeline: plan.deliveryPipeline.map { redactedPipeline($0, redactor: redactor) },
                    startsWithoutReview: planStartsWithoutReview
                )
            },
            runs: projectedRuns
                .map {
                    runProjection(
                        $0,
                        redactor: redactor,
                        providerTaskTargets: providerTaskTargets,
                        includesActivity: Self.activityRunIDs(in: projectedRuns).contains($0.id)
                    )
                }
                .sorted { $0.updatedAt > $1.updatedAt },
            automations: automationProjection(projectedAutomations, redactor: redactor),
            approvals: approvals.compactMap { approval in
                guard let runID = runIDByAssignment[approval.assignmentID] else { return nil }
                var actions: [GADApprovalAction] = [.decline]
                let isCompletelyDisclosable = approval.hasCompleteOperationBinding
                    && approval.summary.utf8.count <= ApprovalDisclosureLimits.canonicalSummaryUTF8Limit
                    && (approval.details?.utf8.count ?? 0) <= ApprovalDisclosureLimits.canonicalDetailsUTF8Limit
                if approval.canAccept && isCompletelyDisclosable {
                    actions.append(.allowOnce)
                }
                actions.append(.cancel)
                return GADApprovalProjection(
                    id: approval.routingID,
                    runID: runID,
                    assignmentID: approval.assignmentID,
                    providerID: approval.providerID,
                    kind: approval.kind,
                    summary: "\(approval.kind.displayName) approval requested",
                    details: nil,
                    actions: actions,
                    approvalSessionID: approval.approvalSessionID,
                    // The provider's unsalted operation digest may contain a
                    // dictionary oracle for aliased Mac paths. Exact mobile
                    // decisions use the short-lived host disclosure receipt.
                    operationDigest: nil,
                    disclosureComplete: approval.disclosureComplete,
                    expiresAt: generatedAt.addingTimeInterval(300)
                )
            },
            codexTasks: codexTasks
                .map { task in
                    GADCodexTaskProjection(
                        id: opaqueID(prefix: "task", source: task.id),
                        projectID: task.projectID,
                        title: redactor.text(task.title, limit: 240),
                        summary: task.summary.map { redactor.text($0, limit: 600) },
                        status: task.status,
                        updatedAt: task.updatedAt
                    )
                }
                .sorted { $0.updatedAt > $1.updatedAt },
            account: account.map {
                GADAccountProjection(
                    authenticated: $0.authenticated,
                    planName: $0.planName.map { redactor.text($0, limit: 80) },
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt,
                    secondaryUsedPercent: $0.secondaryUsedPercent,
                    secondaryResetsAt: $0.secondaryResetsAt
                )
            },
            providerAccounts: providerAccounts
                .map { account in
                    providerAccountProjection(
                        account,
                        activityFreshness: providerActivityFreshness[account.providerID],
                        credentialConfigured: providerCredentialConfigured[account.providerID],
                        redactor: redactor
                    )
                }
                .sorted { $0.providerID < $1.providerID },
            providerTasks: providerTasks
                .map { task in
                    GADProviderTaskProjection(
                        id: opaqueID(
                            prefix: "provider-task",
                            source: "\(task.providerID.rawValue):\(task.identity.nativeID)"
                        ),
                        providerID: task.providerID,
                        projectID: task.projectID,
                        title: redactor.text(task.title, limit: 240),
                        summary: task.summary.map { redactor.text($0, limit: 600) },
                        status: task.status,
                        updatedAt: task.updatedAt,
                        agentRole: task.agentRole.map { redactor.text($0, limit: 120) },
                        parentTaskID: task.parentTaskIdentity.map {
                            opaqueID(
                                prefix: "provider-task",
                                source: "\($0.providerID.rawValue):\($0.nativeID)"
                            )
                        },
                        agentID: providerTaskTargets[task.identity]?.agentID
                    )
                }
                .sorted { $0.updatedAt > $1.updatedAt },
            providerBindings: lab.providerBindings
                .map { binding in
                    GADProviderBindingProjection(
                        id: binding.id,
                        providerID: binding.providerID,
                        agentID: binding.agentID,
                        projectID: binding.projectID,
                        capabilities: binding.capabilities.sorted { $0.rawValue < $1.rawValue },
                        state: binding.state,
                        hasInstructionsOverride: binding.instructionsOverride?.isEmpty == false
                    )
                }
                .sorted {
                    if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
                    return $0.id.rawValue < $1.id.rawValue
                },
            handoffLinks: lab.agentHandoffLinks
                .map { link in
                    GADHandoffLinkProjection(
                        id: link.id,
                        source: endpoint(link.source),
                        destination: endpoint(link.destination),
                        purpose: redactor.text(link.purpose, limit: 600),
                        conditions: redactor.text(link.conditions, limit: 1_000),
                        triggers: link.triggers.sorted { $0.rawValue < $1.rawValue },
                        isEnabled: link.isEnabled
                    )
                }
                .sorted { $0.id.rawValue < $1.id.rawValue },
            handoffs: lab.handoffs
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(500)
                .map { handoff in
                    GADHandoffProjection(
                        id: handoff.id,
                        runID: handoff.bundle.runID,
                        destinationRunID: handoff.destinationRunID,
                        linkID: handoff.bundle.linkID,
                        sourceAssignmentID: handoff.bundle.sourceAssignmentID,
                        source: endpoint(handoff.bundle.source),
                        destination: endpoint(handoff.bundle.destination),
                        state: handoff.state,
                        purpose: redactor.text(handoff.bundle.purpose, limit: 600),
                        sourceOutcomeSummary: redactor.text(
                            handoff.bundle.sourceOutcomeSummary,
                            limit: 2_000
                        ),
                        requestedNextAction: redactor.text(
                            handoff.bundle.requestedNextAction,
                            limit: 1_000
                        ),
                        attemptCount: handoff.attemptCount,
                        statusReason: handoff.statusReason.map { redactor.text($0, limit: 1_000) },
                        updatedAt: handoff.updatedAt
                    )
                },
            health: health.checks.map {
                GADHealthProjection(
                    kind: $0.kind,
                    status: $0.status,
                    summary: redactor.text($0.summary, limit: 240)
                )
            }
        )
        return ProjectionHistoryBudget.apply(
            to: projection,
            totalRunCount: runs.count,
            totalOccurrenceCount: automations.occurrences.count
        )
    }

    /// Steps travel only for active runs and the few most recently updated
    /// ones, keeping snapshots small; older runs show their answer instead.
    static let recentActivityRunCount = 3

    static func activityRunIDs(in runs: [RunRecord]) -> Set<RunID> {
        let active = runs.filter { !$0.status.isFinished }.map(\.id)
        let recent = runs.sorted { $0.updatedAt > $1.updatedAt }.prefix(recentActivityRunCount).map(\.id)
        return Set(active + recent)
    }

    private func runProjection(
        _ run: RunRecord,
        redactor: ProjectionRedactor,
        providerTaskTargets: [ProviderTaskIdentity: AgentRouteTarget],
        includesActivity: Bool = false
    ) -> GADRunProjection {
        GADRunProjection(
            id: run.id,
            goal: redactor.text(run.plan.interpretedGoal, limit: 4_000),
            attachments: run.plan.attachments.map {
                GADDraftAttachmentProjection(
                    id: $0.id,
                    kind: $0.kind,
                    displayName: redactor.text($0.displayName, limit: 240),
                    byteCount: $0.byteCount,
                    typeHint: $0.typeHint.map { redactor.text($0, limit: 80) }
                )
            },
            risk: run.plan.risk,
            confidence: run.plan.confidence,
            gitOperations: run.plan.gitOperations.map {
                GADPlannedGitOperationProjection(
                    id: $0.id,
                    projectID: $0.projectID,
                    kind: $0.kind,
                    branch: $0.branch.map { redactor.text($0, limit: 240) },
                    remote: $0.remote.map { redactor.text($0, limit: 160) }
                )
            },
            warnings: run.plan.warnings.map { redactor.text($0, limit: 1_000) },
            status: run.status,
            assignments: run.assignments.map { assignment in
                GADAssignmentProjection(
                    id: assignment.id,
                    projectID: assignment.projectID,
                    agentID: assignment.agentID,
                    providerID: assignment.providerID,
                    providerBindingID: assignment.providerBindingID,
                    model: assignment.model.map { redactor.text($0, limit: 160) },
                    status: assignment.status,
                    currentTask: redactor.text(assignment.currentTask, limit: 1_000),
                    progress: assignment.progress,
                    statusReason: assignment.statusReason.map { redactor.text($0, limit: 1_000) },
                    startIsIndeterminate: assignment.hasIndeterminateProviderStart,
                    deliveryStageID: assignment.deliveryStageID
                )
            },
            helperTasks: run.helperTasks.map { task in
                GADProviderTaskProjection(
                    id: opaqueID(
                        prefix: "provider-task",
                        source: "\(task.providerID.rawValue):\(task.identity.nativeID)"
                    ),
                    providerID: task.providerID,
                    projectID: task.projectID,
                    title: redactor.text(task.title, limit: 240),
                    summary: task.summary.map { redactor.text($0, limit: 4_000) },
                    status: task.status,
                    updatedAt: task.updatedAt,
                    agentRole: task.agentRole.map { redactor.text($0, limit: 120) },
                    parentTaskID: task.parentTaskIdentity.map {
                        opaqueID(
                            prefix: "provider-task",
                            source: "\($0.providerID.rawValue):\($0.nativeID)"
                        )
                    },
                    agentID: providerTaskTargets[task.identity]?.agentID
                )
            },
            projectSnapshot: run.projectSnapshot.map {
                GADRunProjectSnapshot(id: $0.id, name: redactor.text($0.name, limit: 160))
            },
            outcome: run.outcome.map { redactor.text($0, limit: 8_000) },
            journal: RunJournalCompactor.compact(run.journal, limit: 250).map {
                GADJournalProjection(
                    id: $0.id,
                    kind: $0.kind,
                    message: redactor.text($0.message, limit: 1_000),
                    assignmentID: $0.assignmentID,
                    occurredAt: $0.occurredAt
                )
            },
            // Titles only, through the mobile redactor; details and command
            // output stay on the Mac.
            activity: (includesActivity ? Array(run.activity.suffix(GADRunActivityProjection.limit)) : []).map {
                GADRunActivityProjection(
                    id: $0.id,
                    assignmentID: $0.assignmentID,
                    kind: $0.kind.rawValue,
                    title: redactor.text(
                        $0.title,
                        limit: $0.kind == .message
                            ? GADRunActivityProjection.messageTitleLimit
                            : GADRunActivityProjection.titleLimit
                    ),
                    status: $0.status.rawValue,
                    exitCode: $0.exitCode,
                    startedAt: $0.startedAt,
                    finishedAt: $0.finishedAt
                )
            },
            createdAt: run.createdAt,
            updatedAt: run.updatedAt,
            deliveryPipeline: run.plan.deliveryPipeline.map { redactedPipeline($0, redactor: redactor) }
        )
    }

    private func scope(_ scope: AgentScope) -> GADAgentScopeProjection {
        switch scope {
        case .global: .global
        case .union: .union
        case let .project(id): .project(id)
        }
    }

    private func providerAccountProjection(
        _ account: ProviderAccountSnapshot,
        activityFreshness: ProviderActivityFreshness?,
        credentialConfigured: Bool?,
        redactor: ProjectionRedactor
    ) -> GADProviderAccountProjection {
        GADProviderAccountProjection(
            providerID: account.providerID,
            connectionState: redacted(account.connectionState, using: redactor),
            planName: account.planName.map { redactor.text($0, limit: 80) },
            selectedModel: account.selectedModel.map { redactor.text($0, limit: 120) },
            availableModels: account.availableModels.map { redactor.text($0, limit: 120) },
            usage: account.usage.map { usage in
                GADProviderUsageProjection(
                    id: redactor.text(usage.id, limit: 120),
                    kind: usage.kind,
                    label: redactor.text(usage.label, limit: 120),
                    value: usage.value,
                    unit: redactor.text(usage.unit, limit: 40),
                    resetsAt: usage.resetsAt,
                    isEstimate: usage.isEstimate
                )
            },
            observedAt: account.observedAt,
            activityFreshness: activityFreshness,
            credentialConfigured: credentialConfigured
        )
    }

    private func redacted(
        _ state: ProviderConnectionState,
        using redactor: ProjectionRedactor
    ) -> ProviderConnectionState {
        switch state {
        case .notChecked: .notChecked
        case let .unavailable(reason): .unavailable(reason: redactor.text(reason, limit: 500))
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(version):
            .connected(version: version.map { redactor.text($0, limit: 80) })
        case .needsAuthentication: .needsAuthentication
        case let .failed(message): .failed(message: redactor.text(message, limit: 500))
        }
    }

    private func endpoint(_ endpoint: AgentHandoffEndpoint) -> GADHandoffEndpointProjection {
        GADHandoffEndpointProjection(
            providerID: endpoint.providerID,
            bindingID: endpoint.bindingID,
            agentID: endpoint.agentID,
            projectID: endpoint.projectID
        )
    }

    private func automationProjection(
        _ snapshot: AutomationSnapshot,
        redactor: ProjectionRedactor
    ) -> AutomationSnapshot {
        AutomationSnapshot(
            definitions: snapshot.definitions.map { definition in
                AutomationDefinition(
                    id: definition.id,
                    name: redactor.text(definition.name, limit: 120),
                    schedule: definition.schedule,
                    actions: definition.actions.map {
                        AutomationAction(
                            id: $0.id,
                            instruction: redactor.text($0.instruction, limit: 32_000),
                            target: $0.target
                        )
                    },
                    state: definition.state,
                    automaticallyApproveRuntimeRequests: definition.automaticallyApproveRuntimeRequests,
                    nextRunAt: definition.nextRunAt,
                    revision: definition.revision,
                    createdAt: definition.createdAt,
                    updatedAt: definition.updatedAt
                )
            },
            occurrences: snapshot.occurrences.map { occurrence in
                AutomationOccurrence(
                    id: occurrence.id,
                    automationID: occurrence.automationID,
                    automationName: occurrence.automationName.map {
                        redactor.text($0, limit: 120)
                    },
                    definitionRevision: occurrence.definitionRevision,
                    actions: occurrence.actions.map {
                        AutomationAction(
                            id: $0.id,
                            instruction: redactor.text($0.instruction, limit: 32_000),
                            target: $0.target
                        )
                    },
                    trigger: occurrence.trigger,
                    scheduledAt: occurrence.scheduledAt,
                    status: occurrence.status,
                    currentActionIndex: occurrence.currentActionIndex,
                    attempts: occurrence.attempts.map { attempt in
                        AutomationActionAttempt(
                            actionID: attempt.actionID,
                            plan: attempt.plan.map { planProjection($0, redactor: redactor) },
                            runID: attempt.runID,
                            status: attempt.status,
                            message: attempt.message.map { redactor.text($0, limit: 2_000) },
                            updatedAt: attempt.updatedAt
                        )
                    },
                    message: occurrence.message.map { redactor.text($0, limit: 2_000) },
                    createdAt: occurrence.createdAt,
                    updatedAt: occurrence.updatedAt
                )
            }
        )
    }

    private func boundedRuns(_ runs: [RunRecord], requiredRunIDs: Set<RunID>) -> [RunRecord] {
        let ordered = runs.sorted { lhs, rhs in
            if lhs.status.isFinished != rhs.status.isFinished {
                return !lhs.status.isFinished
            }
            return lhs.updatedAt == rhs.updatedAt
                ? lhs.id.rawValue < rhs.id.rawValue : lhs.updatedAt > rhs.updatedAt
        }
        let recentIDs = Set(ordered.prefix(250).map(\.id))
        return ordered.filter {
            !$0.status.isFinished || recentIDs.contains($0.id) || requiredRunIDs.contains($0.id)
        }
    }

    private func boundedAutomations(_ snapshot: AutomationSnapshot) -> AutomationSnapshot {
        AutomationSnapshot(
            definitions: Array(snapshot.definitions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(256)),
            occurrences: snapshot.occurrences.sorted { lhs, rhs in
                if lhs.status.isFinished != rhs.status.isFinished {
                    return !lhs.status.isFinished
                }
                return lhs.updatedAt == rhs.updatedAt
                    ? lhs.id.rawValue < rhs.id.rawValue : lhs.updatedAt > rhs.updatedAt
            }.enumerated().compactMap { index, occurrence in
                index < 500 || !occurrence.status.isFinished ? occurrence : nil
            }
        )
    }

    private func redactedPipeline(
        _ pipeline: DeliveryPipeline,
        redactor: ProjectionRedactor
    ) -> DeliveryPipeline {
        DeliveryPipeline(
            stages: pipeline.stages.map {
                DeliveryStage(
                    id: $0.id,
                    kind: $0.kind,
                    target: $0.target,
                    reason: redactor.text($0.reason, limit: 600),
                    passCriteria: redactor.text($0.passCriteria, limit: 600)
                )
            },
            maximumReworkCycles: pipeline.maximumReworkCycles
        )
    }

    private func planProjection(
        _ plan: RoutingPlan,
        redactor: ProjectionRedactor
    ) -> RoutingPlan {
        RoutingPlan(
            id: plan.id,
            interpretedGoal: redactor.text(plan.interpretedGoal, limit: 4_000),
            attachments: [],
            routes: plan.routes.map {
                ProjectRoute(
                    projectID: $0.projectID,
                    providerID: $0.providerID,
                    model: $0.model.map { redactor.text($0, limit: 160) },
                    agentIDs: $0.agentIDs,
                    providerBindings: $0.providerBindings,
                    reason: redactor.text($0.reason, limit: 600)
                )
            },
            risk: plan.risk,
            confidence: plan.confidence,
            gitOperations: plan.gitOperations.map {
                PlannedGitOperation(
                    id: $0.id,
                    projectID: $0.projectID,
                    kind: $0.kind,
                    branch: $0.branch.map { redactor.text($0, limit: 240) },
                    remote: $0.remote.map { redactor.text($0, limit: 160) }
                )
            },
            warnings: plan.warnings.map { redactor.text($0, limit: 1_000) },
            createdAt: plan.createdAt,
            deliveryPipeline: plan.deliveryPipeline.map { redactedPipeline($0, redactor: redactor) }
        )
    }

    private func forbiddenValues(
        lab: LabSnapshot,
        runs: [RunRecord],
        resources: [SharedResource],
        plan: RoutingPlan?,
        account: CodexAccountSnapshot?,
        exactForbiddenValues: [String]
    ) -> [String] {
        var values = exactForbiddenValues
        for project in lab.projects {
            values.append(project.rootURL.path(percentEncoded: false))
            values.append(contentsOf: project.instructionFiles.map { $0.path(percentEncoded: false) })
            values.append(contentsOf: project.testCommands)
        }
        for agent in lab.agents {
            if let sourcePath = agent.sourceURL?.path(percentEncoded: false) { values.append(sourcePath) }
            // Short role names and registration keys are ordinary vocabulary
            // (for example "iOS"). Replacing them inside a shared draft can
            // silently change the task that the host later sends to Codex.
            values.append(contentsOf: [agent.instructions, agent.codexRegistrationKey]
                .compactMap { $0 }
                .filter { $0.count >= 8 })
        }
        for resource in resources {
            values.append(resource.url.path(percentEncoded: false))
        }
        for run in runs {
            values.append(contentsOf: run.assignments.flatMap {
                [$0.workingDirectory?.path(percentEncoded: false), $0.codexThreadID, $0.codexTurnID].compactMap { $0 }
            })
            values.append(contentsOf: run.instructionSnapshot.map(\.body).filter { $0.count >= 8 })
            values.append(contentsOf: run.agentSnapshot.compactMap(\.instructions).filter { $0.count >= 8 })
            values.append(contentsOf: run.resourceSnapshot.map { $0.url.path(percentEncoded: false) })
            values.append(contentsOf: sensitiveAttachmentValues(run.plan.attachments))
        }
        values.append(contentsOf: sensitiveAttachmentValues(plan?.attachments ?? []))
        if let displayName = account?.displayName { values.append(displayName) }
        return values
    }

    private func sensitiveAttachmentValues(_ attachments: [PromptAttachment]) -> [String] {
        attachments.compactMap { attachment in
            switch attachment.source {
            case let .localFile(url): url.path(percentEncoded: false)
            case let .text(text): text
            case nil: nil
            }
        }
    }

    private func opaqueID(prefix: String, source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)-\(String(hash, radix: 16))"
    }
}

private struct ProjectionRedactor: Sendable {
    let forbiddenValues: SensitiveTextRedactor.PreparedExactValues

    init(forbiddenValues: [String]) {
        self.forbiddenValues = .init(forbiddenValues)
    }

    func text(_ source: String, limit: Int, preservePlanSlashCommand: Bool = false) -> String {
        SensitiveTextRedactor.redact(
            source,
            preparedExactValues: forbiddenValues,
            limit: limit,
            preservePlanSlashCommand: preservePlanSlashCommand
        )
    }
}

private extension CodexApprovalKind {
    var displayName: String {
        switch self {
        case .command: "Command"
        case .fileChange: "File change"
        case .permissions: "Permission"
        }
    }
}
