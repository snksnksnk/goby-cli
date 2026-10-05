import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Relay provisioning installation identity")
struct KeychainRelayProvisioningIdentityStoreTests {
    @Test("Creates one opaque stable identity per Keychain record")
    func persistsStableIdentity() async throws {
        let suffix = UUID().uuidString.lowercased()
        let store = KeychainRelayProvisioningIdentityStore(
            service: "com.goby.tests.relay-provisioning.\(suffix)",
            account: "test-installation"
        )

        let first = try await store.loadOrCreate()
        let second = try await store.loadOrCreate()

        #expect(first == second)
        #expect(first.count == 43)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}
