import CryptoKit
import Foundation
import Synchronization

public struct GADCommandEffect: Sendable {
    public let changes: [GADStateChange]
    public let artifact: GADCommandArtifact?

    public init(changes: [GADStateChange] = [], artifact: GADCommandArtifact? = nil) {
        self.changes = changes
        self.artifact = artifact
    }
}

public struct GADCommandFailure: LocalizedError, Sendable {
    public let disposition: GADCommandDisposition
    public let message: String

    public var errorDescription: String? { message }

    public init(_ disposition: GADCommandDisposition, _ message: String) {
        self.disposition = disposition
        self.message = message
    }
}

public protocol GADCommandHandling: Sendable {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect
}

public actor ProjectionGADCommandHandler: GADCommandHandling {
    public init() {}

    public func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        switch payload {
        case let .replaceDraft(replacement):
            guard replacement.expectedRevision == projection.draft.revision else {
                throw GADCommandFailure(.rejectedStale, "The shared draft changed on another device.")
            }
            let draft = GADDraftProjection(
                revision: projection.draft.revision.advanced(),
                text: String(replacement.text.prefix(32_000)),
                attachments: replacement.attachments.prefix(12).map(GADDraftAttachmentProjection.init),
                providerID: replacement.providerID,
                model: replacement.model,
                platform: replacement.platform,
                projectIDs: replacement.projectIDs,
                agentTargets: replacement.agentTargets,
                groupID: replacement.groupID
            )
            return GADCommandEffect(changes: [.draft(draft)])
        default:
            throw GADCommandFailure(.rejectedCapability, "This command requires a host application adapter.")
        }
    }
}

public actor GADCoordinator {
    private final class Subscriber: Sendable {
        private struct State {
            var buffered: [GADStateDelta]
            var waiters: [CheckedContinuation<GADStateDelta?, Never>] = []
            var isFinished = false
        }

        let deviceID: DeviceID
        private let capacity: Int
        private let state: Mutex<State>

        init(deviceID: DeviceID, initialDeltas: [GADStateDelta], capacity: Int) {
            self.deviceID = deviceID
            self.capacity = capacity
            state = Mutex(State(buffered: Array(initialDeltas.suffix(capacity))))
        }

        func next() async -> GADStateDelta? {
            await withCheckedContinuation { continuation in
                var immediate: GADStateDelta?
                let shouldResume = state.withLock { state in
                    if state.isFinished {
                        return true
                    }
                    if !state.buffered.isEmpty {
                        immediate = state.buffered.removeFirst()
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume(returning: immediate)
                }
            }
        }

        func yield(_ delta: GADStateDelta) {
            var waiter: CheckedContinuation<GADStateDelta?, Never>?
            state.withLock { state in
                guard !state.isFinished else { return }
                if !state.waiters.isEmpty {
                    waiter = state.waiters.removeFirst()
                    return
                }
                state.buffered.append(delta)
                if state.buffered.count > capacity {
                    state.buffered.removeFirst(state.buffered.count - capacity)
                }
            }
            waiter?.resume(returning: delta)
        }

        func finish() {
            let waiters: [CheckedContinuation<GADStateDelta?, Never>] = state.withLock { state in
                guard !state.isFinished else { return [] }
                state.isFinished = true
                state.buffered.removeAll(keepingCapacity: false)
                let waiters = state.waiters
                state.waiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }
    }

    private struct IdempotencyRecord: Sendable {
        let commandID: CommandID
        let deviceID: DeviceID
        let hostEpoch: HostEpoch
        let baseRevision: StateRevision
        let payloadKind: String
        let commandDigest: String?
        let acknowledgement: GADCommandAcknowledgement
        let recordedAt: Date

        func matches(
            _ command: GADCommand,
            payloadKind: String,
            commandDigest: String
        ) -> Bool {
            commandID == command.id
                && deviceID == command.deviceID
                && hostEpoch == command.hostEpoch
                && baseRevision == command.baseRevision
                && self.payloadKind == payloadKind
                && self.commandDigest == commandDigest
        }
    }

    public let hostID: HostID
    public let hostEpoch: HostEpoch
    public let protocolVersion: GADProtocolVersion

    private let handler: any GADCommandHandling
    private let now: @Sendable () -> Date
    private let journalLimit: Int
    private let idempotencyLimit: Int
    private let persistCheckpoint: (@Sendable (GADCoordinatorCheckpoint) async throws -> Void)?
    private var projection: DashboardProjection
    private var capabilities: Set<GADCapability>
    private var authorizedDevices: Set<DeviceID>
    private var revocationDepth: [DeviceID: Int] = [:]
    private var journal: [GADStateDelta] = []
    private var journalByteSizes: [Int] = []
    private var journalBytes = 2
    private var idempotency: [String: IdempotencyRecord] = [:]
    private var inFlightIdempotencyKeys: Set<String> = []
    private var inFlightDeviceID: DeviceID?
    private var acceptsCommands = true
    private var commandDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UUID: Subscriber] = [:]
    private var lifecycleSubscribers: [
        UUID: (deviceID: DeviceID, continuation: AsyncStream<GobyClientLifecycleEvent>.Continuation)
    ] = [:]

    public init(
        hostID: HostID,
        hostEpoch: HostEpoch = .make(),
        protocolVersion: GADProtocolVersion = .current,
        initialProjection: DashboardProjection,
        capabilities: Set<GADCapability>,
        authorizedDevices: Set<DeviceID>,
        handler: any GADCommandHandling,
        journalLimit: Int = GADCoordinatorCheckpoint.maximumReplayJournalCount,
        idempotencyLimit: Int = 10_000,
        restoredCheckpoint: GADCoordinatorCheckpoint? = nil,
        persistCheckpoint: (@Sendable (GADCoordinatorCheckpoint) async throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        let restored = restoredCheckpoint.flatMap { checkpoint in
            checkpoint.hostID == hostID
                && checkpoint.protocolVersion.major == protocolVersion.major
                ? checkpoint
                : nil
        }
        self.hostID = hostID
        self.hostEpoch = restored?.hostEpoch ?? hostEpoch
        self.protocolVersion = protocolVersion
        self.projection = restored?.projection ?? initialProjection
        self.capabilities = capabilities
        self.authorizedDevices = authorizedDevices
        self.handler = handler
        self.journalLimit = min(max(1, journalLimit), GADCoordinatorCheckpoint.maximumReplayJournalCount)
        self.idempotencyLimit = max(1, idempotencyLimit)
        self.persistCheckpoint = persistCheckpoint
        self.now = now
        if let restored {
            let eligibleJournal = restored.journal.filter {
                $0.hostEpoch == restored.hostEpoch
                    && $0.revision <= restored.projection.revision
            }
            journal = GADCoordinatorCheckpoint.boundedReplayJournal(eligibleJournal, maximumCount: self.journalLimit)
            journalByteSizes = journal.map(GADCoordinatorCheckpoint.replayByteSize)
            journalBytes = 2 + journalByteSizes.reduce(0, +)
            idempotency = Dictionary(
                restored.idempotency.suffix(self.idempotencyLimit).map { entry in
                    (
                        entry.idempotencyKey,
                        IdempotencyRecord(
                            commandID: entry.commandID,
                            deviceID: entry.deviceID,
                            hostEpoch: entry.hostEpoch,
                            baseRevision: entry.baseRevision,
                            payloadKind: entry.payloadKind,
                            commandDigest: entry.commandDigest,
                            acknowledgement: Self.mobileSafeAcknowledgement(entry.acknowledgement),
                            recordedAt: entry.recordedAt
                        )
                    )
                },
                uniquingKeysWith: { _, latest in latest }
            )
        }
    }

    public func authorize(_ deviceID: DeviceID) {
        guard revocationDepth[deviceID] == nil else { return }
        authorizedDevices.insert(deviceID)
    }

    /// Removes new command authority immediately, then waits for the revoked
    /// device's one already-admitted semantic mutation to finish. Callers may
    /// publish revocation as complete only after this method returns.
    public func revoke(_ deviceID: DeviceID) async {
        await revoke(Set([deviceID]))
    }

    /// Removes a complete revocation set atomically before the first
    /// suspension, then drains the one globally admitted semantic command if
    /// its device belongs to that set.
    public func revoke(_ deviceIDs: Set<DeviceID>) async {
        for deviceID in deviceIDs {
            revocationDepth[deviceID, default: 0] += 1
        }
        defer {
            for deviceID in deviceIDs {
                guard let depth = revocationDepth[deviceID] else { continue }
                if depth == 1 {
                    revocationDepth.removeValue(forKey: deviceID)
                } else {
                    revocationDepth[deviceID] = depth - 1
                }
            }
        }
        authorizedDevices.subtract(deviceIDs)
        finishLifecycleSubscribers(for: deviceIDs, event: .revoked)
        finishSubscribers(for: deviceIDs)
        guard let inFlightDeviceID, deviceIDs.contains(inFlightDeviceID) else { return }
        await withCheckedContinuation { continuation in
            commandDrainWaiters.append(continuation)
        }
    }

    public func connect(deviceID: DeviceID) throws -> ClientSession {
        guard authorizedDevices.contains(deviceID) else {
            throw GADCommandFailure(.rejectedRevoked, "This device is not paired with the host.")
        }
        return ClientSession(
            hostID: hostID,
            hostEpoch: hostEpoch,
            protocolVersion: protocolVersion,
            revision: projection.revision,
            capabilities: capabilities.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func snapshot(deviceID: DeviceID) throws -> DashboardProjection {
        guard authorizedDevices.contains(deviceID) else {
            throw GADCommandFailure(.rejectedRevoked, "This device is not paired with the host.")
        }
        return projection
    }

    /// Host-internal read used to derive a section diff after local state
    /// changes. Remote clients must continue to use the device-authorized API.
    public func currentProjection() -> DashboardProjection {
        projection
    }

    /// Publishes state that changed on the authoritative host outside a remote
    /// command (for example streamed Codex progress or a local macOS action).
    /// The coordinator remains the only component allowed to assign revisions
    /// and journal/broadcast deltas.
    @discardableResult
    public func synchronize(_ authoritative: DashboardProjection) async -> StateRevision {
        let changes = projection.changes(replacingWith: authoritative)
        guard !changes.isEmpty else { return projection.revision }
        let timestamp = now()
        let revision = projection.revision.advanced()
        projection = projection.applying(changes, revision: revision, generatedAt: timestamp)
        appendAndBroadcast(GADStateDelta(
            hostEpoch: hostEpoch,
            revision: revision,
            occurredAt: timestamp,
            originatingCommandID: nil,
            changes: changes
        ))
        try? await persistCurrentCheckpoint()
        return revision
    }

    public func checkpoint() -> GADCoordinatorCheckpoint {
        makeCheckpoint(savedAt: now())
    }

    public func flushCheckpoint() async throws {
        try await persistCurrentCheckpoint()
    }

    /// Stops admitting new mutations and waits for every already-reserved
    /// command to finish. Reads and projection synchronization remain
    /// available while canonical store ownership is transferred.
    public func quiesceCommands() async {
        acceptsCommands = false
        guard !inFlightIdempotencyKeys.isEmpty else { return }
        await withCheckedContinuation { continuation in
            commandDrainWaiters.append(continuation)
        }
    }

    /// Reopens command admission after a failed host quiesce operation.
    public func resumeCommands() {
        acceptsCommands = true
    }

    public func send(_ command: GADCommand) async -> GADCommandAcknowledgement {
        let kind = payloadKind(command.payload)
        let digest = commandDigest(command)
        let timestamp = now()
        pruneExpiredIdempotency(at: timestamp)
        if let existing = idempotency[command.idempotencyKey] {
            if existing.matches(command, payloadKind: kind, commandDigest: digest) {
                return Self.mobileSafeAcknowledgement(existing.acknowledgement)
            }
            return acknowledgement(
                for: command,
                disposition: .rejectedPolicy,
                message: "The idempotency key was already used for a different command."
            )
        }

        guard acceptsCommands else {
            return acknowledgement(
                for: command,
                disposition: .failedRecoverable,
                message: "The host is quiescing for maintenance. Refresh after it finishes, then try again."
            )
        }

        let preflight = preflight(command, at: timestamp)
        if let preflight {
            if idempotency.count < idempotencyLimit {
                idempotency[command.idempotencyKey] = makeIdempotencyRecord(
                    command: command,
                    payloadKind: kind,
                    acknowledgement: preflight,
                    recordedAt: timestamp
                )
                try? await persistCurrentCheckpoint()
            }
            return preflight
        }

        // Command handlers cross actors and the main actor, so this actor is
        // reentrant while a mutation is being applied. Do not admit a second
        // semantic mutation against the same stale projection. Returning a
        // retryable result without reserving its key lets the client refresh
        // and submit it again after the first mutation has completed.
        guard inFlightIdempotencyKeys.isEmpty else {
            return acknowledgement(
                for: command,
                disposition: .failedRecoverable,
                message: "Another dashboard change is finishing. Refresh, then try this action again.",
                wasDeferredBeforeAdmission: true
            )
        }

        guard idempotency.count < idempotencyLimit else {
            return acknowledgement(
                for: command,
                disposition: .rejectedPolicy,
                message: "The host is retaining too many recent commands. Wait for the current command window to expire, then retry."
            )
        }

        // Reserve the idempotency key durably before invoking any adapter that
        // may mutate projects, runs, files or provider sessions. If the process
        // stops after this point, a retry returns indeterminate instead of
        // replaying the operation.
        let reservation = acknowledgement(
            for: command,
            disposition: .failedIndeterminate,
            message: "The prior host stopped after reserving this command; refresh canonical state before deciding what to do next."
        )
        idempotency[command.idempotencyKey] = makeIdempotencyRecord(
            command: command,
            payloadKind: kind,
            acknowledgement: reservation,
            recordedAt: timestamp
        )
        inFlightIdempotencyKeys.insert(command.idempotencyKey)
        inFlightDeviceID = command.deviceID
        defer {
            inFlightIdempotencyKeys.remove(command.idempotencyKey)
            inFlightDeviceID = nil
            if inFlightIdempotencyKeys.isEmpty, !commandDrainWaiters.isEmpty {
                let waiters = commandDrainWaiters
                commandDrainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            try await persistCurrentCheckpoint()
        } catch {
            let unavailable = acknowledgement(
                for: command,
                disposition: .failedRecoverable,
                message: "The host could not durably reserve this command, so it was not applied."
            )
            idempotency[command.idempotencyKey] = makeIdempotencyRecord(
                command: command,
                payloadKind: kind,
                acknowledgement: unavailable,
                recordedAt: timestamp
            )
            return unavailable
        }

        do {
            try validateApprovalIfNeeded(command.payload, at: timestamp)
            let effect = try await handler.apply(command.payload, to: projection, deviceID: command.deviceID)
            var revision = projection.revision
            if !effect.changes.isEmpty {
                revision = revision.advanced()
                projection = projection.applying(effect.changes, revision: revision, generatedAt: timestamp)
                let delta = GADStateDelta(
                    hostEpoch: hostEpoch,
                    revision: revision,
                    occurredAt: timestamp,
                    originatingCommandID: command.id,
                    changes: effect.changes
                )
                appendAndBroadcast(delta)
            }
            let accepted = GADCommandAcknowledgement(
                commandID: command.id,
                disposition: .accepted,
                revision: revision,
                artifact: effect.artifact
            )
            return await recordAndPersist(accepted, for: command)
        } catch let failure as GADCommandFailure {
            let rejected = acknowledgement(
                for: command,
                disposition: failure.disposition,
                message: SensitiveTextRedactor.redact(failure.message, limit: 600)
            )
            return await recordAndPersist(rejected, for: command)
        } catch {
            let failed = acknowledgement(for: command, disposition: .failedIndeterminate, message: "The host could not determine whether the operation completed.")
            return await recordAndPersist(failed, for: command)
        }
    }

    private static func mobileSafeAcknowledgement(
        _ acknowledgement: GADCommandAcknowledgement
    ) -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: acknowledgement.commandID,
            disposition: acknowledgement.disposition,
            revision: acknowledgement.revision,
            message: acknowledgement.message.map {
                SensitiveTextRedactor.redact($0, limit: 600)
            },
            artifact: acknowledgement.artifact,
            wasDeferredBeforeAdmission: acknowledgement.wasDeferredBeforeAdmission
        )
    }

    public func events(deviceID: DeviceID, after revision: StateRevision) -> AsyncStream<GADStateDelta> {
        guard authorizedDevices.contains(deviceID) else {
            return AsyncStream { $0.finish() }
        }

        let initialDeltas: [GADStateDelta]
        if requiresReplaySnapshot(after: revision) {
            initialDeltas = [resyncDelta()]
        } else {
            initialDeltas = journal.filter { $0.revision > revision }
        }
        let subscriberID = UUID()
        let subscriber = Subscriber(
            deviceID: deviceID,
            initialDeltas: initialDeltas,
            capacity: 500
        )
        subscribers[subscriberID] = subscriber
        return AsyncStream(
            unfolding: { await subscriber.next() },
            onCancel: { [weak self] in
                subscriber.finish()
                Task { await self?.removeSubscriber(subscriberID) }
            }
        )
    }

    public func lifecycleEvents(deviceID: DeviceID) -> AsyncStream<GobyClientLifecycleEvent> {
        let pair = AsyncStream<GobyClientLifecycleEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        guard authorizedDevices.contains(deviceID) else {
            pair.continuation.yield(.revoked)
            pair.continuation.finish()
            return pair.stream
        }
        let subscriberID = UUID()
        lifecycleSubscribers[subscriberID] = (deviceID, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLifecycleSubscriber(subscriberID) }
        }
        return pair.stream
    }

    /// Returns a bounded journal batch for request/reply transports such as
    /// local XPC. Remote streaming clients continue to use `events`.
    public func replay(
        deviceID: DeviceID,
        after revision: StateRevision,
        maximumCount: Int
    ) throws -> [GADStateDelta] {
        guard authorizedDevices.contains(deviceID) else {
            throw GADCommandFailure(.rejectedRevoked, "This device is not paired with the host.")
        }
        let limit = min(max(maximumCount, 1), GADHostIPCEventRequest.maximumEventCount)
        if requiresReplaySnapshot(after: revision) {
            return [resyncDelta()]
        }
        return Array(journal.lazy.filter { $0.revision > revision }.prefix(limit))
    }

    /// A large individual journal entry can exceed the local IPC reply limit.
    /// Let the local transport replace it with one current-state delta without
    /// replaying or dropping any command.
    public func replaySnapshot(deviceID: DeviceID) throws -> GADStateDelta {
        guard authorizedDevices.contains(deviceID) else {
            throw GADCommandFailure(.rejectedRevoked, "This device is not paired with the host.")
        }
        return resyncDelta()
    }

    private func preflight(_ command: GADCommand, at timestamp: Date) -> GADCommandAcknowledgement? {
        guard !command.idempotencyKey.isEmpty, command.idempotencyKey.count <= 128 else {
            return acknowledgement(for: command, disposition: .rejectedPolicy, message: "Invalid idempotency key.")
        }
        guard authorizedDevices.contains(command.deviceID) else {
            return acknowledgement(for: command, disposition: .rejectedRevoked, message: "This device is not paired with the host.")
        }
        guard command.hostEpoch == hostEpoch else {
            return acknowledgement(for: command, disposition: .rejectedStale, message: "The host restarted; refresh before retrying.")
        }
        guard command.issuedAt <= command.expiresAt, timestamp <= command.expiresAt else {
            return acknowledgement(for: command, disposition: .rejectedExpired, message: "This command expired.")
        }
        guard command.issuedAt <= timestamp.addingTimeInterval(30),
              command.expiresAt.timeIntervalSince(command.issuedAt) <= 120 else {
            return acknowledgement(
                for: command,
                disposition: .rejectedExpired,
                message: "This command has an invalid time window. Check device time and refresh."
            )
        }
        if command.payload.requiresExactBaseRevision,
           command.baseRevision != projection.revision,
           !allowsUnrelatedRevisionAdvanceForPlanStart(command) {
            return acknowledgement(for: command, disposition: .rejectedStale, message: "Canonical state changed; review the refreshed scope.")
        }
        if let required = requiredCapability(for: command.payload), !capabilities.contains(required) {
            return acknowledgement(for: command, disposition: .rejectedCapability, message: "The host does not support this operation.")
        }
        return nil
    }

    /// Starting a reviewed plan is safe after unrelated activity updates only
    /// when the complete journal since the client's revision proves that no
    /// request, scope, resource, or provider binding changed. A gap fails closed.
    private func allowsUnrelatedRevisionAdvanceForPlanStart(_ command: GADCommand) -> Bool {
        guard case .startRun = command.payload,
              command.baseRevision < projection.revision,
              !requiresReplaySnapshot(after: command.baseRevision) else { return false }
        return journal.lazy.filter { $0.revision > command.baseRevision }.allSatisfy { delta in
            delta.changes.allSatisfy { change in
                switch change {
                case .host, .runs, .automations, .approvals, .codexTasks,
                     .account, .providerAccounts, .providerTasks, .health:
                    true
                case .draft, .projects, .agents, .projectGroups, .resources,
                     .instructions, .plan, .providerBindings, .handoffLinks, .handoffs:
                    false
                }
            }
        }
    }

    private func validateApprovalIfNeeded(_ payload: GADCommandPayload, at timestamp: Date) throws {
        if case let .saveAutomation(mutation) = payload,
           mutation.automation.automaticallyApproveRuntimeRequests {
            guard mutation.authorizationAssertion?.isEmpty == false else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "Local authentication is required to allow automatic automation approvals."
                )
            }
        }
        if case let .reviewAndRunAutomationOccurrence(review) = payload {
            guard let occurrence = projection.automations.occurrences.first(where: { $0.id == review.id }),
                  let plan = occurrence.currentReviewAttempt?.plan else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation action is no longer waiting for review."
                )
            }
            guard let binding = review.reviewBinding,
                  occurrence.currentReviewBinding == binding else {
                throw GADCommandFailure(.rejectedStale,
                    "This automation review changed or came from an older app. Update if needed, then reopen the current action review.")
            }
            if plan.risk >= .medium || !plan.gitOperations.isEmpty {
                guard review.authorizationAssertion?.isEmpty == false else {
                    throw GADCommandFailure(
                        .rejectedPolicy,
                        "Local authentication is required for this automation action."
                    )
                }
            }
            let requestedResourceIDs = Set(review.selectedResourceIDs)
            let enabledResourceIDs = Set(
                projection.resources.lazy.filter(\.isEnabled).map(\.id)
            )
            guard review.selectedResourceIDs.count == requestedResourceIDs.count,
                  requestedResourceIDs.isSubset(of: enabledResourceIDs) else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "The selected shared-folder scope changed. Review this automation action again."
                )
            }
            return
        }
        if case let .startRun(approval) = payload {
            guard let plan = projection.plan, plan.id == approval.planID else {
                throw GADCommandFailure(.rejectedStale, "This plan changed; review the refreshed scope.")
            }
            // A plan the host marked as a trusted start was already checked
            // against the owner's trusted projects and the isolation boundary.
            let trustedStart = plan.startsWithoutReview == true && !approval.automaticallyApproveRuntimeRequests
            if (plan.risk >= .medium || !plan.gitOperations.isEmpty || approval.automaticallyApproveRuntimeRequests),
               !trustedStart {
                guard approval.authorizationAssertion?.isEmpty == false else {
                    throw GADCommandFailure(.rejectedPolicy, "Local authentication is required for this plan.")
                }
            }
            return
        }

        guard case let .respondToApproval(response) = payload else { return }
        guard let approval = projection.approvals.first(where: { $0.id == response.approvalID }),
              approval.runID == response.runID,
              approval.assignmentID == response.assignmentID else {
            throw GADCommandFailure(.rejectedStale, "This approval is no longer pending.")
        }
        guard approval.expiresAt >= timestamp, approval.actions.contains(response.action) else {
            throw GADCommandFailure(.rejectedPolicy, "This approval action is unavailable or expired.")
        }
        if response.action == .allowOnce || response.action == .allowForRun {
            guard response.authorizationAssertion?.isEmpty == false else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    response.action == .allowForRun
                        ? "Local authentication is required for a run-wide approval."
                        : "Local authentication is required for this approval."
                )
            }
        }
        if response.action == .allowForRun {
            guard let currentSession = approval.approvalSessionID,
                  currentSession == response.approvalSessionID else {
                throw GADCommandFailure(.rejectedStale, "The agent session changed; review the new approval.")
            }
        }
    }

    private func requiredCapability(for payload: GADCommandPayload) -> GADCapability? {
        switch payload {
        case .replaceDraft, .beginPromptAttachmentUpload, .appendPromptAttachmentUpload,
             .commitPromptAttachmentUpload, .cancelPromptAttachmentUpload:
            .sharedDraft
        case .preparePlan, .updatePlan, .cancelPlan, .startRun: .planReview
        case .controlRun, .reuseRequest: .runControl
        case .rememberedApprovals, .requestApprovalDisclosure: .runtimeApprovalOnce
        case let .respondToApproval(response): response.action == .allowForRun ? .runtimeApprovalRun : .runtimeApprovalOnce
        case .followUp: .activeRunFollowUp
        // Asking uses the provider on the Mac like preparing a plan does, but
        // changes no work state and has no project, file or command access.
        case .askTemporaryChat, .endTemporaryChat: .planReview
        case .refreshProviders, .refreshProviderActivity: .providerActivity
        case .dispatchManualHandoff: .manualHandoffs
        case .refreshCodex: .codexRefresh
        case .saveProjectGroup, .deleteProjectGroup: .projectGroups
        case .setProjectTrust: .hostAdminProjects
        case .requestInstructionEditor, .saveInstruction: .instructionPacks
        case .requestProviderBindingInstructionEditor, .saveProviderBindingInstructions:
            .providerBindingInstructions
        case .requestCodexCatalogDiscovery: .hostAdminProjects
        case .requestAgentCatalogDiscovery: .hostAdminAgents
        case .requestProjectGitBranches: .projectGitBranches
        case let .requestHostAdminPreview(request): capability(for: request)
        case .commitHostAdmin: nil
        case .updateNotificationRegistration: .notifications
        case .revokeCurrentDevice: .deviceSelfRevocation
        case .saveAutomation, .setAutomationState, .deleteAutomation, .runAutomationNow,
             .runAutomationNowChecked,
             .reviewAndRunAutomationOccurrence, .cancelAutomationOccurrence:
            .automations
        }
    }

    private func capability(for request: GADHostAdminRequest) -> GADCapability {
        switch request {
        case .createProject, .removeProject, .syncCodexCatalog: .hostAdminProjects
        case .importAgents, .saveAgent, .createTemporaryAgent, .retireTemporaryAgent,
             .addMissingAutomationAgents, .setAgentEnabled, .publishAgent, .deleteAgent,
             .restoreLastDeletedAgent, .restructureAgents, .undoLastAgentRestructure: .hostAdminAgents
        case .setResourceAccess: .hostAdminResources
        case .switchProjectBranch: .projectGitBranches
        case .exportRedactedDiagnostics: .redactedDiagnostics
        }
    }

    private func acknowledgement(
        for command: GADCommand,
        disposition: GADCommandDisposition,
        message: String,
        wasDeferredBeforeAdmission: Bool? = nil
    ) -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: command.id,
            disposition: disposition,
            revision: projection.revision,
            message: message,
            wasDeferredBeforeAdmission: wasDeferredBeforeAdmission
        )
    }

    private func appendAndBroadcast(_ delta: GADStateDelta) {
        let size = GADCoordinatorCheckpoint.replayByteSize(delta)
        journal.append(delta)
        journalByteSizes.append(size)
        journalBytes += size
        while journal.count > journalLimit || journalBytes > GADCoordinatorCheckpoint.maximumReplayJournalBytes {
            journal.removeFirst()
            journalBytes -= journalByteSizes.removeFirst()
        }
        for subscriber in subscribers.values { subscriber.yield(delta) }
    }

    private func requiresReplaySnapshot(after revision: StateRevision) -> Bool {
        guard revision < projection.revision else { return false }
        guard let earliest = journal.first?.revision else { return true }
        return revision.advanced() < earliest
    }

    private func pruneExpiredIdempotency(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-600)
        idempotency = idempotency.filter { key, record in
            inFlightIdempotencyKeys.contains(key) || record.recordedAt >= cutoff
        }
    }

    private func recordAndPersist(
        _ result: GADCommandAcknowledgement,
        for command: GADCommand
    ) async -> GADCommandAcknowledgement {
        idempotency[command.idempotencyKey] = makeIdempotencyRecord(
            command: command,
            payloadKind: payloadKind(command.payload),
            acknowledgement: result,
            recordedAt: now()
        )
        do {
            try await persistCurrentCheckpoint()
            return result
        } catch {
            let indeterminate = acknowledgement(
                for: command,
                disposition: .failedIndeterminate,
                message: "The operation may have completed, but the host could not persist its acknowledgement. Refresh before taking another action."
            )
            idempotency[command.idempotencyKey] = makeIdempotencyRecord(
                command: command,
                payloadKind: payloadKind(command.payload),
                acknowledgement: indeterminate,
                recordedAt: now()
            )
            try? await persistCurrentCheckpoint()
            return indeterminate
        }
    }

    private func makeIdempotencyRecord(
        command: GADCommand,
        payloadKind: String,
        acknowledgement: GADCommandAcknowledgement,
        recordedAt: Date
    ) -> IdempotencyRecord {
        IdempotencyRecord(
            commandID: command.id,
            deviceID: command.deviceID,
            hostEpoch: command.hostEpoch,
            baseRevision: command.baseRevision,
            payloadKind: payloadKind,
            commandDigest: commandDigest(command),
            acknowledgement: acknowledgement,
            recordedAt: recordedAt
        )
    }

    private func durableAcknowledgement(
        _ acknowledgement: GADCommandAcknowledgement
    ) -> GADCommandAcknowledgement {
        guard let artifact = acknowledgement.artifact else { return acknowledgement }
        if case .operationReceipt = artifact { return acknowledgement }
        return GADCommandAcknowledgement(
            commandID: acknowledgement.commandID,
            disposition: .failedRecoverable,
            revision: acknowledgement.revision,
            message: "This transient result was not retained across a host restart. Refresh and request it again."
        )
    }

    private func payloadKind(_ payload: GADCommandPayload) -> String {
        switch payload {
        case .replaceDraft: "replaceDraft"
        case .beginPromptAttachmentUpload: "beginPromptAttachmentUpload"
        case .appendPromptAttachmentUpload: "appendPromptAttachmentUpload"
        case .commitPromptAttachmentUpload: "commitPromptAttachmentUpload"
        case .cancelPromptAttachmentUpload: "cancelPromptAttachmentUpload"
        case .preparePlan: "preparePlan"
        case .updatePlan: "updatePlan"
        case .cancelPlan: "cancelPlan"
        case .startRun: "startRun"
        case .controlRun: "controlRun"
        case .reuseRequest: "reuseRequest"
        case .rememberedApprovals: "rememberedApprovals"
        case .requestApprovalDisclosure: "requestApprovalDisclosure"
        case .respondToApproval: "respondToApproval"
        case .followUp: "followUp"
        case .askTemporaryChat: "askTemporaryChat"
        case .endTemporaryChat: "endTemporaryChat"
        case .refreshProviders: "refreshProviders"
        case .refreshProviderActivity: "refreshProviderActivity"
        case .dispatchManualHandoff: "dispatchManualHandoff"
        case .refreshCodex: "refreshCodex"
        case .saveProjectGroup: "saveProjectGroup"
        case .setProjectTrust: "setProjectTrust"
        case .deleteProjectGroup: "deleteProjectGroup"
        case .requestInstructionEditor: "requestInstructionEditor"
        case .saveInstruction: "saveInstruction"
        case .requestProviderBindingInstructionEditor: "requestProviderBindingInstructionEditor"
        case .saveProviderBindingInstructions: "saveProviderBindingInstructions"
        case .requestCodexCatalogDiscovery: "requestCodexCatalogDiscovery"
        case .requestAgentCatalogDiscovery: "requestAgentCatalogDiscovery"
        case .requestProjectGitBranches: "requestProjectGitBranches"
        case .requestHostAdminPreview: "requestHostAdminPreview"
        case .commitHostAdmin: "commitHostAdmin"
        case .updateNotificationRegistration: "updateNotificationRegistration"
        case .saveAutomation: "saveAutomation"
        case .setAutomationState: "setAutomationState"
        case .deleteAutomation: "deleteAutomation"
        case .runAutomationNow: "runAutomationNow"
        case .runAutomationNowChecked: "runAutomationNowChecked"
        case .reviewAndRunAutomationOccurrence: "reviewAndRunAutomationOccurrence"
        case .cancelAutomationOccurrence: "cancelAutomationOccurrence"
        case .revokeCurrentDevice: "revokeCurrentDevice"
        }
    }

    private func commandDigest(_ command: GADCommand) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        let encoded = (try? encoder.encode(command)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private func persistCurrentCheckpoint() async throws {
        guard let persistCheckpoint else { return }
        try await persistCheckpoint(makeCheckpoint(savedAt: now()))
    }

    private func makeCheckpoint(savedAt: Date) -> GADCoordinatorCheckpoint {
        let entries = idempotency
            .sorted { lhs, rhs in
                if lhs.value.recordedAt == rhs.value.recordedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.recordedAt < rhs.value.recordedAt
            }
            .suffix(idempotencyLimit)
            .map { key, record in
                GADCoordinatorIdempotencyCheckpoint(
                    idempotencyKey: key,
                    commandID: record.commandID,
                    deviceID: record.deviceID,
                    hostEpoch: record.hostEpoch,
                    baseRevision: record.baseRevision,
                    payloadKind: record.payloadKind,
                    commandDigest: record.commandDigest,
                    acknowledgement: durableAcknowledgement(record.acknowledgement),
                    recordedAt: record.recordedAt
                )
            }
        return GADCoordinatorCheckpoint(
            hostID: hostID,
            hostEpoch: hostEpoch,
            protocolVersion: protocolVersion,
            projection: projection,
            journal: journal,
            idempotency: Array(entries),
            savedAt: savedAt
        )
    }

    private func resyncDelta() -> GADStateDelta {
        GADStateDelta(
            hostEpoch: hostEpoch,
            revision: projection.revision,
            occurredAt: now(),
            originatingCommandID: nil,
            changes: [
                .host(projection.host), .draft(projection.draft), .projects(projection.projects),
                .agents(projection.agents), .projectGroups(projection.projectGroups), .resources(projection.resources),
                .instructions(projection.instructions),
                .plan(projection.plan), .runs(projection.runs), .approvals(projection.approvals), .codexTasks(projection.codexTasks),
                .account(projection.account), .providerAccounts(projection.providerAccounts),
                .providerTasks(projection.providerTasks), .providerBindings(projection.providerBindings),
                .handoffLinks(projection.handoffLinks), .handoffs(projection.handoffs),
                .automations(projection.automations), .health(projection.health)
            ],
            isResyncSnapshot: true
        )
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    private func removeLifecycleSubscriber(_ id: UUID) {
        lifecycleSubscribers.removeValue(forKey: id)?.continuation.finish()
    }

    private func finishSubscribers(for deviceIDs: Set<DeviceID>) {
        let matchingIDs = subscribers.compactMap { id, subscriber in
            deviceIDs.contains(subscriber.deviceID) ? id : nil
        }
        for id in matchingIDs {
            subscribers.removeValue(forKey: id)?.finish()
        }
    }

    private func finishLifecycleSubscribers(
        for deviceIDs: Set<DeviceID>,
        event: GobyClientLifecycleEvent
    ) {
        let matchingIDs = lifecycleSubscribers.compactMap { id, subscriber in
            deviceIDs.contains(subscriber.deviceID) ? id : nil
        }
        for id in matchingIDs {
            guard let subscriber = lifecycleSubscribers.removeValue(forKey: id) else { continue }
            subscriber.continuation.yield(event)
            subscriber.continuation.finish()
        }
    }
}

public actor LocalGobyClient: GobyClient {
    private let coordinator: GADCoordinator
    private let deviceID: DeviceID

    public init(coordinator: GADCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
    }

    public func connect() async throws -> ClientSession {
        try await coordinator.connect(deviceID: deviceID)
    }

    public func snapshot() async throws -> DashboardProjection {
        try await coordinator.snapshot(deviceID: deviceID)
    }

    public func send(_ command: GADCommand) async -> GADCommandAcknowledgement {
        await coordinator.send(command)
    }

    public func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        await coordinator.events(deviceID: deviceID, after: revision)
    }

    public func lifecycleEvents() async -> AsyncStream<GobyClientLifecycleEvent> {
        await coordinator.lifecycleEvents(deviceID: deviceID)
    }

    public func disconnect() async {}
}
