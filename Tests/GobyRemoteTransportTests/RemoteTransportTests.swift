import CryptoKit
import Foundation
import Testing
import GobyApplication
import GobyRemoteContract
@testable import GobyRemoteTransport

private final class RelayStatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "relay-status.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 410,
            httpVersion: "HTTP/1.1",
            headerFields: [
                GADRelayURLBuilder.revocationProofHeader: String(repeating: "A", count: 1_024),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor TestDeviceIdentitySigner: GADDeviceIdentitySigning {
    private let key = P256.Signing.PrivateKey()

    func identity() async throws -> GADDeviceIdentity {
        GADDeviceIdentity(
            signingPublicKey: key.publicKey.rawRepresentation,
            protection: .keychain
        )
    }

    func sign(_ data: Data) async throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

private actor TestDeviceAuthorizationSigner: GADDeviceAuthorizationSigning {
    private let key = P256.Signing.PrivateKey()

    func publicKey() -> Data {
        key.publicKey.rawRepresentation
    }

    func signAuthorized(_ data: Data, reason: String) throws -> Data {
        _ = reason
        return try key.signature(for: data).derRepresentation
    }
}

private actor RevocationWebSocketSpy: GADWebSocketTransport {
    private let coordinator: GADCoordinator
    private let deviceID: DeviceID
    private(set) var sentFrames: [Data] = []
    private(set) var authorityWasRemovedBeforeSend = false
    private(set) var isClosed = false

    init(coordinator: GADCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
    }

    func connect() {}

    func send(_ data: Data) async throws {
        authorityWasRemovedBeforeSend = (try? await coordinator.connect(deviceID: deviceID)) == nil
        sentFrames.append(data)
    }

    func receive() throws -> Data {
        throw GADRemoteClientError.disconnected
    }

    func close() {
        isClosed = true
    }
}

private actor SelfRevocationWebSocketSpy: GADWebSocketTransport {
    private var receivedFrames: [Data]
    private(set) var sentFrames: [Data] = []
    private(set) var isClosed = false

    init(receivedFrames: [Data]) {
        self.receivedFrames = receivedFrames
    }

    func connect() {}

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func receive() throws -> Data {
        guard !receivedFrames.isEmpty else { throw GADRemoteClientError.disconnected }
        return receivedFrames.removeFirst()
    }

    func close() {
        isClosed = true
    }
}

private actor ReplayTestWebSocket: GADWebSocketTransport {
    private var receivedFrames: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data, any Error>?
    private(set) var sentFrames: [Data] = []

    func connect() {}

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func receive() async throws -> Data {
        if !receivedFrames.isEmpty {
            return receivedFrames.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func deliver(_ data: Data) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: data)
        } else {
            receivedFrames.append(data)
        }
    }

    func close() {
        receiveContinuation?.resume(throwing: GADRemoteClientError.disconnected)
        receiveContinuation = nil
    }
}

private actor SilentPairingWebSocket: GADWebSocketTransport {
    private var receiveContinuation: CheckedContinuation<Data, any Error>?
    private(set) var isClosed = false

    func connect() {}
    func send(_ data: Data) { _ = data }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() {
        isClosed = true
        receiveContinuation?.resume(throwing: GADRemoteClientError.disconnected)
        receiveContinuation = nil
    }
}

private actor AcceptedPairingWebSocket: GADWebSocketTransport {
    private let acceptance: Data
    private(set) var sentFrames: [Data] = []
    private var delivered = false

    init(acceptance: Data) { self.acceptance = acceptance }
    func connect() {}
    func send(_ data: Data) { sentFrames.append(data) }
    func receive() throws -> Data {
        guard !delivered else { throw GADRemoteClientError.disconnected }
        delivered = true
        return acceptance
    }
    func close() {}
}

private actor SelfRevocationProbe {
    private(set) var began = false
    private(set) var completed = false

    func begin() -> Bool {
        began = true
        return true
    }

    func complete() {
        completed = true
    }
}

private actor SelfRevocationCommandHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        guard case .revokeCurrentDevice = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unexpected test command.")
        }
        return GADCommandEffect(artifact: .operationReceipt(.init(
            id: deviceID.rawValue,
            summary: "Revoked",
            isUndoAvailable: false
        )))
    }
}

@Suite("GAD encrypted transport")
struct RemoteTransportTests {
    @Test("Cold-start replay cannot satisfy a new hello or snapshot request")
    func coldStartResponseReplayIsRejected() async throws {
        let profile = try profile(id: "replay-phone", name: "Replay iPhone")
        let codec = GADWireCodec()
        let cryptor = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion
        )
        let session = ClientSession(
            hostID: profile.hostID,
            hostEpoch: .init(rawValue: "replay-epoch"),
            protocolVersion: .current,
            revision: .init(rawValue: 5),
            capabilities: [.sharedDraft]
        )
        let snapshot = DashboardProjection(
            revision: .init(rawValue: 5),
            generatedAt: .now,
            host: .init(
                id: profile.hostID,
                displayName: "Studio Mac",
                reachability: .online,
                lastUpdatedAt: .now
            )
        )
        let relayControl = GADRelayNotificationClient(sender: RelayHTTPSenderSpy())

        let firstSocket = ReplayTestWebSocket()
        let firstClient = try RemoteGobyClient(
            profile: profile,
            relayControl: relayControl,
            connection: firstSocket,
            requestTimeout: .seconds(2)
        )
        let firstConnect = Task { try await firstClient.connect() }
        let firstHelloData = try await sentFrame(from: firstSocket, at: 0)
        let firstHello = try cryptor.open(codec.decode(GADRelayFrame.self, from: firstHelloData).envelope)
        guard case .clientHello = firstHello.message else {
            Issue.record("Expected the first client hello.")
            return
        }
        let capturedHello = try deviceFrame(
            profile: profile,
            sequence: 1,
            replyToMessageID: firstHello.messageID,
            message: .serverHello(session)
        )
        await firstSocket.deliver(capturedHello)
        #expect(try await firstConnect.value == session)

        let firstSnapshot = Task { try await firstClient.snapshot() }
        let firstSnapshotRequestData = try await sentFrame(from: firstSocket, at: 1)
        let firstSnapshotRequest = try cryptor.open(
            codec.decode(GADRelayFrame.self, from: firstSnapshotRequestData).envelope
        )
        guard case .snapshotRequest = firstSnapshotRequest.message else {
            Issue.record("Expected the first snapshot request.")
            return
        }
        let capturedSnapshot = try deviceFrame(
            profile: profile,
            sequence: 2,
            replyToMessageID: firstSnapshotRequest.messageID,
            message: .snapshot(snapshot)
        )
        await firstSocket.deliver(capturedSnapshot)
        let acceptedSnapshot = try await firstSnapshot.value
        #expect(acceptedSnapshot.revision == snapshot.revision)
        await firstClient.disconnect()

        let restartedSocket = ReplayTestWebSocket()
        let restartedClient = try RemoteGobyClient(
            profile: profile,
            relayControl: relayControl,
            connection: restartedSocket,
            requestTimeout: .seconds(2)
        )
        let restartedConnect = Task { try await restartedClient.connect() }
        let restartedHelloData = try await sentFrame(from: restartedSocket, at: 0)
        let restartedHello = try cryptor.open(
            codec.decode(GADRelayFrame.self, from: restartedHelloData).envelope
        )
        #expect(restartedHello.messageID != firstHello.messageID)
        await restartedSocket.deliver(capturedHello)
        do {
            _ = try await restartedConnect.value
            Issue.record("A prior-process server hello satisfied a new connection.")
        } catch {
            #expect(error is GADRemoteClientError)
        }

        let freshSocket = ReplayTestWebSocket()
        let freshClient = try RemoteGobyClient(
            profile: profile,
            relayControl: relayControl,
            connection: freshSocket,
            requestTimeout: .seconds(2)
        )
        let freshConnect = Task { try await freshClient.connect() }
        let freshHelloData = try await sentFrame(from: freshSocket, at: 0)
        let freshHello = try cryptor.open(codec.decode(GADRelayFrame.self, from: freshHelloData).envelope)
        await freshSocket.deliver(try deviceFrame(
            profile: profile,
            sequence: 1,
            replyToMessageID: freshHello.messageID,
            message: .serverHello(session)
        ))
        #expect(try await freshConnect.value == session)

        let freshSnapshot = Task { try await freshClient.snapshot() }
        let freshSnapshotRequestData = try await sentFrame(from: freshSocket, at: 1)
        let freshSnapshotRequest = try cryptor.open(
            codec.decode(GADRelayFrame.self, from: freshSnapshotRequestData).envelope
        )
        #expect(freshSnapshotRequest.messageID != firstSnapshotRequest.messageID)
        await freshSocket.deliver(capturedSnapshot)
        try await Task.sleep(for: .milliseconds(10))
        await freshSocket.deliver(try deviceFrame(
            profile: profile,
            sequence: 3,
            replyToMessageID: freshSnapshotRequest.messageID,
            message: .snapshot(snapshot)
        ))
        let freshAcceptedSnapshot = try await freshSnapshot.value
        #expect(freshAcceptedSnapshot.revision == snapshot.revision)

        let refresh = Task { try await freshClient.snapshot() }
        let refreshRequestData = try await sentFrame(from: freshSocket, at: 2)
        let refreshRequest = try cryptor.open(
            codec.decode(GADRelayFrame.self, from: refreshRequestData).envelope
        )
        #expect(refreshRequest.messageID != freshSnapshotRequest.messageID)
        await freshSocket.deliver(try deviceFrame(
            profile: profile,
            sequence: 4,
            replyToMessageID: refreshRequest.messageID,
            message: .snapshot(snapshot)
        ))
        let refreshedSnapshot = try await refresh.value
        #expect(refreshedSnapshot.revision == snapshot.revision)
    }

    @Test("Pairing freshness covers the complete transaction deadline")
    func pairingDeadline() {
        let expiry = Date(timeIntervalSince1970: 100)

        #expect(GADPairingHost.isWithinPairingDeadline(
            expiresAt: expiry,
            now: Date(timeIntervalSince1970: 100)
        ))
        #expect(!GADPairingHost.isWithinPairingDeadline(
            expiresAt: expiry,
            now: Date(timeIntervalSince1970: 100.001)
        ))
    }

    @Test("Pairing timeout completes when a relay socket stays silent")
    func pairingTimeoutUnblocksSilentSocket() async throws {
        let payload = try GADPairingPayload(
            version: .version1,
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "silent-host"),
            deviceID: .init(rawValue: "silent-phone"),
            oneTimeSecret: Data(repeating: 7, count: 32),
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        let socket = SilentPairingWebSocket()
        let client = try GADPairingClient(
            payload: payload,
            connection: socket,
            timeout: .milliseconds(50)
        )

        do {
            _ = try await client.exchange()
            Issue.record("A silent relay must time out.")
        } catch GADPairingExchangeError.timedOut {
            #expect(await socket.isClosed)
        }
    }

    @Test("Phone acknowledges the final pairing acceptance before closing")
    func pairingAcceptanceHasDeviceReceipt() async throws {
        let payload = try GADPairingPayload(
            version: .version1,
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "receipt-host"),
            deviceID: .init(rawValue: "receipt-phone"),
            oneTimeSecret: Data(repeating: 9, count: 32),
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        let codec = GADWireCodec()
        let cryptor = try GADEnvelopeCryptor(
            sharedSecret: payload.oneTimeSecret,
            protocolVersion: payload.version
        )
        let acceptance = GADUnsignedEnvelope(
            protocolVersion: payload.version,
            messageID: UUID(),
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            sequence: 1,
            sentAt: .now,
            message: .pairingAccepted
        )
        let socket = AcceptedPairingWebSocket(acceptance: try codec.encode(GADRelayFrame(
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            recipient: .device,
            envelope: cryptor.seal(acceptance, hostID: payload.hostID)
        )))
        let client = try GADPairingClient(payload: payload, connection: socket)

        let profile = try await client.exchange()
        let frames = await socket.sentFrames
        #expect(profile.deviceID == payload.deviceID)
        #expect(frames.count == 2)
        let receipt = try cryptor.open(codec.decode(GADRelayFrame.self, from: frames[1]).envelope)
        #expect(receipt.message == .pairingAccepted)
    }

    @Test("Pairing URLs round-trip without exposing an invalid transport")
    func pairingRoundTrip() throws {
        let hostKeys = GADPairingHostKeyMaterial()
        let payload = try GADPairingPayload(
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            oneTimeSecret: Data(repeating: 7, count: 32),
            hostEphemeralPublicKey: hostKeys.publicKey,
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )

        let decoded = try GADPairingPayload.decode(url: payload.url())

        #expect(decoded == payload)
        #expect(decoded.version == .current)
        #expect(try decoded.profile().deviceID.rawValue == "phone")
        #expect(try decoded.profile().protocolVersion == .current)
    }

    @Test("Pairing text is bounded before URL and Base64 expansion")
    func pairingInputBounds() throws {
        let payload = try GADPairingPayload(
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            oneTimeSecret: Data(repeating: 7, count: 32),
            hostEphemeralPublicKey: GADPairingHostKeyMaterial().publicKey,
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        let validText = try payload.url().absoluteString
        let validated = try GADPairingPayload.validatedURL(from: " \n\(validText)\n ")
        #expect(try GADPairingPayload.decode(url: validated) == payload)

        let oversizedText = String(repeating: "A", count: GADPairingPayload.maximumURLBytes + 1)
        #expect(throws: GADPairingError.invalidPayload) {
            _ = try GADPairingPayload.validatedURL(from: oversizedText)
        }

        let oversizedEncoded = String(
            repeating: "A",
            count: GADPairingPayload.maximumEncodedPayloadBytes + 1
        )
        let oversizedURL = try #require(URL(string: "goby://pair?payload=\(oversizedEncoded)"))
        #expect(throws: GADPairingError.invalidPayload) {
            _ = try GADPairingPayload.decode(url: oversizedURL)
        }
    }

    @Test("Relay endpoints exclude URL credentials and capability-like suffixes")
    func relayEndpointValidation() throws {
        let normalized = try GADRelayEndpoint.validated("  WSS://relay.example.test/goby  ")
        #expect(normalized.absoluteString == "wss://relay.example.test/goby")

        for source in [
            "ws://relay.example.test/goby",
            "wss://user:secret@relay.example.test/goby",
            "wss://relay.example.test/goby?capability=secret",
            "wss://relay.example.test/goby#secret",
            "wss:///missing-host"
        ] {
            #expect(throws: GADRelayEndpointValidationError.invalidURL) {
                _ = try GADRelayEndpoint.validated(source)
            }
        }
    }

    @Test("Pairing payloads and saved profiles reject credential-bearing relay URLs")
    func pairingRejectsCredentialBearingRelayURLs() throws {
        let unsafeRelay = try #require(URL(string: "wss://user:secret@relay.example.test/goby?capability=secret"))
        let hostKeys = GADPairingHostKeyMaterial()

        #expect(throws: GADPairingError.invalidPayload) {
            _ = try GADPairingPayload(
                relayURL: unsafeRelay,
                hostID: .init(rawValue: "host"),
                deviceID: .init(rawValue: "phone"),
                oneTimeSecret: Data(repeating: 7, count: 32),
                hostEphemeralPublicKey: hostKeys.publicKey,
                hostDisplayName: "Studio Mac",
                expiresAt: .distantFuture
            )
        }

        #expect(throws: GADPairingError.invalidPayload) {
            _ = try GADPairingProfile(
                relayURL: unsafeRelay,
                hostID: .init(rawValue: "host"),
                deviceID: .init(rawValue: "phone"),
                sharedSecret: Data(repeating: 7, count: 32),
                displayName: "Studio Mac"
            )
        }

        let safeProfile = try GADPairingProfile(
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            sharedSecret: Data(repeating: 7, count: 32),
            displayName: "Studio Mac"
        )
        let codec = GADWireCodec()
        var persistedObject = try #require(
            JSONSerialization.jsonObject(with: codec.encode(safeProfile)) as? [String: Any]
        )
        persistedObject["relayURL"] = unsafeRelay.absoluteString
        let unsafePersistedData = try JSONSerialization.data(
            withJSONObject: persistedObject,
            options: [.sortedKeys]
        )
        #expect(throws: GADPairingError.invalidPayload) {
            _ = try codec.decode(GADPairingProfile.self, from: unsafePersistedData)
        }
    }

    @Test("Version-three pairing derives one application secret and authenticates both peers")
    func authenticatedPairing() async throws {
        let hostKeys = GADPairingHostKeyMaterial()
        let payload = try GADPairingPayload(
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            oneTimeSecret: Data(repeating: 7, count: 32),
            hostEphemeralPublicKey: hostKeys.publicKey,
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        let codec = GADWireCodec(maximumBytes: 65_536)
        let authorizationSigner = TestDeviceAuthorizationSigner()
        let device = try await GADAuthenticatedPairingCrypto.makeDeviceContext(
            payload: payload,
            deviceDisplayName: "Owner iPhone",
            identityStore: TestDeviceIdentitySigner(),
            authorizationStore: authorizationSigner,
            codec: codec
        )
        let material = device.request.material
        let missingAuthorizationKey = GADAuthenticatedPairingRequest(
            material: GADAuthenticatedPairingMaterial(
                protocolVersion: material.protocolVersion,
                relayURL: material.relayURL,
                hostID: material.hostID,
                deviceID: material.deviceID,
                hostEphemeralPublicKey: material.hostEphemeralPublicKey,
                deviceIdentityPublicKey: material.deviceIdentityPublicKey,
                deviceEphemeralPublicKey: material.deviceEphemeralPublicKey,
                clientNonce: material.clientNonce,
                deviceDisplayName: material.deviceDisplayName,
                expiresAt: material.expiresAt
            ),
            deviceSignature: device.request.deviceSignature
        )
        #expect(throws: GADAuthenticatedPairingCryptoError.invalidMaterial) {
            _ = try GADAuthenticatedPairingCrypto.makeHostContext(
                payload: payload,
                hostPrivateKey: hostKeys.privateKey,
                request: missingAuthorizationKey,
                codec: codec
            )
        }
        let host = try GADAuthenticatedPairingCrypto.makeHostContext(
            payload: payload,
            hostPrivateKey: hostKeys.privateKey,
            request: device.request,
            codec: codec
        )

        #expect(device.sessionSecret == host.sessionSecret)
        #expect(device.sessionSecret != payload.oneTimeSecret)
        #expect(device.confirmationCode == host.confirmationCode)
        let authorizationPublicKey = await authorizationSigner.publicKey()
        #expect(device.request.material.deviceAuthorizationPublicKey == authorizationPublicKey)
        #expect(device.confirmationCode.count == 6)
        #expect(Int(device.confirmationCode) != nil)

        let challenge = GADAuthenticatedPairingCrypto.challenge(
            for: host,
            relayRevocationProof: String(repeating: "R", count: 43)
        )
        try GADAuthenticatedPairingCrypto.validate(challenge, for: device)
        let response = GADAuthenticatedPairingCrypto.response(accepted: true, context: device)
        try GADAuthenticatedPairingCrypto.validate(response, for: host)

        var tamperedProof = response.deviceProof
        tamperedProof[tamperedProof.startIndex] ^= 0xff
        #expect(throws: GADAuthenticatedPairingCryptoError.authenticationFailed) {
            try GADAuthenticatedPairingCrypto.validate(
                GADAuthenticatedPairingResponse(accepted: true, deviceProof: tamperedProof),
                for: host
            )
        }
    }

    @Test("Version-three pairing rejects a forged device identity proof")
    func authenticatedPairingRejectsForgedIdentity() async throws {
        let hostKeys = GADPairingHostKeyMaterial()
        let payload = try GADPairingPayload(
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            oneTimeSecret: Data(repeating: 3, count: 32),
            hostEphemeralPublicKey: hostKeys.publicKey,
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        let codec = GADWireCodec(maximumBytes: 65_536)
        let authorizationSigner = TestDeviceAuthorizationSigner()
        let device = try await GADAuthenticatedPairingCrypto.makeDeviceContext(
            payload: payload,
            deviceDisplayName: "Owner iPhone",
            identityStore: TestDeviceIdentitySigner(),
            authorizationStore: authorizationSigner,
            codec: codec
        )
        var forgedSignature = device.request.deviceSignature
        forgedSignature[forgedSignature.startIndex] ^= 0xff
        let forged = GADAuthenticatedPairingRequest(
            material: device.request.material,
            deviceSignature: forgedSignature
        )

        #expect(throws: GADAuthenticatedPairingCryptoError.authenticationFailed) {
            _ = try GADAuthenticatedPairingCrypto.makeHostContext(
                payload: payload,
                hostPrivateKey: hostKeys.privateKey,
                request: forged,
                codec: codec
            )
        }
    }

    @Test("Paired-device registry renames, revokes and enforces its bound")
    func pairedDeviceRegistryState() throws {
        var state = GADPairingRegistryState()
        for index in 0..<GADPairingRegistryState.maximumDevices {
            try state.upsert(try profile(id: "phone-\(index)", name: "Phone \(index)"))
        }
        #expect(state.profiles.count == GADPairingRegistryState.maximumDevices)
        #expect(throws: GADPairingError.maximumDevices) {
            try state.upsert(try profile(id: "overflow", name: "Overflow"))
        }

        let original = try #require(state.profiles.first { $0.deviceID.rawValue == "phone-2" })
        try state.rename(deviceID: original.deviceID, displayName: "  Travel iPhone  ")
        let renamed = try #require(state.profiles.first { $0.deviceID == original.deviceID })
        #expect(renamed.displayName == "Travel iPhone")
        #expect(renamed.sharedSecret == original.sharedSecret)
        #expect(renamed.createdAt == original.createdAt)

        let pending = state.beginRevocation(deviceID: original.deviceID)
        #expect(pending == renamed)
        #expect(!state.profiles.contains { $0.deviceID == original.deviceID })
        #expect(state.pendingRevocations.map(\.deviceID) == [original.deviceID])
        #expect(state.beginRevocation(deviceID: original.deviceID) == renamed)
        #expect(throws: GADPairingError.maximumDevices) {
            try state.upsert(try profile(id: "still-overflow", name: "Still Overflow"))
        }
        state.completeRevocation(deviceID: original.deviceID)
        try state.upsert(try profile(id: "replacement", name: "Replacement"))
        #expect(state.profiles.count == GADPairingRegistryState.maximumDevices)
    }

    @Test("Pending pairings never become active after their deadline")
    func pendingPairingPromotionIsDeadlineBound() throws {
        let candidate = try profile(id: "pending-phone", name: "Pending Phone")
        let deadline = Date(timeIntervalSince1970: 1_000)
        var state = GADPairingRegistryState()

        try state.stagePairing(candidate, expiresAt: deadline)
        #expect(state.profiles.isEmpty)
        #expect(state.pendingPairings.map(\.profile.deviceID) == [candidate.deviceID])

        let activated = state.activatePendingPairing(
            deviceID: candidate.deviceID,
            now: deadline
        )
        #expect(activated == candidate)
        #expect(state.profiles == [candidate])
        #expect(state.pendingPairings.isEmpty)

        let expired = try profile(id: "expired-phone", name: "Expired Phone")
        var expiredState = GADPairingRegistryState()
        try expiredState.stagePairing(expired, expiresAt: deadline)
        #expect(expiredState.activatePendingPairing(
            deviceID: expired.deviceID,
            now: deadline.addingTimeInterval(0.001)
        ) == nil)
        #expect(expiredState.profiles.isEmpty)
        #expect(expiredState.pendingPairings.isEmpty)
    }

    @Test("Version-three commands sign exact canonical bytes before decoding")
    func signedCommands() async throws {
        let signer = TestDeviceIdentitySigner()
        let authorizationSigner = TestDeviceAuthorizationSigner()
        let identity = try await signer.identity()
        let authorizationPublicKey = await authorizationSigner.publicKey()
        let command = GADCommand(
            id: .init(rawValue: "command"),
            idempotencyKey: "command-key",
            hostEpoch: .init(rawValue: "epoch"),
            deviceID: .init(rawValue: "phone"),
            baseRevision: .init(rawValue: 4),
            issuedAt: Date(timeIntervalSince1970: 20_000),
            expiresAt: Date(timeIntervalSince1970: 20_060),
            payload: .refreshCodex
        )
        let codec = GADWireCodec()
        let envelope = try await GADDeviceCommandAuthenticator.sign(
            command,
            expectedPublicKey: identity.signingPublicKey,
            signer: signer,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            authorizationSigner: authorizationSigner,
            codec: codec
        )

        #expect(try GADDeviceCommandAuthenticator.verify(
            envelope,
            expectedPublicKey: identity.signingPublicKey,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            codec: codec
        ) == command)

        var alteredBytes = envelope.commandBytes
        alteredBytes[alteredBytes.startIndex] ^= 0x01
        #expect(throws: GADDeviceCommandAuthenticationError.invalidSignature) {
            _ = try GADDeviceCommandAuthenticator.verify(
                GADSignedCommandEnvelope(
                    commandBytes: alteredBytes,
                    deviceSignature: envelope.deviceSignature,
                    localAuthorizationSignature: envelope.localAuthorizationSignature
                ),
                expectedPublicKey: identity.signingPublicKey,
                expectedAuthorizationPublicKey: authorizationPublicKey,
                codec: codec
            )
        }
        await #expect(throws: GADDeviceCommandAuthenticationError.identityMismatch) {
            _ = try await GADDeviceCommandAuthenticator.sign(
                command,
                expectedPublicKey: Data(repeating: 0, count: 64),
                signer: signer,
                expectedAuthorizationPublicKey: authorizationPublicKey,
                authorizationSigner: authorizationSigner,
                codec: codec
            )
        }


        let authorizedCommand = GADCommand(
            id: .init(rawValue: "authorized-command"),
            idempotencyKey: "authorized-command-key",
            hostEpoch: .init(rawValue: "epoch"),
            deviceID: .init(rawValue: "phone"),
            baseRevision: .init(rawValue: 4),
            issuedAt: Date(timeIntervalSince1970: 20_000),
            expiresAt: Date(timeIntervalSince1970: 20_060),
            payload: .startRun(.init(
                planID: .init(rawValue: "run"),
                authorizationAssertion: "user-presence-required"
            ))
        )
        let authorizedEnvelope = try await GADDeviceCommandAuthenticator.sign(
            authorizedCommand,
            expectedPublicKey: identity.signingPublicKey,
            signer: signer,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            authorizationSigner: authorizationSigner,
            codec: codec
        )
        #expect(authorizedEnvelope.localAuthorizationSignature != nil)
        #expect(try GADDeviceCommandAuthenticator.verify(
            authorizedEnvelope,
            expectedPublicKey: identity.signingPublicKey,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            codec: codec
        ) == authorizedCommand)

        let allowOnceCommand = GADCommand(
            id: .init(rawValue: "allow-once-command"),
            idempotencyKey: "allow-once-command-key",
            hostEpoch: .init(rawValue: "epoch"),
            deviceID: .init(rawValue: "phone"),
            baseRevision: .init(rawValue: 4),
            issuedAt: Date(timeIntervalSince1970: 20_000),
            expiresAt: Date(timeIntervalSince1970: 20_060),
            payload: .respondToApproval(.init(
                approvalID: "approval",
                runID: "run",
                assignmentID: "assignment",
                action: .allowOnce,
                authorizationAssertion: "user-presence-required"
            ))
        )
        let allowOnceEnvelope = try await GADDeviceCommandAuthenticator.sign(
            allowOnceCommand,
            expectedPublicKey: identity.signingPublicKey,
            signer: signer,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            authorizationSigner: authorizationSigner,
            codec: codec
        )
        #expect(allowOnceEnvelope.localAuthorizationSignature != nil)
        #expect(try GADDeviceCommandAuthenticator.verify(
            allowOnceEnvelope,
            expectedPublicKey: identity.signingPublicKey,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            codec: codec
        ) == allowOnceCommand)
        #expect(throws: GADDeviceCommandAuthenticationError.invalidAuthorizationSignature) {
            _ = try GADDeviceCommandAuthenticator.verify(
                .init(
                    commandBytes: authorizedEnvelope.commandBytes,
                    deviceSignature: authorizedEnvelope.deviceSignature
                ),
                expectedPublicKey: identity.signingPublicKey,
                expectedAuthorizationPublicKey: authorizationPublicKey,
                codec: codec
            )
        }
        await #expect(throws: GADDeviceCommandAuthenticationError.authorizationIdentityMismatch) {
            _ = try await GADDeviceCommandAuthenticator.sign(
                authorizedCommand,
                expectedPublicKey: identity.signingPublicKey,
                signer: signer,
                expectedAuthorizationPublicKey: nil,
                authorizationSigner: authorizationSigner,
                codec: codec
            )
        }
        var forgedAuthorizationSignature = try #require(
            authorizedEnvelope.localAuthorizationSignature
        )
        forgedAuthorizationSignature[forgedAuthorizationSignature.startIndex] ^= 0xff
        #expect(throws: GADDeviceCommandAuthenticationError.invalidAuthorizationSignature) {
            _ = try GADDeviceCommandAuthenticator.verify(
                .init(
                    commandBytes: authorizedEnvelope.commandBytes,
                    deviceSignature: authorizedEnvelope.deviceSignature,
                    localAuthorizationSignature: forgedAuthorizationSignature
                ),
                expectedPublicKey: identity.signingPublicKey,
                expectedAuthorizationPublicKey: authorizationPublicKey,
                codec: codec
            )
        }

        let automationReviewCommand = GADCommand(
            id: .init(rawValue: "automation-review-command"),
            idempotencyKey: "automation-review-command-key",
            hostEpoch: .init(rawValue: "epoch"),
            deviceID: .init(rawValue: "phone"),
            baseRevision: .init(rawValue: 4),
            issuedAt: Date(timeIntervalSince1970: 20_000),
            expiresAt: Date(timeIntervalSince1970: 20_060),
            payload: .reviewAndRunAutomationOccurrence(.init(
                id: .init(rawValue: "automation-occurrence"),
                reviewBinding: .init(actionID: "action-a", planID: "plan-a"),
                authorizationAssertion: "user-presence-required",
                selectedResourceIDs: ["research-folder"]
            ))
        )
        let automationReviewEnvelope = try await GADDeviceCommandAuthenticator.sign(
            automationReviewCommand,
            expectedPublicKey: identity.signingPublicKey,
            signer: signer,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            authorizationSigner: authorizationSigner,
            codec: codec
        )
        #expect(automationReviewEnvelope.localAuthorizationSignature != nil)
        #expect(try GADDeviceCommandAuthenticator.verify(
            automationReviewEnvelope,
            expectedPublicKey: identity.signingPublicKey,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            codec: codec
        ) == automationReviewCommand)
        let alteredAutomationReview = GADCommand(
            id: automationReviewCommand.id,
            idempotencyKey: automationReviewCommand.idempotencyKey,
            hostEpoch: automationReviewCommand.hostEpoch,
            deviceID: automationReviewCommand.deviceID,
            baseRevision: automationReviewCommand.baseRevision,
            issuedAt: automationReviewCommand.issuedAt,
            expiresAt: automationReviewCommand.expiresAt,
            payload: .reviewAndRunAutomationOccurrence(.init(
                id: "automation-occurrence",
                reviewBinding: .init(actionID: "action-b", planID: "plan-b"),
                authorizationAssertion: "user-presence-required",
                selectedResourceIDs: ["research-folder"]
            ))
        )
        let alteredAutomationBytes = try codec.encode(alteredAutomationReview)
        #expect(throws: GADDeviceCommandAuthenticationError.invalidSignature) {
            _ = try GADDeviceCommandAuthenticator.verify(
                .init(
                    commandBytes: alteredAutomationBytes,
                    deviceSignature: automationReviewEnvelope.deviceSignature,
                    localAuthorizationSignature: automationReviewEnvelope.localAuthorizationSignature
                ),
                expectedPublicKey: identity.signingPublicKey,
                expectedAuthorizationPublicKey: authorizationPublicKey,
                codec: codec
            )
        }
    }

    @Test("Version-one pairing and saved profiles remain readable")
    func legacyPairingCompatibility() throws {
        let payload = try GADPairingPayload(
            version: .version1,
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            oneTimeSecret: Data(repeating: 7, count: 32),
            hostDisplayName: "Studio Mac",
            expiresAt: .distantFuture
        )
        #expect(try GADPairingPayload.decode(url: payload.url()).version == .version1)

        let profile = try payload.profile()
        let codec = GADWireCodec()
        var object = try #require(
            JSONSerialization.jsonObject(with: codec.encode(profile)) as? [String: Any]
        )
        object.removeValue(forKey: "protocolVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try codec.decode(GADPairingProfile.self, from: legacyData)

        #expect(decoded.protocolVersion == .version1)
        #expect(decoded.deviceID == profile.deviceID)

        let version32 = GADProtocolVersion(major: 3, minor: 2)
        let version32Profile = try GADPairingProfile(
            protocolVersion: version32,
            relayURL: profile.relayURL,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sharedSecret: profile.sharedSecret,
            displayName: profile.displayName,
            deviceIdentityPublicKey: Data(repeating: 9, count: 64)
        )
        var version32Object = try #require(
            JSONSerialization.jsonObject(with: codec.encode(version32Profile)) as? [String: Any]
        )
        version32Object.removeValue(forKey: "deviceAuthorizationPublicKey")
        let version32Data = try JSONSerialization.data(
            withJSONObject: version32Object,
            options: [.sortedKeys]
        )
        let decodedVersion32 = try codec.decode(GADPairingProfile.self, from: version32Data)
        #expect(decodedVersion32.protocolVersion == version32)
        #expect(decodedVersion32.deviceAuthorizationPublicKey == nil)
    }

    @Test("Legacy unsigned pairings cannot mutate host state")
    func legacyPairingIsReadOnly() {
        let command = GADCommand(
            id: .init(rawValue: "legacy-command"),
            idempotencyKey: "legacy-command",
            hostEpoch: .init(rawValue: "epoch"),
            deviceID: .init(rawValue: "phone"),
            baseRevision: .zero,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_060),
            payload: .preparePlan
        )

        let acknowledgement = RemoteGobyHost.legacyCommandRejection(
            command,
            revision: .init(rawValue: 12)
        )
        #expect(acknowledgement.commandID == command.id)
        #expect(acknowledgement.disposition == .rejectedCapability)
        #expect(acknowledgement.revision == .init(rawValue: 12))
        #expect(acknowledgement.message?.contains("Pair this device again") == true)
    }

    @Test("Live revocation sends an authenticated reason after authority removal and before close")
    func liveRevocationNotifiesBeforeClose() async throws {
        let profile = try profile(id: "live-revoked-phone", name: "Revoked iPhone")
        let now = Date(timeIntervalSince1970: 20_000)
        let coordinator = GADCoordinator(
            hostID: profile.hostID,
            hostEpoch: .init(rawValue: "revocation-epoch"),
            protocolVersion: profile.protocolVersion,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(
                    id: profile.hostID,
                    displayName: "Studio Mac",
                    reachability: .online,
                    lastUpdatedAt: now
                )
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [profile.deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { now }
        )
        let socket = RevocationWebSocketSpy(
            coordinator: coordinator,
            deviceID: profile.deviceID
        )
        let relaySender = RelayHTTPSenderSpy()
        let host = try RemoteGobyHost(
            profile: profile,
            coordinator: coordinator,
            hostAdmission: try relayAdmission(),
            relayControl: GADRelayNotificationClient(sender: relaySender),
            connection: socket
        )

        try await host.revoke()

        #expect(await socket.authorityWasRemovedBeforeSend)
        #expect(await socket.isClosed)
        let frameData = try #require(await socket.sentFrames.first)
        let frame = try GADWireCodec().decode(GADRelayFrame.self, from: frameData)
        #expect(frame.recipient == .device)
        let unsigned = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion
        ).open(frame.envelope)
        guard case let .disconnect(reason) = unsigned.message else {
            Issue.record("Expected an authenticated disconnect frame before transport close.")
            return
        }
        #expect(reason == "device-revoked")
        #expect((try? await coordinator.connect(deviceID: profile.deviceID)) == nil)
    }

    @Test("A signed device self-revocation removes authority before acknowledging and completes cleanup")
    func deviceSelfRevocationIsAcknowledgedAndFinal() async throws {
        let signer = TestDeviceIdentitySigner()
        let authorizationSigner = TestDeviceAuthorizationSigner()
        let identity = try await signer.identity()
        let authorizationPublicKey = await authorizationSigner.publicKey()
        let timestamp = Date.now
        let profile = try GADPairingProfile(
            protocolVersion: .current,
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "self-revoke-host"),
            deviceID: .init(rawValue: "self-revoke-phone"),
            sharedSecret: Data(repeating: 0x31, count: 32),
            relayHostSecret: Data(repeating: 0x32, count: 32),
            relayRevocationProof: String(repeating: "R", count: 43),
            displayName: "Owner iPhone",
            deviceIdentityPublicKey: identity.signingPublicKey,
            deviceAuthorizationPublicKey: authorizationPublicKey,
            createdAt: timestamp
        )
        let epoch = HostEpoch(rawValue: "self-revoke-epoch")
        let coordinator = GADCoordinator(
            hostID: profile.hostID,
            hostEpoch: epoch,
            protocolVersion: .current,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: profile.hostID,
                    displayName: "Studio Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [.deviceSelfRevocation],
            authorizedDevices: [profile.deviceID],
            handler: SelfRevocationCommandHandler(),
            now: { timestamp }
        )
        let command = GADCommand(
            id: .init(rawValue: "self-revoke-command"),
            idempotencyKey: "self-revoke-command",
            hostEpoch: epoch,
            deviceID: profile.deviceID,
            baseRevision: .zero,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(60),
            payload: .revokeCurrentDevice
        )
        let codec = GADWireCodec()
        let signed = try await GADDeviceCommandAuthenticator.sign(
            command,
            expectedPublicKey: identity.signingPublicKey,
            signer: signer,
            expectedAuthorizationPublicKey: authorizationPublicKey,
            authorizationSigner: authorizationSigner,
            codec: codec
        )
        let cryptor = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion
        )
        let helloMessageID = UUID()
        let hello = GADRelayFrame(
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            recipient: .host,
            envelope: try cryptor.seal(.init(
                protocolVersion: .current,
                messageID: helloMessageID,
                hostID: profile.hostID,
                deviceID: profile.deviceID,
                sequence: 1,
                sentAt: timestamp,
                message: .clientHello(
                    deviceID: profile.deviceID,
                    supportedVersions: [.current],
                    lastHostEpoch: nil,
                    lastRevision: nil
                )
            ), hostID: profile.hostID)
        )
        let commandMessageID = UUID()
        let inbound = GADRelayFrame(
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            recipient: .host,
            envelope: try cryptor.seal(.init(
                protocolVersion: .current,
                messageID: commandMessageID,
                hostID: profile.hostID,
                deviceID: profile.deviceID,
                sequence: 2,
                sentAt: timestamp,
                message: .signedCommand(signed)
            ), hostID: profile.hostID)
        )
        let socket = SelfRevocationWebSocketSpy(receivedFrames: [
            try codec.encode(hello),
            try codec.encode(inbound),
        ])
        let probe = SelfRevocationProbe()
        let host = try RemoteGobyHost(
            profile: profile,
            coordinator: coordinator,
            onSelfRevocationAccepted: { _ in await probe.begin() },
            onSelfRevocationTransportClosed: { _ in await probe.complete() },
            hostAdmission: try relayAdmission(),
            relayControl: GADRelayNotificationClient(sender: RelayHTTPSenderSpy()),
            connection: socket
        )

        await host.start()
        for _ in 0..<100 {
            if await probe.completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await probe.began)
        #expect(await probe.completed)
        #expect(await socket.isClosed)
        #expect((try? await coordinator.connect(deviceID: profile.deviceID)) == nil)
        let sentFrames = await socket.sentFrames
        #expect(sentFrames.count == 2)
        let helloResponseFrame = try codec.decode(
            GADRelayFrame.self,
            from: try #require(sentFrames.first)
        )
        let helloResponse = try cryptor.open(helloResponseFrame.envelope)
        guard case .serverHello = helloResponse.message else {
            Issue.record("Expected a correlated server hello before the command acknowledgement.")
            return
        }
        #expect(helloResponse.replyToMessageID == helloMessageID)

        let responseData = try #require(sentFrames.last)
        let responseFrame = try codec.decode(GADRelayFrame.self, from: responseData)
        let response = try cryptor.open(responseFrame.envelope)
        guard case let .acknowledgement(acknowledgement) = response.message else {
            Issue.record("Expected a self-revocation acknowledgement.")
            return
        }
        #expect(acknowledgement.disposition == .accepted)
        #expect(response.replyToMessageID == commandMessageID)
        await host.stop()
    }

    @Test("Pairing rotates the operational secret inside the encrypted exchange")
    func pairingSecretRotationEnvelope() throws {
        let challengeSecret = Data(repeating: 7, count: 32)
        let sessionSecret = Data(repeating: 8, count: 32)
        let cryptor = try GADEnvelopeCryptor(sharedSecret: challengeSecret)
        let message = GADWireMessage.pairingRequest(
            deviceID: .init(rawValue: "phone"),
            sessionSecret: sessionSecret,
            deviceDisplayName: "iPhone"
        )
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: .version1,
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            sequence: 9,
            sentAt: Date(timeIntervalSince1970: 20_000),
            message: message
        )

        let sealed = try cryptor.seal(unsigned, hostID: .init(rawValue: "host"))
        let encoded = try GADWireCodec().encode(sealed)

        #expect(challengeSecret != sessionSecret)
        #expect(encoded.range(of: sessionSecret) == nil)
        #expect(try cryptor.open(sealed).message == message)
    }

    @Test("Relay authentication uses opaque headers instead of URL credentials")
    func relayAuthenticationHeaders() throws {
        let profile = try GADPairingProfile(
            protocolVersion: .current,
            relayURL: #require(URL(string: "wss://relay.example.test/v1/connect")),
            hostID: .init(rawValue: "host-private-id"),
            deviceID: .init(rawValue: "device-private-id"),
            sharedSecret: Data(repeating: 4, count: 32),
            relayHostSecret: Data(repeating: 5, count: 32),
            relayRevocationProof: String(repeating: "R", count: 43),
            displayName: "Mac"
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let request = GADRelayURLBuilder.request(for: profile, role: .device, now: now)
        let hostRequest = GADRelayURLBuilder.request(
            for: profile,
            role: .host,
            hostAdmission: try relayAdmission(),
            now: now
        )
        let renewedRequest = GADRelayURLBuilder.request(
            for: profile,
            role: .device,
            now: now.addingTimeInterval(1)
        )

        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Goby-Route")?.count == 43)
        #expect(request.value(forHTTPHeaderField: "X-Goby-Route") == hostRequest.value(forHTTPHeaderField: "X-Goby-Route"))
        #expect(request.value(forHTTPHeaderField: "X-Goby-Route") == renewedRequest.value(forHTTPHeaderField: "X-Goby-Route"))
        #expect(request.value(forHTTPHeaderField: "X-Goby-Role") == "device")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") != hostRequest.value(forHTTPHeaderField: "Authorization"))
        #expect(request.value(forHTTPHeaderField: "Authorization") != renewedRequest.value(forHTTPHeaderField: "Authorization"))
        #expect(request.value(forHTTPHeaderField: "X-Goby-Credential-Expires-At") == "2000000900")
        #expect(request.value(forHTTPHeaderField: "X-Goby-Route-Verifier")?.count == 43)
        #expect(hostRequest.value(forHTTPHeaderField: "X-Goby-Route-Verifier")?.count == 43)
        #expect(request.value(forHTTPHeaderField: "X-Goby-Route-Verifier")
            != hostRequest.value(forHTTPHeaderField: "X-Goby-Route-Verifier"))
        #expect(hostRequest.value(
            forHTTPHeaderField: GADRelayURLBuilder.deviceVerifierHashHeader
        )?.count == 43)
        let deviceOnlyProfile = try GADPairingProfile(
            protocolVersion: profile.protocolVersion,
            relayURL: profile.relayURL,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sharedSecret: profile.sharedSecret,
            relayRevocationProof: profile.relayRevocationProof,
            displayName: profile.displayName
        )
        let deniedHostRequest = GADRelayURLBuilder.request(
            for: deviceOnlyProfile,
            role: .host,
            now: now
        )
        #expect(deniedHostRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(deniedHostRequest.value(forHTTPHeaderField: "X-Goby-Role") == nil)
        #expect(!String(describing: request.url).contains(profile.hostID.rawValue))
        #expect(!String(describing: request.url).contains(profile.deviceID.rawValue))
    }

    @Test("Authenticated encryption round-trips and detects tampering")
    func encryptionAndTamperDetection() throws {
        let secret = Data(repeating: 9, count: 32)
        let cryptor = try GADEnvelopeCryptor(sharedSecret: secret)
        let timestamp = Date(timeIntervalSince1970: 20_000)
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: .version1,
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            sequence: 4,
            sentAt: timestamp,
            message: .snapshotRequest
        )

        let sealed = try cryptor.seal(unsigned, hostID: .init(rawValue: "host"))
        #expect(try cryptor.open(sealed) == unsigned)

        var tamperedCiphertext = sealed.ciphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 0xff
        let tampered = GADSealedEnvelope(
            protocolVersion: sealed.protocolVersion,
            messageID: sealed.messageID,
            hostID: sealed.hostID,
            deviceID: sealed.deviceID,
            sequence: sealed.sequence,
            sentAt: sealed.sentAt,
            nonce: sealed.nonce,
            ciphertext: tamperedCiphertext,
            signature: sealed.signature
        )
        #expect(throws: GADCryptoError.authenticationFailed) {
            _ = try cryptor.open(tampered)
        }
    }

    @Test("Version-three traffic keys rotate in bounded epochs and reject stale envelopes")
    func rotatingTrafficKeys() throws {
        let secret = Data(repeating: 6, count: 32)
        let firstDate = Date(timeIntervalSince1970: 10 * GADEnvelopeCryptor.trafficKeyRotationInterval + 60)
        let secondDate = firstDate.addingTimeInterval(GADEnvelopeCryptor.trafficKeyRotationInterval)
        #expect(GADEnvelopeCryptor.trafficKeyEpoch(at: firstDate) + 1
            == GADEnvelopeCryptor.trafficKeyEpoch(at: secondDate))

        let firstCryptor = try GADEnvelopeCryptor(
            sharedSecret: secret,
            protocolVersion: .version3,
            now: { firstDate }
        )
        let firstEnvelope = GADUnsignedEnvelope(
            protocolVersion: .version3,
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            sequence: 6,
            sentAt: firstDate,
            message: .ping(UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)
        )
        let sealed = try firstCryptor.seal(firstEnvelope, hostID: .init(rawValue: "host"))
        #expect(try firstCryptor.open(sealed) == firstEnvelope)

        let rotatedCryptor = try GADEnvelopeCryptor(
            sharedSecret: secret,
            protocolVersion: .version3,
            now: { secondDate }
        )
        #expect(throws: GADCryptoError.expiredEnvelope) {
            _ = try rotatedCryptor.open(sealed)
        }
    }

    @Test("Replay protection rejects duplicate and older sequences")
    func replayProtection() async throws {
        let protector = GADReplayProtector()
        let device: DeviceID = .init(rawValue: "phone")
        try await protector.accept(deviceID: device, sequence: 8)
        await #expect(throws: GADCryptoError.replayedSequence) {
            try await protector.accept(deviceID: device, sequence: 8)
        }
        await #expect(throws: GADCryptoError.replayedSequence) {
            try await protector.accept(deviceID: device, sequence: 7)
        }
    }

    @Test("Relay notification registration is role-bound, bounded and contains no dashboard content")
    func relayNotificationRegistration() async throws {
        let sender = RelayHTTPSenderSpy()
        let client = GADRelayNotificationClient(sender: sender)
        let profile = try profile(id: "phone", name: "Owner iPhone")
        let admission = try relayAdmission()
        try await client.register(.init(
            token: Data(repeating: 0xab, count: 32),
            environment: .sandbox,
            categories: [.needsAttention, .runFinished]
        ), for: profile, hostAdmission: admission)

        let request = try #require(await sender.lastRequest)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.path == "/v1/notifications/register")
        #expect(request.value(forHTTPHeaderField: "X-Goby-Role") == "host")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: GADRelayURLBuilder.hostAdmissionHeader) == admission.rawValue)
        let body = try #require(request.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(String(repeating: "ab", count: 32)))
        #expect(!text.localizedCaseInsensitiveContains("prompt"))
        #expect(!text.localizedCaseInsensitiveContains("project"))
        #expect(!text.localizedCaseInsensitiveContains("outcome"))
    }

    @Test("Relay status sender cancels at headers before body delivery")
    func relayStatusSenderCancelsResponseBody() throws {
        let delegate = GADRelayStatusOnlyRequest()
        let session = URLSession(configuration: .ephemeral)
        let url = try #require(URL(string: "https://relay-status.example.test/large-body"))
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(8 * 1_024 * 1_024)]
        ))
        var disposition: URLSession.ResponseDisposition?

        delegate.urlSession(session, dataTask: task, didReceive: response) {
            disposition = $0
        }

        #expect(disposition == .cancel)
        session.invalidateAndCancel()
    }

    @Test("Relay status sender refuses redirects before a second request")
    func relayStatusSenderRejectsRedirects() throws {
        let delegate = GADRelayStatusOnlyRequest()
        let session = URLSession(configuration: .ephemeral)
        let url = try #require(URL(string: "https://relay-status.example.test/redirect"))
        let redirectedURL = try #require(URL(string: "https://other.example.test/followed"))
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        var acceptedRedirect: URLRequest? = URLRequest(url: redirectedURL)

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) {
            acceptedRedirect = $0
        }

        #expect(acceptedRedirect == nil)
        session.invalidateAndCancel()
    }

    @Test("Relay status sender discards oversized revocation proof headers")
    func relayStatusSenderBoundsRevocationProof() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStatusURLProtocol.self]
        let sender = GADURLSessionRelayHTTPRequestSender(
            session: URLSession(configuration: configuration)
        )
        let url = try #require(URL(string: "https://relay-status.example.test/oversized-proof"))

        let response = try await sender.response(for: URLRequest(url: url))
        #expect(response.statusCode == 410)
        #expect(response.revocationProof == nil)
    }

    @Test("Relay FCM registration preserves the bounded token and omits APNs environment")
    func relayFCMNotificationRegistration() async throws {
        let sender = RelayHTTPSenderSpy()
        let client = GADRelayNotificationClient(sender: sender)
        let profile = try profile(id: "android", name: "Owner Android")
        let admission = try relayAdmission()
        try await client.register(.init(
            token: Data("fcm-token:abc_123-def".utf8),
            environment: .production,
            categories: [.needsAttention, .runFinished],
            transport: .fcm
        ), for: profile, hostAdmission: admission)

        let request = try #require(await sender.lastRequest)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["transport"] as? String == "fcm")
        #expect(object["token"] as? String == "fcm-token:abc_123-def")
        #expect(object["environment"] == nil)
    }

    @Test("Relay route status and revocation use authenticated role-bound control requests")
    func relayRouteRevocationControl() async throws {
        let profile = try profile(id: "revoked-phone", name: "Revoked iPhone")
        let proof = GADRelayURLBuilder.revocationProof(for: profile)
        let admission = try relayAdmission()
        let sender = RelayHTTPSenderSpy(responses: [
            .init(statusCode: 410, revocationProof: proof),
            .init(statusCode: 204),
        ])
        let client = GADRelayNotificationClient(sender: sender)

        #expect(try await client.routeStatus(for: profile, role: .device) == .revoked)
        let statusRequest = try #require(await sender.lastRequest)
        #expect(statusRequest.url?.path == "/v1/status")
        #expect(statusRequest.httpMethod == "GET")
        #expect(statusRequest.value(forHTTPHeaderField: "X-Goby-Role") == "device")

        try await client.revoke(for: profile, hostAdmission: admission)
        let revokeRequest = try #require(await sender.lastRequest)
        #expect(revokeRequest.url?.path == "/v1/revoke")
        #expect(revokeRequest.httpMethod == "POST")
        #expect(revokeRequest.value(forHTTPHeaderField: "X-Goby-Role") == "host")
        #expect(revokeRequest.value(forHTTPHeaderField: GADRelayURLBuilder.revocationProofHeader) == proof)
        #expect(revokeRequest.value(forHTTPHeaderField: GADRelayURLBuilder.hostAdmissionHeader) == admission.rawValue)
        #expect(revokeRequest.value(forHTTPHeaderField: GADRelayURLBuilder.deviceVerifierHashHeader) != nil)
    }

    @Test("Relay 410 cannot erase device state without the exact host-authenticated proof")
    func relayRevocationProofIsProfileBound() async throws {
        let primary = try profile(id: "proof-phone", name: "Proof iPhone")
        let other = try profile(id: "other-phone", name: "Other iPhone")
        #expect(!GADRelayURLBuilder.isValidRevocationProof(
            GADRelayURLBuilder.revocationProof(for: other),
            for: primary
        ))

        for response in [
            GADRelayHTTPResponse(statusCode: 410),
            GADRelayHTTPResponse(
                statusCode: 410,
                revocationProof: GADRelayURLBuilder.revocationProof(for: other)
            ),
        ] {
            let client = GADRelayNotificationClient(sender: RelayHTTPSenderSpy(responses: [response]))
            await #expect(throws: GADRelayNotificationError.invalidRevocationProof) {
                try await client.routeStatus(for: primary, role: GADRelayRole.device)
            }
        }
    }

    private func profile(id: String, name: String) throws -> GADPairingProfile {
        try GADPairingProfile(
            protocolVersion: .current,
            relayURL: #require(URL(string: "wss://relay.example.test/goby")),
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: id),
            sharedSecret: Data(repeating: UInt8(id.utf8.count), count: 32),
            relayHostSecret: Data(repeating: UInt8(id.utf8.count + 1), count: 32),
            displayName: name,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id.utf8.count))
        )
    }

    private func relayAdmission() throws -> GADRelayHostAdmissionCredential {
        try GADRelayHostAdmissionCredential(
            "v1.\(String(repeating: "A", count: 43)).4102444800.\(String(repeating: "B", count: 43))"
        )
    }

    private func sentFrame(from socket: ReplayTestWebSocket, at index: Int) async throws -> Data {
        for _ in 0..<200 {
            let frames = await socket.sentFrames
            if frames.indices.contains(index) {
                return frames[index]
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw GADRemoteClientError.requestTimedOut("test frame")
    }

    private func deviceFrame(
        profile: GADPairingProfile,
        sequence: UInt64,
        replyToMessageID: UUID?,
        message: GADWireMessage
    ) throws -> Data {
        let codec = GADWireCodec()
        let cryptor = try GADEnvelopeCryptor(
            sharedSecret: profile.sharedSecret,
            protocolVersion: profile.protocolVersion
        )
        let unsigned = GADUnsignedEnvelope(
            protocolVersion: .current,
            messageID: UUID(),
            replyToMessageID: replyToMessageID,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sequence: sequence,
            sentAt: .now,
            message: message
        )
        return try codec.encode(GADRelayFrame(
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            recipient: .device,
            envelope: try cryptor.seal(unsigned, hostID: profile.hostID)
        ))
    }
}

private actor RelayHTTPSenderSpy: GADRelayHTTPRequestSending {
    private(set) var lastRequest: URLRequest?
    private var responses: [GADRelayHTTPResponse]

    init(responses: [GADRelayHTTPResponse] = [.init(statusCode: 204)]) {
        self.responses = responses
    }

    func response(for request: URLRequest) -> GADRelayHTTPResponse {
        lastRequest = request
        return responses.isEmpty ? .init(statusCode: 204) : responses.removeFirst()
    }
}
