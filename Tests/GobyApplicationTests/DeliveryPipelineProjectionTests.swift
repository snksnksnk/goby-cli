import Foundation
import Testing
import GobyApplication
import GobyDomain

struct DeliveryPipelineProjectionTests {
    private func projection(_ pipeline: DeliveryPipeline?) -> GADPlanProjection {
        GADPlanProjection(
            id: "plan", goal: "Ship", routes: [], risk: .medium, confidence: 1,
            gitOperations: [], warnings: [], selectedResourceIDs: [],
            createdAt: Date(timeIntervalSince1970: 0), deliveryPipeline: pipeline
        )
    }

    private let pipeline = DeliveryPipeline(stages: [DeliveryStageKind.implement, .qualityAssurance].map {
        DeliveryStage(
            kind: $0,
            target: AgentHandoffEndpoint(providerID: .codex, bindingID: "b", agentID: "a", projectID: "p"),
            reason: "r",
            passCriteria: "c"
        )
    })

    @Test("Single-step plans omit the field so older clients see unchanged JSON")
    func omittedWhenAbsent() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection(nil))) as? [String: Any]
        #expect(object?["deliveryPipeline"] == nil)
    }

    @Test("Staged plans round-trip and never auto-start")
    func roundTrip() throws {
        let original = projection(pipeline)
        let decoded = try JSONDecoder().decode(GADPlanProjection.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.deliveryPipeline?.stages.count == 2)
        #expect(!decoded.canStartAutomatically)
    }

    @Test("Assignment projections carry the stage identity")
    func assignmentStage() throws {
        let assignment = GADAssignmentProjection(
            id: "x", projectID: "p", agentID: "a", status: .queued, currentTask: "t",
            progress: nil, statusReason: nil, deliveryStageID: "stage-1"
        )
        let decoded = try JSONDecoder().decode(GADAssignmentProjection.self, from: JSONEncoder().encode(assignment))
        #expect(decoded.deliveryStageID == "stage-1")
    }
}
