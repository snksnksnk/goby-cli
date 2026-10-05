import Foundation
import Testing
@testable import GobyApplication

@Suite("Relay host admission")
struct RelayHostAdmissionTests {
    private let installation = String(repeating: "A", count: 43)
    private let signature = String(repeating: "b", count: 43)

    @Test("An issued installation capability is parsed without exposing its components")
    func parsesIssuedCapability() throws {
        let credential = try GADRelayHostAdmissionCredential(
            "v1.\(installation).2000000000.\(signature)",
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(credential.rawValue.hasPrefix("v1."))
    }

    @Test("Malformed and expired capabilities fail closed")
    func rejectsMalformedAndExpiredCapabilities() {
        #expect(throws: GADRelayHostAdmissionError.invalid) {
            _ = try GADRelayHostAdmissionCredential("shared-beta-key")
        }
        #expect(throws: GADRelayHostAdmissionError.expired) {
            _ = try GADRelayHostAdmissionCredential(
                "v1.\(installation).2000000000.\(signature)",
                now: Date(timeIntervalSince1970: 2_000_000_001)
            )
        }
    }
}
