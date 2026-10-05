import CryptoKit
import Foundation
import GobyDomain

/// Client-side explicit scope preference. Each CLI store gets its own suite;
/// execution and catalog ownership stay in Core.
@MainActor
public final class GobyCLIProjectPreferences {
    private let defaults: UserDefaults
    public init(store: URL) throws {
        let digest = SHA256.hash(data: Data(GobySocketIO.canonicalLocation(store).path.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let defaults = UserDefaults(suiteName: "com.goby.cli.scope." + digest) else { throw GobyTerminalError("CLI scope preferences are unavailable.", code: 3) }
        self.defaults = defaults
    }
    public var selected: [ProjectID] { (defaults.stringArray(forKey: "projectIDs") ?? []).map(ProjectID.init(rawValue:)) }
    public func select(_ ids: [ProjectID]) { defaults.set(ids.map(\.rawValue), forKey: "projectIDs") }
}
