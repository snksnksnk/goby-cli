import Foundation

/// Typed request/reply transport implemented by the macOS XPC client. Keeping
/// the transport behind this port lets `GobyClient` remain independent of XPC.
public protocol GADHostIPCTransporting: Sendable {
    func exchange(_ request: GADHostIPCRequest) async throws -> GADHostIPCResponse
}

public enum GADHostIPCClientError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case incompatibleVersion
    case hostReadOnly
    case hostUnavailable(String)
    /// The running app's signed bundle was replaced on disk (an Xcode build,
    /// an update, or a copy over the running app). macOS code-signing checks
    /// then reject every XPC message in both directions, so retrying can never
    /// succeed; only relaunching the replaced bundle restores the connection.
    case applicationReplaced

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The background host returned an invalid semantic response."
        case .incompatibleVersion:
            "The app and background host use incompatible local protocols."
        case .hostReadOnly:
            "The background host has not completed ownership validation."
        case let .hostUnavailable(message):
            message
        case .applicationReplaced:
            "Goby was rebuilt or updated while it was open. Relaunch Goby to reconnect to the background host."
        }
    }
}

/// Application-facing local client used by the macOS presentation process
/// after host ownership has transferred. The helper remains the sole authority;
/// this adapter never opens persistence or provider processes itself.
public actor GADHostIPCGobyClient: GobyClient {
    private let transport: any GADHostIPCTransporting
    private let deviceID: DeviceID
    private let eventBatchSize: Int
    private let idlePollInterval: Duration
    private var eventTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        transport: any GADHostIPCTransporting,
        deviceID: DeviceID,
        eventBatchSize: Int = 200,
        idlePollInterval: Duration = .milliseconds(250)
    ) {
        self.transport = transport
        self.deviceID = deviceID
        self.eventBatchSize = min(max(eventBatchSize, 1), GADHostIPCEventRequest.maximumEventCount)
        self.idlePollInterval = max(idlePollInterval, .milliseconds(50))
    }

    public func connect() async throws -> ClientSession {
        let response = try await request(.connect(deviceID))
        guard case let .session(session) = response.artifact else {
            throw GADHostIPCClientError.invalidResponse
        }
        return session
    }

    public func snapshot() async throws -> DashboardProjection {
        let response = try await request(.snapshot(deviceID))
        guard case let .snapshot(projection) = response.artifact else {
            throw GADHostIPCClientError.invalidResponse
        }
        return projection
    }

    public func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        guard command.deviceID == deviceID else {
            throw GADHostIPCClientError.invalidResponse
        }
        let response = try await request(.send(command))
        guard case let .acknowledgement(acknowledgement) = response.artifact,
              acknowledgement.commandID == command.id else {
            throw GADHostIPCClientError.invalidResponse
        }
        return acknowledgement
    }

    public func events(after revision: StateRevision) async -> AsyncStream<GADStateDelta> {
        let streamID = UUID()
        let pair = AsyncStream<GADStateDelta>.makeStream(bufferingPolicy: .bufferingNewest(500))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.pollEvents(after: revision, into: pair.continuation)
        }
        eventTasks[streamID] = task
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.stopEventTask(streamID) }
        }
        return pair.stream
    }

    public func disconnect() async {
        let tasks = eventTasks.values
        eventTasks.removeAll()
        for task in tasks { task.cancel() }
        _ = try? await request(.disconnect(deviceID))
    }

    private func request(_ operation: GADHostIPCOperation) async throws -> GADHostIPCResponse {
        let request = GADHostIPCRequest(operation: operation)
        let response = try await transport.exchange(request)
        guard response.requestID == request.requestID else {
            throw GADHostIPCClientError.invalidResponse
        }
        guard response.protocolVersion == GADHostIPCRequest.currentProtocolVersion else {
            throw GADHostIPCClientError.incompatibleVersion
        }
        if let message = response.error {
            if let disposition = response.failureDisposition {
                throw GADCommandFailure(disposition, message)
            }
            throw GADHostIPCClientError.hostUnavailable(message)
        }
        guard !response.isReadOnly else {
            throw GADHostIPCClientError.hostReadOnly
        }
        return response
    }

    private func pollEvents(
        after initialRevision: StateRevision,
        into continuation: AsyncStream<GADStateDelta>.Continuation
    ) async {
        var revision = initialRevision
        var transientFailures = 0
        do {
            while !Task.isCancelled {
                let response: GADHostIPCResponse
                do {
                    response = try await request(.events(.init(
                        deviceID: deviceID,
                        afterRevision: revision,
                        maximumCount: eventBatchSize
                    )))
                    transientFailures = 0
                } catch let failure as GADCommandFailure where failure.disposition == .rejectedRevoked {
                    throw failure
                } catch GADHostIPCClientError.incompatibleVersion {
                    throw GADHostIPCClientError.incompatibleVersion
                } catch GADHostIPCClientError.applicationReplaced {
                    throw GADHostIPCClientError.applicationReplaced
                } catch {
                    // This is a read-only cursor request. A brief helper restart
                    // can be retried without replaying a command or flashing the
                    // whole dashboard into a disconnected state.
                    transientFailures += 1
                    guard transientFailures <= 2 else { throw error }
                    try await ContinuousClock().sleep(for: .milliseconds(150 * transientFailures))
                    continue
                }
                guard case let .deltas(deltas) = response.artifact else {
                    throw GADHostIPCClientError.invalidResponse
                }
                if deltas.isEmpty {
                    try await ContinuousClock().sleep(for: idlePollInterval)
                    continue
                }
                for delta in deltas where !Task.isCancelled {
                    continuation.yield(delta)
                    revision = max(revision, delta.revision)
                }
            }
        } catch is CancellationError {
            // Normal stream termination.
        } catch {
            // `GobyClient.events` has no throwing element. Ending the stream
            // makes the feature store report stale state and reconnect safely.
        }
        continuation.finish()
    }

    private func stopEventTask(_ id: UUID) {
        eventTasks.removeValue(forKey: id)?.cancel()
    }
}

/// Same-user, same-Team administrative client for host-owned settings. These
/// operations are deliberately unavailable through the remote Goby protocol.
public actor GADHostIPCAdministrationClient {
    private let transport: any GADHostIPCTransporting

    public init(transport: any GADHostIPCTransporting) {
        self.transport = transport
    }

    public func remoteAccessSnapshot() async throws -> GADHostRemoteAccessSnapshot {
        try await exchange(.remoteAccessSnapshot)
    }

    public func apply(
        _ command: GADHostRemoteAccessCommand
    ) async throws -> GADHostRemoteAccessSnapshot {
        try await exchange(.remoteAccessCommand(command))
    }

    public func applyLocal(
        _ command: GADHostLocalCommand
    ) async throws -> GADHostIPCArtifact {
        let request = GADHostIPCRequest(operation: .localAdministration(command))
        let response = try await transport.exchange(request)
        guard response.requestID == request.requestID,
              response.protocolVersion == GADHostIPCRequest.currentProtocolVersion else {
            throw GADHostIPCClientError.invalidResponse
        }
        if let message = response.error {
            throw GADHostIPCClientError.hostUnavailable(message)
        }
        guard !response.isReadOnly else { throw GADHostIPCClientError.hostReadOnly }
        guard let artifact = response.artifact else { throw GADHostIPCClientError.invalidResponse }
        return artifact
    }

    public func preparePermanentHostShutdown() async throws -> GADOperationReceipt {
        let artifact = try await applyLocal(.preparePermanentHostShutdown)
        guard case let .localReceipt(receipt) = artifact else {
            throw GADHostIPCClientError.invalidResponse
        }
        return receipt
    }

    private func exchange(_ operation: GADHostIPCOperation) async throws -> GADHostRemoteAccessSnapshot {
        let request = GADHostIPCRequest(operation: operation)
        let response = try await transport.exchange(request)
        guard response.requestID == request.requestID,
              response.protocolVersion == GADHostIPCRequest.currentProtocolVersion else {
            throw GADHostIPCClientError.invalidResponse
        }
        if let message = response.error {
            throw GADHostIPCClientError.hostUnavailable(message)
        }
        guard !response.isReadOnly else { throw GADHostIPCClientError.hostReadOnly }
        guard case let .remoteAccess(snapshot) = response.artifact else {
            throw GADHostIPCClientError.invalidResponse
        }
        return snapshot
    }
}
