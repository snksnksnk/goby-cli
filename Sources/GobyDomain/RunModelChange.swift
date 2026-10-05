import Foundation

/// An explicit choice for a fresh attempt of an existing run. The original
/// reviewed plan remains historical; the override is recorded on assignments
/// and in the run journal. It never authorizes a pending provider operation.
public struct RunModelChange: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let model: String
    public let expectedUpdatedAt: Date

    public init(providerID: AgentProviderID, model: String, expectedUpdatedAt: Date) {
        self.providerID = providerID
        self.model = model
        self.expectedUpdatedAt = expectedUpdatedAt
    }

    public func matchesRunVersion(_ updatedAt: Date) -> Bool {
        // IPC encodes milliseconds since 1970; Date uses seconds since 2001.
        // That floating-point conversion can lose a fraction of a microsecond.
        abs(updatedAt.timeIntervalSince(expectedUpdatedAt)) < 0.000_001
    }
}
