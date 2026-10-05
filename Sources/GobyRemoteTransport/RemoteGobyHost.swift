import Foundation
import GobyApplication
import GobyRemoteContract

public actor RemoteGobyHost {
    private let profile: GADPairingProfile
    private let coordinator: GADCoordinator
    private let codec: GADWireCodec
    private let cryptor: GADEnvelopeCryptor
    private let connection: any GADWebSocketTransport
    private let relayControl: GADRelayNotificationClient
    private let hostAdmission: GADRelayHostAdmissionCredential
    private let onClientConnected: @Sendable (DeviceID) async -> Void
    private let onConnectionEnded: @Sendable () async -> Void
    private let onSelfRevocationAccepted: @Sendable (DeviceID) async -> Bool
    private let onSelfRevocationTransportClosed: @Sendable (DeviceID) async -> Void
    private let replayProtector = GADReplayProtector()
    private var outboundSequence: UInt64 = GADSequenceSeed.make()
    private var listener: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var clientRequestedDisconnect = false
    private var negotiatedProtocolVersion: GADProtocolVersion?
    private var activeReplayRequestMessageID: UUID?

    public init(
        profile: GADPairingProfile,
        coordinator: GADCoordinator,
        onClientConnected: @escaping @Sendable (DeviceID) async -> Void = { _ in },
        onConnectionEnded: @escaping @Sendable () async -> Void = {},
        onSelfRevocationAccepted: @escaping @Sendable (DeviceID) async -> Bool = { _ in true },
        onSelfRevocationTransportClosed: @escaping @Sendable (DeviceID) async -> Void = { _ in },
        hostAdmission: GADRelayHostAdmissionCredential,
        relayControl: GADRelayNotificationClient = .init(),
        maximumMessageBytes: Int = GADWireCodec.defaultMaximumBytes
    ) throws {
        try self.init(
            profile: profile,
            coordinator: coordinator,
            onClientConnected: onClientConnected,
            onConnectionEnded: onConnectionEnded,
            onSelfRevocationAccepted: onSelfRevocationAccepted,
            onSelfRevocationTransportClosed: onSelfRevocationTransportClosed,
            hostAdmission: hostAdmission,
            relayControl: relayControl,
            connection: GADWebSocketConnection {
                GADRelayURLBuilder.request(
                    for: profile,
                    role: .host,
                    hostAdmission: hostAdmission
                )
            },
            maximumMessageBytes: maximumMessageBytes
        )
    }

    init(
        profile: GADPairingProfile,
        coordinator: GADCoordinator,
        onClientConnected: @escaping @Sendable (DeviceID) async -> Void = { _ in },
        onConnectionEnded: @escaping @Sendable () async -> Void = {},
        onSelfRevocationAccepted: @escaping @Sendable (DeviceID) async -> Bool = { _ in true },
        onSelfRevocationTransportClosed: @escaping @Sendable (DeviceID) async -> Void = { _ in },
        hostAdmission: GADRelayHostAdmissionCredential,
        relayControl: GADRelayNotificationClient,
        connection: any GADWebSocketTransport,
        maximumMessageBytes: Int = GADWireCodec.defaultMaximumBytes
    ) throws {
        self.profile = profile
        self.coordinator = coordinator
        self.onClientConnected = onClientConnected
        self.onConnectionEnded = onConnectionEnded
        self.onSelfRevocationAccepted = onSelfRevocationAccepted
        self.onSelfRevocationTransportClosed = onSelfRevocationTransportClosed
        self.hostAdmission = hostAdmission
        self.relayControl = relayControl
        let codec = GADWireCodec(maximumBytes: maximumMessageBytes)
        self.codec = codec
        self.cryptor = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion,
            codec: codec
        )
        self.connection = connection
    }

    public func start() async {
        guard listener == nil else { return }
        await connection.connect()
        listener = Task { [weak self] in await self?.receiveLoop() }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    try await self.sendHeartbeatIfConnected()
                } catch {
                    return
                }
            }
        }
    }

    public func stop() async {
        let listener = listener
        let replayTask = replayTask
        let heartbeatTask = heartbeatTask
        listener?.cancel()
        replayTask?.cancel()
        heartbeatTask?.cancel()
        await connection.close()
        await listener?.value
        await replayTask?.value
        await heartbeatTask?.value
        self.listener = nil
        self.replayTask = nil
        self.heartbeatTask = nil
        negotiatedProtocolVersion = nil
        activeReplayRequestMessageID = nil
    }

    public func revoke(
        hostAdmission replacementAdmission: GADRelayHostAdmissionCredential? = nil
    ) async throws {
        // Local command authority is the security boundary. Remove it and stop
        // reception before awaiting the explicitly untrusted relay. A live
        // phone receives the authenticated reason before its socket closes so
        // it can erase cached state immediately; delivery remains best effort
        // because the proof-bound relay tombstone is the offline authority.
        await coordinator.revoke(profile.deviceID)
        await notifyRevocationAndStop()
        try await relayControl.revoke(
            for: profile,
            hostAdmission: replacementAdmission ?? hostAdmission
        )
    }

    public func notifyRevocationAndStop() async {
        try? await transmit(.disconnect(reason: "device-revoked"))
        await stop()
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await connection.receive()
                let frame = try codec.decode(GADRelayFrame.self, from: data)
                guard frame.hostID == profile.hostID,
                      frame.deviceID == profile.deviceID,
                      frame.recipient == .host else {
                    throw GADRemoteClientError.malformedRelayFrame
                }
                let unsigned = try cryptor.open(frame.envelope)
                try await replayProtector.accept(deviceID: profile.deviceID, sequence: unsigned.sequence)
                do {
                    try await handle(unsigned)
                } catch let failure as GADCommandFailure where failure.disposition == .rejectedRevoked {
                    try? await transmit(.disconnect(reason: "device-revoked"))
                    throw failure
                } catch GADRemoteClientError.incompatibleHost {
                    try? await transmit(.disconnect(reason: "incompatible-protocol"))
                    throw GADRemoteClientError.incompatibleHost
                }
            }
        } catch {
            let shouldReconnect = !Task.isCancelled && !clientRequestedDisconnect
            clientRequestedDisconnect = false
            listener = nil
            replayTask?.cancel()
            replayTask = nil
            negotiatedProtocolVersion = nil
            activeReplayRequestMessageID = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            await connection.close()
            if shouldReconnect {
                await onConnectionEnded()
            }
        }
    }

    private func handle(_ envelope: GADUnsignedEnvelope) async throws {
        guard envelope.hostID == profile.hostID else {
            throw GADRemoteClientError.malformedRelayFrame
        }
        switch envelope.message {
        case let .clientHello(deviceID, versions, _, _):
            let hostProtocolVersion = await coordinator.protocolVersion
            guard negotiatedProtocolVersion == nil,
                  envelope.replyToMessageID == nil,
                  envelope.protocolVersion == hostProtocolVersion,
                  hostProtocolVersion == GADProtocolVersion.current,
                  deviceID == profile.deviceID,
                  versions.contains(hostProtocolVersion) else {
                throw GADRemoteClientError.incompatibleHost
            }
            let session = try await coordinator.connect(deviceID: deviceID)
            negotiatedProtocolVersion = hostProtocolVersion
            try await transmit(.serverHello(session), replyToMessageID: envelope.messageID)
            await onClientConnected(deviceID)
        case .snapshotRequest:
            try validateRequestEnvelope(envelope)
            try await transmit(
                .snapshot(try await coordinator.snapshot(deviceID: profile.deviceID)),
                replyToMessageID: envelope.messageID
            )
        case let .replayRequest(revision):
            try validateRequestEnvelope(envelope)
            replayTask?.cancel()
            activeReplayRequestMessageID = envelope.messageID
            let coordinator = coordinator
            let deviceID = profile.deviceID
            let requestID = envelope.messageID
            replayTask = Task { [weak self] in
                let stream = await coordinator.events(deviceID: deviceID, after: revision)
                for await delta in stream {
                    guard !Task.isCancelled else { return }
                    try? await self?.transmitReplayDelta(delta, requestID: requestID)
                }
            }
        case let .command(command):
            try validateRequestEnvelope(envelope)
            guard profile.protocolVersion.major < GADProtocolVersion.version3.major,
                  command.deviceID == profile.deviceID else {
                throw GADRemoteClientError.malformedRelayFrame
            }
            let revision = await coordinator.currentProjection().revision
            try await transmit(
                .acknowledgement(Self.legacyCommandRejection(command, revision: revision)),
                replyToMessageID: envelope.messageID
            )
        case let .signedCommand(signedCommand):
            try validateRequestEnvelope(envelope)
            try await handleSignedCommand(signedCommand, requestID: envelope.messageID)
        case let .ping(id):
            try validateRequestEnvelope(envelope)
            try await transmit(.pong(id), replyToMessageID: envelope.messageID)
        case .disconnect:
            try validateRequestEnvelope(envelope)
            clientRequestedDisconnect = true
            throw GADRemoteClientError.disconnected
        case .pong:
            guard envelope.protocolVersion == negotiatedProtocolVersion,
                  envelope.replyToMessageID != nil else {
                throw GADRemoteClientError.malformedRelayFrame
            }
        case .pairingRequest, .authenticatedPairingRequest,
             .authenticatedPairingChallenge, .authenticatedPairingResponse,
             .pairingAccepted, .pairingRejected,
             .serverHello, .acknowledgement, .snapshot, .delta:
            throw GADRemoteClientError.malformedRelayFrame
        }
    }

    private func validateRequestEnvelope(_ envelope: GADUnsignedEnvelope) throws {
        guard envelope.protocolVersion == negotiatedProtocolVersion,
              envelope.replyToMessageID == nil else {
            throw GADRemoteClientError.malformedRelayFrame
        }
    }

    private func handleSignedCommand(
        _ signedCommand: GADSignedCommandEnvelope,
        requestID: UUID
    ) async throws {
        guard profile.protocolVersion.major >= GADProtocolVersion.version3.major,
              let identityPublicKey = profile.deviceIdentityPublicKey else {
            throw GADRemoteClientError.malformedRelayFrame
        }
        let command = try GADDeviceCommandAuthenticator.verify(
            signedCommand,
            expectedPublicKey: identityPublicKey,
            expectedAuthorizationPublicKey: profile.deviceAuthorizationPublicKey,
            codec: codec
        )
        guard command.deviceID == profile.deviceID else {
            throw GADRemoteClientError.malformedRelayFrame
        }
        let acknowledgement = await coordinator.send(command)
        guard case .revokeCurrentDevice = command.payload,
              acknowledgement.disposition == .accepted else {
            try await transmit(.acknowledgement(acknowledgement), replyToMessageID: requestID)
            return
        }
        guard await onSelfRevocationAccepted(profile.deviceID) else {
            let revision = await coordinator.currentProjection().revision
            try await transmit(
                .acknowledgement(.init(
                    commandID: command.id,
                    disposition: .failedRecoverable,
                    revision: revision,
                    message: "The Mac could not durably revoke this device. The pairing remains active; try again."
                )),
                replyToMessageID: requestID
            )
            return
        }
        await coordinator.revoke(profile.deviceID)
        // Local authority is gone before the success acknowledgement. Relay
        // cleanup is allowed to finish after the socket closes and is
        // retried from its durable pending record after a host restart.
        try? await transmit(.acknowledgement(acknowledgement), replyToMessageID: requestID)
        clientRequestedDisconnect = true
        await connection.close()
        await onSelfRevocationTransportClosed(profile.deviceID)
        throw GADRemoteClientError.disconnected
    }

    private func transmitReplayDelta(_ delta: GADStateDelta, requestID: UUID) async throws {
        guard activeReplayRequestMessageID == requestID else { return }
        try await transmit(.delta(delta), replyToMessageID: requestID)
    }

    private func sendHeartbeatIfConnected() async throws {
        guard negotiatedProtocolVersion != nil else { return }
        try await transmit(.ping(UUID()))
    }

    private func transmit(
        _ message: GADWireMessage,
        messageID: UUID = UUID(),
        replyToMessageID: UUID? = nil
    ) async throws {
        outboundSequence &+= 1
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: negotiatedProtocolVersion ?? profile.protocolVersion,
            messageID: messageID,
            replyToMessageID: replyToMessageID,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sequence: outboundSequence,
            sentAt: .now,
            message: message
        )
        let sealed = try cryptor.seal(unsigned, hostID: profile.hostID)
        let frame = GADRelayFrame(
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            recipient: .device,
            envelope: sealed
        )
        try await connection.send(codec.encode(frame))
    }

    nonisolated static func legacyCommandRejection(
        _ command: GADCommand,
        revision: StateRevision
    ) -> GADCommandAcknowledgement {
        GADCommandAcknowledgement(
            commandID: command.id,
            disposition: .rejectedCapability,
            revision: revision,
            message: "This legacy pairing is read-only because it cannot sign device commands. Pair this device again before making changes."
        )
    }
}
