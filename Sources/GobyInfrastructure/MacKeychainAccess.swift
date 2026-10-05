import Foundation
import Security

/// Resolves the shared app/helper Keychain group only when the running process
/// has a real Team identity and the exact entitlement. Ad-hoc development
/// builds return nil and continue to use their process-local Keychain records.
public enum GADMacKeychainAccess {
    public static let groupSuffix = "com.demetrisgeorgiou.GobyShared"

    /// Security entitlement inspection can synchronously consult system
    /// services. Resolve it away from the presentation actor, then inject the
    /// resulting value into the app/helper composition roots.
    public static func sharedGroup() async -> String? {
        await sharedGroup(entitledGroupsProvider: entitledGroups)
    }

    static func sharedGroup(
        entitledGroupsProvider: @escaping @Sendable () -> [String]?
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            sharedGroup(from: entitledGroupsProvider() ?? [])
        }.value
    }

    private static func entitledGroups() -> [String]? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String] else {
            return nil
        }
        return groups
    }

    static func sharedGroup(from entitledGroups: [String]) -> String? {
        let suffix = ".\(groupSuffix)"
        let matches = entitledGroups.filter {
            $0.hasSuffix(suffix) && $0.count > suffix.count
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
