import Foundation
import Testing
import GobyDomain

@Suite("AssignmentProgressTests")
struct AssignmentProgressTests {
    @Test("New and recovered assignments bound finite progress", arguments: [-3.0, 0, 0.4, 1, 7])
    func boundsProgress(_ value: Double) throws {
        let expected = min(max(value, 0), 1)
        #expect(assignment(progress: value).progress == expected)
        let encoded = try JSONEncoder().encode(assignment(progress: nil))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["progress"] = value
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AgentAssignment.self, from: data).progress == expected)
    }

    @Test("Non-finite progress becomes unknown and remains persistable", arguments: [Double.nan, .infinity, -.infinity])
    func rejectsNonFinite(_ value: Double) throws {
        let fresh = assignment(progress: value)
        #expect(fresh.progress == nil)
        let data = try JSONEncoder().encode(fresh)
        #expect(try JSONDecoder().decode(AgentAssignment.self, from: data).progress == nil)
    }

    @Test("Legacy assignments without progress preserve unknown progress")
    func missingProgress() throws {
        let data = try JSONEncoder().encode(assignment(progress: nil))
        #expect(try JSONDecoder().decode(AgentAssignment.self, from: data).progress == nil)
    }

    private func assignment(progress: Double?) -> AgentAssignment {
        AgentAssignment(runID: "run", projectID: "project", agentID: "agent",
                        status: .working, currentTask: "Verify", progress: progress)
    }
}
