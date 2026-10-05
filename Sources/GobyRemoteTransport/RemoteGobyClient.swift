import CryptoKit
import Foundation
import GobyApplication
import GobyRemoteContract

public enum GADRemoteClientError: LocalizedError, Sendable {
    case disconnected
    case malformedRelayFrame
    case incompatibleHost
    case hostRejected(String)
    case requestAlreadyPending(String)
    case requestTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The Goby host connection closed."
        case .malformedRelayFrame: "The relay delivered an invalid Goby frame."
        case .incompatibleHost: "This Goby host uses an incompatible protocol."
        case let .hostRejected(reason): reason
        case let .requestAlreadyPending(operation): "A remote \(operation) request is already waiting for the Mac."
        case let .requestTimedOut(operation): "The Mac did not answer the remote \(operation) request in time."
        }
    }
}

public enum GADRelayRole: String, Codable, Sendable {
    case host
    case device
}

public struct GADRelayFrame: Codable, Equatable, Sendable {
    public let hostID: HostID
    public let deviceID: DeviceID
    public let recipient: GADRelayRole
    public let envelope: GADSealedEnvelope

    public init(hostID: HostID, deviceID: DeviceID, recipient: GADRelayRole, envelope: GADSealedEnvelope) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.recipient = recipient
        self.envelope = envelope
    }
}

protocol GADWebSocketTransport: Sendable {
    func connect() async
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public actor GADWebSocketConnection: GADWebSocketTransport {
    private let requestProvider: @Sendable () -> URLRequest
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    public init(requestProvider: @escaping @Sendable () -> URLRequest) {
        self.requestProvider = requestProvider
    }

    public func connect() {
        guard task == nil else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: requestProvider())
        self.session = session
        self.task = task
        task.resume()
    }

    public func send(_ data: Data) async throws {
        guard let task else { throw GADRemoteClientError.disconnected }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        guard let task else { throw GADRemoteClientError.disconnected }
        switch try await task.receive() {
        case let .data(data): return data
        case let .string(text):
            guard let data = text.data(using: .utf8) else { throw GADRemoteClientError.malformedRelayFrame }
            return data
        @unknown default:
            throw GADRemoteClientError.malformedRelayFrame
        }
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}

public actor RemoteGobyClient: GobyClient {
    private let profile: GADPairingProfile
    private let codec: GADWireCodec
    private let cryptor: GADEnvelopeCryptor
    private let connection: any GADWebSocketTransport
    private let relayControl: GADRelayNotificationClient
    private let identitySigner: any GADDeviceIdentitySigning
    private let authorizationSigner: any GADDeviceAuthorizationSigning
    private let requestTimeout: Duration
    private let replayProtector = GADReplayProtector()
    private var outboundSequence: UInt64 = GADSequenceSeed.make()
    private var listener: Task<Void, Never>?
    private var connectedSession: ClientSession?
    private var latestSnapshot: DashboardProjection?
    private var helloContinuation: CheckedContinuation<ClientSession, any Error>?
    private var snapshotContinuation: CheckedContinuation<DashboardProjection, any Error>?
    private var acknowledgementContinuations: [CommandID: CheckedContinuation<GADCommandAcknowledgement, any Error>] = [:]
    private var helloRequestMessageID: UUID?
    private var snapshotRequestMessageID: UUID?
    private var acknowledgementRequestMessageIDs: [CommandID: UUID] = [:]
    private var replayRequestMessageID: UUID?
    private var eventContinuations: [UUID: AsyncStream<GADStateDelta>.Continuation] = [:]
    private var lifecycleContinuations: [UUID: AsyncStream<GobyClientLifecycleEvent>.Continuation] = [:]
    private var helloTimeoutTask: Task<Void, Never>?
    private var snapshotTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTasks: [CommandID: Task<Void, Never>] = [:]

    public init(
        profile: GADPairingProfile,
        identitySigner: any GADDeviceIdentitySigning = GADDeviceIdentityStore(),
        authorizationSigner: any GADDeviceAuthorizationSigning = GADDeviceAuthorizationStore(),
        relayControl: GADRelayNotificationClient = .init(),
        maximumMessageBytes: Int = GADWireCodec.defaultMaximumBytes,
        requestTimeout: Duration = .seconds(30)
    ) throws {
        try self.init(
            profile: profile,
            identitySigner: identitySigner,
            authorizationSigner: authorizationSigner,
            relayControl: relayControl,
            connection: GADWebSocketConnection {
                GADRelayURLBuilder.request(for: profile, role: .device)
            },
            maximumMessageBytes: maximumMessageBytes,
            requestTimeout: requestTimeout
        )
    }

    init(
        profile: GADPairingProfile,
        identitySigner: any GADDeviceIdentitySigning = GADDeviceIdentityStore(),
        authorizationSigner: any GADDeviceAuthorizationSigning = GADDeviceAuthorizationStore(),
        relayControl: GADRelayNotificationClient,
        connection: any GADWebSocketTransport,
        maximumMessageBytes: Int = GADWireCodec.defaultMaximumBytes,
        requestTimeout: Duration = .seconds(30)
    ) throws {
        self.profile = profile
        self.identitySigner = identitySigner
        self.authorizationSigner = authorizationSigner
        self.relayControl = relayControl
        self.requestTimeout = requestTimeout
        let codec = GADWireCodec(maximumBytes: maximumMessageBytes)
        self.codec = codec
        self.cryptor = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion,
            codec: codec
        )
        self.connection = connection
    }

    public func connect() async throws -> ClientSession {
        if let connectedSession { return connectedSession }
        guard helloContinuation == nil else { throw GADRemoteClientError.requestAlreadyPending("connection") }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                helloContinuation = continuation
                helloRequestMessageID = requestID
                scheduleHelloTimeout(requestID: requestID)
                Task { await self.beginHandshake(requestID: requestID) }
            }
        } onCancel: {
            Task { await self.cancelHelloRequest(requestID: requestID) }
        }
    }

    public func snapshot() async throws -> DashboardProjection {
        guard connectedSession != nil else { throw GADRemoteClientError.disconnected }
        guard snapshotContinuation == nil else { throw GADRemoteClientError.requestAlreadyPending("snapshot") }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                snapshotContinuation = continuation
                snapshotRequestMessageID = requestID
                scheduleSnapshotTimeout(requestID: requestID)
                Task { await self.sendSnapshotRequest(requestID: requestID) }
            }
        } onCancel: {
            Task { await self.cancelSnapshotRequest(requestID: requestID) }
        }
    }

    public func send(_ command: GADCommand) async throws -> GADCommandAcknowledgement {
        guard connectedSession != nil else { throw GADRemoteClientError.disconnected }
        guard acknowledgementContinuations[command.id] == nil else {
            throw GADRemoteClientError.requestAlreadyPending("command")
        }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                acknowledgementContinuations[command.id] = continuation
                acknowledgementRequestMessageIDs[command.id] = requestID
                scheduleAcknowledgementTimeout(for: command.id, requestID: requestID)
                Task { await self.sendCommand(command, requestID: requestID) }
            }
        } onCancel: {
            Task { await self.cancelCommandRequest(command.id, requestID: requestID) }
        }
    }

    public func events(after revision: StateRevision) -> AsyncStream<GADStateDelta> {
        let pair = AsyncStream<GADStateDelta>.makeStream(bufferingPolicy: .bufferingNewest(500))
        let id = UUID()
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        let requestID = UUID()
        replayRequestMessageID = requestID
        Task { await self.sendReplayRequest(after: revision, requestID: requestID) }
        return pair.stream
    }

    public func lifecycleEvents() -> AsyncStream<GobyClientLifecycleEvent> {
        let pair = AsyncStream<GobyClientLifecycleEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let id = UUID()
        lifecycleContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLifecycleContinuation(id) }
        }
        return pair.stream
    }

    public func disconnect() async {
        listener?.cancel()
        listener = nil
        await connection.close()
        finishPending(with: GADRemoteClientError.disconnected)
    }

    private func beginHandshake(requestID: UUID) async {
        do {
            let routeStatus = try await relayControl.routeStatus(for: profile, role: .device)
            guard helloRequestMessageID == requestID,
                  helloContinuation != nil else { return }
            guard routeStatus == .active else {
                throw GADCommandFailure(.rejectedRevoked, "This iPhone was revoked on the Goby host.")
            }
            await connection.connect()
            guard helloRequestMessageID == requestID,
                  helloContinuation != nil else { return }
            if listener == nil {
                listener = Task { [weak self] in await self?.receiveLoop() }
            }
            try await transmit(.clientHello(
                deviceID: profile.deviceID,
                supportedVersions: GADProtocolVersion.supportedVersions,
                lastHostEpoch: connectedSession?.hostEpoch,
                lastRevision: latestSnapshot?.revision
            ), messageID: requestID)
        } catch {
            guard helloRequestMessageID == requestID else { return }
            publishLifecycle(for: error)
            failHandshake(error, requestID: requestID)
        }
    }

    private func sendSnapshotRequest(requestID: UUID) async {
        guard snapshotRequestMessageID == requestID,
              snapshotContinuation != nil else { return }
        do { try await transmit(.snapshotRequest, messageID: requestID) }
        catch { failSnapshot(error, requestID: requestID) }
    }

    private func sendReplayRequest(after revision: StateRevision, requestID: UUID) async {
        guard replayRequestMessageID == requestID else { return }
        do {
            try await transmit(.replayRequest(after: revision), messageID: requestID)
        } catch {
            if replayRequestMessageID == requestID {
                replayRequestMessageID = nil
            }
        }
    }

    private func sendCommand(_ command: GADCommand, requestID: UUID) async {
        do {
            guard acknowledgementRequestMessageIDs[command.id] == requestID,
                  acknowledgementContinuations[command.id] != nil else { return }
            if profile.protocolVersion.major >= GADProtocolVersion.version3.major {
                guard let identityPublicKey = profile.deviceIdentityPublicKey else {
                    throw GADDeviceCommandAuthenticationError.identityMismatch
                }
                let signed = try await GADDeviceCommandAuthenticator.sign(
                    command,
                    expectedPublicKey: identityPublicKey,
                    signer: identitySigner,
                    expectedAuthorizationPublicKey: profile.deviceAuthorizationPublicKey,
                    authorizationSigner: authorizationSigner,
                    codec: codec
                )
                guard acknowledgementRequestMessageIDs[command.id] == requestID else { return }
                try await transmit(.signedCommand(signed), messageID: requestID)
            } else {
                try await transmit(.command(command), messageID: requestID)
            }
        }
        catch GADDeviceCommandAuthenticationError.authorizationIdentityMismatch {
            guard acknowledgementRequestMessageIDs[command.id] == requestID else { return }
            acknowledgementRequestMessageIDs.removeValue(forKey: command.id)
            acknowledgementTimeoutTasks.removeValue(forKey: command.id)?.cancel()
            acknowledgementContinuations.removeValue(forKey: command.id)?.resume(
                throwing: GobyClientLocalError.localAuthenticationUnavailable
            )
        } catch {
            guard acknowledgementRequestMessageIDs[command.id] == requestID else { return }
            acknowledgementRequestMessageIDs.removeValue(forKey: command.id)
            acknowledgementTimeoutTasks.removeValue(forKey: command.id)?.cancel()
            acknowledgementContinuations.removeValue(forKey: command.id)?.resume(throwing: error)
        }
    }

    private func transmit(
        _ message: GADWireMessage,
        messageID: UUID = UUID(),
        replyToMessageID: UUID? = nil
    ) async throws {
        outboundSequence &+= 1
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: connectedSession?.protocolVersion ?? GADProtocolVersion.current,
            messageID: messageID,
            replyToMessageID: replyToMessageID,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sequence: outboundSequence,
            sentAt: .now,
            message: message
        )
        let sealed = try cryptor.seal(unsigned, hostID: profile.hostID)
        let frame = GADRelayFrame(hostID: profile.hostID, deviceID: profile.deviceID, recipient: .host, envelope: sealed)
        try await connection.send(codec.encode(frame))
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await connection.receive()
                let frame = try codec.decode(GADRelayFrame.self, from: data)
                guard frame.hostID == profile.hostID,
                      frame.deviceID == profile.deviceID,
                      frame.recipient == .device else {
                    throw GADRemoteClientError.malformedRelayFrame
                }
                let unsigned = try cryptor.open(frame.envelope)
                try await replayProtector.accept(deviceID: profile.deviceID, sequence: unsigned.sequence)
                try await receive(unsigned)
            }
        } catch {
            listener = nil
            await connection.close()
            publishLifecycle(for: error)
            finishPending(with: error)
        }
    }

    private func receive(_ envelope: GADUnsignedEnvelope) async throws {
        guard envelope.hostID == profile.hostID else {
            throw GADRemoteClientError.malformedRelayFrame
        }
        switch envelope.message {
        case let .serverHello(session):
            guard session.hostID == profile.hostID,
                  session.protocolVersion == GADProtocolVersion.current,
                  envelope.protocolVersion == session.protocolVersion else {
                throw GADRemoteClientError.incompatibleHost
            }
            guard let requestID = helloRequestMessageID,
                  helloContinuation != nil else { return }
            guard let replyToMessageID = envelope.replyToMessageID else {
                throw GADRemoteClientError.incompatibleHost
            }
            guard replyToMessageID == requestID else { return }
            connectedSession = session
            helloRequestMessageID = nil
            helloTimeoutTask?.cancel()
            helloTimeoutTask = nil
            helloContinuation?.resume(returning: session)
            helloContinuation = nil
        case let .snapshot(snapshot):
            guard envelope.protocolVersion == connectedSession?.protocolVersion,
                  snapshot.host.id == profile.hostID,
                  snapshot.revision >= (connectedSession?.revision ?? .zero) else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard let requestID = snapshotRequestMessageID,
                  snapshotContinuation != nil else { return }
            guard let replyToMessageID = envelope.replyToMessageID else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard replyToMessageID == requestID else { return }
            latestSnapshot = snapshot
            snapshotRequestMessageID = nil
            snapshotTimeoutTask?.cancel()
            snapshotTimeoutTask = nil
            snapshotContinuation?.resume(returning: snapshot)
            snapshotContinuation = nil
        case let .acknowledgement(acknowledgement):
            guard envelope.protocolVersion == connectedSession?.protocolVersion else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard let requestID = acknowledgementRequestMessageIDs[acknowledgement.commandID],
                  acknowledgementContinuations[acknowledgement.commandID] != nil else { return }
            guard let replyToMessageID = envelope.replyToMessageID else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard replyToMessageID == requestID else { return }
            acknowledgementRequestMessageIDs.removeValue(forKey: acknowledgement.commandID)
            acknowledgementTimeoutTasks.removeValue(forKey: acknowledgement.commandID)?.cancel()
            acknowledgementContinuations.removeValue(forKey: acknowledgement.commandID)?.resume(returning: acknowledgement)
        case let .delta(delta):
            guard envelope.protocolVersion == connectedSession?.protocolVersion else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard let requestID = replayRequestMessageID else { return }
            guard let replyToMessageID = envelope.replyToMessageID else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            guard replyToMessageID == requestID else { return }
            for continuation in eventContinuations.values { continuation.yield(delta) }
        case let .ping(id):
            guard envelope.protocolVersion == connectedSession?.protocolVersion,
                  envelope.replyToMessageID == nil else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            try await transmit(.pong(id), replyToMessageID: envelope.messageID)
        case let .disconnect(reason):
            guard envelope.protocolVersion == connectedSession?.protocolVersion,
                  envelope.replyToMessageID == nil else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            if reason == "device-revoked" {
                throw GADCommandFailure(.rejectedRevoked, "This iPhone was revoked on the Goby host.")
            }
            if reason == "incompatible-protocol" {
                throw GADRemoteClientError.incompatibleHost
            }
            throw GADRemoteClientError.hostRejected(reason)
        case .pairingRequest, .authenticatedPairingRequest,
             .authenticatedPairingChallenge, .authenticatedPairingResponse,
             .pairingAccepted, .pairingRejected,
             .clientHello, .snapshotRequest, .replayRequest, .command, .signedCommand, .pong:
            throw GADRemoteClientError.malformedRelayFrame
        }
    }

    private func failHandshake(_ error: any Error, requestID: UUID) {
        guard helloRequestMessageID == requestID else { return }
        helloRequestMessageID = nil
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        helloContinuation?.resume(throwing: error)
        helloContinuation = nil
    }

    private func failSnapshot(_ error: any Error, requestID: UUID) {
        guard snapshotRequestMessageID == requestID else { return }
        snapshotRequestMessageID = nil
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        snapshotContinuation?.resume(throwing: error)
        snapshotContinuation = nil
    }

    private func finishPending(with error: any Error) {
        connectedSession = nil
        helloRequestMessageID = nil
        snapshotRequestMessageID = nil
        replayRequestMessageID = nil
        acknowledgementRequestMessageIDs.removeAll()
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        for task in acknowledgementTimeoutTasks.values { task.cancel() }
        acknowledgementTimeoutTasks.removeAll()
        helloContinuation?.resume(throwing: error)
        helloContinuation = nil
        snapshotContinuation?.resume(throwing: error)
        snapshotContinuation = nil
        for continuation in acknowledgementContinuations.values { continuation.resume(throwing: error) }
        acknowledgementContinuations.removeAll()
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    private func publishLifecycle(for error: any Error) {
        let event: GobyClientLifecycleEvent
        if let failure = error as? GADCommandFailure,
           failure.disposition == .rejectedRevoked {
            event = .revoked
        } else if let remoteError = error as? GADRemoteClientError {
            if case .incompatibleHost = remoteError {
                event = .incompatible
            } else {
                event = .transportLost
            }
        } else {
            event = .transportLost
        }
        for continuation in lifecycleContinuations.values { continuation.yield(event) }
    }

    private func removeLifecycleContinuation(_ id: UUID) {
        lifecycleContinuations.removeValue(forKey: id)
    }

    private func scheduleHelloTimeout(requestID: UUID) {
        helloTimeoutTask?.cancel()
        let timeout = requestTimeout
        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutHelloRequest(requestID: requestID)
        }
    }

    private func scheduleSnapshotTimeout(requestID: UUID) {
        snapshotTimeoutTask?.cancel()
        let timeout = requestTimeout
        snapshotTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutSnapshotRequest(requestID: requestID)
        }
    }

    private func scheduleAcknowledgementTimeout(for commandID: CommandID, requestID: UUID) {
        acknowledgementTimeoutTasks.removeValue(forKey: commandID)?.cancel()
        let timeout = requestTimeout
        acknowledgementTimeoutTasks[commandID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutCommandRequest(commandID, requestID: requestID)
        }
    }

    private func timeoutHelloRequest(requestID: UUID) async {
        guard helloRequestMessageID == requestID,
              let continuation = helloContinuation else { return }
        helloContinuation = nil
        helloRequestMessageID = nil
        helloTimeoutTask = nil
        continuation.resume(throwing: GADRemoteClientError.requestTimedOut("connection"))
        listener?.cancel()
        listener = nil
        connectedSession = nil
        await connection.close()
    }

    private func timeoutSnapshotRequest(requestID: UUID) {
        guard snapshotRequestMessageID == requestID,
              let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        snapshotRequestMessageID = nil
        snapshotTimeoutTask = nil
        continuation.resume(throwing: GADRemoteClientError.requestTimedOut("snapshot"))
    }

    private func timeoutCommandRequest(_ commandID: CommandID, requestID: UUID) {
        guard acknowledgementRequestMessageIDs[commandID] == requestID else { return }
        acknowledgementRequestMessageIDs.removeValue(forKey: commandID)
        acknowledgementTimeoutTasks.removeValue(forKey: commandID)
        acknowledgementContinuations.removeValue(forKey: commandID)?.resume(
            throwing: GADRemoteClientError.requestTimedOut("command")
        )
    }

    private func cancelHelloRequest(requestID: UUID) async {
        guard helloRequestMessageID == requestID,
              let continuation = helloContinuation else { return }
        helloContinuation = nil
        helloRequestMessageID = nil
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        continuation.resume(throwing: CancellationError())
        listener?.cancel()
        listener = nil
        connectedSession = nil
        await connection.close()
    }

    private func cancelSnapshotRequest(requestID: UUID) {
        guard snapshotRequestMessageID == requestID,
              let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        snapshotRequestMessageID = nil
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        continuation.resume(throwing: CancellationError())
    }

    private func cancelCommandRequest(_ commandID: CommandID, requestID: UUID) {
        guard acknowledgementRequestMessageIDs[commandID] == requestID else { return }
        acknowledgementRequestMessageIDs.removeValue(forKey: commandID)
        acknowledgementTimeoutTasks.removeValue(forKey: commandID)?.cancel()
        acknowledgementContinuations.removeValue(forKey: commandID)?.resume(throwing: CancellationError())
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

}

enum GADSequenceSeed {
    static func make(now: Date = .now) -> UInt64 {
        // A time-based high-water mark keeps replay ordering valid across host
        // process restarts without persisting transport counters.
        UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
    }
}

public enum GADRelayURLBuilder {
    public static let credentialLifetime: TimeInterval = 15 * 60
    public static let revocationProofHeader = "X-Goby-Revocation-Proof"
    public static let hostAdmissionHeader = "X-Goby-Host-Admission"
    public static let deviceVerifierHashHeader = "X-Goby-Device-Verifier-Hash"

    public static func request(
        for profile: GADPairingProfile,
        role: GADRelayRole,
        hostAdmission: GADRelayHostAdmissionCredential? = nil,
        now: Date = .now
    ) -> URLRequest {
        let routeKey = SymmetricKey(data: profile.sharedSecret)
        let route = routeToken(for: profile, key: routeKey)
        let deviceVerifierData = authenticationCode(
            for: Data("goby-relay-device-verifier-v2:\(route)".utf8),
            key: routeKey
        )
        let verifierKeyData: Data
        switch role {
        case .device:
            verifierKeyData = deviceVerifierData
        case .host:
            guard let relayHostSecret = profile.relayHostSecret,
                  relayHostSecret.count == 32 else {
                var denied = URLRequest(url: profile.relayURL)
                denied.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                return denied
            }
            verifierKeyData = authenticationCode(
                for: Data("goby-relay-host-verifier-v2:\(route)".utf8),
                key: SymmetricKey(data: relayHostSecret)
            )
        }
        let verifier = base64URL(verifierKeyData)
        let expiresAt = Int64(now.timeIntervalSince1970 + credentialLifetime)
        let credential = token(
            for: Data("goby-relay-connection-v1:\(route):\(role.rawValue):\(expiresAt)".utf8),
            key: SymmetricKey(data: verifierKeyData)
        )
        var request = URLRequest(url: profile.relayURL)
        request.setValue(route, forHTTPHeaderField: "X-Goby-Route")
        request.setValue(role.rawValue, forHTTPHeaderField: "X-Goby-Role")
        request.setValue(String(expiresAt), forHTTPHeaderField: "X-Goby-Credential-Expires-At")
        request.setValue(verifier, forHTTPHeaderField: "X-Goby-Route-Verifier")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if role == .host, let hostAdmission {
            request.setValue(
                hostAdmission.rawValue,
                forHTTPHeaderField: hostAdmissionHeader
            )
            request.setValue(
                sha256Token(base64URL(deviceVerifierData)),
                forHTTPHeaderField: deviceVerifierHashHeader
            )
        }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// Opaque host-authenticated proof retained by the untrusted relay. A 410
    /// can erase iPhone state only when it carries this exact profile-bound MAC.
    public static func revocationProof(for profile: GADPairingProfile) -> String {
        if let relayRevocationProof = profile.relayRevocationProof {
            return relayRevocationProof
        }
        guard let relayHostSecret = profile.relayHostSecret else { return "" }
        return token(
            for: revocationMaterial(for: profile),
            key: SymmetricKey(data: relayHostSecret)
        )
    }

    public static func isValidRevocationProof(
        _ candidate: String,
        for profile: GADPairingProfile
    ) -> Bool {
        guard let expected = data(fromBase64URL: revocationProof(for: profile)),
              let actual = data(fromBase64URL: candidate),
              expected.count == 32,
              actual.count == expected.count else { return false }
        return zip(expected, actual).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func routeToken(
        for profile: GADPairingProfile,
        key: SymmetricKey
    ) -> String {
        token(
            for: Data("goby-route-v1".utf8)
                + Data(profile.hostID.rawValue.utf8)
                + Data(profile.deviceID.rawValue.utf8),
            key: key
        )
    }

    private static func sha256Token(_ value: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private static func revocationMaterial(for profile: GADPairingProfile) -> Data {
        let key = SymmetricKey(data: profile.sharedSecret)
        let fields = [
            "goby-relay-revocation-v1",
            routeToken(for: profile, key: key),
            profile.hostID.rawValue,
            profile.deviceID.rawValue,
        ]
        var material = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(bytes)
        }
        return material
    }

    private static func token(for data: Data, key: SymmetricKey) -> String {
        base64URL(authenticationCode(for: data, key: key))
    }

    private static func authenticationCode(for data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64URL source: String) -> Data? {
        guard source.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            return nil
        }
        var base64 = source
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
