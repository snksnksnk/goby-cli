import Foundation
import GobyApplication
import Testing
@testable import GobyInfrastructure

@Suite("Keychain relay host admission store", .serialized)
struct KeychainRelayHostAdmissionStoreTests {
    @Test("A relay capability round-trips, replaces, and removes from Keychain")
    func roundTripsReplacesAndRemovesCredential() async throws {
        let service = "com.goby.agentic-dashboard.tests.relay-admission.\(UUID().uuidString)"
        let store = KeychainRelayHostAdmissionStore(
            service: service,
            account: "host-installation"
        )
        let first = try credential(installation: "A", signature: "b")
        let replacement = try credential(installation: "C", signature: "d")

        do {
            try await store.remove()
            #expect(try await store.credential() == nil)

            try await store.save(first)
            #expect(try await store.credential() == first)

            try await store.save(replacement)
            #expect(try await store.credential() == replacement)

            try await store.remove()
            #expect(try await store.credential() == nil)
        } catch {
            try? await store.remove()
            throw error
        }
    }

    private func credential(
        installation: Character,
        signature: Character
    ) throws -> GADRelayHostAdmissionCredential {
        try GADRelayHostAdmissionCredential(
            "v1.\(String(repeating: installation, count: 43)).2000000000.\(String(repeating: signature, count: 43))",
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }
}
