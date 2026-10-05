import Foundation
import GobyApplication
import GobyDomain
import Testing

struct RunModelChangeContractTests {
    @Test("Legacy run controls decode without a model change")
    func legacyControl() throws {
        let encoded = try JSONEncoder().encode(GADRunControl(runID: "run", action: .resume))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["modelChange"] == nil)
        let control = try JSONDecoder().decode(GADRunControl.self, from: encoded)
        #expect(control.modelChange == nil)
        #expect(control.action == .resume)
    }

    @Test("A model retry retains the exact provider, model, and displayed run revision")
    func exactModelChoice() throws {
        let change = RunModelChange(providerID: .claude, model: "provider-reported-model", expectedUpdatedAt: .now)
        let control = GADRunControl(runID: "run", action: .resume, modelChange: change)
        let data = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(GADRunControl.self, from: data) == control)
    }

    @Test("IPC timestamp precision preserves the displayed version but rejects later changes")
    func wireTimestampPrecision() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for offset in 0..<100 {
            let timestamp = Date(timeIntervalSinceReferenceDate: 811_111_111.123_456 + Double(offset) / 10_000_000)
            let change = RunModelChange(providerID: .codex, model: "model", expectedUpdatedAt: timestamp)
            let received = try decoder.decode(RunModelChange.self, from: encoder.encode(change))
            #expect(received.matchesRunVersion(timestamp))
            #expect(!received.matchesRunVersion(timestamp.addingTimeInterval(0.001)))
        }
    }
}
