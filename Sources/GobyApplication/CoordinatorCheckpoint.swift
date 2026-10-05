import Foundation

public struct GADCoordinatorIdempotencyCheckpoint: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let commandID: CommandID
    public let deviceID: DeviceID
    public let hostEpoch: HostEpoch
    public let baseRevision: StateRevision
    public let payloadKind: String
    /// SHA-256 of the canonical encoded command. The digest binds a durable
    /// idempotency acknowledgement without retaining prompt or command bodies.
    public let commandDigest: String?
    public let acknowledgement: GADCommandAcknowledgement
    public let recordedAt: Date

    public init(
        idempotencyKey: String,
        commandID: CommandID,
        deviceID: DeviceID,
        hostEpoch: HostEpoch,
        baseRevision: StateRevision,
        payloadKind: String,
        commandDigest: String? = nil,
        acknowledgement: GADCommandAcknowledgement,
        recordedAt: Date
    ) {
        self.idempotencyKey = idempotencyKey
        self.commandID = commandID
        self.deviceID = deviceID
        self.hostEpoch = hostEpoch
        self.baseRevision = baseRevision
        self.payloadKind = payloadKind
        self.commandDigest = commandDigest
        self.acknowledgement = acknowledgement
        self.recordedAt = recordedAt
    }
}

/// Durable canonical protocol state shared by the foreground Mac app and its
/// background host. Pairing secrets and device credentials remain in Keychain.
public struct GADCoordinatorCheckpoint: Codable, Equatable, Sendable {
    /// Replay is a disposable cache, not run history or command authority.
    /// Large provider snapshots must not make every checkpoint/startup unbounded.
    public static let maximumReplayJournalBytes = 2 * 1_024 * 1_024
    public static let maximumReplayJournalCount = 256

    public let hostID: HostID
    public let hostEpoch: HostEpoch
    public let protocolVersion: GADProtocolVersion
    public let projection: DashboardProjection
    public let journal: [GADStateDelta]
    public let idempotency: [GADCoordinatorIdempotencyCheckpoint]
    public let savedAt: Date

    private enum CodingKeys: String, CodingKey {
        case hostID, hostEpoch, protocolVersion, projection, journal, idempotency, savedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(HostID.self, forKey: .hostID)
        hostEpoch = try container.decode(HostEpoch.self, forKey: .hostEpoch)
        protocolVersion = try container.decode(GADProtocolVersion.self, forKey: .protocolVersion)
        projection = try container.decode(DashboardProjection.self, forKey: .projection)
        idempotency = try container.decode([GADCoordinatorIdempotencyCheckpoint].self, forKey: .idempotency)
        savedAt = try container.decode(Date.self, forKey: .savedAt)

        // Visit the newest entries first without materializing every legacy
        // delta. Old checkpoints can contain tens of MB of repeated task lists.
        var entries = try container.nestedUnkeyedContainer(forKey: .journal)
        var pending: [any Decoder] = []
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            pending.append(entry)
            if pending.count > Self.maximumReplayJournalCount { pending.removeFirst() }
        }
        var retained: [GADStateDelta] = []
        var bytes = 2 // JSON array delimiters
        for entry in pending.reversed() {
            let delta = try GADStateDelta(from: entry)
            let size = Self.replayByteSize(delta)
            guard size <= Self.maximumReplayJournalBytes - bytes else { break }
            retained.append(delta)
            bytes += size
        }
        journal = retained.reversed()
    }

    static func replayByteSize(_ delta: GADStateDelta) -> Int {
        // Count a separator as well, conservatively including the final entry.
        guard let data = try? JSONEncoder().encode(delta) else { return maximumReplayJournalBytes + 1 }
        return data.count + 1
    }

    static func boundedReplayJournal(_ journal: [GADStateDelta], maximumCount: Int) -> [GADStateDelta] {
        var retained: [GADStateDelta] = []
        var bytes = 2
        for delta in journal.suffix(min(maximumCount, maximumReplayJournalCount)).reversed() {
            let size = replayByteSize(delta)
            guard size <= maximumReplayJournalBytes - bytes else { break }
            retained.append(delta)
            bytes += size
        }
        return retained.reversed()
    }

    public init(
        hostID: HostID,
        hostEpoch: HostEpoch,
        protocolVersion: GADProtocolVersion,
        projection: DashboardProjection,
        journal: [GADStateDelta],
        idempotency: [GADCoordinatorIdempotencyCheckpoint],
        savedAt: Date
    ) {
        self.hostID = hostID
        self.hostEpoch = hostEpoch
        self.protocolVersion = protocolVersion
        self.projection = projection
        self.journal = journal
        self.idempotency = idempotency
        self.savedAt = savedAt
    }
}

public protocol GADCoordinatorCheckpointRepository: Sendable {
    func loadCoordinatorCheckpoint(hostID: HostID) async throws -> GADCoordinatorCheckpoint?
    func saveCoordinatorCheckpoint(_ checkpoint: GADCoordinatorCheckpoint) async throws
}
