import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyRemoteContract

@Suite("GAD remote wire contract")
struct WireEnvelopeTests {
    private struct OptionalMetadataFixture: Codable, Equatable, Sendable {
        let providerAccounts: [GADProviderAccountProjection]
        let projectSnapshot: [GADRunProjectSnapshot]
        let hosts: [GADHostProjection]
    }

    @Test("Protocol 3.9 optional account and retained-project metadata uses canonical wire dates")
    func optionalProjectionMetadataFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(
            path: "Remote/Fixtures/protocol-3.9-optional-projection-metadata.json"
        ))
        let codec = GADWireCodec()
        let fixture = try codec.decode(OptionalMetadataFixture.self, from: data)
        #expect(fixture.providerAccounts[0].activityFreshness == .unavailable(
            since: Date(timeIntervalSince1970: 1_789_589_940),
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_789_589_880)
        ))
        #expect(fixture.providerAccounts[1].credentialConfigured == true)
        #expect(fixture.providerAccounts[2].credentialConfigured == nil)
        #expect(fixture.providerAccounts[2].activityFreshness == nil)
        #expect(fixture.projectSnapshot == [.init(id: "retained-demo-project", name: "Archived Demo")])
        #expect(fixture.hosts[0].omittedHistoryRunCount == 225)
        #expect(fixture.hosts[0].omittedAutomationOccurrenceCount == 10)
        #expect(fixture.hosts[1].omittedHistoryRunCount == nil)
        #expect(fixture.hosts[1].omittedAutomationOccurrenceCount == nil)
        #expect(try codec.decode(OptionalMetadataFixture.self, from: codec.encode(fixture)) == fixture)
    }

    private struct RunActivityFixture: Codable, Equatable, Sendable {
        let current: GADRunProjection
        let legacy: GADRunProjection
    }

    @Test("Protocol 3.11 run activity decodes, tolerates unknown step kinds, and is optional")
    func runActivityFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Remote/Fixtures/protocol-3.11-run-activity.json"))
        let codec = GADWireCodec()
        let fixture = try codec.decode(RunActivityFixture.self, from: data)
        #expect(fixture.current.activity.map(\.step.kind) == [.message, .read, .tool])
        #expect(fixture.current.activity[2].step.status == .running)
        #expect(fixture.current.activity[1].exitCode == 0)
        #expect(fixture.legacy.activity.isEmpty)
        #expect(try codec.decode(RunActivityFixture.self, from: codec.encode(fixture)) == fixture)
    }

    private struct TemporaryChatFixture: Codable, Equatable, Sendable {
        let current: GADHostProjection
        let legacy: GADHostProjection
    }

    @Test("Protocol 3.12 temporary chat travels with the host section and is optional")
    func temporaryChatFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Remote/Fixtures/protocol-3.12-temporary-chat.json"))
        let codec = GADWireCodec()
        let fixture = try codec.decode(TemporaryChatFixture.self, from: data)
        #expect(fixture.current.temporaryChat?.messages.map(\.role) == [.user, .assistant])
        #expect(fixture.current.temporaryChat?.status == .answering)
        #expect(fixture.current.temporaryChat?.canAsk == false)
        #expect(fixture.legacy.temporaryChat == nil)
        #expect(try codec.decode(TemporaryChatFixture.self, from: codec.encode(fixture)) == fixture)
    }

    @Test("Temporary chat commands round-trip, and older sessions report no chat support")
    func temporaryChatCommandsAndSession() throws {
        let codec = GADWireCodec()
        for payload in [
            GADCommandPayload.askTemporaryChat(.init(chatID: nil, text: "Hi", model: "gpt-demo")),
            .askTemporaryChat(.init(chatID: "chat-1", text: "More")),
            .endTemporaryChat("chat-1"),
        ] {
            #expect(try codec.decode(GADCommandPayload.self, from: codec.encode(payload)) == payload)
        }
        let session = ClientSession(
            hostID: HostID(rawValue: "host"), hostEpoch: HostEpoch(rawValue: "epoch"), protocolVersion: .current,
            revision: .zero, capabilities: []
        )
        var object = try #require(JSONSerialization.jsonObject(with: codec.encode(session)) as? [String: Any])
        #expect(object["supportsTemporaryChat"] as? Bool == true)
        #expect(object["supportsParallelRequests"] as? Bool == true)
        object.removeValue(forKey: "supportsTemporaryChat")
        object.removeValue(forKey: "supportsParallelRequests")
        let legacy = try codec.decode(ClientSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.supportsTemporaryChat == false)
        #expect(legacy.supportsParallelRequests == false, "Run Anyway is never offered to older hosts")
        // Protocol 3.13 run control round-trips.
        let startNow = GADCommandPayload.controlRun(.init(runID: "run", action: .startNow))
        #expect(try codec.decode(GADCommandPayload.self, from: codec.encode(startNow)) == startNow)
    }

    @Test("A projected temporary chat is redacted and kept within its size budget")
    func temporaryChatProjection() throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_784_000)
        var chat = TemporaryChat(startedAt: timestamp, updatedAt: timestamp)
        chat.append(.init(role: .user, text: "My key is sk-ant-api03-abcdefghijklmnopqrstuv, is it valid?", createdAt: timestamp))
        for index in 0..<30 {
            chat.append(.init(role: index.isMultiple(of: 2) ? .assistant : .user,
                              text: String(repeating: "answer \(index) ", count: 900), createdAt: timestamp))
        }
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: timestamp),
            revision: .zero, lab: .empty, runs: [], approvals: [], resources: [],
            codexTasks: [], account: nil, health: .init(checks: []),
            temporaryChat: chat, generatedAt: timestamp
        )
        let projected = try #require(projection.host.temporaryChat)
        let total = projected.messages.map { $0.text.count }.reduce(0, +)
        #expect(total <= GADTemporaryChatProjection.totalTextLimit)
        #expect(projected.messages.allSatisfy { $0.text.count <= GADTemporaryChatProjection.messageTextLimit })
        #expect(projected.omittedMessageCount > 0)
        #expect(projected.messages.count + projected.omittedMessageCount == chat.messages.count)

        var short = TemporaryChat(startedAt: timestamp, updatedAt: timestamp)
        short.append(.init(role: .user, text: "My key is sk-ant-api03-abcdefghijklmnopqrstuv", createdAt: timestamp))
        let redacted = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: timestamp),
            revision: .zero, lab: .empty, runs: [], approvals: [], resources: [],
            codexTasks: [], account: nil, health: .init(checks: []),
            temporaryChat: short, generatedAt: timestamp
        )
        #expect(redacted.host.temporaryChat?.messages.first?.text.contains("sk-ant-api03") == false)
    }

    @Test("Mobile run activity is redacted, output-free, bounded and limited to recent runs")
    func runActivityProjection() throws {
        let timestamp = Date(timeIntervalSince1970: 1_789_590_000)
        func run(_ index: Int, status: RunStatus) -> RunRecord {
            let plan = RoutingPlan(
                id: RunID(rawValue: "run-\(index)"), interpretedGoal: "Task \(index)",
                routes: [.init(projectID: "demo", agentIDs: ["agent"], reason: "Test")], risk: .readOnly, confidence: 1
            )
            let steps = (0..<200).map { step in
                RunActivityStep(
                    id: "s\(step)", assignmentID: AssignmentID(rawValue: "a\(index)"), kind: .command,
                    title: "cat /Users/someone/private/notes.md token=sk-ant-api03-abcdefghijklmnop",
                    detail: "SECRET OUTPUT", status: .succeeded
                )
            }
            return RunRecord(
                id: plan.id, plan: plan, status: status,
                assignments: [.init(runID: plan.id, projectID: "demo", agentID: "agent", status: .completed, currentTask: "t")],
                activity: steps,
                createdAt: timestamp.addingTimeInterval(Double(index)),
                updatedAt: timestamp.addingTimeInterval(Double(index))
            )
        }
        let runs = (0..<8).map { run($0, status: $0 == 0 ? .running : .completed) }
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: timestamp),
            revision: .zero, lab: .empty, runs: runs, approvals: [], resources: [],
            codexTasks: [], account: nil, health: .init(checks: []), generatedAt: timestamp
        )
        let withActivity = Set(projection.runs.filter { !$0.activity.isEmpty }.map(\.id.rawValue))
        #expect(withActivity == ["run-0", "run-7", "run-6", "run-5"])
        let steps = projection.runs.flatMap(\.activity)
        #expect(projection.runs.allSatisfy { $0.activity.count <= GADRunActivityProjection.limit })
        #expect(steps.allSatisfy { !$0.title.contains("/Users/someone") && !$0.title.contains("sk-ant-api03") })
        let encoded = String(decoding: try GADWireCodec().encode(projection), as: UTF8.self)
        #expect(!encoded.contains("SECRET OUTPUT"))
    }

    @Test("Routine projections remain transportable as completed history grows")
    func largeHistoryFitsProjectionTransport() throws {
        let timestamp = Date(timeIntervalSince1970: 1_789_590_000)
        let runs = (0..<250).map { index in
            let plan = RoutingPlan(
                id: RunID(rawValue: "history-\(index)"), interpretedGoal: "Completed review \(index)",
                routes: [.init(projectID: "demo", agentIDs: ["reviewer"], reason: "Reviewed scope")],
                risk: .readOnly, confidence: 1
            )
            return RunRecord(
                id: plan.id, plan: plan, status: .completed,
                assignments: [.init(runID: plan.id, projectID: "demo", agentID: "reviewer", status: .completed, currentTask: "Verified")],
                outcome: String(repeating: "Verified result \(index). ", count: 500),
                journal: (0..<12).map { step in
                    .init(kind: .statusChanged,
                          message: "Review \(index), step \(step): " + String(repeating: "Verification evidence. ", count: 35),
                          occurredAt: timestamp.addingTimeInterval(Double(index * 100 + step)))
                },
                createdAt: timestamp.addingTimeInterval(Double(index * 100)),
                updatedAt: timestamp.addingTimeInterval(Double(index * 100 + 20))
            )
        }
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "history-host"), displayName: "Fixture Mac", reachability: .online, lastUpdatedAt: timestamp),
            revision: .zero, lab: .empty, runs: runs, approvals: [], resources: [],
            codexTasks: [], account: nil, health: .init(checks: []), generatedAt: timestamp
        )
        let encoded = try GADWireCodec().encode(projection)
        #expect(encoded.count < GADWireCodec.defaultMaximumBytes)
        #expect(encoded.count <= ProjectionHistoryBudget.maximumProjectionBytes)
        #expect(projection.host.omittedHistoryRunCount == runs.count - projection.runs.count)
        #expect(projection.runs.count > 0 && projection.runs.count < runs.count)
        #expect(projection.runs.first?.id == runs.last?.id)
    }

    @Test("Canonical encoding is deterministic and round-trips")
    func deterministicRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_234.567)
        let replyID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let envelope = GADUnsignedEnvelope(
            protocolVersion: .current,
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            replyToMessageID: replyID,
            hostID: .init(rawValue: "host"),
            deviceID: .init(rawValue: "phone"),
            sequence: 7,
            sentAt: date,
            message: .clientHello(
                deviceID: .init(rawValue: "phone"),
                supportedVersions: [.current],
                lastHostEpoch: .init(rawValue: "epoch"),
                lastRevision: .init(rawValue: 42)
            )
        )
        let codec = GADWireCodec()
        let first = try codec.encode(envelope)
        let second = try codec.encode(envelope)

        #expect(first == second)
        #expect(try codec.decode(GADUnsignedEnvelope.self, from: first) == envelope)
        #expect(try codec.decode(GADUnsignedEnvelope.self, from: first).replyToMessageID == replyID)
    }

    @Test("Pre-3.8 envelopes remain decodable without response correlation")
    func legacyEnvelopeWithoutReplyIDDecodes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "Remote/Fixtures/protocol-3.7-uncorrelated-envelope.json"
        ))
        let envelope = try GADWireCodec().decode(GADUnsignedEnvelope.self, from: data)

        #expect(envelope.protocolVersion == .init(major: 3, minor: 7))
        #expect(envelope.replyToMessageID == nil)
        #expect(envelope.message == .snapshotRequest)
    }

    @Test("Protocol 3.8 fixture carries authenticated response correlation")
    func correlatedEnvelopeFixture() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "Remote/Fixtures/protocol-3.8-correlated-envelope.json"
        ))
        let envelope = try GADWireCodec().decode(GADUnsignedEnvelope.self, from: data)

        #expect(envelope.protocolVersion == .init(major: 3, minor: 8))
        #expect(
            envelope.replyToMessageID
                == UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        #expect(
            envelope.message
                == .pong(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        )
    }

    @Test("Oversized messages fail before decoding")
    func rejectsOversizedMessage() {
        let codec = GADWireCodec(maximumBytes: 1_024)
        #expect(throws: GADWireCodecError.oversized(1_025)) {
            try codec.decode(GADUnsignedEnvelope.self, from: Data(repeating: 0, count: 1_025))
        }
    }

    @Test("Protocol 3.3 authorization envelope fixture remains decodable and bounded")
    func authorizationEnvelopeFixture() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appending(path: "Remote/Fixtures/protocol-3.3-authorized-command-envelope.json")
        let data = try Data(contentsOf: fixtureURL)
        let envelope = try GADWireCodec(maximumBytes: 1_024).decode(
            GADSignedCommandEnvelope.self,
            from: data
        )

        #expect(data.count < 1_024)
        #expect(envelope.commandBytes == Data([1, 2, 3, 4]))
        #expect(envelope.deviceSignature == Data([5, 6, 7, 8]))
        #expect(envelope.localAuthorizationSignature == Data([9, 10, 11, 12]))
    }

    @Test("Protocol 3.3 retains purpose-bound provider instruction editing")
    func providerInstructionEditorRoundTrip() throws {
        let editor = GADProviderBindingInstructionEditor(
            bindingID: .init(rawValue: "binding"),
            instructions: "Use the provider's reviewed tool policy.",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        let acknowledgement = GADCommandAcknowledgement(
            commandID: .init(rawValue: "command"),
            disposition: .accepted,
            revision: .init(rawValue: 7),
            artifact: .providerBindingInstructionEditor(editor)
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(acknowledgement)

        #expect(GADProtocolVersion.current >= .init(major: 3, minor: 3))
        #expect(try codec.decode(GADCommandAcknowledgement.self, from: encoded) == acknowledgement)
    }

    @Test("Android FCM registration has a stable optional-associated-value wire shape")
    func androidFCMRegistrationWireShape() throws {
        let codec = GADWireCodec()
        let registration = GADNotificationRegistration(
            token: Data("fcm-token:abc_123-def".utf8),
            environment: .production,
            categories: [.needsAttention, .runFinished],
            transport: .fcm
        )
        let enabled = try codec.encode(
            GADCommandPayload.updateNotificationRegistration(registration)
        )
        let disabled = try codec.encode(
            GADCommandPayload.updateNotificationRegistration(nil)
        )

        #expect(
            String(decoding: enabled, as: UTF8.self)
                == #"{"updateNotificationRegistration":{"_0":{"categories":["needsAttention","runFinished"],"environment":"production","token":"ZmNtLXRva2VuOmFiY18xMjMtZGVm","transport":"fcm"}}}"#
        )
        #expect(
            String(decoding: disabled, as: UTF8.self)
                == #"{"updateNotificationRegistration":{}}"#
        )
        #expect(
            try codec.decode(GADCommandPayload.self, from: enabled)
                == .updateNotificationRegistration(registration)
        )
    }

    @Test("Android attachment chunks retain the bounded Swift wire shape")
    func androidAttachmentUploadWireShape() throws {
        let codec = GADWireCodec()
        let uploadID = UUID(uuidString: "c6a62d52-cba1-4cd9-9e61-0bd62fdcd92c")!
        let attachmentID = UUID(uuidString: "e9517ec8-c137-402d-8188-216ce39f03eb")!
        let start = GADCommandPayload.beginPromptAttachmentUpload(.init(
            uploadID: uploadID,
            attachmentID: attachmentID,
            kind: .image,
            displayName: "diagram.png",
            byteCount: 3,
            typeHint: "PNG",
            contentSHA256: String(repeating: "a", count: 64),
            expectedDraftRevision: .init(rawValue: 14)
        ))
        let chunk = GADCommandPayload.appendPromptAttachmentUpload(.init(
            uploadID: uploadID,
            offset: 0,
            data: Data([0, 1, 2])
        ))
        let startData = try codec.encode(start)
        let chunkData = try codec.encode(chunk)

        #expect(
            String(decoding: startData, as: UTF8.self)
                == #"{"beginPromptAttachmentUpload":{"_0":{"attachmentID":"E9517EC8-C137-402D-8188-216CE39F03EB","byteCount":3,"contentSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","displayName":"diagram.png","expectedDraftRevision":14,"kind":"image","typeHint":"PNG","uploadID":"C6A62D52-CBA1-4CD9-9E61-0BD62FDCD92C"}}}"#
        )
        #expect(
            String(decoding: chunkData, as: UTF8.self)
                == #"{"appendPromptAttachmentUpload":{"_0":{"data":"AAEC","offset":0,"uploadID":"C6A62D52-CBA1-4CD9-9E61-0BD62FDCD92C"}}}"#
        )
        #expect(try codec.decode(GADCommandPayload.self, from: startData) == start)
        #expect(try codec.decode(GADCommandPayload.self, from: chunkData) == chunk)
    }

    @Test("Protocol 3.4 round-trips path-free branch discovery and exact reviewed switching")
    func projectBranchRoundTrip() throws {
        let projectID = ProjectID(rawValue: "project")
        let discovery = GADProjectBranchDiscovery(
            projectID: projectID,
            currentBranch: "main",
            localBranches: ["feature/mobile-parity", "main"],
            hasUncommittedChanges: false,
            expiresAt: Date(timeIntervalSince1970: 2_050)
        )
        let approval = ProjectGitBranchSwitchApproval(
            projectID: projectID,
            expectedCurrentBranch: "main",
            destinationBranch: "feature/mobile-parity"
        )
        let codec = GADWireCodec()

        let artifactData = try codec.encode(GADCommandArtifact.projectGitBranches(discovery))
        let payloadData = try codec.encode(GADCommandPayload.requestProjectGitBranches(projectID))
        let requestData = try codec.encode(GADHostAdminRequest.switchProjectBranch(approval))
        let combinedText = [artifactData, payloadData, requestData]
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()

        #expect(
            try codec.decode(GADCommandArtifact.self, from: artifactData)
                == .projectGitBranches(discovery)
        )
        #expect(
            try codec.decode(GADCommandPayload.self, from: payloadData)
                == .requestProjectGitBranches(projectID)
        )
        #expect(
            try codec.decode(GADHostAdminRequest.self, from: requestData)
                == .switchProjectBranch(approval)
        )
        #expect(!combinedText.contains("/Users/"))
        #expect(!combinedText.contains("git switch"))
        #expect(!combinedText.contains("remote"))
    }

    @Test("Protocol 3.4 projects attachment metadata without content and decodes older plan/run data")
    func attachmentMetadataCompatibility() throws {
        let date = Date(timeIntervalSince1970: 2_060)
        let attachment = GADDraftAttachmentProjection(
            id: UUID(uuidString: "A04B1187-BB37-43E5-BFFA-1520B29B5017")!,
            kind: .file,
            displayName: "Release.md",
            byteCount: 512,
            typeHint: "Markdown"
        )
        let plan = GADPlanProjection(
            id: "plan",
            goal: "Review release context",
            attachments: [attachment],
            routes: [],
            risk: .low,
            confidence: 1,
            gitOperations: [],
            warnings: [],
            selectedResourceIDs: [],
            createdAt: date
        )
        let run = GADRunProjection(
            id: "run",
            goal: "Review release context",
            attachments: [attachment],
            risk: .low,
            status: .completed,
            assignments: [],
            outcome: "Ready",
            journal: [],
            createdAt: date,
            updatedAt: date
        )
        let codec = GADWireCodec()
        let planData = try codec.encode(plan)
        let runData = try codec.encode(run)
        let combinedText = String(decoding: planData + runData, as: UTF8.self)

        #expect(try codec.decode(GADPlanProjection.self, from: planData) == plan)
        #expect(try codec.decode(GADRunProjection.self, from: runData) == run)
        #expect(!combinedText.contains("/private/host/Release.md"))
        #expect(!combinedText.contains("release body"))

        let legacyPlan = try removingAttachmentField(from: planData)
        let legacyRun = try removingAttachmentField(from: runData)
        #expect(try codec.decode(GADPlanProjection.self, from: legacyPlan).attachments.isEmpty)
        #expect(try codec.decode(GADRunProjection.self, from: legacyRun).attachments.isEmpty)
    }

    @Test("Protocol 3.2 round-trips a complete reviewed New Project intent")
    func newProjectIntentRoundTrip() throws {
        let intent = GADCreateProjectIntent(
            name: "Mobile Service",
            directoryName: "mobile-service",
            parentLocationID: .init(rawValue: "authorized-resource"),
            source: .gitClone(repository: "https://example.invalid/mobile-service.git"),
            platforms: [.backend, .iOS],
            providerIDs: [.codex, .claude],
            agents: [.init(
                name: "API Agent",
                summary: "Builds the service API",
                instructions: "Keep compatibility.",
                capabilities: [.backend, .testing],
                providerIDs: [.codex, .claude],
                providerInstructions: [.claude: "Challenge API assumptions."]
            )],
            link: .init(
                projectID: "existing",
                groupName: "Mobile Platform",
                projectRole: .backend,
                linkedProjectRole: .mobile
            ),
            collaborateAcrossProviders: true,
            handoffLinks: [.init(
                sourceAgentIndex: 0,
                sourceProviderID: .codex,
                destinationAgentIndex: 0,
                destinationProviderID: .claude,
                purpose: "Request an independent review.",
                conditions: "After a reviewed checkpoint."
            )]
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(intent)

        #expect(try codec.decode(GADCreateProjectIntent.self, from: encoded) == intent)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("/Users/"))
    }

    @Test("New Project templates round-trip by stable version without host paths or file bytes")
    func newProjectTemplateIntentRoundTrip() throws {
        let intent = GADCreateProjectIntent(
            name: "Pocket Ledger",
            directoryName: "PocketLedger",
            parentLocationID: .init(rawValue: "authorized-resource"),
            source: .blank,
            platforms: [.iOS],
            template: ProjectTemplateSelection(
                id: "ios-swiftui-clean",
                version: 1,
                parameters: [
                    .moduleName: "PocketLedger",
                    .bundleIdentifier: "com.example.PocketLedger"
                ]
            )
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(intent)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(try codec.decode(GADCreateProjectIntent.self, from: encoded) == intent)
        #expect(text.contains("ios-swiftui-clean"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("project.pbxproj"))
        #expect(!text.contains("AppStore.swift"))
    }

    @Test("Protocol 3.0 New Project intents decode with safe defaults")
    func legacyNewProjectIntentDefaults() throws {
        let encoded = Data(#"{"directoryName":"Legacy","name":"Legacy","parentLocationID":"resource","platforms":["general"]}"#.utf8)
        let intent = try JSONDecoder().decode(GADCreateProjectIntent.self, from: encoded)

        #expect(intent.providerIDs == [.codex])
        #expect(intent.agents.isEmpty)
        #expect(intent.link == nil)
        #expect(intent.source == .blank)
        #expect(!intent.collaborateAcrossProviders)
        #expect(intent.handoffLinks.isEmpty)
        #expect(intent.template == nil)
    }

    @Test("Agent mutation preserves union scope and reviewed tool preset")
    func agentMutationRoundTrip() throws {
        let intent = GADAgentMutationIntent(
            agentID: nil,
            projectID: nil,
            scope: .union,
            name: "Visual Union",
            summary: "Coordinates visual identity",
            instructions: "Use the approved icon workflow.",
            capabilities: [.design],
            toolPreset: .iconComposer
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(intent)

        #expect(try codec.decode(GADAgentMutationIntent.self, from: encoded) == intent)
        #expect(String(decoding: encoded, as: UTF8.self).contains("union"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("icon-composer"))
    }

    @Test("Legacy agent mutation derives project scope and defaults tool preset")
    func legacyAgentMutationDefaults() throws {
        let encoded = Data(#"{"agentID":null,"projectID":"project","name":"Agent","summary":"Summary","instructions":null,"capabilities":["testing"]}"#.utf8)
        let intent = try JSONDecoder().decode(GADAgentMutationIntent.self, from: encoded)

        #expect(intent.scope == .project("project"))
        #expect(intent.toolPreset == nil)
    }

    @Test("Sanitized Codex discovery round-trips without filesystem authority")
    func codexDiscoveryRoundTrip() throws {
        let discovery = GADCodexCatalogDiscovery(
            projects: [.init(
                id: "project",
                name: "Mobile App",
                platforms: [.iOS],
                isGitRepository: true,
                evidence: ["Inspected from a Mac-authorized project folder"]
            )],
            agents: [.init(
                id: "agent",
                name: "iOS Agent",
                summary: "Owns mobile work",
                capabilities: [.iOS],
                scope: .project("project"),
                evidence: ["Goby-inferred role; no imported instruction body"],
                requiresMacReview: false
            )],
            scannedProjectCount: 1,
            scannedAgentCount: 1,
            limitedProjectAccessCount: 0,
            warnings: [],
            expiresAt: Date(timeIntervalSince1970: 2_100)
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(GADCommandArtifact.codexCatalogDiscovery(discovery))
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(try codec.decode(GADCommandArtifact.self, from: encoded) == .codexCatalogDiscovery(discovery))
        #expect(!text.contains("rootURL"))
        #expect(!text.contains("sourceURL"))
        #expect(!text.contains("instructions"))
        #expect(!text.contains("testCommands"))
    }

    @Test("Purpose-bound agent discovery round-trips without filesystem authority")
    func agentDiscoveryRoundTrip() throws {
        let discovery = GADAgentCatalogDiscovery(
            candidates: [.init(
                id: "agent",
                name: "iOS Agent",
                summary: "Owns mobile work",
                instructions: "Use the reviewed mobile architecture. Credential: [redacted]",
                capabilities: [.iOS, .testing],
                scope: .project("project"),
                evidence: ["Matched iOS terminology"],
                canRestructure: true,
                reviewHash: String(repeating: "a", count: 64)
            )],
            totalCandidateCount: 2,
            nextOffset: 1,
            expiresAt: Date(timeIntervalSince1970: 2_200)
        )
        let codec = GADWireCodec()
        let encoded = try codec.encode(GADCommandArtifact.agentCatalogDiscovery(discovery))
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(try codec.decode(GADCommandArtifact.self, from: encoded) == .agentCatalogDiscovery(discovery))
        #expect(!text.contains("sourceURL"))
        #expect(!text.contains("targetURL"))
        #expect(!text.contains("archiveURL"))
        #expect(!text.contains("configurationPreview"))
        #expect(!text.contains("authorizedDirectoryURL"))

        let requests: [GADHostAdminRequest] = [
            .importAgents([.init(agentID: "agent", reviewHash: String(repeating: "a", count: 64))]),
            .restructureAgents([.init(agentID: "agent", reviewHash: String(repeating: "a", count: 64))])
        ]
        for request in requests {
            let requestData = try codec.encode(request)
            #expect(try codec.decode(GADHostAdminRequest.self, from: requestData) == request)
        }
    }

    private func removingAttachmentField(from data: Data) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "attachments")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
