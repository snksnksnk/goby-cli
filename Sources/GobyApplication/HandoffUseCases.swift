import CryptoKit
import Foundation
import GobyDomain

public struct SaveHandoffLinkUseCase: Sendable {
    private let catalog: any HandoffCatalogManaging

    public init(catalog: any HandoffCatalogManaging) {
        self.catalog = catalog
    }

    public func callAsFunction(_ link: AgentHandoffLink) async throws {
        guard link.mode == .suggestOnly else {
            throw GobyApplicationError.automaticHandoffsUnavailable
        }
        guard link.source != link.destination else {
            throw GobyApplicationError.invalidHandoffLink("the source and destination must be different")
        }
        try await catalog.saveHandoffLink(link)
    }
}

/// Reviewed, provider-neutral source material for one manual continuation.
/// Raw provider transcripts and approval receipts deliberately have no field.
public struct PrepareManualHandoffRequest: Sendable {
    public let runID: RunID
    public let linkID: AgentHandoffLinkID
    public let sourceAssignmentID: AssignmentID
    public let trigger: HandoffTrigger
    public let sourceOutcomeSummary: String
    public let completedSteps: [String]
    public let unresolvedWork: [String]
    public let knownRisks: [String]
    public let requestedNextAction: String
    public let artifacts: [HandoffArtifactReference]
    public let changedFiles: [String]
    public let patchOrCommitReference: String?
    public let workingCopyIdentity: String?
    public let verificationEvidence: [HandoffVerificationEvidence]
    public let parentHandoffID: HandoffID?

    public init(
        runID: RunID,
        linkID: AgentHandoffLinkID,
        sourceAssignmentID: AssignmentID,
        trigger: HandoffTrigger,
        sourceOutcomeSummary: String,
        completedSteps: [String] = [],
        unresolvedWork: [String] = [],
        knownRisks: [String] = [],
        requestedNextAction: String,
        artifacts: [HandoffArtifactReference] = [],
        changedFiles: [String] = [],
        patchOrCommitReference: String? = nil,
        workingCopyIdentity: String? = nil,
        verificationEvidence: [HandoffVerificationEvidence] = [],
        parentHandoffID: HandoffID? = nil
    ) {
        self.runID = runID
        self.linkID = linkID
        self.sourceAssignmentID = sourceAssignmentID
        self.trigger = trigger
        self.sourceOutcomeSummary = sourceOutcomeSummary
        self.completedSteps = completedSteps
        self.unresolvedWork = unresolvedWork
        self.knownRisks = knownRisks
        self.requestedNextAction = requestedNextAction
        self.artifacts = artifacts
        self.changedFiles = changedFiles
        self.patchOrCommitReference = patchOrCommitReference
        self.workingCopyIdentity = workingCopyIdentity
        self.verificationEvidence = verificationEvidence
        self.parentHandoffID = parentHandoffID
    }
}

public struct PrepareManualHandoffUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let runs: any RunRepository
    private let handoffs: any HandoffCatalogManaging
    private let credentials: (any ProviderCredentialRepository)?

    public init(
        catalog: any LabCatalogRepository,
        runs: any RunRepository,
        handoffs: any HandoffCatalogManaging,
        credentials: (any ProviderCredentialRepository)? = nil
    ) {
        self.catalog = catalog
        self.runs = runs
        self.handoffs = handoffs
        self.credentials = credentials
    }

    public func callAsFunction(_ request: PrepareManualHandoffRequest) async throws -> HandoffRecord {
        async let snapshotValue = catalog.snapshot()
        async let runValues = runs.allRuns()
        let (snapshot, allRuns) = try await (snapshotValue, runValues)

        guard let link = snapshot.agentHandoffLinks.first(where: { $0.id == request.linkID }) else {
            throw GobyApplicationError.unknownHandoffLink(request.linkID)
        }
        guard link.isEnabled else {
            throw GobyApplicationError.invalidHandoffLink("the reviewed path is disabled")
        }
        guard link.mode == .suggestOnly else {
            throw GobyApplicationError.automaticHandoffsUnavailable
        }
        guard link.source != link.destination else {
            throw GobyApplicationError.invalidHandoffLink("the source and destination must be different")
        }
        guard link.triggers.contains(request.trigger) else {
            throw GobyApplicationError.invalidHandoffLink("the source checkpoint is not allowed by this path")
        }
        guard let run = allRuns.first(where: { $0.id == request.runID }),
              let sourceAssignment = run.assignments.first(where: { $0.id == request.sourceAssignmentID }) else {
            throw GobyApplicationError.handoffSourceNotReady(request.sourceAssignmentID)
        }
        try validateSource(sourceAssignment, run: run, link: link, trigger: request.trigger)
        try validateDestination(link.destination, in: snapshot)
        try validateArtifacts(request, accepted: link.acceptedArtifacts)

        let parentHandoffID = request.parentHandoffID ?? sourceAssignment.handoffID
        let depth = try continuationDepth(
            parentID: parentHandoffID,
            sourceAssignment: sourceAssignment,
            runID: run.id,
            link: link,
            snapshot: snapshot
        )
        guard depth <= link.maximumDepth else {
            throw GobyApplicationError.handoffDepthExceeded(maximum: link.maximumDepth)
        }

        let exactForbiddenValues = try await providerCredentialValues()
        let sanitized = HandoffBundleSanitizer.sanitize(
            request,
            exactForbiddenValues: exactForbiddenValues
        )
        guard !sanitized.sourceOutcomeSummary.isEmpty,
              !sanitized.requestedNextAction.isEmpty else {
            throw GobyApplicationError.invalidHandoffLink("add a source outcome and requested next action")
        }

        let idempotencyKey = HandoffBundleIntegrity.idempotencyKey(
            runID: run.id,
            linkID: link.id,
            sourceAssignmentID: sourceAssignment.id,
            trigger: request.trigger,
            parentHandoffID: parentHandoffID,
            depth: depth
        )
        if let existing = snapshot.handoffs.first(where: {
            $0.bundle.idempotencyKey == idempotencyKey
        }) {
            guard HandoffBundleIntegrity.isValid(existing.bundle),
                  existing.bundle.linkID == link.id,
                  existing.bundle.source == link.source,
                  existing.bundle.destination == link.destination else {
                throw GobyApplicationError.invalidHandoffLink(
                    "the existing continuation record no longer matches this reviewed path"
                )
            }
            return existing
        }
        // Provider-native task identifiers are neither needed by the destination
        // nor safe to place in a cross-provider continuation bundle.
        let sourceTaskIdentity: ProviderTaskIdentity? = nil
        let resources = run.resourceSnapshot.map {
            HandoffResourceDescriptor(
                name: HandoffBundleSanitizer.text(
                    $0.name,
                    exactForbiddenValues: exactForbiddenValues,
                    limit: 160
                ),
                capability: $0.access.displayName
            )
        }
        let provisional = HandoffBundle(
            idempotencyKey: idempotencyKey,
            runID: run.id,
            linkID: link.id,
            source: link.source,
            destination: link.destination,
            originalGoal: HandoffBundleSanitizer.text(
                run.plan.interpretedGoal,
                exactForbiddenValues: exactForbiddenValues,
                limit: 4_000
            ),
            purpose: HandoffBundleSanitizer.text(
                link.purpose,
                exactForbiddenValues: exactForbiddenValues,
                limit: 1_000
            ),
            sourceOutcomeSummary: sanitized.sourceOutcomeSummary,
            sourceTrigger: request.trigger,
            completedSteps: sanitized.completedSteps,
            unresolvedWork: sanitized.unresolvedWork,
            knownRisks: sanitized.knownRisks,
            requestedNextAction: sanitized.requestedNextAction,
            artifacts: sanitized.artifacts,
            changedFiles: sanitized.changedFiles,
            patchOrCommitReference: sanitized.patchOrCommitReference,
            workingCopyIdentity: sanitized.workingCopyIdentity,
            verificationEvidence: sanitized.verificationEvidence,
            resources: resources,
            sourceAssignmentID: sourceAssignment.id,
            sourceTaskIdentity: sourceTaskIdentity,
            parentHandoffID: parentHandoffID,
            depth: depth,
            integrityHash: ""
        )
        let bundle = HandoffBundleIntegrity.seal(provisional)
        let record = HandoffRecord(bundle: bundle, state: .ready)
        try await handoffs.saveHandoff(record)
        return record
    }

    private func providerCredentialValues() async throws -> [String] {
        guard let credentials else { return [] }
        var values: [String] = []
        for providerID in AgentProviderID.builtIn {
            if let credential = try await credentials.credential(for: providerID),
               credential.count >= 3 {
                values.append(credential)
            }
        }
        return values
    }

    private func validateSource(
        _ assignment: AgentAssignment,
        run: RunRecord,
        link: AgentHandoffLink,
        trigger: HandoffTrigger
    ) throws {
        guard assignment.providerID == link.source.providerID,
              assignment.agentID == link.source.agentID,
              assignment.projectID == link.source.projectID,
              run.providerBindingSnapshot.contains(where: {
                  $0.id == link.source.bindingID
                      && $0.providerID == link.source.providerID
                      && $0.agentID == link.source.agentID
                      && $0.projectID == link.source.projectID
              }), sourceStatusIsSafe(assignment.status, for: trigger) else {
            throw GobyApplicationError.handoffSourceNotReady(assignment.id)
        }
    }

    private func sourceStatusIsSafe(_ status: AgentStatus, for trigger: HandoffTrigger) -> Bool {
        switch trigger {
        case .success:
            status == .completed
        case .failure:
            status == .failed
        case .blockage:
            status == .paused || status == .waitingForApproval || status == .failed
        case .checkpoint:
            status == .paused || status == .completed || status == .failed
        }
    }

    private func validateDestination(_ endpoint: AgentHandoffEndpoint, in snapshot: LabSnapshot) throws {
        guard let binding = snapshot.providerBindings.first(where: { $0.id == endpoint.bindingID }),
              binding.providerID == endpoint.providerID,
              binding.agentID == endpoint.agentID,
              binding.projectID == endpoint.projectID,
              binding.state == .configured,
              let agent = snapshot.agents.first(where: { $0.id == endpoint.agentID }),
              agent.isEnabled else {
            throw GobyApplicationError.missingProviderBinding(
                agentID: endpoint.agentID,
                providerID: endpoint.providerID,
                projectID: endpoint.projectID
            )
        }
    }

    private func validateArtifacts(
        _ request: PrepareManualHandoffRequest,
        accepted: Set<HandoffArtifactKind>
    ) throws {
        let suppliedKinds = Set(request.artifacts.map(\.kind))
            .union(request.changedFiles.isEmpty ? [] : [.changedFileList])
            .union(request.patchOrCommitReference == nil ? [] : [.patch])
            .union(request.verificationEvidence.isEmpty ? [] : [.verificationEvidence])
        guard suppliedKinds.isSubset(of: accepted) else {
            throw GobyApplicationError.invalidHandoffLink("the bundle contains an artifact kind not accepted by the destination")
        }
    }

    private func continuationDepth(
        parentID: HandoffID?,
        sourceAssignment: AgentAssignment,
        runID: RunID,
        link: AgentHandoffLink,
        snapshot: LabSnapshot
    ) throws -> Int {
        guard let parentID else { return 1 }
        var ancestorID: HandoffID? = parentID
        var visited: Set<HandoffID> = []
        while let currentID = ancestorID {
            guard visited.insert(currentID).inserted,
                  let ancestor = snapshot.handoffs.first(where: { $0.id == currentID }),
                  HandoffBundleIntegrity.isValid(ancestor.bundle) else {
                throw GobyApplicationError.invalidHandoffLink(
                    "the continuation ancestry is missing, cyclic, or failed integrity validation"
                )
            }
            guard ancestor.bundle.source != link.destination,
                  ancestor.bundle.destination != link.destination else {
                throw GobyApplicationError.invalidHandoffLink(
                    "the continuation would return to an earlier endpoint"
                )
            }
            ancestorID = ancestor.bundle.parentHandoffID
        }
        guard let parent = snapshot.handoffs.first(where: { $0.id == parentID }),
              (parent.destinationRunID ?? parent.bundle.runID) == runID,
              parent.bundle.destination == link.source,
              sourceAssignment.handoffID == parentID else {
            throw GobyApplicationError.invalidHandoffLink("the parent continuation does not lead to this source assignment")
        }
        return parent.bundle.depth + 1
    }
}

public struct DispatchedManualHandoff: Sendable {
    public let run: RunRecord
    public let handoff: HandoffRecord

    public init(run: RunRecord, handoff: HandoffRecord) {
        self.run = run
        self.handoff = handoff
    }
}

/// Dispatch is the explicit user action for a suggest-only link. It queues one
/// destination assignment but never forwards source credentials or approvals.
public struct DispatchManualHandoffUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let runs: any RunRepository
    private let handoffs: any HandoffCatalogManaging

    public init(
        catalog: any LabCatalogRepository,
        runs: any RunRepository,
        handoffs: any HandoffCatalogManaging
    ) {
        self.catalog = catalog
        self.runs = runs
        self.handoffs = handoffs
    }

    public func callAsFunction(handoffID: HandoffID) async throws -> DispatchedManualHandoff {
        async let snapshotValue = catalog.snapshot()
        async let runValues = runs.allRuns()
        let (snapshot, allRuns) = try await (snapshotValue, runValues)
        guard let record = snapshot.handoffs.first(where: { $0.id == handoffID }) else {
            throw GobyApplicationError.unknownHandoff(handoffID)
        }
        guard HandoffBundleIntegrity.isValid(record.bundle) else {
            throw GobyApplicationError.handoffNotDispatchable(handoffID)
        }
        guard allRuns.contains(where: { $0.id == record.bundle.runID }) else {
            throw GobyApplicationError.handoffNotDispatchable(handoffID)
        }

        if let destinationRun = existingDestinationRun(for: record, in: allRuns),
           let existing = destinationRun.assignments.first(where: { $0.handoffID == handoffID }) {
            let reconciled = queuedRecord(
                record,
                runID: destinationRun.id,
                assignmentID: existing.id
            )
            try await handoffs.saveHandoff(reconciled)
            return DispatchedManualHandoff(run: destinationRun, handoff: reconciled)
        }
        guard record.state == .ready || record.state == .awaitingApproval else {
            throw GobyApplicationError.handoffNotDispatchable(handoffID)
        }

        let destination = record.bundle.destination
        guard let binding = snapshot.providerBindings.first(where: {
            $0.id == destination.bindingID
                && $0.providerID == destination.providerID
                && $0.agentID == destination.agentID
                && $0.projectID == destination.projectID
                && $0.state == .configured
        }), let agent = snapshot.agents.first(where: { $0.id == destination.agentID && $0.isEnabled }),
              let project = snapshot.projects.first(where: { $0.id == destination.projectID }) else {
            throw GobyApplicationError.missingProviderBinding(
                agentID: destination.agentID,
                providerID: destination.providerID,
                projectID: destination.projectID
            )
        }

        let destinationRunID = RunID.make()
        let assignment = AgentAssignment(
            runID: destinationRunID,
            projectID: destination.projectID,
            agentID: destination.agentID,
            status: .queued,
            currentTask: HandoffPromptRenderer.render(record.bundle),
            statusReason: "Queued from a reviewed manual handoff.",
            providerID: destination.providerID,
            providerBindingID: destination.bindingID,
            handoffID: handoffID
        )
        let destinationRun = isolatedDestinationRun(
            id: destinationRunID,
            assignment: assignment,
            destinationAgent: agent,
            destinationBinding: binding,
            destinationProject: project,
            handoff: record
        )

        // Save the assignment first. If the process stops before the record is
        // updated, a retry finds `handoffID` and reconciles without duplicating.
        try await runs.save(destinationRun)
        let queued = queuedRecord(
            record,
            runID: destinationRunID,
            assignmentID: assignment.id
        )
        try await handoffs.saveHandoff(queued)
        return DispatchedManualHandoff(run: destinationRun, handoff: queued)
    }

    private func existingDestinationRun(
        for record: HandoffRecord,
        in runs: [RunRecord]
    ) -> RunRecord? {
        if let destinationRunID = record.destinationRunID,
           let run = runs.first(where: { $0.id == destinationRunID }) {
            return run
        }
        // Reconcile the crash window after the isolated run is saved but before
        // the handoff record receives its destination identifiers.
        return runs.first(where: { run in
            run.assignments.contains(where: { $0.handoffID == record.id })
        })
    }

    private func queuedRecord(
        _ record: HandoffRecord,
        runID: RunID,
        assignmentID: AssignmentID
    ) -> HandoffRecord {
        HandoffRecord(
            bundle: record.bundle,
            state: .queued,
            destinationRunID: runID,
            destinationAssignmentID: assignmentID,
            destinationTaskIdentity: record.destinationTaskIdentity,
            attemptCount: max(1, record.attemptCount),
            statusReason: "Queued by explicit user action.",
            updatedAt: .now
        )
    }

    private func isolatedDestinationRun(
        id: RunID,
        assignment: AgentAssignment,
        destinationAgent: AgentProfile,
        destinationBinding: ProviderAgentBinding,
        destinationProject: LabProject,
        handoff: HandoffRecord
    ) -> RunRecord {
        let warning = "This is a fresh read-only destination run. Source approvals, shared resources, attachments, Git operations, credentials, and provider transcripts were not inherited."
        let plan = RoutingPlan(
            id: id,
            interpretedGoal: handoff.bundle.requestedNextAction,
            routes: [ProjectRoute(
                projectID: assignment.projectID,
                providerID: assignment.providerID,
                agentIDs: [assignment.agentID],
                providerBindings: [ProviderRouteBinding(
                    agentID: assignment.agentID,
                    bindingID: destinationBinding.id
                )],
                reason: "Manual continuation through the reviewed handoff path \(handoff.bundle.linkID.rawValue)."
            )],
            risk: .readOnly,
            confidence: 1,
            warnings: [warning]
        )
        return RunRecord(
            id: id,
            plan: plan,
            status: .ready,
            assignments: [assignment],
            agentSnapshot: [destinationAgent],
            providerBindingSnapshot: [destinationBinding],
            projectSnapshot: [destinationProject],
            journal: [
                RunJournalEntry(
                    kind: .created,
                    message: "Created an isolated read-only run from reviewed handoff \(handoff.id.rawValue)."
                ),
                RunJournalEntry(
                    kind: .assignmentChanged,
                    message: "Queued reviewed handoff to \(destinationAgent.name) on \(assignment.providerID.displayName).",
                    assignmentID: assignment.id
                ),
            ]
        )
    }
}

public enum HandoffBundleIntegrity {
    public static func isValid(_ bundle: HandoffBundle) -> Bool {
        constantTimeEquals(bundle.integrityHash, digest(material(for: bundle)))
    }

    static func idempotencyKey(
        runID: RunID,
        linkID: AgentHandoffLinkID,
        sourceAssignmentID: AssignmentID,
        trigger: HandoffTrigger,
        parentHandoffID: HandoffID?,
        depth: Int
    ) -> String {
        digest(Data([
            runID.rawValue,
            linkID.rawValue,
            sourceAssignmentID.rawValue,
            trigger.rawValue,
            parentHandoffID?.rawValue ?? "root",
            String(depth),
        ].joined(separator: "\u{1f}").utf8))
    }

    static func seal(_ bundle: HandoffBundle) -> HandoffBundle {
        HandoffBundle(
            id: bundle.id,
            idempotencyKey: bundle.idempotencyKey,
            runID: bundle.runID,
            linkID: bundle.linkID,
            createdAt: bundle.createdAt,
            source: bundle.source,
            destination: bundle.destination,
            originalGoal: bundle.originalGoal,
            purpose: bundle.purpose,
            sourceOutcomeSummary: bundle.sourceOutcomeSummary,
            sourceTrigger: bundle.sourceTrigger,
            completedSteps: bundle.completedSteps,
            unresolvedWork: bundle.unresolvedWork,
            knownRisks: bundle.knownRisks,
            requestedNextAction: bundle.requestedNextAction,
            artifacts: bundle.artifacts,
            changedFiles: bundle.changedFiles,
            patchOrCommitReference: bundle.patchOrCommitReference,
            workingCopyIdentity: bundle.workingCopyIdentity,
            verificationEvidence: bundle.verificationEvidence,
            resources: bundle.resources,
            sourceAssignmentID: bundle.sourceAssignmentID,
            sourceTaskIdentity: bundle.sourceTaskIdentity,
            parentHandoffID: bundle.parentHandoffID,
            depth: bundle.depth,
            integrityHash: digest(material(for: bundle))
        )
    }

    private static func material(for bundle: HandoffBundle) -> Data {
        let material = HandoffIntegrityMaterial(bundle: bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(material)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct HandoffIntegrityMaterial: Codable {
    let idempotencyKey: String
    let runID: RunID
    let linkID: AgentHandoffLinkID
    let source: AgentHandoffEndpoint
    let destination: AgentHandoffEndpoint
    let originalGoal: String
    let purpose: String
    let sourceOutcomeSummary: String
    let sourceTrigger: HandoffTrigger
    let completedSteps: [String]
    let unresolvedWork: [String]
    let knownRisks: [String]
    let requestedNextAction: String
    let artifacts: [HandoffArtifactReference]
    let changedFiles: [String]
    let patchOrCommitReference: String?
    let workingCopyIdentity: String?
    let verificationEvidence: [HandoffVerificationEvidence]
    let resources: [HandoffResourceDescriptor]
    let sourceAssignmentID: AssignmentID?
    let sourceTaskIdentity: ProviderTaskIdentity?
    let parentHandoffID: HandoffID?
    let depth: Int

    init(bundle: HandoffBundle) {
        idempotencyKey = bundle.idempotencyKey
        runID = bundle.runID
        linkID = bundle.linkID
        source = bundle.source
        destination = bundle.destination
        originalGoal = bundle.originalGoal
        purpose = bundle.purpose
        sourceOutcomeSummary = bundle.sourceOutcomeSummary
        sourceTrigger = bundle.sourceTrigger
        completedSteps = bundle.completedSteps
        unresolvedWork = bundle.unresolvedWork
        knownRisks = bundle.knownRisks
        requestedNextAction = bundle.requestedNextAction
        artifacts = bundle.artifacts
        changedFiles = bundle.changedFiles
        patchOrCommitReference = bundle.patchOrCommitReference
        workingCopyIdentity = bundle.workingCopyIdentity
        verificationEvidence = bundle.verificationEvidence
        resources = bundle.resources
        sourceAssignmentID = bundle.sourceAssignmentID
        sourceTaskIdentity = bundle.sourceTaskIdentity
        parentHandoffID = bundle.parentHandoffID
        depth = bundle.depth
    }
}

private struct SanitizedHandoffInput {
    let sourceOutcomeSummary: String
    let completedSteps: [String]
    let unresolvedWork: [String]
    let knownRisks: [String]
    let requestedNextAction: String
    let artifacts: [HandoffArtifactReference]
    let changedFiles: [String]
    let patchOrCommitReference: String?
    let workingCopyIdentity: String?
    let verificationEvidence: [HandoffVerificationEvidence]
}

private enum HandoffBundleSanitizer {
    static func sanitize(
        _ request: PrepareManualHandoffRequest,
        exactForbiddenValues: [String]
    ) -> SanitizedHandoffInput {
        SanitizedHandoffInput(
            sourceOutcomeSummary: text(request.sourceOutcomeSummary, exactForbiddenValues: exactForbiddenValues, limit: 8_000),
            completedSteps: list(request.completedSteps, exactForbiddenValues: exactForbiddenValues),
            unresolvedWork: list(request.unresolvedWork, exactForbiddenValues: exactForbiddenValues),
            knownRisks: list(request.knownRisks, exactForbiddenValues: exactForbiddenValues),
            requestedNextAction: text(request.requestedNextAction, exactForbiddenValues: exactForbiddenValues, limit: 4_000),
            artifacts: Array(request.artifacts.prefix(100)).map { artifact in
                HandoffArtifactReference(
                    id: text(artifact.id, exactForbiddenValues: exactForbiddenValues, limit: 160),
                    kind: artifact.kind,
                    name: text(artifact.name, exactForbiddenValues: exactForbiddenValues, limit: 240),
                    url: sanitizedURL(artifact.url, exactForbiddenValues: exactForbiddenValues),
                    contentHash: artifact.contentHash.map { text($0, exactForbiddenValues: exactForbiddenValues, limit: 256) }
                )
            },
            changedFiles: Array(request.changedFiles.prefix(500)).compactMap {
                sanitizedRelativePath($0, exactForbiddenValues: exactForbiddenValues)
            },
            patchOrCommitReference: request.patchOrCommitReference.map {
                text($0, exactForbiddenValues: exactForbiddenValues, limit: 1_000)
            },
            workingCopyIdentity: request.workingCopyIdentity.flatMap {
                sanitizedWorkingCopyIdentity($0, exactForbiddenValues: exactForbiddenValues)
            },
            verificationEvidence: Array(request.verificationEvidence.prefix(200)).map { evidence in
                HandoffVerificationEvidence(
                    id: text(evidence.id, exactForbiddenValues: exactForbiddenValues, limit: 160),
                    command: text(evidence.command, exactForbiddenValues: exactForbiddenValues, limit: 2_000),
                    status: text(evidence.status, exactForbiddenValues: exactForbiddenValues, limit: 160),
                    exitCode: evidence.exitCode,
                    source: text(evidence.source, exactForbiddenValues: exactForbiddenValues, limit: 160)
                )
            }
        )
    }

    static func text(
        _ value: String,
        exactForbiddenValues: [String] = [],
        limit: Int
    ) -> String {
        SensitiveTextRedactor.redact(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            exactForbiddenValues: exactForbiddenValues,
            limit: limit
        )
    }

    private static func list(
        _ values: [String],
        exactForbiddenValues: [String],
        itemLimit: Int = 100,
        textLimit: Int = 2_000
    ) -> [String] {
        Array(values.prefix(itemLimit))
            .map { text($0, exactForbiddenValues: exactForbiddenValues, limit: textLimit) }
            .filter { !$0.isEmpty }
    }

    private static func sanitizedURL(
        _ url: URL?,
        exactForbiddenValues: [String]
    ) -> URL? {
        guard let url else { return nil }
        guard !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let relativePath = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path
        let safePath = SensitiveTextRedactor.redact(
            relativePath,
            exactForbiddenValues: exactForbiddenValues,
            limit: 1_000
        )
        guard !safePath.contains("[redacted") else { return nil }
        components.path = components.path.hasPrefix("/") ? "/\(safePath)" : safePath
        return components.url
    }

    private static func sanitizedRelativePath(
        _ value: String,
        exactForbiddenValues: [String]
    ) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= 1_000,
              !candidate.hasPrefix("/"),
              !candidate.hasPrefix("~"),
              !candidate.contains("\\"),
              URL(string: candidate)?.scheme == nil else { return nil }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let result = text(candidate, exactForbiddenValues: exactForbiddenValues, limit: 1_000)
        return result.contains("[redacted") ? nil : result
    }

    private static func sanitizedWorkingCopyIdentity(
        _ value: String,
        exactForbiddenValues: [String]
    ) -> String? {
        let candidate = text(value, exactForbiddenValues: exactForbiddenValues, limit: 160)
        guard !candidate.isEmpty,
              !candidate.contains("/"),
              !candidate.contains("\\"),
              candidate != ".",
              candidate != "..",
              !candidate.contains("[redacted") else { return nil }
        return candidate
    }
}

private enum HandoffPromptRenderer {
    static func render(_ bundle: HandoffBundle) -> String {
        var sections = [
            "Continue reviewed work from \(bundle.source.providerID.displayName).",
            "Original goal: \(bundle.originalGoal)",
            "Handoff purpose: \(bundle.purpose)",
            "Source outcome: \(bundle.sourceOutcomeSummary)",
            "Requested next action: \(bundle.requestedNextAction)",
        ]
        append("Completed steps", bundle.completedSteps, to: &sections)
        append("Unresolved work", bundle.unresolvedWork, to: &sections)
        append("Known risks", bundle.knownRisks, to: &sections)
        append("Changed files", bundle.changedFiles, to: &sections)
        if let reference = bundle.patchOrCommitReference {
            sections.append("Patch or commit reference: \(reference)")
        }
        if !bundle.verificationEvidence.isEmpty {
            sections.append("Verification evidence:\n" + bundle.verificationEvidence.map {
                "- \($0.command): \($0.status)" + ($0.exitCode.map { " (exit \($0))" } ?? "")
            }.joined(separator: "\n"))
        }
        sections.append("Handoff integrity: \(bundle.integrityHash)")
        return sections.joined(separator: "\n\n")
    }

    private static func append(_ title: String, _ values: [String], to sections: inout [String]) {
        guard !values.isEmpty else { return }
        sections.append("\(title):\n" + values.map { "- \($0)" }.joined(separator: "\n"))
    }
}
