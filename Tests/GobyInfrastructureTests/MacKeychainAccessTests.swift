import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Mac Keychain access")
struct MacKeychainAccessTests {
    @Test("Selects the exact entitled Goby shared group")
    func selectsEntitledSharedGroup() {
        #expect(GADMacKeychainAccess.sharedGroup(from: [
            "TEAM123.com.example.Unrelated",
            "TEAM123.com.demetrisgeorgiou.GobyShared",
        ]) == "TEAM123.com.demetrisgeorgiou.GobyShared")
    }

    @Test("Rejects missing, malformed, or ambiguous shared groups")
    func rejectsUnsafeSharedGroupCandidates() {
        #expect(GADMacKeychainAccess.sharedGroup(from: []) == nil)
        #expect(GADMacKeychainAccess.sharedGroup(from: [
            "com.demetrisgeorgiou.GobyShared",
        ]) == nil)
        #expect(GADMacKeychainAccess.sharedGroup(from: [
            "TEAM1.com.demetrisgeorgiou.GobyShared",
            "TEAM2.com.demetrisgeorgiou.GobyShared",
        ]) == nil)
    }

    @Test("Resolves entitlement groups away from the main thread")
    @MainActor
    func resolvesAwayFromMainThread() async {
        let expected = "TEAM123.com.demetrisgeorgiou.GobyShared"
        let resolved = await GADMacKeychainAccess.sharedGroup {
            Thread.isMainThread ? nil : [expected]
        }

        #expect(resolved == expected)
    }
}
