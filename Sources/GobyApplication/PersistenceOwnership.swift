import Foundation

/// Retires a repository instance before its process releases the one-writer
/// lease. Suspending drains admitted asynchronous writes and rejects later
/// writes, including recovery writes triggered by reads.
public protocol GADPersistenceOwnershipControlling: Sendable {
    func suspendWrites() async
    /// Only the composition root may reopen the same instance, after it has
    /// reacquired the exclusive lease during a failed ownership transfer.
    func resumeWrites() async
}

public enum GADPersistenceOwnershipError: LocalizedError, Equatable, Sendable {
    case writesSuspended
    case transferInProgress

    public var errorDescription: String? {
        switch self {
        case .writesSuspended:
            "This store has relinquished write access for the background host."
        case .transferInProgress:
            "Goby is finishing its background-host setup. This action can continue when setup completes."
        }
    }
}
