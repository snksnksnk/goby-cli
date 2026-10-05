import Foundation

/// Task freshness is independent of account connectivity and dashboard updates.
public struct ProviderActivityFreshness: Codable, Equatable, Sendable {
    public let lastSuccessfulAt: Date?
    public let staleSince: Date?

    public static func fresh(at date: Date) -> Self {
        Self(lastSuccessfulAt: date, staleSince: nil)
    }

    public static func unavailable(since date: Date, lastSuccessfulAt: Date? = nil) -> Self {
        Self(lastSuccessfulAt: lastSuccessfulAt, staleSince: date)
    }

    public var isStale: Bool { staleSince != nil }

    public func markingStale(at date: Date) -> Self {
        Self(lastSuccessfulAt: lastSuccessfulAt, staleSince: staleSince ?? date)
    }
}
