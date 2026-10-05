import Foundation
import GobyApplication

public struct GADAuthenticatedPairingMaterial: Codable, Equatable, Sendable {
    public let protocolVersion: GADProtocolVersion
    public let relayURL: URL
    public let hostID: HostID
    public let deviceID: DeviceID
    public let hostEphemeralPublicKey: Data
    public let deviceIdentityPublicKey: Data
    public let deviceAuthorizationPublicKey: Data?
    public let deviceEphemeralPublicKey: Data
    public let clientNonce: Data
    public let deviceDisplayName: String
    public let expiresAt: Date

    public init(
        protocolVersion: GADProtocolVersion,
        relayURL: URL,
        hostID: HostID,
        deviceID: DeviceID,
        hostEphemeralPublicKey: Data,
        deviceIdentityPublicKey: Data,
        deviceAuthorizationPublicKey: Data? = nil,
        deviceEphemeralPublicKey: Data,
        clientNonce: Data,
        deviceDisplayName: String,
        expiresAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.relayURL = relayURL
        self.hostID = hostID
        self.deviceID = deviceID
        self.hostEphemeralPublicKey = hostEphemeralPublicKey
        self.deviceIdentityPublicKey = deviceIdentityPublicKey
        self.deviceAuthorizationPublicKey = deviceAuthorizationPublicKey
        self.deviceEphemeralPublicKey = deviceEphemeralPublicKey
        self.clientNonce = clientNonce
        self.deviceDisplayName = deviceDisplayName
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, relayURL, hostID, deviceID, hostEphemeralPublicKey
        case deviceIdentityPublicKey, deviceAuthorizationPublicKey
        case deviceEphemeralPublicKey, clientNonce, deviceDisplayName, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(GADProtocolVersion.self, forKey: .protocolVersion)
        relayURL = try container.decode(URL.self, forKey: .relayURL)
        hostID = try container.decode(HostID.self, forKey: .hostID)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        hostEphemeralPublicKey = try container.decode(Data.self, forKey: .hostEphemeralPublicKey)
        deviceIdentityPublicKey = try container.decode(Data.self, forKey: .deviceIdentityPublicKey)
        deviceAuthorizationPublicKey = try container.decodeIfPresent(
            Data.self,
            forKey: .deviceAuthorizationPublicKey
        )
        deviceEphemeralPublicKey = try container.decode(Data.self, forKey: .deviceEphemeralPublicKey)
        clientNonce = try container.decode(Data.self, forKey: .clientNonce)
        deviceDisplayName = try container.decode(String.self, forKey: .deviceDisplayName)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public struct GADAuthenticatedPairingRequest: Codable, Equatable, Sendable {
    public let material: GADAuthenticatedPairingMaterial
    public let deviceSignature: Data

    public init(material: GADAuthenticatedPairingMaterial, deviceSignature: Data) {
        self.material = material
        self.deviceSignature = deviceSignature
    }
}

public struct GADAuthenticatedPairingChallenge: Codable, Equatable, Sendable {
    public let confirmationCode: String
    public let hostProof: Data
    public let relayRevocationProof: String?

    public init(
        confirmationCode: String,
        hostProof: Data,
        relayRevocationProof: String? = nil
    ) {
        self.confirmationCode = confirmationCode
        self.hostProof = hostProof
        self.relayRevocationProof = relayRevocationProof
    }
}

public struct GADAuthenticatedPairingResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let deviceProof: Data

    public init(accepted: Bool, deviceProof: Data) {
        self.accepted = accepted
        self.deviceProof = deviceProof
    }
}

public struct GADSignedCommandEnvelope: Codable, Equatable, Sendable {
    public let commandBytes: Data
    public let deviceSignature: Data
    public let localAuthorizationSignature: Data?

    public init(
        commandBytes: Data,
        deviceSignature: Data,
        localAuthorizationSignature: Data? = nil
    ) {
        self.commandBytes = commandBytes
        self.deviceSignature = deviceSignature
        self.localAuthorizationSignature = localAuthorizationSignature
    }

    private enum CodingKeys: String, CodingKey {
        case commandBytes, deviceSignature, localAuthorizationSignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandBytes = try container.decode(Data.self, forKey: .commandBytes)
        deviceSignature = try container.decode(Data.self, forKey: .deviceSignature)
        localAuthorizationSignature = try container.decodeIfPresent(
            Data.self,
            forKey: .localAuthorizationSignature
        )
    }
}

public enum GADWireMessage: Codable, Equatable, Sendable {
    case pairingRequest(deviceID: DeviceID, sessionSecret: Data, deviceDisplayName: String)
    case authenticatedPairingRequest(GADAuthenticatedPairingRequest)
    case authenticatedPairingChallenge(GADAuthenticatedPairingChallenge)
    case authenticatedPairingResponse(GADAuthenticatedPairingResponse)
    case pairingAccepted
    case pairingRejected(reason: String)
    case clientHello(deviceID: DeviceID, supportedVersions: [GADProtocolVersion], lastHostEpoch: HostEpoch?, lastRevision: StateRevision?)
    case serverHello(ClientSession)
    case snapshotRequest
    case replayRequest(after: StateRevision)
    case command(GADCommand)
    case signedCommand(GADSignedCommandEnvelope)
    case acknowledgement(GADCommandAcknowledgement)
    case snapshot(DashboardProjection)
    case delta(GADStateDelta)
    case ping(UUID)
    case pong(UUID)
    case disconnect(reason: String)
}

public struct GADUnsignedEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: GADProtocolVersion
    public let messageID: UUID
    /// The authenticated identifier of the request this message answers.
    /// Protocol 3.8 requires it for operational responses and leaves it nil
    /// for requests and unsolicited lifecycle messages.
    public let replyToMessageID: UUID?
    public let hostID: HostID?
    public let deviceID: DeviceID
    public let sequence: UInt64
    public let sentAt: Date
    public let message: GADWireMessage

    public init(
        protocolVersion: GADProtocolVersion,
        messageID: UUID,
        replyToMessageID: UUID? = nil,
        hostID: HostID?,
        deviceID: DeviceID,
        sequence: UInt64,
        sentAt: Date,
        message: GADWireMessage
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.replyToMessageID = replyToMessageID
        self.hostID = hostID
        self.deviceID = deviceID
        self.sequence = sequence
        self.sentAt = sentAt
        self.message = message
    }
}

public struct GADSealedEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: GADProtocolVersion
    public let messageID: UUID
    public let hostID: HostID
    public let deviceID: DeviceID
    public let sequence: UInt64
    public let sentAt: Date
    public let nonce: Data
    public let ciphertext: Data
    public let signature: Data

    public init(
        protocolVersion: GADProtocolVersion,
        messageID: UUID,
        hostID: HostID,
        deviceID: DeviceID,
        sequence: UInt64,
        sentAt: Date,
        nonce: Data,
        ciphertext: Data,
        signature: Data
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.hostID = hostID
        self.deviceID = deviceID
        self.sequence = sequence
        self.sentAt = sentAt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }
}

public enum GADWireCodecError: Error, Equatable {
    case oversized(Int)
}

public struct GADWireCodec: Sendable {
    public static let defaultMaximumBytes = 1_048_576

    private let maximumBytes: Int

    public init(maximumBytes: Int = GADWireCodec.defaultMaximumBytes) {
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public func encode<T: Encodable & Sendable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw GADWireCodecError.oversized(data.count) }
        return data
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw GADWireCodecError.oversized(data.count) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }
}
