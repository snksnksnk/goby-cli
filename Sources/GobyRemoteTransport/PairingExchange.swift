import Foundation
import GobyApplication
import GobyRemoteContract
import Security

public enum GADPairingExchangeError: LocalizedError, Equatable, Sendable {
    case alreadyStarted
    case expired
    case invalidResponse
    case declined
    case timedOut
    case secureRandom(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "A Goby pairing exchange is already in progress."
        case .expired: "This Goby pairing code expired. Create a new code on the Mac."
        case .invalidResponse: "The Mac returned an invalid Goby pairing response."
        case .declined: "Pairing was not confirmed on both devices. Create a new code and try again."
        case .timedOut: "The Mac did not complete pairing in time. Make sure it is awake and try a new code."
        case let .secureRandom(status): "Goby could not create secure device session material (\(status))."
        }
    }
}

/// Exchanges the QR challenge for a distinct long-lived device session secret.
/// The challenge secret is never persisted by the iOS caller.
public actor GADPairingClient {
    private let payload: GADPairingPayload
    private let codec: GADWireCodec
    private let cryptor: GADEnvelopeCryptor
    private let connection: any GADWebSocketTransport
    private let identityStore: any GADDeviceIdentitySigning
    private let authorizationStore: any GADDeviceAuthorizationSigning
    private let timeout: Duration
    private var outboundSequence = GADSequenceSeed.make()
    private var exchangeInProgress = false
    private var heartbeatTask: Task<Void, Never>?
    private var pendingReceive: (id: UUID, continuation: CheckedContinuation<GADWireMessage, any Error>)?
    private var receiveTask: Task<Void, Never>?
    private var receiveTimeoutTask: Task<Void, Never>?

    public init(
        payload: GADPairingPayload,
        identityStore: any GADDeviceIdentitySigning = GADDeviceIdentityStore(),
        authorizationStore: any GADDeviceAuthorizationSigning = GADDeviceAuthorizationStore(),
        timeout: Duration = .seconds(30),
        maximumMessageBytes: Int = 65_536
    ) throws {
        let profile = try payload.profile()
        try self.init(
            payload: payload,
            identityStore: identityStore,
            authorizationStore: authorizationStore,
            connection: GADWebSocketConnection {
                GADRelayURLBuilder.request(for: profile, role: .device)
            },
            timeout: timeout,
            maximumMessageBytes: maximumMessageBytes
        )
    }

    init(
        payload: GADPairingPayload,
        identityStore: any GADDeviceIdentitySigning = GADDeviceIdentityStore(),
        authorizationStore: any GADDeviceAuthorizationSigning = GADDeviceAuthorizationStore(),
        connection: any GADWebSocketTransport,
        timeout: Duration = .seconds(30),
        maximumMessageBytes: Int = 65_536
    ) throws {
        self.payload = payload
        self.identityStore = identityStore
        self.authorizationStore = authorizationStore
        self.codec = GADWireCodec(maximumBytes: maximumMessageBytes)
        self.cryptor = try GADEnvelopeCryptor(
            sharedSecret: payload.oneTimeSecret,
            protocolVersion: payload.version,
            codec: GADWireCodec(maximumBytes: maximumMessageBytes)
        )
        self.connection = connection
        self.timeout = timeout
    }

    public func exchange(
        deviceDisplayName: String = "iPhone",
        confirmation: @escaping @Sendable (GADPairingConfirmation) async -> Bool = { _ in false }
    ) async throws -> GADPairingProfile {
        guard !exchangeInProgress else { throw GADPairingExchangeError.alreadyStarted }
        guard payload.expiresAt >= .now else { throw GADPairingExchangeError.expired }
        exchangeInProgress = true
        defer { exchangeInProgress = false }

        await connection.connect()
        startHeartbeat()
        defer {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
        do {
            if payload.version.major >= GADProtocolVersion.version3.major {
                let profile = try await authenticatedExchange(
                    deviceDisplayName: deviceDisplayName,
                    confirmation: confirmation
                )
                await connection.close()
                return profile
            }
            let sessionSecret = try Self.secureRandomBytes(count: 32)
            try await transmit(.pairingRequest(
                deviceID: payload.deviceID,
                sessionSecret: sessionSecret,
                deviceDisplayName: String(deviceDisplayName.prefix(120))
            ))
            let message = try await receiveBeforeTimeout()
            guard message == .pairingAccepted else { throw GADPairingExchangeError.invalidResponse }
            try? await transmit(.pairingAccepted)
            await connection.close()
            return try GADPairingProfile(
                protocolVersion: payload.version,
                relayURL: payload.relayURL,
                hostID: payload.hostID,
                deviceID: payload.deviceID,
                sharedSecret: sessionSecret,
                displayName: payload.hostDisplayName
            )
        } catch {
            await connection.close()
            throw error
        }
    }

    private func authenticatedExchange(
        deviceDisplayName: String,
        confirmation: @escaping @Sendable (GADPairingConfirmation) async -> Bool
    ) async throws -> GADPairingProfile {
        let context = try await GADAuthenticatedPairingCrypto.makeDeviceContext(
            payload: payload,
            deviceDisplayName: deviceDisplayName,
            identityStore: identityStore,
            authorizationStore: authorizationStore,
            codec: codec
        )
        try await transmit(.authenticatedPairingRequest(context.request))
        guard case let .authenticatedPairingChallenge(challenge) = try await receiveBeforeTimeout() else {
            throw GADPairingExchangeError.invalidResponse
        }
        try GADAuthenticatedPairingCrypto.validate(challenge, for: context)
        let accepted = await confirmation(GADPairingConfirmation(
            code: context.confirmationCode,
            peerDisplayName: payload.hostDisplayName
        ))
        try await transmit(.authenticatedPairingResponse(
            GADAuthenticatedPairingCrypto.response(accepted: accepted, context: context)
        ))
        guard accepted else { throw GADPairingExchangeError.declined }
        switch try await receiveBeforeTimeout() {
        case .pairingAccepted:
            try? await transmit(.pairingAccepted)
            return try GADPairingProfile(
                protocolVersion: payload.version,
                relayURL: payload.relayURL,
                hostID: payload.hostID,
                deviceID: payload.deviceID,
                sharedSecret: context.sessionSecret,
                relayRevocationProof: challenge.relayRevocationProof,
                displayName: payload.hostDisplayName,
                deviceIdentityPublicKey: context.request.material.deviceIdentityPublicKey,
                deviceAuthorizationPublicKey: context.request.material.deviceAuthorizationPublicKey
            )
        case .pairingRejected:
            throw GADPairingExchangeError.declined
        default:
            throw GADPairingExchangeError.invalidResponse
        }
    }

    private func receiveBeforeTimeout() async throws -> GADWireMessage {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceive = (id, continuation)
            receiveTask = Task {
                do {
                    finishReceive(.success(try await receiveOne()), id: id)
                } catch {
                    finishReceive(.failure(error), id: id)
                }
            }
            receiveTimeoutTask = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                finishReceive(.failure(GADPairingExchangeError.timedOut), id: id)
                await connection.close()
            }
        }
    }

    private func finishReceive(_ result: Result<GADWireMessage, any Error>, id: UUID) {
        guard let pendingReceive, pendingReceive.id == id else { return }
        self.pendingReceive = nil
        receiveTask?.cancel()
        receiveTask = nil
        receiveTimeoutTask?.cancel()
        receiveTimeoutTask = nil
        pendingReceive.continuation.resume(with: result)
    }

    private func receiveOne() async throws -> GADWireMessage {
        while true {
            let data = try await connection.receive()
            let frame = try codec.decode(GADRelayFrame.self, from: data)
            guard frame.hostID == payload.hostID,
                  frame.deviceID == payload.deviceID,
                  frame.recipient == .device else {
                throw GADPairingExchangeError.invalidResponse
            }
            let unsigned = try cryptor.open(frame.envelope)
            guard unsigned.hostID == payload.hostID,
                  unsigned.deviceID == payload.deviceID else {
                throw GADPairingExchangeError.invalidResponse
            }
            switch unsigned.message {
            case let .ping(id):
                try await transmit(.pong(id))
            case .pong:
                continue
            default:
                return unsigned.message
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    try await self.transmit(.ping(UUID()))
                } catch {
                    return
                }
            }
        }
    }

    private func transmit(_ message: GADWireMessage) async throws {
        outboundSequence &+= 1
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: payload.version,
            messageID: UUID(),
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            sequence: outboundSequence,
            sentAt: .now,
            message: message
        )
        let sealed = try cryptor.seal(unsigned, hostID: payload.hostID)
        let frame = GADRelayFrame(
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            recipient: .host,
            envelope: sealed
        )
        try await connection.send(codec.encode(frame))
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw GADPairingExchangeError.secureRandom(status) }
        return data
    }
}

/// Owns one short-lived relay route and consumes it after one successful
/// session-secret exchange. The operational host uses the rotated secret on a
/// different opaque relay route.
public actor GADPairingHost {
    private let payload: GADPairingPayload
    private let codec: GADWireCodec
    private let cryptor: GADEnvelopeCryptor
    private let connection: GADWebSocketConnection
    private let hostPrivateKey: Data?
    private let onConfirmationRequired: @Sendable (GADPairingConfirmation) async -> Bool
    private let onPairingAccepted: @Sendable (GADPairingProfile) async throws -> Void
    private let onFailure: @Sendable (String) async -> Void
    private let now: @Sendable () -> Date
    private var outboundSequence = GADSequenceSeed.make()
    private var listener: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var consumed = false

    public init(
        payload: GADPairingPayload,
        hostPrivateKey: Data? = nil,
        hostAdmission: GADRelayHostAdmissionCredential,
        onConfirmationRequired: @escaping @Sendable (GADPairingConfirmation) async -> Bool = { _ in false },
        onPairingAccepted: @escaping @Sendable (GADPairingProfile) async throws -> Void,
        onFailure: @escaping @Sendable (String) async -> Void = { _ in },
        maximumMessageBytes: Int = 65_536,
        now: @escaping @Sendable () -> Date = { .now }
    ) throws {
        self.payload = payload
        if payload.version.major >= GADProtocolVersion.version3.major {
            guard let hostPrivateKey,
                  try GADPairingHostKeyMaterial(privateKey: hostPrivateKey).publicKey
                    == payload.hostEphemeralPublicKey else {
                throw GADPairingExchangeError.invalidResponse
            }
        }
        self.hostPrivateKey = hostPrivateKey
        self.onConfirmationRequired = onConfirmationRequired
        self.onPairingAccepted = onPairingAccepted
        self.onFailure = onFailure
        self.now = now
        let codec = GADWireCodec(maximumBytes: maximumMessageBytes)
        self.codec = codec
        self.cryptor = try GADEnvelopeCryptor(
            sharedSecret: payload.oneTimeSecret,
            protocolVersion: payload.version,
            codec: codec
        )
        let baseProfile = try payload.profile()
        let profile = try GADPairingProfile(
            protocolVersion: baseProfile.protocolVersion,
            relayURL: baseProfile.relayURL,
            hostID: baseProfile.hostID,
            deviceID: baseProfile.deviceID,
            sharedSecret: baseProfile.sharedSecret,
            relayHostSecret: hostPrivateKey,
            displayName: baseProfile.displayName,
            createdAt: baseProfile.createdAt,
            sessionKeyCreatedAt: baseProfile.sessionKeyCreatedAt
        )
        self.connection = GADWebSocketConnection {
            GADRelayURLBuilder.request(
                for: profile,
                role: .host,
                hostAdmission: hostAdmission
            )
        }
    }

    public func start() async {
        guard listener == nil, !consumed else { return }
        await connection.connect()
        listener = Task { [weak self] in await self?.receivePairingRequest() }
        startHeartbeat()
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await connection.close()
    }

    private func receivePairingRequest() async {
        do {
            guard !consumed else { throw GADPairingExchangeError.invalidResponse }
            try requireFreshPairing()
            let message = try await receivePairingMessage()
            try requireFreshPairing()
            let profile: GADPairingProfile
            switch message {
            case let .pairingRequest(deviceID, sessionSecret, displayName):
                guard payload.version.major < GADProtocolVersion.version3.major,
                      deviceID == payload.deviceID,
                      sessionSecret.count == 32 else {
                    throw GADPairingExchangeError.invalidResponse
                }
                profile = try GADPairingProfile(
                    protocolVersion: payload.version,
                    relayURL: payload.relayURL,
                    hostID: payload.hostID,
                    deviceID: deviceID,
                    sharedSecret: sessionSecret,
                    displayName: String(displayName.prefix(120))
                )
            case let .authenticatedPairingRequest(request):
                guard let hostPrivateKey else { throw GADPairingExchangeError.invalidResponse }
                profile = try await authenticatedProfile(
                    request: request,
                    hostPrivateKey: hostPrivateKey
                )
            default:
                throw GADPairingExchangeError.invalidResponse
            }
            try requireFreshPairing()
            try await onPairingAccepted(profile)
            consumed = true
            try await transmit(.pairingAccepted)
            // Keep the one-time route open until the device confirms receipt.
            // A WebSocket send completing only means that the relay accepted the
            // frame; closing immediately can discard the final acceptance.
            await awaitDeviceReceipt()
        } catch {
            if !Task.isCancelled {
                await onFailure(error.localizedDescription)
            }
        }
        listener = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await connection.close()
    }

    private func authenticatedProfile(
        request: GADAuthenticatedPairingRequest,
        hostPrivateKey: Data
    ) async throws -> GADPairingProfile {
        try requireFreshPairing()
        let context = try GADAuthenticatedPairingCrypto.makeHostContext(
            payload: payload,
            hostPrivateKey: hostPrivateKey,
            request: request,
            codec: codec
        )
        let provisionalProfile = try GADPairingProfile(
            protocolVersion: payload.version,
            relayURL: payload.relayURL,
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            sharedSecret: context.sessionSecret,
            relayHostSecret: hostPrivateKey,
            displayName: request.material.deviceDisplayName,
            deviceIdentityPublicKey: request.material.deviceIdentityPublicKey,
            deviceAuthorizationPublicKey: request.material.deviceAuthorizationPublicKey
        )
        let revocationProof = GADRelayURLBuilder.revocationProof(for: provisionalProfile)
        try await transmit(.authenticatedPairingChallenge(
            GADAuthenticatedPairingCrypto.challenge(
                for: context,
                relayRevocationProof: revocationProof
            )
        ))
        try requireFreshPairing()
        let acceptedOnHost = await onConfirmationRequired(GADPairingConfirmation(
            code: context.confirmationCode,
            peerDisplayName: request.material.deviceDisplayName
        ))
        guard acceptedOnHost else {
            try? await transmit(.pairingRejected(reason: "declined-on-host"))
            throw GADPairingExchangeError.declined
        }
        try requireFreshPairing()
        guard case let .authenticatedPairingResponse(response) = try await receivePairingMessage() else {
            throw GADPairingExchangeError.invalidResponse
        }
        try requireFreshPairing()
        try GADAuthenticatedPairingCrypto.validate(response, for: context)
        guard response.accepted else {
            try? await transmit(.pairingRejected(reason: "declined-on-device"))
            throw GADPairingExchangeError.declined
        }
        try requireFreshPairing()
        return try GADPairingProfile(
            protocolVersion: payload.version,
            relayURL: payload.relayURL,
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            sharedSecret: context.sessionSecret,
            relayHostSecret: hostPrivateKey,
            relayRevocationProof: revocationProof,
            displayName: request.material.deviceDisplayName,
            deviceIdentityPublicKey: request.material.deviceIdentityPublicKey,
            deviceAuthorizationPublicKey: request.material.deviceAuthorizationPublicKey
        )
    }

    private func requireFreshPairing() throws {
        guard Self.isWithinPairingDeadline(expiresAt: payload.expiresAt, now: now()) else {
            throw GADPairingExchangeError.expired
        }
    }

    static func isWithinPairingDeadline(expiresAt: Date, now: Date) -> Bool {
        now <= expiresAt
    }

    private func receivePairingMessage() async throws -> GADWireMessage {
        while true {
            let data = try await connection.receive()
            let frame = try codec.decode(GADRelayFrame.self, from: data)
            guard frame.hostID == payload.hostID,
                  frame.deviceID == payload.deviceID,
                  frame.recipient == .host else {
                throw GADPairingExchangeError.invalidResponse
            }
            let unsigned = try cryptor.open(frame.envelope)
            guard unsigned.hostID == payload.hostID,
                  unsigned.deviceID == payload.deviceID else {
                throw GADPairingExchangeError.invalidResponse
            }
            switch unsigned.message {
            case let .ping(id):
                try await transmit(.pong(id))
            case .pong:
                continue
            default:
                return unsigned.message
            }
        }
    }

    private func awaitDeviceReceipt() async {
        let deadline = Task { [connection] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await connection.close()
        }
        defer { deadline.cancel() }
        _ = try? await receivePairingMessage()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    try await self.transmit(.ping(UUID()))
                } catch {
                    return
                }
            }
        }
    }

    private func transmit(_ message: GADWireMessage) async throws {
        outboundSequence &+= 1
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: payload.version,
            messageID: UUID(),
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            sequence: outboundSequence,
            sentAt: .now,
            message: message
        )
        let sealed = try cryptor.seal(unsigned, hostID: payload.hostID)
        let frame = GADRelayFrame(
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            recipient: .device,
            envelope: sealed
        )
        try await connection.send(codec.encode(frame))
    }
}
