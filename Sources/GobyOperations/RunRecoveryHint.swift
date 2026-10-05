import GobyDomain

/// Why a stopped run cannot simply be retried, when the cause is visible in
/// provider state: the provider it used is unavailable, signed out or failing.
/// Built from state, never from parsing error text.
public struct RunRecoveryHint: Equatable, Sendable {
    public let providerID: AgentProviderID
    public let message: String

    public static func hint(
        for run: RunRecord,
        availableProviderIDs: Set<AgentProviderID>,
        accounts: [ProviderAccountSnapshot],
        codexState: CodexConnectionState? = nil
    ) -> RunRecoveryHint? {
        guard run.status == .failed || run.status == .needsAttention else { return nil }
        var seen = Set<AgentProviderID>()
        for providerID in run.assignments.map(\.providerID) where seen.insert(providerID).inserted {
            let name = providerID.displayName
            guard availableProviderIDs.contains(providerID) else {
                return RunRecoveryHint(providerID: providerID, message: "\(name) isn't available on this Mac.")
            }
            // Codex reports its connection separately from provider accounts.
            let state: ProviderConnectionState? = if providerID == .codex, let codexState {
                switch codexState {
                case .notChecked: .notChecked
                case let .unavailable(reason): .unavailable(reason: reason)
                case .disconnected: .disconnected
                case .connecting: .connecting
                case let .connected(version): .connected(version: version)
                case .needsAuthentication: .needsAuthentication
                case let .failed(message): .failed(message: message)
                }
            } else {
                accounts.first(where: { $0.providerID == providerID })?.connectionState
            }
            switch state {
            case .needsAuthentication:
                return RunRecoveryHint(providerID: providerID, message: "Sign in to \(name) to run this again.")
            case .disconnected:
                return RunRecoveryHint(providerID: providerID, message: "\(name) is disconnected.")
            case let .unavailable(reason):
                return RunRecoveryHint(providerID: providerID, message: "\(name) is unavailable: \(reason)")
            case let .failed(message):
                return RunRecoveryHint(providerID: providerID, message: "\(name) reported a problem: \(message)")
            case .notChecked, .connecting, .connected, nil:
                continue
            }
        }
        return nil
    }
}
