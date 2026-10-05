import Foundation

public enum GADPushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

public enum GADPushTransport: String, Codable, Equatable, Sendable {
    case apns
    case fcm
}

public enum GADNotificationCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case needsAttention
    case runFinished
}

/// A purpose-bound APNs or FCM endpoint sent inside Goby's encrypted device-to-host
/// channel. It is never added to dashboard projections, logs or receipts.
public struct GADNotificationRegistration: Codable, Equatable, Sendable {
    public static let maximumAPNSTokenBytes = 128
    public static let maximumFCMTokenBytes = 2_048
    /// Retained for source compatibility with the APNs-only registration API.
    public static let maximumTokenBytes = maximumAPNSTokenBytes

    public let token: Data
    public let environment: GADPushEnvironment
    public let categories: [GADNotificationCategory]
    public let transport: GADPushTransport

    public init(
        token: Data,
        environment: GADPushEnvironment,
        categories: [GADNotificationCategory],
        transport: GADPushTransport = .apns
    ) {
        self.token = token
        self.environment = environment
        self.categories = categories
        self.transport = transport
    }

    public var isValid: Bool {
        tokenIsValid
            && !categories.isEmpty
            && Set(categories).count == categories.count
    }

    private var tokenIsValid: Bool {
        guard !token.isEmpty else { return false }
        switch transport {
        case .apns:
            return token.count <= Self.maximumAPNSTokenBytes
        case .fcm:
            guard token.count <= Self.maximumFCMTokenBytes,
                  let value = String(data: token, encoding: .utf8),
                  value.utf8.count == token.count else { return false }
            return !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case token, environment, categories, transport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(Data.self, forKey: .token)
        environment = try container.decode(GADPushEnvironment.self, forKey: .environment)
        categories = try container.decode([GADNotificationCategory].self, forKey: .categories)
        transport = try container.decodeIfPresent(GADPushTransport.self, forKey: .transport) ?? .apns
    }
}

public protocol GADNotificationRegistrationPersisting: Sendable {
    func registration(for deviceID: DeviceID) async throws -> GADNotificationRegistration?
    func save(_ registration: GADNotificationRegistration, for deviceID: DeviceID) async throws
    func remove(for deviceID: DeviceID) async throws
}

public struct UpdateNotificationRegistrationUseCase: Sendable {
    private let repository: any GADNotificationRegistrationPersisting

    public init(repository: any GADNotificationRegistrationPersisting) {
        self.repository = repository
    }

    public func callAsFunction(
        _ registration: GADNotificationRegistration?,
        for deviceID: DeviceID
    ) async throws {
        if let registration {
            guard registration.isValid else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "The notification endpoint is invalid or exceeds Goby's safe limits."
                )
            }
            try await repository.save(registration, for: deviceID)
        } else {
            try await repository.remove(for: deviceID)
        }
    }
}
