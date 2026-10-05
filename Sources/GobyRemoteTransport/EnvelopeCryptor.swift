import CryptoKit
import Foundation
import GobyApplication
import GobyRemoteContract

public enum GADCryptoError: LocalizedError, Equatable, Sendable {
    case invalidSecret
    case invalidEnvelope
    case authenticationFailed
    case metadataMismatch
    case replayedSequence
    case expiredEnvelope

    public var errorDescription: String? {
        switch self {
        case .invalidSecret:
            "Goby could not open the protected pairing key. Pair this device again."
        case .invalidEnvelope, .authenticationFailed, .metadataMismatch:
            "Goby rejected an invalid encrypted relay message."
        case .replayedSequence:
            "Goby rejected a duplicate or out-of-order relay message. Refresh the connection."
        case .expiredEnvelope:
            "Goby rejected a stale relay message. Check that Date & Time is set automatically on both devices, then reconnect."
        }
    }
}

public struct GADEnvelopeCryptor: Sendable {
    private struct AuthenticationData: Codable, Sendable {
        let protocolVersion: GADProtocolVersion
        let messageID: UUID
        let hostID: HostID
        let deviceID: DeviceID
        let sequence: UInt64
        let sentAt: Date
        let nonce: Data
        let ciphertext: Data
    }

    public static let trafficKeyRotationInterval: TimeInterval = 6 * 60 * 60

    private struct TrafficKeys {
        let encryption: SymmetricKey
        let authentication: SymmetricKey
    }

    private let rootKey: SymmetricKey
    private let protocolVersion: GADProtocolVersion
    private let rotationInterval: TimeInterval
    private let maximumMessageAge: TimeInterval
    private let now: @Sendable () -> Date
    private let codec: GADWireCodec

    public init(
        sharedSecret: Data,
        protocolVersion: GADProtocolVersion = .version1,
        rotationInterval: TimeInterval = GADEnvelopeCryptor.trafficKeyRotationInterval,
        maximumMessageAge: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { .now },
        codec: GADWireCodec = .init()
    ) throws {
        guard sharedSecret.count == 32 else { throw GADCryptoError.invalidSecret }
        rootKey = SymmetricKey(data: sharedSecret)
        self.protocolVersion = protocolVersion
        self.rotationInterval = max(60, rotationInterval)
        self.maximumMessageAge = max(30, maximumMessageAge)
        self.now = now
        self.codec = codec
    }

    public func seal(_ envelope: GADUnsignedEnvelope, hostID: HostID) throws -> GADSealedEnvelope {
        let keys = trafficKeys(at: envelope.sentAt)
        let plaintext = try codec.encode(envelope)
        let sealed = try ChaChaPoly.seal(plaintext, using: keys.encryption)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let ciphertext = sealed.ciphertext + sealed.tag
        let authenticationData = AuthenticationData(
            protocolVersion: envelope.protocolVersion,
            messageID: envelope.messageID,
            hostID: hostID,
            deviceID: envelope.deviceID,
            sequence: envelope.sequence,
            sentAt: envelope.sentAt,
            nonce: nonce,
            ciphertext: ciphertext
        )
        let signature = Data(HMAC<SHA256>.authenticationCode(
            for: try codec.encode(authenticationData),
            using: keys.authentication
        ))
        return GADSealedEnvelope(
            protocolVersion: envelope.protocolVersion,
            messageID: envelope.messageID,
            hostID: hostID,
            deviceID: envelope.deviceID,
            sequence: envelope.sequence,
            sentAt: envelope.sentAt,
            nonce: nonce,
            ciphertext: ciphertext,
            signature: signature
        )
    }

    public func open(_ envelope: GADSealedEnvelope) throws -> GADUnsignedEnvelope {
        guard envelope.nonce.count == 12, envelope.ciphertext.count >= 16 else {
            throw GADCryptoError.invalidEnvelope
        }
        if protocolVersion.major >= GADProtocolVersion.version3.major,
           abs(now().timeIntervalSince(envelope.sentAt)) > maximumMessageAge {
            throw GADCryptoError.expiredEnvelope
        }
        let keys = trafficKeys(at: envelope.sentAt)
        let authenticationData = AuthenticationData(
            protocolVersion: envelope.protocolVersion,
            messageID: envelope.messageID,
            hostID: envelope.hostID,
            deviceID: envelope.deviceID,
            sequence: envelope.sequence,
            sentAt: envelope.sentAt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        let authenticatedBytes = try codec.encode(authenticationData)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            envelope.signature,
            authenticating: authenticatedBytes,
            using: keys.authentication
        ) else {
            throw GADCryptoError.authenticationFailed
        }
        let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        let ciphertext = envelope.ciphertext.dropLast(16)
        let tag = envelope.ciphertext.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let decoded = try codec.decode(
            GADUnsignedEnvelope.self,
            from: ChaChaPoly.open(box, using: keys.encryption)
        )
        guard decoded.protocolVersion == envelope.protocolVersion,
              decoded.messageID == envelope.messageID,
              decoded.hostID == nil || decoded.hostID == envelope.hostID,
              decoded.deviceID == envelope.deviceID,
              decoded.sequence == envelope.sequence,
              abs(decoded.sentAt.timeIntervalSince(envelope.sentAt)) < 0.001 else {
            throw GADCryptoError.metadataMismatch
        }
        return decoded
    }

    static func trafficKeyEpoch(
        at date: Date,
        rotationInterval: TimeInterval = trafficKeyRotationInterval
    ) -> UInt64 {
        UInt64(max(0, floor(date.timeIntervalSince1970 / max(60, rotationInterval))))
    }

    private func trafficKeys(at date: Date) -> TrafficKeys {
        if protocolVersion.major < GADProtocolVersion.version3.major {
            return legacyTrafficKeys()
        }
        var epoch = Self.trafficKeyEpoch(at: date, rotationInterval: rotationInterval).bigEndian
        let epochData = withUnsafeBytes(of: &epoch) { Data($0) }
        let salt = Data("Goby GAD traffic keys v3".utf8)
        return TrafficKeys(
            encryption: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: rootKey,
                salt: salt,
                info: Data("encryption:".utf8) + epochData,
                outputByteCount: 32
            ),
            authentication: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: rootKey,
                salt: salt,
                info: Data("authentication:".utf8) + epochData,
                outputByteCount: 32
            )
        )
    }

    private func legacyTrafficKeys() -> TrafficKeys {
        let salt = Data("Goby GAD protocol v1".utf8)
        return TrafficKeys(
            encryption: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: rootKey,
                salt: salt,
                info: Data("encryption".utf8),
                outputByteCount: 32
            ),
            authentication: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: rootKey,
                salt: salt,
                info: Data("authentication".utf8),
                outputByteCount: 32
            )
        )
    }
}

public actor GADReplayProtector {
    private var highestSequenceByDevice: [DeviceID: UInt64] = [:]

    public init() {}

    public func accept(deviceID: DeviceID, sequence: UInt64) throws {
        if let highest = highestSequenceByDevice[deviceID], sequence <= highest {
            throw GADCryptoError.replayedSequence
        }
        highestSequenceByDevice[deviceID] = sequence
    }

    public func reset(deviceID: DeviceID) {
        highestSequenceByDevice.removeValue(forKey: deviceID)
    }
}
