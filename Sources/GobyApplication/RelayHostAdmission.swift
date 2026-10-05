import Foundation

public enum GADRelayHostAdmissionError: LocalizedError, Equatable, Sendable {
    case invalid
    case expired

    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Enter the installation-specific relay access key supplied by the beta operator."
        case .expired:
            "This relay access key expired. Request a replacement before enabling Remote Access."
        }
    }
}

/// An opaque, installation-bound capability issued by the relay operator.
/// Its value belongs only in Keychain and host request headers.
public struct GADRelayHostAdmissionCredential: Equatable, Sendable {
    public let rawValue: String
    public let expiresAt: Date

    public init(_ rawValue: String, now: Date = .now) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "v1",
              Self.isBase64URL32(parts[1]),
              parts[2].count == 10,
              parts[2].allSatisfy(\.isNumber),
              Self.isBase64URL32(parts[3]),
              let seconds = TimeInterval(parts[2]) else {
            throw GADRelayHostAdmissionError.invalid
        }
        let expiresAt = Date(timeIntervalSince1970: seconds)
        guard expiresAt > now else { throw GADRelayHostAdmissionError.expired }
        self.rawValue = normalized
        self.expiresAt = expiresAt
    }

    private static func isBase64URL32(_ value: Substring) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "_"
                || scalar == "-"
        }
    }
}

public protocol GADRelayHostAdmissionPersisting: Sendable {
    func credential() async throws -> GADRelayHostAdmissionCredential?
    func save(_ credential: GADRelayHostAdmissionCredential) async throws
    func remove() async throws
}
