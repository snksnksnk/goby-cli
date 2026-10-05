import CryptoKit
import Foundation
import GobyApplication
import GobyRemoteContract
import Security

public struct GADPairingProfile: Codable, Equatable, Sendable {
    public let protocolVersion: GADProtocolVersion
    public let relayURL: URL
    public let hostID: HostID
    public let deviceID: DeviceID
    public let sharedSecret: Data
    /// Present only in the Mac registry. This value must never be encoded into
    /// a QR payload or copied into the iOS profile.
    public let relayHostSecret: Data?
    /// Fixed proof that lets the device authenticate a relay revocation 410
    /// without receiving the Mac-only relay secret.
    public let relayRevocationProof: String?
    public let displayName: String
    public let deviceIdentityPublicKey: Data?
    public let deviceAuthorizationPublicKey: Data?
    public let createdAt: Date
    public let sessionKeyCreatedAt: Date

    public init(
        protocolVersion: GADProtocolVersion = .current,
        relayURL: URL,
        hostID: HostID,
        deviceID: DeviceID,
        sharedSecret: Data,
        relayHostSecret: Data? = nil,
        relayRevocationProof: String? = nil,
        displayName: String,
        deviceIdentityPublicKey: Data? = nil,
        deviceAuthorizationPublicKey: Data? = nil,
        createdAt: Date = .now,
        sessionKeyCreatedAt: Date? = nil
    ) throws {
        guard let relayURL = try? GADRelayEndpoint.validated(relayURL),
              sharedSecret.count == 32,
              relayHostSecret == nil || relayHostSecret?.count == 32,
              relayRevocationProof == nil || relayRevocationProof?.count == 43,
              deviceIdentityPublicKey == nil || deviceIdentityPublicKey?.count == 64,
              deviceAuthorizationPublicKey == nil || deviceAuthorizationPublicKey?.count == 64 else {
            throw GADPairingError.invalidPayload
        }
        self.protocolVersion = protocolVersion
        self.relayURL = relayURL
        self.hostID = hostID
        self.deviceID = deviceID
        self.sharedSecret = sharedSecret
        self.relayHostSecret = relayHostSecret
        self.relayRevocationProof = relayRevocationProof
        self.displayName = String(displayName.prefix(120))
        self.deviceIdentityPublicKey = deviceIdentityPublicKey
        self.deviceAuthorizationPublicKey = deviceAuthorizationPublicKey
        self.createdAt = createdAt
        self.sessionKeyCreatedAt = sessionKeyCreatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, relayURL, hostID, deviceID, sharedSecret, relayHostSecret
        case relayRevocationProof, displayName
        case deviceIdentityPublicKey, deviceAuthorizationPublicKey, createdAt, sessionKeyCreatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(
            GADProtocolVersion.self,
            forKey: .protocolVersion
        ) ?? .version1
        let decodedRelayURL = try container.decode(URL.self, forKey: .relayURL)
        guard let validatedRelayURL = try? GADRelayEndpoint.validated(decodedRelayURL) else {
            throw GADPairingError.invalidPayload
        }
        relayURL = validatedRelayURL
        hostID = try container.decode(HostID.self, forKey: .hostID)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        sharedSecret = try container.decode(Data.self, forKey: .sharedSecret)
        relayHostSecret = try container.decodeIfPresent(Data.self, forKey: .relayHostSecret)
        relayRevocationProof = try container.decodeIfPresent(String.self, forKey: .relayRevocationProof)
        displayName = try container.decode(String.self, forKey: .displayName)
        deviceIdentityPublicKey = try container.decodeIfPresent(Data.self, forKey: .deviceIdentityPublicKey)
        deviceAuthorizationPublicKey = try container.decodeIfPresent(
            Data.self,
            forKey: .deviceAuthorizationPublicKey
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        sessionKeyCreatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .sessionKeyCreatedAt
        ) ?? createdAt
        guard sharedSecret.count == 32,
              relayHostSecret == nil || relayHostSecret?.count == 32,
              relayRevocationProof == nil || relayRevocationProof?.count == 43,
              deviceIdentityPublicKey == nil || deviceIdentityPublicKey?.count == 64,
              deviceAuthorizationPublicKey == nil || deviceAuthorizationPublicKey?.count == 64 else {
            throw GADPairingError.invalidPayload
        }
    }

    public var requiresRelayRepair: Bool {
        protocolVersion < GADProtocolVersion(major: 3, minor: 6)
            || relayHostSecret == nil
            || relayRevocationProof == nil
    }
}

public struct GADPairingPayload: Codable, Equatable, Sendable {
    public static let scheme = "goby"
    public static let host = "pair"
    /// Pairing records are intentionally much smaller than ordinary remote
    /// frames. Bound both textual and decoded forms before Foundation URL or
    /// Base64 helpers can create attacker-sized intermediate allocations.
    public static let maximumDecodedPayloadBytes = 16_384
    public static let maximumEncodedPayloadBytes = 21_848
    public static let maximumURLBytes = 24_576

    public let version: GADProtocolVersion
    public let relayURL: URL
    public let hostID: HostID
    public let deviceID: DeviceID
    public let oneTimeSecret: Data
    public let hostEphemeralPublicKey: Data?
    public let hostDisplayName: String
    public let expiresAt: Date

    public init(
        version: GADProtocolVersion = .current,
        relayURL: URL,
        hostID: HostID,
        deviceID: DeviceID,
        oneTimeSecret: Data,
        hostEphemeralPublicKey: Data? = nil,
        hostDisplayName: String,
        expiresAt: Date
    ) throws {
        guard let relayURL = try? GADRelayEndpoint.validated(relayURL),
              oneTimeSecret.count == 32,
              expiresAt > .now,
              version.major < GADProtocolVersion.version3.major
                || hostEphemeralPublicKey?.count == 32 else {
            throw GADPairingError.invalidPayload
        }
        self.version = version
        self.relayURL = relayURL
        self.hostID = hostID
        self.deviceID = deviceID
        self.oneTimeSecret = oneTimeSecret
        self.hostEphemeralPublicKey = hostEphemeralPublicKey
        self.hostDisplayName = String(hostDisplayName.prefix(120))
        self.expiresAt = expiresAt
    }

    public func url(codec: GADWireCodec = .init()) throws -> URL {
        let data = try codec.encode(self)
        guard data.count <= Self.maximumDecodedPayloadBytes else {
            throw GADPairingError.invalidPayload
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "payload", value: data.base64URLEncodedString())]
        guard let url = components.url else { throw GADPairingError.invalidPayload }
        return url
    }

    public static func validatedURL(from source: String) throws -> URL {
        guard source.utf8.count <= maximumURLBytes else {
            throw GADPairingError.invalidPayload
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumURLBytes,
              let url = URL(string: trimmed) else {
            throw GADPairingError.invalidPayload
        }
        return url
    }

    public static func decode(url: URL, now: Date = .now, codec: GADWireCodec = .init()) throws -> Self {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              url.scheme == scheme, url.host == host,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "payload" })?.value,
              encoded.utf8.count <= maximumEncodedPayloadBytes,
              let data = Data(base64URLEncoded: encoded) else {
            throw GADPairingError.invalidPayload
        }
        guard data.count <= maximumDecodedPayloadBytes else {
            throw GADPairingError.invalidPayload
        }
        let payload = try codec.decode(Self.self, from: data)
        guard GADProtocolVersion.supports(payload.version),
              payload.expiresAt >= now,
              (try? GADRelayEndpoint.validated(payload.relayURL)) != nil,
              payload.oneTimeSecret.count == 32,
              payload.version.major < GADProtocolVersion.version3.major
                || payload.hostEphemeralPublicKey?.count == 32 else {
            throw GADPairingError.expiredOrIncompatible
        }
        return payload
    }

    public func profile() throws -> GADPairingProfile {
        try GADPairingProfile(
            protocolVersion: version,
            relayURL: relayURL,
            hostID: hostID,
            deviceID: deviceID,
            sharedSecret: oneTimeSecret,
            displayName: hostDisplayName
        )
    }
}

public enum GADPairingError: LocalizedError, Equatable, Sendable {
    case invalidPayload
    case expiredOrIncompatible
    case maximumDevices
    case invalidDisplayName
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "This is not a valid Goby pairing code."
        case .expiredOrIncompatible: "This pairing code expired or uses an incompatible protocol."
        case .maximumDevices: "Goby already has the maximum of eight paired devices. Revoke one before pairing another."
        case .invalidDisplayName: "Enter a device name between 1 and 120 characters."
        case let .keychain(status): "Goby could not access the secure pairing record (\(status))."
        }
    }
}

public actor GADPairingProfileStore {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let codec: GADWireCodec

    public init(
        service: String = "com.demetrisgeorgiou.Goby.pairing",
        account: String = "owner-device",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.codec = GADWireCodec(maximumBytes: 16_384)
    }

    public func load() throws -> GADPairingProfile? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GADPairingError.keychain(status) }
        return try codec.decode(GADPairingProfile.self, from: data)
    }

    public func save(_ profile: GADPairingProfile) throws {
        let data = try codec.encode(profile)
        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { identity[kSecAttrAccessGroup as String] = accessGroup }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GADPairingError.keychain(added) }
        } else if updated != errSecSuccess {
            throw GADPairingError.keychain(updated)
        }
    }

    public func remove() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GADPairingError.keychain(status) }
    }
}

struct GADPendingPairing: Codable, Equatable, Sendable {
    let profile: GADPairingProfile
    let expiresAt: Date
}

struct GADPairingRegistryState: Equatable, Sendable {
    static let maximumDevices = 8
    private(set) var profiles: [GADPairingProfile]
    private(set) var pendingPairings: [GADPendingPairing]
    private(set) var pendingRevocations: [GADPairingProfile]

    init(
        profiles: [GADPairingProfile] = [],
        pendingPairings: [GADPendingPairing] = [],
        pendingRevocations: [GADPairingProfile] = []
    ) {
        self.profiles = profiles.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.deviceID.rawValue < rhs.deviceID.rawValue
            }
            return lhs.createdAt < rhs.createdAt
        }
        self.pendingPairings = pendingPairings.sorted { lhs, rhs in
            if lhs.profile.createdAt == rhs.profile.createdAt {
                return lhs.profile.deviceID.rawValue < rhs.profile.deviceID.rawValue
            }
            return lhs.profile.createdAt < rhs.profile.createdAt
        }
        self.pendingRevocations = pendingRevocations.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.deviceID.rawValue < rhs.deviceID.rawValue
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    mutating func upsert(_ profile: GADPairingProfile) throws {
        guard !pendingPairings.contains(where: { $0.profile.deviceID == profile.deviceID }) else {
            throw GADPairingError.invalidPayload
        }
        guard !pendingRevocations.contains(where: { $0.deviceID == profile.deviceID }) else {
            throw GADPairingError.invalidPayload
        }
        if let index = profiles.firstIndex(where: { $0.deviceID == profile.deviceID }) {
            profiles[index] = profile
        } else {
            guard profiles.count + pendingPairings.count + pendingRevocations.count < Self.maximumDevices else {
                throw GADPairingError.maximumDevices
            }
            profiles.append(profile)
        }
        self = GADPairingRegistryState(
            profiles: profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
    }

    mutating func stagePairing(_ profile: GADPairingProfile, expiresAt: Date) throws {
        guard !profiles.contains(where: { $0.deviceID == profile.deviceID }),
              !pendingRevocations.contains(where: { $0.deviceID == profile.deviceID }) else {
            throw GADPairingError.invalidPayload
        }
        let pending = GADPendingPairing(profile: profile, expiresAt: expiresAt)
        if let index = pendingPairings.firstIndex(where: { $0.profile.deviceID == profile.deviceID }) {
            pendingPairings[index] = pending
        } else {
            guard profiles.count + pendingPairings.count + pendingRevocations.count < Self.maximumDevices else {
                throw GADPairingError.maximumDevices
            }
            pendingPairings.append(pending)
        }
        self = GADPairingRegistryState(
            profiles: profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
    }

    mutating func activatePendingPairing(deviceID: DeviceID, now: Date) -> GADPairingProfile? {
        guard let index = pendingPairings.firstIndex(where: { $0.profile.deviceID == deviceID }) else {
            return nil
        }
        let pending = pendingPairings.remove(at: index)
        guard now <= pending.expiresAt else {
            self = GADPairingRegistryState(
                profiles: profiles,
                pendingPairings: pendingPairings,
                pendingRevocations: pendingRevocations
            )
            return nil
        }
        profiles.append(pending.profile)
        self = GADPairingRegistryState(
            profiles: profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
        return pending.profile
    }

    mutating func discardPendingPairing(deviceID: DeviceID) {
        pendingPairings.removeAll { $0.profile.deviceID == deviceID }
    }

    mutating func rename(deviceID: DeviceID, displayName: String) throws {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 120 else {
            throw GADPairingError.invalidDisplayName
        }
        guard let index = profiles.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        let profile = profiles[index]
        profiles[index] = try GADPairingProfile(
            protocolVersion: profile.protocolVersion,
            relayURL: profile.relayURL,
            hostID: profile.hostID,
            deviceID: profile.deviceID,
            sharedSecret: profile.sharedSecret,
            relayHostSecret: profile.relayHostSecret,
            relayRevocationProof: profile.relayRevocationProof,
            displayName: normalized,
            deviceIdentityPublicKey: profile.deviceIdentityPublicKey,
            deviceAuthorizationPublicKey: profile.deviceAuthorizationPublicKey,
            createdAt: profile.createdAt,
            sessionKeyCreatedAt: profile.sessionKeyCreatedAt
        )
    }

    mutating func remove(deviceID: DeviceID) {
        profiles.removeAll { $0.deviceID == deviceID }
    }

    mutating func beginRevocation(deviceID: DeviceID) -> GADPairingProfile? {
        if let pending = pendingRevocations.first(where: { $0.deviceID == deviceID }) {
            return pending
        }
        guard let index = profiles.firstIndex(where: { $0.deviceID == deviceID }) else { return nil }
        let profile = profiles.remove(at: index)
        pendingRevocations.append(profile)
        self = GADPairingRegistryState(
            profiles: profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
        return profile
    }

    mutating func beginRevokingAll() -> [GADPairingProfile] {
        for profile in profiles where !pendingRevocations.contains(where: { $0.deviceID == profile.deviceID }) {
            pendingRevocations.append(profile)
        }
        profiles.removeAll()
        self = GADPairingRegistryState(
            profiles: profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
        return pendingRevocations
    }

    mutating func completeRevocation(deviceID: DeviceID) {
        pendingRevocations.removeAll { $0.deviceID == deviceID }
    }
}

/// Mac-side Keychain registry for independently revocable paired devices.
/// iOS continues to use `GADPairingProfileStore` for its one local host profile.
public actor GADPairingProfileRegistry {
    public static let maximumDevices = GADPairingRegistryState.maximumDevices

    private struct Record: Codable, Sendable {
        let version: UInt16
        let profiles: [GADPairingProfile]
        let pendingPairings: [GADPendingPairing]?
        let pendingRevocations: [GADPairingProfile]?
    }

    private let service: String
    private let account: String
    private let accessGroup: String?
    private let codec = GADWireCodec(maximumBytes: 128_000)

    public init(
        service: String = "com.demetrisgeorgiou.Goby.pairing-registry",
        account: String = "mac-paired-devices",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func profiles() throws -> [GADPairingProfile] {
        try loadState().profiles
    }

    public func pendingRevocations() throws -> [GADPairingProfile] {
        try loadState().pendingRevocations
    }

    /// New pairings remain non-authoritative until a separate, fresh promotion
    /// commits them to the active profile collection. A crash after staging can
    /// therefore never grant remote command authority on the next launch.
    public func stagePairing(_ profile: GADPairingProfile, expiresAt: Date) throws {
        var state = try loadState()
        try state.stagePairing(profile, expiresAt: expiresAt)
        try save(state)
    }

    public func activatePairing(deviceID: DeviceID, now: Date = .now) throws -> GADPairingProfile {
        var state = try loadState()
        guard let profile = state.activatePendingPairing(deviceID: deviceID, now: now) else {
            // Persist expiry cleanup when possible. Even if this save fails, the
            // retained record is pending and startup never authorizes it.
            try save(state)
            throw GADPairingExchangeError.expired
        }
        try save(state)
        return profile
    }

    public func discardPendingPairing(deviceID: DeviceID) throws {
        var state = try loadState()
        state.discardPendingPairing(deviceID: deviceID)
        if state.profiles.isEmpty && state.pendingPairings.isEmpty && state.pendingRevocations.isEmpty {
            try removeAll()
        } else {
            try save(state)
        }
    }

    public func upsert(_ profile: GADPairingProfile) throws {
        var state = try loadState()
        try state.upsert(profile)
        try save(state)
    }

    public func rename(deviceID: DeviceID, displayName: String) throws {
        var state = try loadState()
        try state.rename(deviceID: deviceID, displayName: displayName)
        try save(state)
    }

    public func remove(deviceID: DeviceID) throws {
        var state = try loadState()
        state.remove(deviceID: deviceID)
        if state.profiles.isEmpty && state.pendingPairings.isEmpty && state.pendingRevocations.isEmpty {
            try removeAll()
        } else {
            try save(state)
        }
    }

    /// Atomically removes the device from the active authorization set while
    /// retaining only the pairing profile needed to finish idempotent relay
    /// revocation. Startup never reauthorizes records in this collection.
    public func beginRevocation(deviceID: DeviceID) throws -> GADPairingProfile? {
        var state = try loadState()
        let profile = state.beginRevocation(deviceID: deviceID)
        if profile != nil { try save(state) }
        return profile
    }

    public func beginRevokingAll() throws -> [GADPairingProfile] {
        var state = try loadState()
        let profiles = state.beginRevokingAll()
        if !profiles.isEmpty { try save(state) }
        return profiles
    }

    public func completeRevocation(deviceID: DeviceID) throws {
        var state = try loadState()
        state.completeRevocation(deviceID: deviceID)
        if state.profiles.isEmpty && state.pendingPairings.isEmpty && state.pendingRevocations.isEmpty {
            try removeAll()
        } else {
            try save(state)
        }
    }

    public func removeAll() throws {
        let status = SecItemDelete(identityQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GADPairingError.keychain(status)
        }
    }

    private var identityQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func loadState() throws -> GADPairingRegistryState {
        var query = identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return GADPairingRegistryState() }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GADPairingError.keychain(status)
        }
        let record = try codec.decode(Record.self, from: data)
        let pendingPairings = record.pendingPairings ?? []
        let pendingRevocations = record.pendingRevocations ?? []
        let deviceIDs = record.profiles.map(\.deviceID)
            + pendingPairings.map(\.profile.deviceID)
            + pendingRevocations.map(\.deviceID)
        guard (record.version == 1 || record.version == 2 || record.version == 3),
              deviceIDs.count <= GADPairingRegistryState.maximumDevices,
              Set(deviceIDs).count == deviceIDs.count else {
            throw GADPairingError.invalidPayload
        }
        return GADPairingRegistryState(
            profiles: record.profiles,
            pendingPairings: pendingPairings,
            pendingRevocations: pendingRevocations
        )
    }

    private func save(_ state: GADPairingRegistryState) throws {
        let data = try codec.encode(Record(
            version: 3,
            profiles: state.profiles,
            pendingPairings: state.pendingPairings,
            pendingRevocations: state.pendingRevocations
        ))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(identityQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = identityQuery
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GADPairingError.keychain(added) }
        } else if updated != errSecSuccess {
            throw GADPairingError.keychain(updated)
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
