import Foundation

public protocol GADHostIPCRequestHandling: Sendable {
    func handle(_ request: GADHostIPCRequest) async -> GADHostIPCResponse
}

/// Keeps the XPC listener stable while the helper waits for an explicit,
/// validated ownership transfer. Replacing the delegate does not promote the
/// activation gate; only a fully prepared handler may be installed.
public actor GADHostIPCRequestRouter: GADHostIPCRequestHandling {
    private var handler: any GADHostIPCRequestHandling

    public init(handler: any GADHostIPCRequestHandling) {
        self.handler = handler
    }

    public func install(_ handler: any GADHostIPCRequestHandling) {
        self.handler = handler
    }

    public func handle(_ request: GADHostIPCRequest) async -> GADHostIPCResponse {
        await handler.handle(request)
    }
}

public enum GADHostIPCMode: Equatable, Sendable {
    case migrationReadOnly
    case validationReadOnly
    case authoritative
    case quiescingReadOnly
}

public enum GADHostIPCActivationError: Error, Equatable, Sendable {
    case invalidTransition(from: GADHostIPCMode, to: GADHostIPCMode)
}

/// Host-internal, monotonic activation gate. No IPC operation can promote this
/// gate; the host composition does so only after lease and snapshot validation.
public actor GADHostIPCActivationGate {
    private var mode: GADHostIPCMode
    private var activeMutationAdmissions: Set<UUID> = []
    private var mutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(mode: GADHostIPCMode = .migrationReadOnly) {
        self.mode = mode
    }

    public func currentMode() -> GADHostIPCMode { mode }

    public func beginValidation() throws {
        switch mode {
        case .migrationReadOnly:
            mode = .validationReadOnly
        case .validationReadOnly:
            return
        case .authoritative:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .validationReadOnly
            )
        case .quiescingReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .validationReadOnly
            )
        }
    }

    public func activate() throws {
        switch mode {
        case .validationReadOnly:
            mode = .authoritative
        case .authoritative:
            return
        case .migrationReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .authoritative
            )
        case .quiescingReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .authoritative
            )
        }
    }

    /// Begins the checked helper-to-foreground handoff. Once entered, every
    /// later mutation is rejected and the caller waits for mutations admitted
    /// before the transition to finish before checkpointing or releasing its
    /// writer lease.
    public func beginQuiescing() async throws {
        switch mode {
        case .authoritative:
            mode = .quiescingReadOnly
        case .quiescingReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .quiescingReadOnly
            )
        case .migrationReadOnly, .validationReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .quiescingReadOnly
            )
        }

        guard !activeMutationAdmissions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            mutationDrainWaiters.append(continuation)
        }
    }

    /// Irreversibly closes mutation admission for process shutdown. Shutdown
    /// may begin from any prepared mode and repeated termination callbacks are
    /// harmless. The call returns only after every admitted mutation has
    /// completed.
    public func quiesceForShutdown() async {
        mode = .quiescingReadOnly
        guard !activeMutationAdmissions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            mutationDrainWaiters.append(continuation)
        }
    }

    /// Restores the helper only when shutdown failed before lease release.
    public func resumeAfterFailedQuiescing() throws {
        switch mode {
        case .quiescingReadOnly:
            mode = .authoritative
        case .authoritative:
            return
        case .migrationReadOnly, .validationReadOnly:
            throw GADHostIPCActivationError.invalidTransition(
                from: mode,
                to: .authoritative
            )
        }
    }

    fileprivate func admitMutation() -> GADHostIPCMutationAdmissionResult {
        guard mode == .authoritative else { return .rejected(mode) }
        let admission = GADHostIPCMutationAdmission(id: UUID())
        activeMutationAdmissions.insert(admission.id)
        return .admitted(admission)
    }

    fileprivate func completeMutation(_ admission: GADHostIPCMutationAdmission) {
        guard activeMutationAdmissions.remove(admission.id) != nil else { return }
        guard activeMutationAdmissions.isEmpty, !mutationDrainWaiters.isEmpty else { return }
        let waiters = mutationDrainWaiters
        mutationDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct GADHostIPCMutationAdmission: Sendable {
    let id: UUID
}

private enum GADHostIPCMutationAdmissionResult: Sendable {
    case admitted(GADHostIPCMutationAdmission)
    case rejected(GADHostIPCMode)
}

/// Semantic local-IPC dispatcher. The bundled helper uses migration mode until
/// lease, checkpoint, backup and snapshot-equivalence gates have all passed.
public actor GADHostIPCRequestHandler: GADHostIPCRequestHandling {
    private let hostVersion: String
    private let coordinator: GADCoordinator?
    private let localAdministration: (any GADHostLocalAdministrationHandling)?
    private let activationGate: GADHostIPCActivationGate
    private let startupFailure: String?
    private let now: @Sendable () -> Date

    public init(
        hostVersion: String,
        coordinator: GADCoordinator?,
        mode: GADHostIPCMode,
        localAdministration: (any GADHostLocalAdministrationHandling)? = nil,
        startupFailure: String? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.hostVersion = hostVersion
        self.coordinator = coordinator
        self.localAdministration = localAdministration
        self.activationGate = GADHostIPCActivationGate(mode: mode)
        self.startupFailure = startupFailure
        self.now = now
    }

    public init(
        hostVersion: String,
        coordinator: GADCoordinator?,
        activationGate: GADHostIPCActivationGate,
        localAdministration: (any GADHostLocalAdministrationHandling)? = nil,
        startupFailure: String? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.hostVersion = hostVersion
        self.coordinator = coordinator
        self.localAdministration = localAdministration
        self.activationGate = activationGate
        self.startupFailure = startupFailure
        self.now = now
    }

    public func handle(_ request: GADHostIPCRequest) async -> GADHostIPCResponse {
        let timestamp = now()
        guard request.protocolVersion == GADHostIPCRequest.currentProtocolVersion else {
            let isReadOnly = await activationGate.currentMode() != .authoritative
            return failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                disposition: .rejectedCapability,
                "The app and host protocol versions are incompatible."
            )
        }
        guard abs(request.issuedAt.timeIntervalSince(timestamp)) <= 30 else {
            let isReadOnly = await activationGate.currentMode() != .authoritative
            return failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                disposition: .rejectedExpired,
                "The local host request expired."
            )
        }

        // The permanent-host shutdown request reserves the transition before any
        // other actor hop. This closes the stale-mode window where two callers
        // could both observe `authoritative`, revoke the same authority and
        // race a second lease release. The transfer itself is deliberately not
        // counted as a mutation because this call also waits for that drain.
        let mode: GADHostIPCMode
        if request.operation.beginsPermanentHostShutdown {
            do {
                try await activationGate.beginQuiescing()
                mode = .authoritative
            } catch {
                let currentMode = await activationGate.currentMode()
                return failure(
                    requestID: request.requestID,
                    at: timestamp,
                    isReadOnly: currentMode != .authoritative,
                    disposition: .rejectedCapability,
                    "The permanent background host is already preparing for update or removal."
                )
            }
        } else {
            mode = await activationGate.currentMode()
        }
        let isReadOnly = mode != .authoritative

        if let startupFailure {
            return failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: true,
                disposition: .rejectedCapability,
                startupFailure
            )
        }

        if case .ping = request.operation {
            return response(requestID: request.requestID, at: timestamp, isReadOnly: isReadOnly)
        }
        guard mode != .migrationReadOnly, let coordinator else {
            return failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                disposition: .rejectedCapability,
                "The background host is still in read-only migration mode. Semantic ownership has not transferred."
            )
        }
        if mode == .validationReadOnly {
            switch request.operation {
            case .connect, .snapshot, .disconnect:
                break
            case .ping, .send, .events, .remoteAccessSnapshot, .remoteAccessCommand,
                 .localAdministration:
                return failure(
                    requestID: request.requestID,
                    at: timestamp,
                    isReadOnly: true,
                    disposition: .rejectedCapability,
                    "The background host is validating canonical state and cannot accept mutations or live subscriptions yet."
                )
            }
        }
        if mode == .quiescingReadOnly {
            switch request.operation {
            case .ping, .disconnect:
                break
            case .connect, .snapshot, .send, .events, .remoteAccessSnapshot,
                 .remoteAccessCommand, .localAdministration:
                return failure(
                    requestID: request.requestID,
                    at: timestamp,
                    isReadOnly: true,
                    disposition: .rejectedCapability,
                    "The permanent background host is preparing for update or removal."
                )
            }
        }

        let mutationAdmission: GADHostIPCMutationAdmission?
        if request.operation.requiresMutationAdmission {
            switch await activationGate.admitMutation() {
            case let .admitted(admission):
                mutationAdmission = admission
            case let .rejected(currentMode):
                return failure(
                    requestID: request.requestID,
                    at: timestamp,
                    isReadOnly: currentMode != .authoritative,
                    disposition: .rejectedCapability,
                    "The permanent background host is preparing for update or removal."
                )
            }
        } else {
            mutationAdmission = nil
        }

        let result: GADHostIPCResponse
        do {
            let artifact: GADHostIPCArtifact?
            switch request.operation {
            case .ping:
                artifact = nil
            case let .connect(deviceID):
                artifact = .session(try await coordinator.connect(deviceID: deviceID))
            case let .snapshot(deviceID):
                artifact = .snapshot(try await coordinator.snapshot(deviceID: deviceID))
            case let .send(command):
                artifact = .acknowledgement(await coordinator.send(command))
            case let .events(eventRequest):
                let replay = try await coordinator.replay(
                    deviceID: eventRequest.deviceID,
                    after: eventRequest.afterRevision,
                    maximumCount: eventRequest.maximumCount
                )
                let fitting = fittingEventPrefix(
                    replay,
                    requestID: request.requestID,
                    at: timestamp,
                    isReadOnly: isReadOnly
                )
                if replay.isEmpty || !fitting.isEmpty {
                    artifact = .deltas(fitting)
                } else {
                    let snapshot = try await coordinator.replaySnapshot(deviceID: eventRequest.deviceID)
                    guard !fittingEventPrefix(
                        [snapshot], requestID: request.requestID,
                        at: timestamp, isReadOnly: isReadOnly
                    ).isEmpty else {
                        throw GADCommandFailure(
                            .failedRecoverable,
                            "The current dashboard state is too large for local delivery. Reduce active output and reconnect."
                        )
                    }
                    artifact = .deltas([snapshot])
                }
            case .disconnect:
                artifact = nil
            case .remoteAccessSnapshot:
                guard let localAdministration else {
                    throw GADCommandFailure(
                        .rejectedCapability,
                        "The background host does not expose local Remote Access administration."
                    )
                }
                artifact = .remoteAccess(await localAdministration.remoteAccessSnapshot())
            case let .remoteAccessCommand(command):
                guard let localAdministration else {
                    throw GADCommandFailure(
                        .rejectedCapability,
                        "The background host does not expose local Remote Access administration."
                    )
                }
                artifact = .remoteAccess(
                    await localAdministration.applyRemoteAccessCommand(command)
                )
            case let .localAdministration(command):
                guard let localAdministration else {
                    throw GADCommandFailure(
                        .rejectedCapability,
                        "The background host does not expose local administration."
                    )
                }
                artifact = try await localAdministration.applyLocalCommand(command)
            }
            result = response(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                artifact: artifact
            )
        } catch let failure as GADCommandFailure {
            result = self.failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                disposition: failure.disposition,
                failure.message
            )
        } catch {
            result = failure(
                requestID: request.requestID,
                at: timestamp,
                isReadOnly: isReadOnly,
                "The background host could not complete the semantic request."
            )
        }
        if let mutationAdmission {
            await activationGate.completeMutation(mutationAdmission)
        }
        return result
    }

    func fittingEventPrefix(
        _ deltas: [GADStateDelta],
        requestID: UUID,
        at timestamp: Date,
        isReadOnly: Bool
    ) -> [GADStateDelta] {
        var lower = 0
        var upper = deltas.count
        while lower < upper {
            let count = lower + (upper - lower + 1) / 2
            let candidate = response(
                requestID: requestID, at: timestamp, isReadOnly: isReadOnly,
                artifact: .deltas(Array(deltas.prefix(count)))
            )
            if (try? GADHostIPCCodec.encodeResponse(candidate)) != nil {
                lower = count
            } else {
                upper = count - 1
            }
        }
        return Array(deltas.prefix(lower))
    }

    private func response(
        requestID: UUID,
        at timestamp: Date,
        isReadOnly: Bool,
        artifact: GADHostIPCArtifact? = nil
    ) -> GADHostIPCResponse {
        GADHostIPCResponse(
            requestID: requestID,
            hostVersion: hostVersion,
            generatedAt: timestamp,
            isReadOnly: isReadOnly,
            artifact: artifact
        )
    }

    private func failure(
        requestID: UUID,
        at timestamp: Date,
        isReadOnly: Bool,
        disposition: GADCommandDisposition? = nil,
        _ message: String
    ) -> GADHostIPCResponse {
        GADHostIPCResponse(
            requestID: requestID,
            hostVersion: hostVersion,
            generatedAt: timestamp,
            isReadOnly: isReadOnly,
            failureDisposition: disposition,
            error: message
        )
    }
}

private extension GADHostIPCOperation {
    var beginsPermanentHostShutdown: Bool {
        guard case let .localAdministration(command) = self,
              case .preparePermanentHostShutdown = command else {
            return false
        }
        return true
    }

    var requiresMutationAdmission: Bool {
        switch self {
        case .send, .remoteAccessCommand:
            true
        case let .localAdministration(command):
            if case .preparePermanentHostShutdown = command {
                false
            } else {
                true
            }
        case .ping, .connect, .snapshot, .events, .disconnect, .remoteAccessSnapshot:
            false
        }
    }
}
