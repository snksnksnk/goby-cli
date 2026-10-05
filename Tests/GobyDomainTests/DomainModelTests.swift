import Foundation
import Testing
@testable import GobyDomain

struct DomainModelTests {
    @Test("Run approval mode defaults off for older saved records")
    func legacyRunApprovalMode() throws {
        let plan = RoutingPlan(interpretedGoal: "Inspect", routes: [], risk: .readOnly, confidence: 1)
        let run = RunRecord(id: plan.id, plan: plan, status: .ready, assignments: [],
                            automaticallyApproveRuntimeRequests: true)
        let data = try JSONEncoder().encode(run)
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(document["automaticallyApproveRuntimeRequests"] as? Bool == true)
        document.removeValue(forKey: "automaticallyApproveRuntimeRequests")
        let oldData = try JSONSerialization.data(withJSONObject: document)
        #expect(try JSONDecoder().decode(RunRecord.self, from: oldData).automaticallyApproveRuntimeRequests == false)
    }

    @Test("Routing confidence is clamped", arguments: [-2.0, 0.0, 0.42, 1.0, 9.0])
    func confidenceIsClamped(input: Double) {
        let plan = RoutingPlan(
            interpretedGoal: "Test",
            routes: [],
            risk: .readOnly,
            confidence: input
        )
        #expect(plan.confidence >= 0)
        #expect(plan.confidence <= 1)
    }

    @Test("Only high-impact Git actions always require separate approval", arguments: GitOperationKind.allTestCases)
    func gitApprovalClassification(kind: GitOperationKind, expected: Bool) {
        #expect(kind.alwaysRequiresSeparateApproval == expected)
    }

    @Test("Instruction scope matches only intended projects")
    func instructionScope() {
        let web = LabProject(
            id: "web",
            name: "Web",
            rootURL: URL(fileURLWithPath: "/tmp/web"),
            platforms: [.web],
            isGitRepository: false
        )
        let iOS = LabProject(
            id: "ios",
            name: "iOS",
            rootURL: URL(fileURLWithPath: "/tmp/ios"),
            platforms: [.iOS],
            isGitRepository: false
        )
        #expect(InstructionScope.platform(.web).includes(web))
        #expect(!InstructionScope.platform(.web).includes(iOS))
        #expect(InstructionScope.projects([iOS.id]).includes(iOS))
    }

    @Test("Only high-confidence warning-free read-only plans can start automatically")
    func automaticStartPolicy() {
        let safe = RoutingPlan(interpretedGoal: "Inspect", routes: [], risk: .readOnly, confidence: 0.9)
        let uncertain = RoutingPlan(interpretedGoal: "Inspect", routes: [], risk: .readOnly, confidence: 0.7)
        let warned = RoutingPlan(interpretedGoal: "Inspect", routes: [], risk: .readOnly, confidence: 0.9, warnings: ["Review scope"])
        let changing = RoutingPlan(interpretedGoal: "Update", routes: [], risk: .medium, confidence: 0.9)

        #expect(safe.canStartAutomatically)
        #expect(!uncertain.canStartAutomatically)
        #expect(!warned.canStartAutomatically)
        #expect(!changing.canStartAutomatically)
    }

    @Test("Authorized filesystem identities reject replacement and symbolic-link substitution")
    func fileSystemIdentityRejectsSubstitution() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "goby-identity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let moved = root.appendingPathExtension("reviewed")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try #require(GADFileSystemIdentity.capture(root))
        #expect(identity.kind == .directory)
        #expect(identity.matchesCurrentObject(at: root))

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!identity.matchesCurrentObject(at: root))

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        #expect(GADFileSystemIdentity.capture(root) == nil)
        #expect(!identity.matchesCurrentObject(at: root))
    }

    @Test("Filesystem identities survive an APFS device-number remount")
    func fileSystemIdentitySurvivesVolumeRemount() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "goby-remount-identity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let current = try #require(GADFileSystemIdentity.capture(root))
        let volumeUUID = try #require(current.volumeUUIDString)
        let staleDevice = current.device == UInt64.max ? current.device - 1 : current.device + 1
        let stableIdentity = GADFileSystemIdentity(
            device: staleDevice,
            inode: current.inode,
            kind: current.kind,
            volumeUUIDString: volumeUUID
        )
        let legacyIdentity = GADFileSystemIdentity(
            device: staleDevice,
            inode: current.inode,
            kind: current.kind
        )
        let wrongVolumeIdentity = GADFileSystemIdentity(
            device: current.device,
            inode: current.inode,
            kind: current.kind,
            volumeUUIDString: UUID().uuidString
        )

        #expect(stableIdentity.matchesCurrentObject(at: root))
        #expect(legacyIdentity.matchesCurrentObject(at: root))
        #expect(legacyIdentity.migratedMountStableIdentity(at: root) == current)
        #expect(!wrongVolumeIdentity.matchesCurrentObject(at: root))
    }

    @Test("Legacy filesystem identity JSON remains decodable")
    func legacyFileSystemIdentityDecoding() throws {
        let data = Data(#"{"device":1,"inode":2,"kind":"directory"}"#.utf8)
        let identity = try JSONDecoder().decode(GADFileSystemIdentity.self, from: data)

        #expect(identity.device == 1)
        #expect(identity.inode == 2)
        #expect(identity.kind == .directory)
        #expect(identity.volumeUUIDString == nil)
    }

    @Test("Attachment digests bind the reviewed file bytes and never follow symbolic links")
    func attachmentDigestIsContentBoundAndNoFollow() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "goby-attachment-identity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "context.txt")
        let link = root.appending(path: "context-link.txt")
        try Data("reviewed bytes".utf8).write(to: file)
        let reviewedDigest = try #require(GADFileSystemIdentity.contentSHA256(at: file))

        try Data("changed bytes".utf8).write(to: file)
        #expect(GADFileSystemIdentity.contentSHA256(at: file) != reviewedDigest)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(GADFileSystemIdentity.contentSHA256(at: link) == nil)
    }

    @Test("Run activity coalesces cumulative updates without hiding state or assignment boundaries")
    func runJournalCompaction() {
        let firstWorking = RunJournalEntry(
            kind: .assignmentChanged,
            message: "Working: Initial output",
            assignmentID: "agent-a"
        )
        let latestWorking = RunJournalEntry(
            kind: .assignmentChanged,
            message: "Working: Initial output with the latest streamed text",
            assignmentID: "agent-a"
        )
        let otherAgent = RunJournalEntry(
            kind: .assignmentChanged,
            message: "Working: Independent output",
            assignmentID: "agent-b"
        )
        let approval = RunJournalEntry(
            kind: .approval,
            message: "Waiting for approval: command",
            assignmentID: "agent-a"
        )
        let resumed = RunJournalEntry(
            kind: .assignmentChanged,
            message: "Working: Continued after approval",
            assignmentID: "agent-a"
        )

        let compacted = RunJournalCompactor.compact([
            firstWorking,
            latestWorking,
            otherAgent,
            approval,
            resumed,
        ])

        #expect(compacted.map(\.id) == [firstWorking.id, otherAgent.id, approval.id, resumed.id])
        #expect(compacted.first?.message == latestWorking.message)
        #expect(compacted.first?.occurredAt == latestWorking.occurredAt)
        #expect(Array(compacted.dropFirst()) == [otherAgent, approval, resumed])

        let nextFragment = RunJournalEntry(
            kind: .assignmentChanged, message: "Working: Another fragment", assignmentID: "agent-a"
        )
        let next = RunJournalCompactor.compact(Array(compacted.prefix(1)) + [nextFragment])
        #expect(next.first?.id == firstWorking.id)
        #expect(next.first?.message == nextFragment.message)
    }

    @Test("Legacy agent profiles decode without executable review provenance")
    func agentProfileBackwardCompatibility() throws {
        let profile = AgentProfile(
            id: "legacy-agent",
            name: "Legacy Agent",
            summary: "An existing saved agent",
            capabilities: [.routing],
            scope: .global
        )
        let encoded = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "instructions")
        object.removeValue(forKey: "definitionReviewProvenance")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: legacyData)

        #expect(decoded.id == profile.id)
        #expect(decoded.instructions == nil)
        #expect(decoded.definitionReviewProvenance == nil)
    }

    @Test("Single-target route requests remain decodable")
    func routeRequestTargetBackwardCompatibility() throws {
        let target = AgentRouteTarget(agentID: "agent", projectID: "project")
        let request = RouteRequest(prompt: "Inspect", agentTargets: [target])
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedTargets = try #require(object["agentTargets"] as? [Any])
        object["agentTarget"] = encodedTargets[0]
        object.removeValue(forKey: "agentTargets")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RouteRequest.self, from: legacyData)

        #expect(decoded.agentTargets == [target])
        #expect(decoded.agentTarget == target)
    }

    @Test("Routing plans written before prompt attachments remain decodable")
    func routingPlanAttachmentBackwardCompatibility() throws {
        let plan = RoutingPlan(
            interpretedGoal: "Inspect",
            attachments: [PromptAttachment(
                kind: .snippet,
                displayName: "Swift snippet",
                source: .text("let value = 1")
            )],
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let encoded = try JSONEncoder().encode(plan)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RoutingPlan.self, from: legacyData)

        #expect(decoded.attachments.isEmpty)
    }

    @Test("Lab snapshots written before project groups remain decodable")
    func labSnapshotProjectGroupBackwardCompatibility() throws {
        let snapshot = LabSnapshot(projects: [], agents: [])
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "projectGroups")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(LabSnapshot.self, from: legacyData)

        #expect(decoded.projectGroups.isEmpty)
    }

    @Test("Legacy snapshots deterministically migrate saved agents to Codex bindings")
    func legacySnapshotProviderMigration() throws {
        let agent = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            summary: "Reviews changes",
            capabilities: [.review],
            scope: .project("project"),
            sourceURL: URL(fileURLWithPath: "/tmp/.codex/agents/reviewer.toml"),
            codexRegistrationKey: "reviewer"
        )
        let snapshot = LabSnapshot(projects: [], agents: [agent])
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "projectProviderConfigurations")
        object.removeValue(forKey: "providerBindings")
        object.removeValue(forKey: "providerCollaborationSets")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let first = try JSONDecoder().decode(LabSnapshot.self, from: legacyData)
        let second = try JSONDecoder().decode(LabSnapshot.self, from: legacyData)
        let binding = try #require(first.providerBindings.first)

        #expect(first.providerBindings == second.providerBindings)
        #expect(binding.providerID == .codex)
        #expect(binding.agentID == agent.id)
        #expect(binding.projectID == "project")
        #expect(binding.nativeID == "reviewer")
        #expect(first.projectProviderConfigurations.isEmpty)
        #expect(first.providerCollaborationSets.isEmpty)
    }

    @Test("Provider binding identities include provider and native identity")
    func providerBindingIdentity() {
        let codex = ProviderAgentBinding(
            providerID: .codex,
            agentID: "builder",
            projectID: "project",
            nativeID: "builder",
            capabilities: [.web]
        )
        let claude = ProviderAgentBinding(
            providerID: .claude,
            agentID: "builder",
            projectID: "project",
            nativeID: "builder",
            capabilities: [.web]
        )

        #expect(codex.id != claude.id)
        #expect(AgentProviderID.builtIn.map(\.displayName) == [
            "Codex", "Claude", "GitHub Copilot",
        ])
    }

    @Test("Collaboration sets represent eligibility without inventing directions")
    func providerCollaborationEligibility() {
        let codexMember = ProviderCollaborationMember(providerID: .codex, bindingID: "codex")
        let claudeMember = ProviderCollaborationMember(providerID: .claude, bindingID: "claude")
        let single = ProviderCollaborationSet(projectID: "project", members: [codexMember])
        let collaborative = ProviderCollaborationSet(
            projectID: "project",
            members: [codexMember, claudeMember]
        )

        #expect(!single.isCollaborative)
        #expect(collaborative.isCollaborative)
        #expect(collaborative.providerIDs == [.codex, .claude])
    }

    @Test("Legacy assignments and direct targets default to the Codex provider")
    func providerIdentityBackwardCompatibility() throws {
        let assignment = AgentAssignment(
            runID: "run",
            projectID: "project",
            agentID: "agent",
            status: .working,
            currentTask: "Implement",
            codexThreadID: "thread",
            codexTurnID: "turn"
        )
        let assignmentData = try JSONEncoder().encode(assignment)
        var assignmentObject = try #require(
            JSONSerialization.jsonObject(with: assignmentData) as? [String: Any]
        )
        assignmentObject.removeValue(forKey: "providerID")
        assignmentObject.removeValue(forKey: "providerTaskID")
        assignmentObject.removeValue(forKey: "providerTurnID")
        let legacyAssignment = try JSONDecoder().decode(
            AgentAssignment.self,
            from: JSONSerialization.data(withJSONObject: assignmentObject)
        )

        let target = AgentRouteTarget(agentID: "agent", projectID: "project")
        let targetData = try JSONEncoder().encode(target)
        var targetObject = try #require(
            JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        )
        targetObject.removeValue(forKey: "providerID")
        let legacyTarget = try JSONDecoder().decode(
            AgentRouteTarget.self,
            from: JSONSerialization.data(withJSONObject: targetObject)
        )

        let request = RouteRequest(prompt: "Inspect", providerID: .claude)
        let requestData = try JSONEncoder().encode(request)
        var requestObject = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        requestObject.removeValue(forKey: "providerID")
        requestObject.removeValue(forKey: "model")
        let legacyRequest = try JSONDecoder().decode(
            RouteRequest.self,
            from: JSONSerialization.data(withJSONObject: requestObject)
        )

        let route = ProjectRoute(
            projectID: "project",
            providerID: .claude,
            agentIDs: ["agent"],
            reason: "Legacy plan"
        )
        let routeData = try JSONEncoder().encode(route)
        var routeObject = try #require(
            JSONSerialization.jsonObject(with: routeData) as? [String: Any]
        )
        routeObject.removeValue(forKey: "providerID")
        routeObject.removeValue(forKey: "model")
        let legacyRoute = try JSONDecoder().decode(
            ProjectRoute.self,
            from: JSONSerialization.data(withJSONObject: routeObject)
        )

        #expect(legacyAssignment.providerID == .codex)
        #expect(legacyAssignment.model == nil)
        #expect(legacyAssignment.providerTaskID == "thread")
        #expect(legacyAssignment.providerTurnID == "turn")
        #expect(legacyTarget.providerID == .codex)
        #expect(legacyRequest.providerID == .codex)
        #expect(legacyRequest.model == nil)
        #expect(legacyRoute.providerID == .codex)
        #expect(legacyRoute.model == nil)
    }

    @Test("Map layout overrides move projects with their children and agents independently")
    func mapLayoutOverrides() {
        let projectID = ProjectID(rawValue: "project")
        let agentID = GraphNodeID.agent(AgentID(rawValue: "agent"), project: projectID)
        let taskID = GraphNodeID.codexTask("task", project: projectID)

        let movedProject = MapLayoutOverrides.empty.moving(
            .project(projectID),
            by: GraphPoint(x: 40, y: -12)
        )
        #expect(movedProject.offset(for: .project(projectID)) == GraphPoint(x: 40, y: -12))
        #expect(movedProject.offset(for: agentID) == GraphPoint(x: 40, y: -12))
        #expect(movedProject.offset(for: taskID) == GraphPoint(x: 40, y: -12))

        let movedAgent = movedProject.moving(agentID, by: GraphPoint(x: 8, y: 20))
        #expect(movedAgent.offset(for: .project(projectID)) == GraphPoint(x: 40, y: -12))
        #expect(movedAgent.offset(for: agentID) == GraphPoint(x: 48, y: 8))
        #expect(movedAgent.offset(for: taskID) == GraphPoint(x: 40, y: -12))

        let resetAgent = movedAgent.resetting(agentID)
        #expect(resetAgent.offset(for: agentID) == GraphPoint(x: 40, y: -12))
        #expect(!resetAgent.hasIndividualOverride(for: agentID))
        #expect(resetAgent.hasIndividualOverride(for: .project(projectID)))
    }

    @Test("Map layout ignores unsupported and invalid moves and removes zero offsets")
    func mapLayoutRejectsInvalidMoves() {
        let projectID = ProjectID(rawValue: "project")
        let projectNode = GraphNodeID.project(projectID)
        let taskNode = GraphNodeID.codexTask("task", project: projectID)
        let moved = MapLayoutOverrides.empty.moving(projectNode, by: GraphPoint(x: 12, y: 4))

        #expect(moved.moving(taskNode, by: GraphPoint(x: 5, y: 5)) == moved)
        #expect(moved.moving(projectNode, by: GraphPoint(x: .infinity, y: 0)) == moved)
        #expect(moved.moving(projectNode, by: GraphPoint(x: -12, y: -4)).isEmpty)
    }

    @Test("Map refresh preserves manually positioned project and agent coordinates")
    func mapLayoutRebasesAcrossRefresh() {
        let project = LabProject(
            id: "project",
            name: "Project",
            rootURL: URL(fileURLWithPath: "/tmp/project"),
            platforms: [.general],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Agent",
            capabilities: [.routing],
            scope: .project(project.id)
        )
        let projectNodeID = GraphNodeID.project(project.id)
        let agentNodeID = GraphNodeID.agent(agent.id, project: project.id)
        let previous = GraphLayoutSnapshot(
            nodes: [
                GraphNode(
                    id: projectNodeID,
                    kind: .project(project, statusSummary: AgentStatusSummary(statuses: [.available])),
                    position: GraphPoint(x: 100, y: 50)
                ),
                GraphNode(
                    id: agentNodeID,
                    kind: .agent(agent, assignment: nil),
                    position: GraphPoint(x: 130, y: 50)
                ),
            ],
            edges: []
        )
        let refreshed = GraphLayoutSnapshot(
            nodes: [
                GraphNode(
                    id: projectNodeID,
                    kind: .project(project, statusSummary: AgentStatusSummary(statuses: [.available])),
                    position: GraphPoint(x: -20, y: 80)
                ),
                GraphNode(
                    id: agentNodeID,
                    kind: .agent(agent, assignment: nil),
                    position: GraphPoint(x: 10, y: 90)
                ),
            ],
            edges: []
        )
        let layout = MapLayoutOverrides.empty
            .moving(projectNodeID, by: GraphPoint(x: 40, y: -10))
            .moving(agentNodeID, by: GraphPoint(x: 5, y: 6))

        let rebased = layout.rebased(preservingPositionsFrom: previous, to: refreshed)

        #expect(
            refreshed.nodes[0].position.adding(rebased.offset(for: projectNodeID))
                == GraphPoint(x: 140, y: 40)
        )
        #expect(
            refreshed.nodes[1].position.adding(rebased.offset(for: agentNodeID))
                == GraphPoint(x: 175, y: 46)
        )
    }

    @Test("Preferred map coordinates remain fixed when automatic layout changes")
    func preferredMapCoordinatesSurviveRefresh() {
        let projectID = ProjectID(rawValue: "project")
        let project = LabProject(
            id: projectID,
            name: "Project",
            rootURL: URL(fileURLWithPath: "/tmp/project"),
            platforms: [.general],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Agent",
            summary: "Agent",
            capabilities: [.routing],
            scope: .project(projectID)
        )
        let projectNodeID = GraphNodeID.project(projectID)
        let agentNodeID = GraphNodeID.agent(agent.id, project: projectID)
        let preferredProjectPosition = GraphPoint(x: 420, y: -135)
        let preferredAgentPosition = GraphPoint(x: 515, y: -92)
        let layout = MapLayoutOverrides.empty
            .preferring(projectNodeID, at: preferredProjectPosition)
            .preferring(
                agentNodeID,
                at: preferredAgentPosition,
                relativeTo: preferredProjectPosition
            )

        let refreshedAutomaticProjectPosition = GraphPoint(x: -220, y: 310)
        let refreshedAutomaticAgentPosition = GraphPoint(x: -60, y: 390)
        let previous = GraphLayoutSnapshot(
            nodes: [
                GraphNode(
                    id: projectNodeID,
                    kind: .project(project, statusSummary: AgentStatusSummary(statuses: [.available])),
                    position: GraphPoint(x: 100, y: 50)
                ),
                GraphNode(
                    id: agentNodeID,
                    kind: .agent(agent, assignment: nil),
                    position: GraphPoint(x: 130, y: 50)
                ),
            ],
            edges: []
        )
        let refreshed = GraphLayoutSnapshot(
            nodes: [
                GraphNode(
                    id: projectNodeID,
                    kind: .project(project, statusSummary: AgentStatusSummary(statuses: [.working])),
                    position: refreshedAutomaticProjectPosition
                ),
                GraphNode(
                    id: agentNodeID,
                    kind: .agent(agent, assignment: nil),
                    position: refreshedAutomaticAgentPosition
                ),
            ],
            edges: []
        )
        let rebased = layout.rebased(preservingPositionsFrom: previous, to: refreshed)

        #expect(rebased.resolvedPosition(
            for: projectNodeID,
            automaticPosition: refreshedAutomaticProjectPosition
        ) == preferredProjectPosition)
        #expect(rebased.resolvedPosition(
            for: agentNodeID,
            automaticPosition: refreshedAutomaticAgentPosition,
            automaticProjectPosition: refreshedAutomaticProjectPosition
        ) == preferredAgentPosition)
    }

    @Test("Saved offset-only map layouts remain decodable")
    func legacyMapLayoutDecoding() throws {
        let projectID = ProjectID(rawValue: "project")
        let layout = MapLayoutOverrides(
            projectOffsets: [projectID: GraphPoint(x: 12, y: -8)]
        )
        let encoded = try JSONEncoder().encode(layout)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "preferredProjectPositions")
        object.removeValue(forKey: "preferredAgentPositionsRelativeToProject")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MapLayoutOverrides.self, from: legacyData)

        #expect(decoded.projectOffsets == layout.projectOffsets)
        #expect(decoded.preferredProjectPositions.isEmpty)
        #expect(decoded.preferredAgentPositionsRelativeToProject.isEmpty)
    }

    @Test("Deleted agent receipts written before Codex registration remain decodable")
    func deletedAgentReceiptBackwardCompatibility() throws {
        let record = DeletedAgentRecord(
            agent: AgentProfile(
                id: "legacy-deleted-agent",
                name: "Legacy Deleted Agent",
                summary: "An archived role",
                capabilities: [.routing],
                scope: .global
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/legacy-agent.toml"),
            archiveURL: URL(fileURLWithPath: "/tmp/archive/legacy-agent.toml"),
            expectedContents: "name = \"Legacy Deleted Agent\"\n"
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "registrationURL")
        object.removeValue(forKey: "registrationKey")
        object.removeValue(forKey: "registrationBlock")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DeletedAgentRecord.self, from: legacyData)

        #expect(decoded.agent == record.agent)
        #expect(decoded.registrationURL == nil)
        #expect(decoded.registrationKey == nil)
        #expect(decoded.registrationBlock == nil)
    }

    @Test("Run records retain invoked helper outcomes and decode older records")
    func runHelperActivityPersistence() throws {
        let plan = RoutingPlan(
            id: "helper-run",
            interpretedGoal: "Inspect",
            routes: [],
            risk: .readOnly,
            confidence: 1
        )
        let helper = ProviderTaskActivity(
            identity: ProviderTaskIdentity(providerID: .codex, nativeID: "helper-thread"),
            projectID: "helper-project",
            title: "Security Baseline",
            summary: "No blocking findings.",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 42),
            parentTaskIdentity: ProviderTaskIdentity(providerID: .codex, nativeID: "parent-thread"),
            agentRole: "security_baseline"
        )
        let run = RunRecord(
            id: plan.id,
            plan: plan,
            status: .completed,
            assignments: [],
            helperTasks: [helper]
        )
        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: encoded)
        #expect(decoded.helperTasks == [helper])

        let encodedObject = try JSONSerialization.jsonObject(with: encoded)
        guard var legacyObject = encodedObject as? [String: Any] else {
            Issue.record("Encoded RunRecord was not a JSON object")
            return
        }
        legacyObject.removeValue(forKey: "helperTasks")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(RunRecord.self, from: legacyData)
        #expect(legacy.helperTasks.isEmpty)
    }
}

private extension GitOperationKind {
    static let allTestCases: [(GitOperationKind, Bool)] = [
        (.createWorktree, false), (.createBranch, false), (.commit, false),
        (.push, true), (.merge, true), (.rebase, true), (.reset, true),
        (.tag, true), (.deleteBranch, true), (.remoteChange, true)
    ]
}
