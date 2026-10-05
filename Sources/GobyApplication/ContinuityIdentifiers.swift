import Foundation

public struct StateRevision: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let zero = StateRevision(rawValue: 0)

    public static func < (lhs: StateRevision, rhs: StateRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func advanced() -> StateRevision {
        StateRevision(rawValue: rawValue + 1)
    }
}

public struct EntityRevision: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let zero = EntityRevision(rawValue: 0)

    public static func < (lhs: EntityRevision, rhs: EntityRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func advanced() -> EntityRevision {
        EntityRevision(rawValue: rawValue + 1)
    }
}

public struct HostID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> HostID { HostID(rawValue: UUID().uuidString.lowercased()) }
}

public struct HostEpoch: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> HostEpoch { HostEpoch(rawValue: UUID().uuidString.lowercased()) }
}

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> DeviceID { DeviceID(rawValue: UUID().uuidString.lowercased()) }
}

public struct CommandID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> CommandID { CommandID(rawValue: UUID().uuidString.lowercased()) }
}

public struct GADProtocolVersion: Codable, Hashable, Comparable, Sendable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public static let version1 = GADProtocolVersion(major: 1, minor: 0)
    /// Provider-scoped projections, refresh and reviewed handoff commands.
    public static let version2 = GADProtocolVersion(major: 2, minor: 0)
    /// Mutually authenticated pairing with human-visible verification. Minor 1
    /// adds purpose-bound provider-binding instruction editing; minor 2 adds
    /// reviewed New Project transactions rooted only in host-authorized
    /// locations; minor 3 binds high-impact mobile authorization to an exact
    /// command using a separate user-presence-protected device key; minor 4
    /// adds remote-safe attachment presentation and reviewed local-branch
    /// switching without exposing a filesystem or Git command endpoint; minor
    /// 5 adds durable automation projection and reviewed schedule controls;
    /// minor 6 separates Mac-only relay authority from device credentials;
    /// minor 7 adds acknowledged device-initiated pairing revocation; minor 8
    /// binds every operational response to the exact current request so a
    /// relay cannot replay a prior live session after an app restart.
    /// Minor 9 adds activity-only polling and explicit pre-admission deferral.
    /// Minor 10 adds an explicit model choice for restarting unfinished run assignments.
    /// Minor 11 adds typed, redacted run activity steps (no command output).
    /// Minor 12 adds the host-held temporary chat (ask/end commands and an
    /// optional host projection field). Minor 13 adds parallel requests:
    /// temporary agent copies, conflict waits and the `startNow` run control.
    public static let version3 = GADProtocolVersion(major: 3, minor: 13)
    public static let current = version3
    public static let supportedVersions = [version3, version2, version1]

    public static func supports(_ version: GADProtocolVersion) -> Bool {
        supportedVersions.contains { $0.major == version.major }
    }

    public static func < (lhs: GADProtocolVersion, rhs: GADProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
