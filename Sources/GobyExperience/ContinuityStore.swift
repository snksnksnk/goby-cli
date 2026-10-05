import Foundation
import Observation
import GobyApplication
import GobyDomain

public enum GADClientConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case live
    case stale(lastSuccessfulAt: Date?)
    case incompatible
    case revoked
    case failed(String)
}

public enum GADDraftSyncPhase: Equatable, Sendable {
    case synced
    case locallyModified
    case syncing
    case conflict(canonicalText: String)
    case failed(String)
}

@MainActor
@Observable
public final class ContinuityStore {
    public private(set) var connectionPhase: GADClientConnectionPhase = .disconnected {
        didSet { scheduleReconnectionIfNeeded() }
    }
    public private(set) var session: ClientSession?
    public private(set) var projection: DashboardProjection?
    public private(set) var draftText = ""
    public private(set) var draftAttachments: [PromptAttachment] = []
    public private(set) var draftSyncPhase: GADDraftSyncPhase = .synced
    public private(set) var lastAcknowledgement: GADCommandAcknowledgement?
    public private(set) var lastClientErrorMessage: String?
    /// True when the running app's signed bundle was replaced on disk. Every
    /// retry would be rejected by code-signing checks, so automatic
    /// reconnection stops and the native shell relaunches the new bundle.
    public private(set) var requiresApplicationRelaunch = false

    public var isRecoveringConnection: Bool {
        guard !hasBeenRevoked else { return false }
        switch connectionPhase {
        case .connecting: return true
        case .stale, .failed: return reconnectTaskID != nil
        default: return false
        }
    }

    @ObservationIgnored private let client: any GobyClient
    @ObservationIgnored private let cache: (any GADProjectionCaching)?
    @ObservationIgnored private let draftCache: (any GADLocalDraftCaching)?
    @ObservationIgnored private let deviceID: DeviceID
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let reconnectDelays: [Duration]
    @ObservationIgnored private let reconnectRepeatDelay: Duration?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private var reconnectTaskID: UUID?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var draftPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var draftSyncTask: Task<Void, Never>?
    private var approvalDisclosureDigests: [String: (String, Date)] = [:]
    @ObservationIgnored private var approvalDisclosureExpiryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectionToken = UUID()
    @ObservationIgnored private var hasBeenRevoked = false
    @ObservationIgnored private var disconnectionTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectionID: UUID?
    @ObservationIgnored private var cacheWriteTask: Task<Void, Error>?
    @ObservationIgnored private var isSendingCommand = false
    @ObservationIgnored private var commandWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>, backgroundPoll: Bool)] = []
    @ObservationIgnored private var providerRefreshes: [ProviderRefreshKey: Task<GADCommandAcknowledgement?, Never>] = [:]
    @ObservationIgnored private var lastIssuedDraft: (id: CommandID, text: String, attachments: [GADDraftAttachmentProjection])?

    private struct ProviderRefreshKey: Hashable {
        let providers: Set<AgentProviderID>
        let activityOnly: Bool

        func covers(_ other: Self) -> Bool {
            providers.isSuperset(of: other.providers) && (!activityOnly || other.activityOnly)
        }
    }
    @ObservationIgnored public var projectionDidChange: (@MainActor @Sendable (DashboardProjection?) -> Void)?
    @ObservationIgnored public var revocationDidOccur: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored public var applicationRelaunchDidBecomeRequired: (@MainActor @Sendable () -> Void)?

    public init(
        client: any GobyClient,
        deviceID: DeviceID,
        cache: (any GADProjectionCaching)? = nil,
        draftCache: (any GADLocalDraftCaching)? = nil,
        reconnectDelays: [Duration] = [],
        reconnectRepeatDelay: Duration? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.deviceID = deviceID
        self.cache = cache
        self.draftCache = draftCache
        self.reconnectDelays = reconnectDelays.map { max($0, .milliseconds(10)) }
        self.reconnectRepeatDelay = reconnectRepeatDelay.map { max($0, .milliseconds(10)) }
        self.now = now
    }

    public func connect() async {
        cancelReconnection()
        await establishConnection()
    }

    /// Tears down any transport that may have been suspended by the OS, then
    /// performs a fresh handshake. The phase changes before teardown can
    /// suspend so the UI never presents an in-flight reconnect as disconnected.
    public func reconnect() async {
        cancelReconnection()
        await stopConnection(finalPhase: .connecting)
        guard !hasBeenRevoked, !Task.isCancelled else { return }
        await establishConnection()
    }

    /// Reads the authoritative projection after a signed local administration
    /// operation without replacing the connection or discarding a local draft.
    public func refreshProjection() async {
        _ = await refreshSnapshot(preservingLocalDraft: true)
    }

    private func establishConnection() async {
        guard !hasBeenRevoked else { return }
        approvalDisclosureDigests.removeAll()
        approvalDisclosureExpiryTasks.values.forEach { $0.cancel() }
        approvalDisclosureExpiryTasks.removeAll()
        invalidateQueuedCommands()
        lastIssuedDraft = nil
        eventTask?.cancel()
        lifecycleTask?.cancel()
        draftSyncTask?.cancel()
        draftSyncTask = nil
        let token = UUID()
        connectionToken = token
        connectionPhase = .connecting
        listenForLifecycle(token: token)
        await disconnectionTask?.value
        _ = await cacheWriteTask?.result
        guard connectionToken == token, !Task.isCancelled, !hasBeenRevoked else { return }
        if !draftHasLocalChanges,
           let persistedDraft = try? await draftCache?.loadLocalDraft() {
            guard connectionToken == token, !Task.isCancelled, !hasBeenRevoked else { return }
            if !draftHasLocalChanges {
                draftText = persistedDraft
                draftSyncPhase = .locallyModified
            }
        }
        guard connectionToken == token, !Task.isCancelled, !hasBeenRevoked else { return }
        if projection == nil, let cache, let cached = try? await cache.load() {
            guard connectionToken == token, !Task.isCancelled else { return }
            projection = cached
            if !draftHasLocalChanges {
                draftText = cached.draft.text
                draftAttachments = mergeProjectedAttachments(cached.draft.attachments)
                draftSyncPhase = .synced
            }
            projectionDidChange?(cached)
        }
        // An empty or failed cache read still suspends. It must not reopen a
        // session that was disconnected or revoked while that read was pending.
        guard connectionToken == token, !Task.isCancelled, !hasBeenRevoked else { return }
        do {
            let connectedSession = try await client.connect()
            guard connectionToken == token, !Task.isCancelled else { return }
            guard connectedSession.protocolVersion.major >= GADProtocolVersion.version1.major,
                  connectedSession.protocolVersion.major <= GADProtocolVersion.current.major else {
                await stopConnection(finalPhase: .incompatible)
                return
            }
            let snapshot = try await client.snapshot()
            guard connectionToken == token, !Task.isCancelled else { return }
            // A user can keep editing while the read-only handshake is in flight.
            let localDraft = draftText
            let localAttachments = draftAttachments
            let preservesLocalDraft = draftHasLocalChanges
            session = connectedSession
            projection = snapshot
            if preservesLocalDraft,
               localDraft != snapshot.draft.text
                || projectedMetadata(for: localAttachments) != snapshot.draft.attachments {
                draftText = localDraft
                draftAttachments = localAttachments
                draftSyncPhase = .conflict(canonicalText: snapshot.draft.text)
            } else {
                draftText = snapshot.draft.text
                draftAttachments = mergeProjectedAttachments(snapshot.draft.attachments)
                draftSyncPhase = .synced
            }
            projectionDidChange?(snapshot)
            lastClientErrorMessage = nil
            requiresApplicationRelaunch = false
            connectionPhase = .live
            listen(after: snapshot.revision, epoch: connectedSession.hostEpoch, token: token)
            await persistProjection(snapshot, token: token)
            if connectionToken == token, !draftHasLocalChanges {
                await clearPersistedLocalDraft()
            }
        } catch let failure as GADCommandFailure where failure.disposition == .rejectedRevoked {
            guard connectionToken == token, !Task.isCancelled else { return }
            await handleRevocation()
        } catch GADHostIPCClientError.incompatibleVersion {
            guard connectionToken == token, !Task.isCancelled else { return }
            lastClientErrorMessage = GADHostIPCClientError.incompatibleVersion.localizedDescription
            await stopConnection(finalPhase: .incompatible)
        } catch GADHostIPCClientError.applicationReplaced {
            guard connectionToken == token, !Task.isCancelled else { return }
            lastClientErrorMessage = GADHostIPCClientError.applicationReplaced.localizedDescription
            let alreadyRequired = requiresApplicationRelaunch
            requiresApplicationRelaunch = true
            // Persists the local draft before the shell relaunches.
            await stopConnection(finalPhase: .incompatible)
            if !alreadyRequired { applicationRelaunchDidBecomeRequired?() }
        } catch {
            guard connectionToken == token, !Task.isCancelled else { return }
            lastClientErrorMessage = error.localizedDescription
            connectionPhase = projection == nil
                ? .failed(error.localizedDescription)
                : .stale(lastSuccessfulAt: projection?.generatedAt)
        }
    }

    public func disconnect() async {
        await stopConnection(finalPhase: .disconnected)
    }

    private func stopConnection(finalPhase: GADClientConnectionPhase) async {
        approvalDisclosureDigests.removeAll()
        approvalDisclosureExpiryTasks.values.forEach { $0.cancel() }
        approvalDisclosureExpiryTasks.removeAll()
        cancelReconnection()
        let token = UUID()
        connectionToken = token
        invalidateQueuedCommands()
        lastIssuedDraft = nil
        if !hasBeenRevoked { connectionPhase = finalPhase }
        eventTask?.cancel()
        eventTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        draftSyncTask?.cancel()
        draftSyncTask = nil
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        let draftWrite = enqueueCurrentDraftWrite()
        let preceding = disconnectionTask
        let id = UUID()
        let task = Task { [client] in
            _ = await draftWrite.result
            await preceding?.value
            await client.disconnect()
        }
        disconnectionTask = task
        disconnectionID = id
        await task.value
        if disconnectionID == id { disconnectionTask = nil; disconnectionID = nil }
        if connectionToken == token, !hasBeenRevoked { connectionPhase = finalPhase }
    }

    /// Native shells choose bounded retries or continued read-only recovery.
    /// Never replay a command: its reply may have been lost after acceptance.
    private var shouldAutomaticallyReconnect: Bool {
        guard !hasBeenRevoked else { return false }
        switch connectionPhase {
        case .stale: return true
        case .failed: return reconnectRepeatDelay != nil
        default: return false
        }
    }

    private func scheduleReconnectionIfNeeded() {
        guard shouldAutomaticallyReconnect, reconnectTask == nil,
              !reconnectDelays.isEmpty || reconnectRepeatDelay != nil else { return }
        let id = UUID()
        reconnectTaskID = id
        reconnectTask = Task { [weak self, reconnectDelays, reconnectRepeatDelay] in
            defer {
                if self?.reconnectTaskID == id {
                    self?.reconnectTask = nil
                    self?.reconnectTaskID = nil
                }
            }
            var delays = reconnectDelays.makeIterator()
            while let delay = delays.next() ?? reconnectRepeatDelay {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, self?.reconnectTaskID == id,
                      self?.shouldAutomaticallyReconnect == true else { return }
                await self?.establishConnection()
                guard self?.shouldAutomaticallyReconnect == true else { return }
            }
        }
    }

    private func cancelReconnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectTaskID = nil
    }

    public func updateDraft(_ text: String) {
        updateDraft(text, attachments: draftAttachments)
    }

    public func updateDraft(_ text: String, attachments: [PromptAttachment]) {
        draftText = String(text.prefix(32_000))
        draftAttachments = Array(attachments.prefix(12))
        if case .conflict = draftSyncPhase {
            // Continuing to type is not permission to replace another device's
            // draft. Preserve local recovery without scheduling a remote save.
            draftSyncTask?.cancel()
            draftSyncTask = nil
            scheduleDraftPersistence()
            return
        }
        if draftText != projection?.draft.text || !attachmentsMatchProjection {
            draftSyncPhase = .locallyModified
            scheduleDraftPersistence()
            scheduleDraftSync()
        } else {
            draftSyncPhase = .synced
            schedulePersistedDraftClear()
        }
    }

    public func flushDraft(
        providerID: AgentProviderID? = nil,
        model: String? = nil,
        platform: ProjectPlatform? = nil,
        projectIDs: [ProjectID] = [],
        agentTargets: [AgentRouteTarget] = [],
        groupID: ProjectGroupID? = nil
    ) async {
        await saveDraft(
            providerID: providerID, model: model, platform: platform,
            projectIDs: projectIDs, agentTargets: agentTargets, groupID: groupID,
            resolvingConflictAt: nil
        )
    }

    private func saveDraft(
        providerID: AgentProviderID?,
        model: String?,
        platform: ProjectPlatform?,
        projectIDs: [ProjectID],
        agentTargets: [AgentRouteTarget],
        groupID: ProjectGroupID?,
        resolvingConflictAt reviewedRevision: EntityRevision?
    ) async {
        let token = connectionToken
        let submittedText = draftText
        let submittedAttachments = draftAttachments
        draftSyncTask?.cancel()
        draftSyncTask = nil
        // Hold admission through the acknowledgement AND canonical snapshot.
        // Otherwise a second save can mistake the old projection for a no-op
        // (notably when the user reverts a selection while the first save runs).
        guard await acquireCommandSlot(), connectionToken == token else { return }
        defer { if connectionToken == token { releaseCommandSlot() } }
        guard let projection, isCurrentLiveSession(token) else { return }
        // Recheck after command admission: a remote edit can arrive while this
        // save waits. Explicit replacement covers only the reviewed revision.
        if let reviewedRevision {
            guard case .conflict = draftSyncPhase,
                  projection.draft.revision == reviewedRevision else { return }
        } else if case .conflict = draftSyncPhase {
            return
        }
        if submittedText == projection.draft.text,
           projectedMetadata(for: submittedAttachments) == projection.draft.attachments,
           (providerID ?? projection.draft.providerID) == projection.draft.providerID,
           model == projection.draft.model,
           platform == projection.draft.platform,
           Set(projectIDs) == Set(projection.draft.projectIDs),
           Set(agentTargets) == Set(projection.draft.agentTargets),
           groupID == projection.draft.groupID {
            if draftText == submittedText, draftAttachments == submittedAttachments {
                draftSyncPhase = .synced
            }
            return
        }
        draftSyncPhase = .syncing
        await persistLocalDraftIfNeeded()
        guard connectionToken == token, !Task.isCancelled, !hasBeenRevoked else { return }
        let acknowledgement = await sendImmediately(.replaceDraft(.init(
            expectedRevision: projection.draft.revision,
            text: submittedText,
            attachments: submittedAttachments,
            providerID: providerID ?? projection.draft.providerID,
            model: model,
            platform: platform,
            projectIDs: projectIDs,
            agentTargets: agentTargets,
            groupID: groupID
        )), token: token)
        guard let acknowledgement, connectionToken == token, !hasBeenRevoked else { return }
        if acknowledgement.disposition == .rejectedStale {
            await reloadDraftAsConflict()
        } else if acknowledgement.disposition == .accepted {
            guard await reconcileAcceptedCommand(preservingLocalDraft: true, token: token),
                  connectionToken == token else { return }
            if draftText != submittedText || draftAttachments != submittedAttachments,
               self.projection?.draft.text == submittedText {
                draftSyncPhase = .locallyModified
                scheduleDraftSync()
            }
        } else if acknowledgement.disposition == .failedRecoverable,
                  acknowledgement.wasDeferredBeforeAdmission == true {
            // The host has not touched this draft. Keep it pending for the next
            // edit/explicit flush; never erase it, loop forever or raise a modal.
            draftSyncPhase = .locallyModified
        } else {
            draftSyncPhase = .failed(acknowledgement.message ?? "The draft could not be saved.")
        }
    }

    /// Flushes pending text using the current canonical routing context.
    public func flushPendingDraft() async {
        switch draftSyncPhase {
        case .locallyModified, .syncing, .failed: break
        case .synced, .conflict: return
        }
        guard let draft = projection?.draft else { return }
        await flushDraft(
            providerID: draft.providerID,
            model: draft.model,
            platform: draft.platform,
            projectIDs: draft.projectIDs,
            agentTargets: draft.agentTargets,
            groupID: draft.groupID
        )
    }

    public func reloadCanonicalDraft() {
        guard let draft = projection?.draft else { return }
        draftText = draft.text
        draftAttachments = mergeProjectedAttachments(draft.attachments)
        draftSyncPhase = .synced
        schedulePersistedDraftClear()
    }

    public func deliberatelyReplaceConflictingDraft(
        providerID: AgentProviderID? = nil,
        model: String? = nil,
        platform: ProjectPlatform? = nil,
        projectIDs: [ProjectID] = [],
        agentTargets: [AgentRouteTarget] = [],
        groupID: ProjectGroupID? = nil
    ) async {
        guard case .conflict = draftSyncPhase,
              let reviewedRevision = projection?.draft.revision else { return }
        await saveDraft(
            providerID: providerID,
            model: model,
            platform: platform,
            projectIDs: projectIDs,
            agentTargets: agentTargets,
            groupID: groupID,
            resolvingConflictAt: reviewedRevision
        )
    }

    @discardableResult
    public func control(runID: RunID, action: GADRunControlAction, modelChange: RunModelChange? = nil) async -> GADCommandAcknowledgement? {
        guard modelChange == nil || (session?.protocolVersion ?? .version1) >= .init(major: 3, minor: 10) else { return nil }
        return await send(.controlRun(.init(runID: runID, action: action, modelChange: modelChange)))
    }

    @discardableResult
    public func preparePlan() async -> GADCommandAcknowledgement? {
        let submittedDraft = projection?.draft
        let submittedText = draftText
        let submittedAttachments = draftAttachments
        let token = connectionToken
        let first = await send(.preparePlan)
        guard first?.disposition == .rejectedStale,
              first?.message == "Canonical state changed; review the refreshed scope.",
              connectionToken == token,
              connectionPhase == .live,
              draftSyncPhase == .synced,
              projection?.draft == submittedDraft,
              draftText == submittedText,
              draftAttachments == submittedAttachments else { return first }
        // The host rejected the first command before admission and the refreshed
        // draft still matches what the user submitted. Background progress may
        // have advanced only the global revision, so retry once with a new key.
        return await send(.preparePlan)
    }

    @discardableResult
    public func updatePlan(
        _ planID: RunID,
        routes: [GADPlanRouteSelection],
        selectedResourceIDs: [SharedResourceID]
    ) async -> GADCommandAcknowledgement? {
        await send(.updatePlan(.init(
            planID: planID,
            routes: routes,
            selectedResourceIDs: selectedResourceIDs
        )))
    }

    @discardableResult
    public func cancelPlan(_ planID: RunID) async -> GADCommandAcknowledgement? {
        await send(.cancelPlan(planID))
    }

    @discardableResult
    public func startRun(
        _ runID: RunID,
        authorizationAssertion: String? = nil,
        automaticallyApproveRuntimeRequests: Bool = false,
        allowsPush: Bool? = nil
    ) async -> GADCommandAcknowledgement? {
        let submittedPlan = projection?.plan
        let submittedDraft = projection?.draft
        let submittedText = draftText
        let submittedAttachments = draftAttachments
        let token = connectionToken
        let payload = GADCommandPayload.startRun(.init(
            planID: runID,
            authorizationAssertion: authorizationAssertion,
            automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests,
            allowsPush: allowsPush
        ))
        let first = await send(payload)
        guard first?.disposition == .rejectedStale,
              first?.message == "Canonical state changed; review the refreshed scope.",
              submittedPlan?.id == runID,
              connectionToken == token,
              connectionPhase == .live,
              draftSyncPhase == .synced,
              projection?.plan == submittedPlan,
              projection?.draft == submittedDraft,
              draftText == submittedText,
              draftAttachments == submittedAttachments else { return first }
        // The first command was rejected before admission. A background status
        // update may have advanced only the global revision, so retry once
        // with a new command identity after verifying the reviewed plan.
        return await send(payload)
    }

    @discardableResult
    public func reuseRequest(from runID: RunID) async -> GADCommandAcknowledgement? {
        await send(.reuseRequest(runID))
    }

    @discardableResult
    public func followUp(runID: RunID, text: String) async -> GADCommandAcknowledgement? {
        await send(.followUp(.init(runID: runID, text: String(text.prefix(32_000)))))
    }

    /// The host's temporary chat, when one is open.
    public var temporaryChat: GADTemporaryChatProjection? { projection?.host.temporaryChat }

    /// Asks the host's temporary chat; nil `chatID` starts a new chat.
    /// Returns nil without sending when the host does not support it.
    public func askTemporaryChat(
        _ text: String,
        chatID: TemporaryChatID?,
        model: String? = nil,
        providerID: AgentProviderID? = nil
    ) async -> GADCommandAcknowledgement? {
        guard session?.supportsTemporaryChat == true,
              let question = TemporaryChat.normalizedQuestion(text) else { return nil }
        return await send(.askTemporaryChat(.init(chatID: chatID, text: question, model: model, providerID: providerID)))
    }

    /// Ends and clears the host's temporary chat.
    public func endTemporaryChat(_ chatID: TemporaryChatID) async -> GADCommandAcknowledgement? {
        guard session?.supportsTemporaryChat == true else { return nil }
        return await send(.endTemporaryChat(chatID))
    }

    @discardableResult
    public func respond(
        to approval: GADApprovalProjection,
        action: GADApprovalAction,
        authorizationAssertion: String? = nil,
        rememberCommand: Bool = false
    ) async -> GADCommandAcknowledgement? {
        guard !rememberCommand || session?.supportsRememberedCommandApprovals == true else { return nil }
        defer {
            approvalDisclosureDigests.removeValue(forKey: approval.id)
            approvalDisclosureExpiryTasks.removeValue(forKey: approval.id)?.cancel()
        }
        return await send(.respondToApproval(.init(
            approvalID: approval.id,
            runID: approval.runID,
            assignmentID: approval.assignmentID,
            action: action,
            approvalSessionID: action == .allowForRun ? approval.approvalSessionID : nil,
            authorizationAssertion: authorizationAssertion,
            disclosureDigest: approvalDisclosureDigests[approval.id].flatMap { entry in
                entry.1 >= now() ? entry.0 : nil
            },
            rememberCommand: rememberCommand ? true : nil
        )))
    }

    public func rememberedApprovals(_ operation: GADRememberedApprovalOperation) async -> GADCommandAcknowledgement? {
        guard session?.supportsRememberedCommandApprovals == true else { return nil }
        return await send(.rememberedApprovals(operation))
    }

    public func hasCurrentApprovalDisclosure(for approvalID: String) -> Bool {
        connectionPhase == .live && approvalDisclosureDigests[approvalID].map { $0.1 >= now() } == true
    }

    public func approvalDisclosure(for approvalID: String) async -> GADApprovalDisclosure? {
        approvalDisclosureDigests.removeValue(forKey: approvalID)
        let acknowledgement = await send(.requestApprovalDisclosure(approvalID))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .approvalDisclosure(disclosure) = acknowledgement?.artifact,
              disclosure.approvalID == approvalID,
              disclosure.expiresAt >= now() else {
            return nil
        }
        guard let digest = disclosure.requestDigest, !digest.isEmpty else { return nil }
        approvalDisclosureDigests[approvalID] = (digest, disclosure.expiresAt)
        approvalDisclosureExpiryTasks[approvalID]?.cancel()
        let lifetime = min(max(disclosure.expiresAt.timeIntervalSince(now()), 0), 86_400)
        approvalDisclosureExpiryTasks[approvalID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            guard let self, self.approvalDisclosureDigests[approvalID]?.0 == digest else { return }
            self.approvalDisclosureDigests.removeValue(forKey: approvalID)
            self.approvalDisclosureExpiryTasks.removeValue(forKey: approvalID)
            self.projectionDidChange?(self.projection)
        }
        return disclosure
    }

    @discardableResult
    public func refreshCodex() async -> GADCommandAcknowledgement? {
        if session?.capabilities.contains(.providerActivity) == true {
            return await refreshProviders([.codex])
        }
        return await send(.refreshCodex)
    }

    @discardableResult
    public func refreshProviders(
        _ providerIDs: [AgentProviderID] = AgentProviderID.builtIn,
        activityOnly: Bool = false
    ) async -> GADCommandAcknowledgement? {
        let supportsActivityOnly = (session?.protocolVersion ?? .version1)
            >= GADProtocolVersion(major: 3, minor: 9)
        let key = ProviderRefreshKey(
            providers: Set(providerIDs),
            activityOnly: activityOnly && supportsActivityOnly
        )
        if let existing = providerRefreshes.first(where: { $0.key.covers(key) })?.value {
            return await existing.value
        }
        let token = connectionToken
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.connectionToken == token else {
                return nil as GADCommandAcknowledgement?
            }
            return await self.send(key.activityOnly
                ? .refreshProviderActivity(key.providers.sorted())
                : .refreshProviders(key.providers.sorted()))
        }
        providerRefreshes[key] = task
        let result = await task.value
        if connectionToken == token { providerRefreshes[key] = nil }
        return result
    }

    @discardableResult
    public func dispatchManualHandoff(
        runID: RunID,
        sourceAssignmentID: AssignmentID,
        linkID: AgentHandoffLinkID
    ) async -> GADCommandAcknowledgement? {
        await send(.dispatchManualHandoff(.init(
            runID: runID,
            sourceAssignmentID: sourceAssignmentID,
            linkID: linkID
        )))
    }

    @discardableResult
    public func setProjectTrust(_ projectID: ProjectID?, trusted: Bool) async -> GADCommandAcknowledgement? {
        await send(.setProjectTrust(.init(projectID: projectID, trusted: trusted)))
    }

    @discardableResult
    public func saveProjectGroup(
        id: ProjectGroupID?,
        name: String,
        members: [ProjectGroupMember]
    ) async -> GADCommandAcknowledgement? {
        await send(.saveProjectGroup(.init(
            id: id,
            expectedRevision: nil,
            name: String(name.prefix(120)),
            members: members
        )))
    }

    @discardableResult
    public func deleteProjectGroup(_ id: ProjectGroupID) async -> GADCommandAcknowledgement? {
        await send(.deleteProjectGroup(id))
    }

    @discardableResult
    public func saveAutomation(
        _ automation: AutomationDefinition
    ) async -> GADCommandAcknowledgement? {
        let expectedRevision = projection?.automations.definitions
            .first(where: { $0.id == automation.id })?.revision
        return await saveAutomation(
            automation,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    public func saveAutomation(
        _ automation: AutomationDefinition,
        expectedRevision: Int?
    ) async -> GADCommandAcknowledgement? {
        return await send(.saveAutomation(.init(
            automation: automation,
            expectedRevision: expectedRevision,
            authorizationAssertion: automation.automaticallyApproveRuntimeRequests
                ? "user-presence-required" : nil
        )))
    }

    @discardableResult
    public func setAutomationState(
        id: AutomationID,
        state: AutomationState
    ) async -> GADCommandAcknowledgement? {
        guard let revision = projection?.automations.definitions
            .first(where: { $0.id == id })?.revision else { return nil }
        return await setAutomationState(
            id: id,
            state: state,
            expectedRevision: revision
        )
    }

    @discardableResult
    public func setAutomationState(
        id: AutomationID,
        state: AutomationState,
        expectedRevision: Int
    ) async -> GADCommandAcknowledgement? {
        return await send(.setAutomationState(.init(
            id: id,
            expectedRevision: expectedRevision,
            state: state
        )))
    }

    @discardableResult
    public func deleteAutomation(id: AutomationID) async -> GADCommandAcknowledgement? {
        guard let revision = projection?.automations.definitions
            .first(where: { $0.id == id })?.revision else { return nil }
        return await deleteAutomation(id: id, expectedRevision: revision)
    }

    @discardableResult
    public func deleteAutomation(
        id: AutomationID,
        expectedRevision: Int
    ) async -> GADCommandAcknowledgement? {
        return await send(.deleteAutomation(id, expectedRevision: expectedRevision))
    }

    @discardableResult
    public func runAutomationNow(id: AutomationID) async -> GADCommandAcknowledgement? {
        guard let revision = projection?.automations.definitions
            .first(where: { $0.id == id })?.revision else { return nil }
        return await runAutomationNow(id: id, expectedRevision: revision)
    }

    @discardableResult
    public func runAutomationNow(
        id: AutomationID,
        expectedRevision: Int
    ) async -> GADCommandAcknowledgement? {
        return await send(.runAutomationNowChecked(.init(
            id: id,
            expectedRevision: expectedRevision
        )))
    }

    @discardableResult
    public func reviewAndRunAutomationOccurrence(
        id: AutomationOccurrenceID,
        reviewBinding: AutomationReviewBinding,
        authorizationAssertion: String?,
        selectedResourceIDs: [SharedResourceID] = []
    ) async -> GADCommandAcknowledgement? {
        guard session?.supportsBoundAutomationReviews == true else {
            lastClientErrorMessage = "Update the paired Mac before reviewing automation actions."
            return nil
        }
        return await send(.reviewAndRunAutomationOccurrence(.init(
            id: id,
            reviewBinding: reviewBinding,
            authorizationAssertion: authorizationAssertion,
            selectedResourceIDs: selectedResourceIDs
        )))
    }

    @discardableResult
    public func cancelAutomationOccurrence(
        id: AutomationOccurrenceID
    ) async -> GADCommandAcknowledgement? {
        await send(.cancelAutomationOccurrence(id))
    }

    public func instructionEditor(for id: InstructionPackID) async -> GADInstructionEditor? {
        let acknowledgement = await send(.requestInstructionEditor(id))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .instructionEditor(editor) = acknowledgement?.artifact,
              editor.id == id,
              editor.expiresAt >= now() else {
            return nil
        }
        return editor
    }

    public func providerBindingInstructionEditor(
        for id: ProviderAgentBindingID
    ) async -> GADProviderBindingInstructionEditor? {
        let acknowledgement = await send(.requestProviderBindingInstructionEditor(id))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .providerBindingInstructionEditor(editor) = acknowledgement?.artifact,
              editor.bindingID == id,
              editor.expiresAt >= now() else {
            return nil
        }
        return editor
    }

    @discardableResult
    public func saveProviderBindingInstructions(
        bindingID: ProviderAgentBindingID,
        instructions: String?
    ) async -> GADCommandAcknowledgement? {
        await send(.saveProviderBindingInstructions(.init(
            bindingID: bindingID,
            instructions: instructions.map { String($0.prefix(64_000)) }
        )))
    }

    @discardableResult
    public func saveInstruction(
        id: InstructionPackID?,
        version: Int?,
        name: String,
        body: String,
        scope: InstructionScope,
        isEnabled: Bool
    ) async -> GADCommandAcknowledgement? {
        await send(.saveInstruction(.init(
            id: id,
            expectedRevision: version.map { EntityRevision(rawValue: UInt64(max(0, $0))) },
            name: name,
            body: body,
            scope: scope,
            isEnabled: isEnabled
        )))
    }

    public func hostAdminPreview(for request: GADHostAdminRequest) async -> GADHostAdminPreview? {
        let acknowledgement = await send(.requestHostAdminPreview(request))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .hostAdminPreview(preview) = acknowledgement?.artifact,
              preview.expiresAt >= now() else {
            return nil
        }
        return preview
    }

    public func codexCatalogDiscovery() async -> GADCodexCatalogDiscovery? {
        let acknowledgement = await send(.requestCodexCatalogDiscovery)
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .codexCatalogDiscovery(discovery) = acknowledgement?.artifact,
              discovery.expiresAt >= now() else {
            return nil
        }
        return discovery
    }

    public func agentCatalogDiscovery(offset: Int = 0) async -> GADAgentCatalogDiscovery? {
        let acknowledgement = await send(.requestAgentCatalogDiscovery(offset: max(0, offset)))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .agentCatalogDiscovery(discovery) = acknowledgement?.artifact,
              discovery.expiresAt >= now() else {
            return nil
        }
        return discovery
    }

    public func projectGitBranches(for projectID: ProjectID) async -> GADProjectBranchDiscovery? {
        let acknowledgement = await send(.requestProjectGitBranches(projectID))
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .projectGitBranches(discovery) = acknowledgement?.artifact,
              discovery.expiresAt >= now() else {
            return nil
        }
        return discovery
    }

    @discardableResult
    public func commitHostAdmin(
        _ preview: GADHostAdminPreview,
        authorizationAssertion: String? = nil
    ) async -> GADCommandAcknowledgement? {
        await send(.commitHostAdmin(.init(
            previewID: preview.id,
            previewHash: preview.hash,
            authorizationAssertion: authorizationAssertion
        )))
    }

    public func redactedDiagnostics(using preview: GADHostAdminPreview) async -> Data? {
        let acknowledgement = await commitHostAdmin(preview)
        defer { lastAcknowledgement = nil }
        guard acknowledgement?.disposition == .accepted,
              case let .redactedDiagnostics(data) = acknowledgement?.artifact else {
            return nil
        }
        return data
    }

    @discardableResult
    public func updateNotificationRegistration(
        _ registration: GADNotificationRegistration?
    ) async -> GADCommandAcknowledgement? {
        await send(.updateNotificationRegistration(registration))
    }

    /// Requests durable revocation on the authoritative Mac. Callers must not
    /// erase the local pairing until an accepted acknowledgement is received.
    @discardableResult
    public func revokeCurrentDevice() async -> GADCommandAcknowledgement? {
        await send(.revokeCurrentDevice)
    }

    private func send(_ payload: GADCommandPayload) async -> GADCommandAcknowledgement? {
        // Actor reentrancy alone does not serialize async operations. Draft
        // autosaves and UI mutations stay serialized. Foreground commands pass
        // queued activity polls, but never an earlier foreground command.
        let token = connectionToken
        guard await acquireCommandSlot(for: payload), connectionToken == token else { return nil }
        defer { if connectionToken == token { releaseCommandSlot() } }
        guard !Task.isCancelled else { return nil }
        return await sendImmediately(payload, token: token)
    }

    private func acquireCommandSlot(for payload: GADCommandPayload? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isSendingCommand {
            isSendingCommand = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let backgroundPoll: Bool
                if case .refreshProviderActivity = payload { backgroundPoll = true }
                else { backgroundPoll = false }
                let insertionIndex = !backgroundPoll
                    ? (commandWaiters.lastIndex { !$0.backgroundPoll }.map { $0 + 1 } ?? 0)
                    : commandWaiters.endIndex
                commandWaiters.insert((id, continuation, backgroundPoll), at: insertionIndex)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.commandWaiters.firstIndex(where: { $0.0 == id }) else { return }
                self.commandWaiters.remove(at: index).1.resume(returning: false)
            }
        }
    }

    private func releaseCommandSlot() {
        if commandWaiters.isEmpty {
            isSendingCommand = false
        } else {
            commandWaiters.removeFirst().1.resume(returning: true)
        }
    }

    private func invalidateQueuedCommands() {
        isSendingCommand = false
        let waiters = commandWaiters
        commandWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: false) }
        for task in providerRefreshes.values { task.cancel() }
        providerRefreshes.removeAll()
    }

    private func sendImmediately(
        _ payload: GADCommandPayload,
        token: UUID
    ) async -> GADCommandAcknowledgement? {
        guard let session, let projection, connectionPhase == .live else { return nil }
        let timestamp = now()
        let command = GADCommand(
            idempotencyKey: UUID().uuidString.lowercased(),
            hostEpoch: session.hostEpoch,
            deviceID: deviceID,
            baseRevision: projection.revision,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(60),
            payload: payload
        )
        if case let .replaceDraft(replacement) = payload {
            lastIssuedDraft = (
                id: command.id,
                text: replacement.text,
                attachments: replacement.attachments.map(GADDraftAttachmentProjection.init)
            )
        }
        do {
            var acknowledgement = try await client.send(command)
            // Only a typed, explicit pre-admission rejection permits retry.
            // Keep the exact command identity and revisions. A lost reply,
            // failedRecoverable alone, or an indeterminate mutation never does.
            for delay in [100, 250, 500, 1_000] {
                guard payload.canRetryBeforeAdmission,
                      acknowledgement.disposition == .failedRecoverable,
                      acknowledgement.wasDeferredBeforeAdmission == true,
                      connectionToken == token, !Task.isCancelled else { break }
                try await Task.sleep(for: .milliseconds(delay))
                guard connectionToken == token, !Task.isCancelled else { return nil }
                acknowledgement = try await client.send(command)
            }
            guard connectionToken == token else { return nil }
            lastClientErrorMessage = acknowledgement.disposition == .accepted
                ? nil
                : acknowledgement.message ?? "The host rejected this request."
            lastAcknowledgement = acknowledgement
            if acknowledgement.disposition == .rejectedRevoked {
                await handleRevocation()
                return acknowledgement
            } else if acknowledgement.disposition == .rejectedStale,
                      payload.requiresGlobalRefresh {
                await refreshSnapshot(preservingLocalDraft: true)
            } else if acknowledgement.disposition == .accepted,
                      payload.requiresGlobalRefresh {
                await reconcileAcceptedCommand(preservingLocalDraft: draftSyncPhase != .synced, token: token)
            }
            guard connectionToken == token else { return nil }
            return acknowledgement
        } catch is CancellationError {
            return nil
        } catch let error as GobyClientLocalError {
            guard connectionToken == token else { return nil }
            lastClientErrorMessage = error.localizedDescription
            return nil
        } catch {
            guard connectionToken == token else { return nil }
            lastClientErrorMessage = error.localizedDescription
            connectionPhase = .stale(lastSuccessfulAt: self.projection?.generatedAt)
            return nil
        }
    }

    private func listen(after revision: StateRevision, epoch: HostEpoch, token: UUID) {
        eventTask = Task { [weak self, client] in
            let stream = await client.events(after: revision)
            for await delta in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(delta, expectedEpoch: epoch, token: token)
            }
            guard !Task.isCancelled else { return }
            self?.eventStreamEnded(token: token, expectedEpoch: epoch)
        }
    }

    private func listenForLifecycle(token: UUID) {
        lifecycleTask = Task { [weak self, client] in
            let stream = await client.lifecycleEvents()
            for await event in stream {
                guard !Task.isCancelled else { return }
                switch event {
                case .revoked:
                    guard self?.connectionToken == token else { return }
                    await self?.handleRevocation()
                    return
                case .incompatible:
                    guard self?.connectionToken == token else { return }
                    await self?.stopConnection(finalPhase: .incompatible)
                    return
                case .transportLost:
                    guard self?.connectionToken == token,
                          self?.connectionPhase == .live else { continue }
                    self?.connectionPhase = .stale(lastSuccessfulAt: self?.projection?.generatedAt)
                }
            }
        }
    }

    private func handleRevocation() async {
        cancelReconnection()
        let shouldNotify = connectionPhase != .revoked
        hasBeenRevoked = true
        connectionToken = UUID()
        invalidateQueuedCommands()
        lastIssuedDraft = nil
        eventTask?.cancel()
        eventTask = nil
        draftSyncTask?.cancel()
        draftSyncTask = nil
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        approvalDisclosureDigests.removeAll()
        approvalDisclosureExpiryTasks.values.forEach { $0.cancel() }
        approvalDisclosureExpiryTasks.removeAll()
        session = nil
        projection = nil
        projectionDidChange?(nil)
        draftText = ""
        draftAttachments = []
        draftSyncPhase = .synced
        lastAcknowledgement = nil
        connectionPhase = .revoked
        // Purge only after previously admitted cache writes have finished.
        // Cancellation cannot stop a cache adapter that already entered I/O.
        let cleanup = enqueueCacheWrite(token: nil) { [cache, draftCache] in
            var cleanupError: Error?
            do { try await cache?.clear() } catch { cleanupError = error }
            do { try await draftCache?.saveLocalDraft(nil) } catch { cleanupError = cleanupError ?? error }
            if let cleanupError { throw cleanupError }
        }
        if shouldNotify { await revocationDidOccur?() }
        do {
            try await cleanup.value
        } catch {
            lastClientErrorMessage = error.localizedDescription
            connectionPhase = .failed("Goby received revocation, but protected local cleanup is still pending. Retry before using this pairing again.")
        }
    }

    private func eventStreamEnded(token: UUID, expectedEpoch: HostEpoch) {
        guard token == connectionToken,
              session?.hostEpoch == expectedEpoch,
              connectionPhase == .live else { return }
        eventTask = nil
        connectionPhase = .stale(lastSuccessfulAt: projection?.generatedAt)
    }

    private func receive(_ delta: GADStateDelta, expectedEpoch: HostEpoch, token: UUID) async {
        guard isCurrentLiveSession(token), session?.hostEpoch == expectedEpoch else { return }
        guard delta.hostEpoch == expectedEpoch, let projection else {
            connectionPhase = .stale(lastSuccessfulAt: self.projection?.generatedAt)
            return
        }
        guard delta.revision > projection.revision else { return }
        guard delta.isResyncSnapshot || delta.revision == projection.revision.advanced() else {
            await refreshSnapshot(preservingLocalDraft: draftSyncPhase != .synced)
            return
        }
        let locallyEdited = draftHasLocalChanges
        let updated = projection.applying(delta.changes, revision: delta.revision, generatedAt: delta.occurredAt)
        self.projection = updated
        if !locallyEdited {
            draftText = updated.draft.text
            draftAttachments = mergeProjectedAttachments(updated.draft.attachments)
            draftSyncPhase = .synced
        } else if (updated.draft.text != projection.draft.text && updated.draft.text != draftText)
                    || updated.draft.attachments != projection.draft.attachments {
            if let originatingCommandID = delta.originatingCommandID,
               originatingCommandID == lastIssuedDraft?.id,
               case .conflict = draftSyncPhase {
                // An earlier genuine conflict still requires user choice.
            } else if let originatingCommandID = delta.originatingCommandID,
                      originatingCommandID == lastIssuedDraft?.id {
                draftSyncPhase = .locallyModified
            } else {
                draftSyncPhase = .conflict(canonicalText: updated.draft.text)
            }
        }
        projectionDidChange?(updated)
        await persistProjection(updated, token: token)
    }

    private func isCurrentLiveSession(_ token: UUID) -> Bool {
        connectionToken == token && !Task.isCancelled && !hasBeenRevoked
            && session != nil && connectionPhase == .live
    }

    @discardableResult
    private func reconcileAcceptedCommand(preservingLocalDraft: Bool, token: UUID) async -> Bool {
        // A cancelled view/autosave cannot undo an admitted command. Finish
        // its read-only reconciliation before releasing the command queue.
        // Disconnect/revocation still invalidate it through the session token.
        let task = Task { @MainActor [weak self] in
            guard let self, self.connectionToken == token else { return false }
            return await self.refreshSnapshot(preservingLocalDraft: preservingLocalDraft || self.draftHasLocalChanges)
        }
        return await task.value
    }

    @discardableResult
    private func refreshSnapshot(preservingLocalDraft: Bool) async -> Bool {
        let token = connectionToken
        guard isCurrentLiveSession(token) else { return false }
        do {
            let draftAtRequest = draftText
            let attachmentsAtRequest = draftAttachments
            let updated = try await client.snapshot()
            guard isCurrentLiveSession(token) else { return false }
            // A newer event may have arrived while the snapshot was in flight.
            guard updated.revision >= (projection?.revision ?? .zero) else { return true }
            let previousDraftRevision = projection?.draft.revision
            let previousDraftPhase = draftSyncPhase
            projection = updated
            let localDraft = draftText
            let localAttachments = draftAttachments
            let editedWhileLoading = localDraft != draftAtRequest || localAttachments != attachmentsAtRequest
            if preservingLocalDraft || editedWhileLoading,
               localDraft != updated.draft.text
                || projectedMetadata(for: localAttachments) != updated.draft.attachments {
                draftText = localDraft
                draftAttachments = localAttachments
                if case .conflict = previousDraftPhase {
                    draftSyncPhase = .conflict(canonicalText: updated.draft.text)
                } else if previousDraftRevision == updated.draft.revision
                            || (lastIssuedDraft?.text == updated.draft.text
                                && lastIssuedDraft?.attachments == updated.draft.attachments) {
                    // Catalog and run refreshes must not turn an unsent local
                    // edit into a cross-device conflict when the host draft
                    // itself has not changed.
                    draftSyncPhase = .locallyModified
                } else {
                    draftSyncPhase = .conflict(canonicalText: updated.draft.text)
                }
            } else {
                draftText = updated.draft.text
                draftAttachments = mergeProjectedAttachments(updated.draft.attachments)
                draftSyncPhase = .synced
            }
            projectionDidChange?(updated)
            await persistProjection(updated, token: token)
            guard isCurrentLiveSession(token) else { return false }
            if !draftHasLocalChanges { await clearPersistedLocalDraft() }
            return isCurrentLiveSession(token)
        } catch let failure as GADCommandFailure where failure.disposition == .rejectedRevoked {
            guard isCurrentLiveSession(token) else { return false }
            await handleRevocation()
            return false
        } catch {
            guard isCurrentLiveSession(token) else { return false }
            connectionPhase = .stale(lastSuccessfulAt: projection?.generatedAt)
            return false
        }
    }

    private func reloadDraftAsConflict() async {
        await refreshSnapshot(preservingLocalDraft: true)
    }

    private var attachmentsMatchProjection: Bool {
        projectedMetadata(for: draftAttachments) == (projection?.draft.attachments ?? [])
    }

    private func projectedMetadata(
        for attachments: [PromptAttachment]
    ) -> [GADDraftAttachmentProjection] {
        attachments.map(GADDraftAttachmentProjection.init)
    }

    private func mergeProjectedAttachments(
        _ projected: [GADDraftAttachmentProjection]
    ) -> [PromptAttachment] {
        let existing = Dictionary(uniqueKeysWithValues: draftAttachments.map { ($0.id, $0) })
        return projected.map { item in
            if let attachment = existing[item.id] { return attachment }
            return item.attachmentReference
        }
    }

    private var draftHasLocalChanges: Bool {
        switch draftSyncPhase {
        case .locallyModified, .syncing, .conflict, .failed: true
        case .synced: false
        }
    }

    /// Actor methods can reenter during storage I/O. Chain writes explicitly
    /// so revocation's purge runs after every write that was already admitted.
    private func enqueueCacheWrite(
        token: UUID?,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        let preceding = cacheWriteTask
        let task = Task { @MainActor [weak self] in
            _ = await preceding?.result
            if let token {
                guard let self, self.connectionToken == token, !self.hasBeenRevoked else { return }
            }
            try await operation()
        }
        cacheWriteTask = task
        return task
    }

    private func persistProjection(_ value: DashboardProjection, token: UUID) async {
        guard let cache else { return }
        try? await enqueueCacheWrite(token: token) { try await cache.save(value) }.value
    }

    private func enqueueCurrentDraftWrite() -> Task<Void, Error> {
        enqueueCacheWrite(token: connectionToken) { [weak self, draftCache] in
            guard let self else { return }
            // Capture at admission, not before waiting behind another write.
            // A delayed clear must not erase text typed in the meantime.
            let text = self.draftHasLocalChanges ? self.draftText : nil
            try await draftCache?.saveLocalDraft(text)
        }
    }

    private func scheduleDraftPersistence() {
        draftPersistenceTask?.cancel()
        let text = draftText
        let token = connectionToken
        draftPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.connectionToken == token, !self.hasBeenRevoked,
                  self.draftHasLocalChanges,
                  self.draftText == text else { return }
            try? await self.enqueueCurrentDraftWrite().value
        }
    }

    private func scheduleDraftSync() {
        draftSyncTask?.cancel()
        guard connectionPhase == .live else { return }
        draftSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.runScheduledDraftSync()
        }
    }

    private func runScheduledDraftSync() async {
        draftSyncTask = nil
        guard connectionPhase == .live,
              draftSyncPhase == .locallyModified,
              let draft = projection?.draft else { return }
        await flushDraft(
            providerID: draft.providerID,
            model: draft.model,
            platform: draft.platform,
            projectIDs: draft.projectIDs,
            agentTargets: draft.agentTargets,
            groupID: draft.groupID
        )
    }

    private func persistLocalDraftIfNeeded() async {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        try? await enqueueCurrentDraftWrite().value
    }

    private func schedulePersistedDraftClear() {
        draftPersistenceTask?.cancel()
        let token = connectionToken
        draftPersistenceTask = Task { [weak self] in
            guard let self, self.connectionToken == token, !Task.isCancelled else { return }
            try? await self.enqueueCurrentDraftWrite().value
        }
    }

    private func clearPersistedLocalDraft() async {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        try? await enqueueCurrentDraftWrite().value
    }
}

private extension GADCommandPayload {
    var canRetryBeforeAdmission: Bool {
        switch self {
        case .refreshProviders, .refreshProviderActivity, .refreshCodex, .replaceDraft: true
        default: false
        }
    }

    var requiresGlobalRefresh: Bool {
        switch self {
        case .replaceDraft, .controlRun, .requestApprovalDisclosure, .requestInstructionEditor,
             .requestCodexCatalogDiscovery, .requestAgentCatalogDiscovery, .requestHostAdminPreview,
             .requestProjectGitBranches,
             .respondToApproval, .refreshProviders, .refreshProviderActivity, .refreshCodex, .revokeCurrentDevice:
            false
        default:
            true
        }
    }
}
