import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

@Suite("Host IPC contract")
struct HostIPCContractTests {
    @Test("Run approval choice round-trips and old clients default to asking")
    func runApprovalModeCompatibility() throws {
        let choice = GADPlanApproval(planID: "run", authorizationAssertion: "reviewed",
                                     automaticallyApproveRuntimeRequests: true)
        #expect(try JSONDecoder().decode(GADPlanApproval.self, from: JSONEncoder().encode(choice)) == choice)
        let legacy = Data(#"{"planID":"run","authorizationAssertion":"reviewed"}"#.utf8)
        #expect(try JSONDecoder().decode(GADPlanApproval.self, from: legacy).automaticallyApproveRuntimeRequests == false)
    }

    @Test("Project automatic-approval switch round-trips through semantic command IPC")
    func projectApprovalSwitchRoundTrip() throws {
        let command = GADCommandPayload.rememberedApprovals(.setProjectEnabled("project", false))
        #expect(try JSONDecoder().decode(GADCommandPayload.self, from: JSONEncoder().encode(command)) == command)
    }

    @Test("Typed host failures preserve their actionable message in connection diagnostics")
    func hostFailureDescription() {
        let failure = GADCommandFailure(.rejectedCapability, "The background host is validating its saved checkpoint.")
        #expect(failure.localizedDescription == failure.message)
    }

    @Test("Local undo availability is optional and does not carry the recovery archive")
    func localUndoMetadata() throws {
        let legacy = Data(#"{"projects":[],"agents":[],"resources":[]}"#.utf8)
        #expect(try JSONDecoder().decode(GADHostLocalCatalogSnapshot.self, from: legacy).lastDeletedAgentName == nil)
        let snapshot = GADHostLocalCatalogSnapshot(
            projects: [], agents: [], lastDeletedAgentName: "Review specialist"
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(GADHostLocalCatalogSnapshot.self, from: data) == snapshot)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["projects", "agents", "resources", "lastDeletedAgentName"])
    }

    @Test("Ping messages round-trip with bounded deterministic JSON")
    func pingRoundTrip() throws {
        let request = GADHostIPCRequest(
            requestID: UUID(uuidString: "A2F4295A-AB60-42B2-BA57-42DBBA761420")!,
            issuedAt: Date(timeIntervalSince1970: 1_788_699_600),
            operation: .ping
        )

        let data = try GADHostIPCCodec.encode(request)
        let decoded = try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data)

        #expect(decoded == request)
        #expect(data.count < GADHostIPCCodec.maximumMessageBytes)
    }

    @Test("Oversized local messages fail closed before decoding")
    func oversizedMessageRejected() {
        let data = Data(repeating: 0x61, count: GADHostIPCCodec.maximumMessageBytes + 1)
        #expect(throws: GADHostIPCCodecError.oversized) {
            try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data)
        }
    }

    @Test("A replaced app refuses an older host even when the IPC schema matches")
    func hostReleaseVersionMustMatch() {
        #expect(GADHostIPCVersionPolicy.accepts(
            hostVersion: "0.2.0",
            applicationVersion: "0.2.0"
        ))
        #expect(!GADHostIPCVersionPolicy.accepts(
            hostVersion: "0.1.0",
            applicationVersion: "0.2.0"
        ))
        #expect(!GADHostIPCVersionPolicy.accepts(
            hostVersion: "",
            applicationVersion: "0.2.0"
        ))
    }

    @Test("Debug host versions identify the exact embedded helper build")
    func debugHostBuildVersionChangesWithExecutableIdentity() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
        let first = try #require(GADHostIPCVersionPolicy.debugBuildVersion(
            marketingVersion: "0.2.0",
            fileSize: 59_360,
            fileIdentifier: 501,
            modificationDate: timestamp
        ))
        let same = try #require(GADHostIPCVersionPolicy.debugBuildVersion(
            marketingVersion: "0.2.0",
            fileSize: 59_360,
            fileIdentifier: 501,
            modificationDate: timestamp
        ))
        let replacement = try #require(GADHostIPCVersionPolicy.debugBuildVersion(
            marketingVersion: "0.2.0",
            fileSize: 59_360,
            fileIdentifier: 502,
            modificationDate: timestamp
        ))

        #expect(first == same)
        #expect(first != replacement)
        #expect(GADHostIPCVersionPolicy.accepts(
            hostVersion: first,
            applicationVersion: same
        ))
        #expect(!GADHostIPCVersionPolicy.accepts(
            hostVersion: first,
            applicationVersion: replacement
        ))
    }

    @Test("Only a different debug build of the same version counts as a rebuild")
    func debugRebuildRecognition() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
        func build(_ marketing: String, _ fileIdentifier: UInt64) throws -> String {
            try #require(GADHostIPCVersionPolicy.debugBuildVersion(
                marketingVersion: marketing,
                fileSize: 59_360,
                fileIdentifier: fileIdentifier,
                modificationDate: timestamp
            ))
        }
        let prior = try build("0.2.0", 501)

        #expect(GADHostIPCVersionPolicy.isDebugRebuild(try build("0.2.0", 502), of: prior))
        #expect(!GADHostIPCVersionPolicy.isDebugRebuild(prior, of: prior))
        #expect(!GADHostIPCVersionPolicy.isDebugRebuild(try build("0.3.0", 502), of: prior))
        #expect(!GADHostIPCVersionPolicy.isDebugRebuild("0.2.0", of: prior))
        #expect(!GADHostIPCVersionPolicy.isDebugRebuild(prior, of: "0.2.0"))
        #expect(!GADHostIPCVersionPolicy.isDebugRebuild("0.2.1", of: "0.2.0"))
    }

    @Test("Only a strictly newer release counts as an upgrade")
    func releaseUpgradeRecognition() throws {
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.1", from: "0.2.0"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.3.0", from: "0.2.9"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("1.0.0", from: "0.9.12"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0", from: "0.2.0-beta.1"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0-beta.2", from: "0.2.0-beta.1"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0-beta.10", from: "0.2.0-beta.9"))
        #expect(GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0-beta.1", from: "0.2.0-alpha.3"))
        // Same version, downgrades, debug builds and unparsable versions never qualify.
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0", from: "0.2.0"))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0", from: "0.2.1"))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("0.2.0-beta.1", from: "0.2.0"))
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
        let debug = try #require(GADHostIPCVersionPolicy.debugBuildVersion(
            marketingVersion: "0.3.0", fileSize: 1, fileIdentifier: 1, modificationDate: timestamp
        ))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade(debug, from: "0.2.0"))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("0.3.0", from: debug))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("next", from: "0.2.0"))
        #expect(!GADHostIPCVersionPolicy.isReleaseUpgrade("0.3", from: ""))
    }

    @Test("Semantic commands round-trip without exposing generic host operations")
    func semanticCommandRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let command = GADCommand(
            id: CommandID(rawValue: "command-1"),
            idempotencyKey: "host-ipc-command-1",
            hostEpoch: HostEpoch(rawValue: "epoch-1"),
            deviceID: DeviceID(rawValue: "mac-ui"),
            baseRevision: .zero,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(30),
            payload: .refreshProviders([.codex])
        )
        let request = GADHostIPCRequest(
            requestID: UUID(uuidString: "2CF68B8E-C929-44C2-9E3B-E3B2640C38CD")!,
            issuedAt: timestamp,
            operation: .send(command)
        )

        let data = try GADHostIPCCodec.encode(request)
        let decoded = try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data)

        #expect(decoded == request)
        #expect(data.count <= GADHostIPCCodec.maximumRequestBytes)
    }

    @Test("Provider credential change IPC carries identity only")
    func providerCredentialChangeCarriesNoSecret() throws {
        let request = GADHostIPCRequest(
            requestID: UUID(uuidString: "6CC95CB3-FC88-4438-B80F-5DBE2977F37E")!,
            issuedAt: Date(timeIntervalSince1970: 1_788_699_600),
            operation: .localAdministration(
                .providerCredentialChanged(providerID: .claude)
            )
        )

        let data = try GADHostIPCCodec.encode(request)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data) == request)
        #expect(text.contains("claude"))
        for forbidden in ["\"credential\":", "\"token\":", "\"secret\":", "sk-ant-"] {
            #expect(!text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test("An exact approved local branch switch round-trips through host IPC")
    func projectBranchSwitchRoundTrip() throws {
        let approval = ProjectGitBranchSwitchApproval(
            projectID: ProjectID(rawValue: "project-1"),
            expectedCurrentBranch: "main",
            destinationBranch: "feature/provider-planes"
        )
        let request = GADHostIPCRequest(
            requestID: UUID(uuidString: "6D9293CB-93B7-42BF-B80F-617E50426B5B")!,
            issuedAt: Date(timeIntervalSince1970: 1_788_699_600),
            operation: .localAdministration(.switchProjectGitBranch(approval))
        )

        let data = try GADHostIPCCodec.encode(request)
        let decoded = try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data)

        #expect(decoded == request)
        #expect(data.count <= GADHostIPCCodec.maximumRequestBytes)
    }

    @Test("Local New Project template IPC carries a stable selection without generated file content")
    func projectTemplateRoundTrip() throws {
        let request = GADHostIPCRequest(
            issuedAt: Date(timeIntervalSince1970: 1_788_699_600),
            operation: .localAdministration(.createProject(.init(
                parentBookmark: Data([1, 2, 3]),
                name: "Pocket Ledger",
                directoryName: "PocketLedger",
                platforms: [.iOS],
                providerIDs: [.codex],
                agents: [],
                link: nil,
                collaborateAcrossProviders: false,
                handoffLinks: [],
                template: ProjectTemplateSelection(
                    id: "ios-swiftui-clean",
                    version: 1,
                    parameters: [
                        .moduleName: "PocketLedger",
                        .bundleIdentifier: "com.example.PocketLedger"
                    ]
                )
            )))
        )

        let data = try GADHostIPCCodec.encode(request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data) == request)
        #expect(text.contains("ios-swiftui-clean"))
        #expect(!text.contains("project.pbxproj"))
        #expect(!text.contains("AppStore.swift"))
    }

    @Test("Signed local presentation snapshots preserve exact paths across IPC")
    func localPresentationSnapshotRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let projectRoot = URL(fileURLWithPath: "/Users/example/Projects/Atlas")
        let project = LabProject(
            id: "atlas",
            name: "Atlas",
            rootURL: projectRoot,
            platforms: [.web],
            isGitRepository: true,
            registeredAt: timestamp
        )
        let agent = AgentProfile(
            id: "atlas-research",
            name: "Atlas Research",
            summary: "Researches Atlas",
            capabilities: [.research],
            scope: .project(project.id),
            sourceURL: projectRoot.appending(path: ".codex/agents/research.toml")
        )
        let resource = SharedResource(
            id: "atlas-reference",
            name: "Atlas Reference",
            url: projectRoot.appending(path: "Reference", directoryHint: .isDirectory),
            access: .readOnly,
            registeredAt: timestamp
        )
        let run = RunRecord(
            id: "atlas-run",
            plan: RoutingPlan(
                id: "atlas-run",
                interpretedGoal: "Audit Atlas",
                routes: [ProjectRoute(
                    projectID: project.id,
                    agentIDs: [agent.id],
                    reason: "Exact reviewed assignment"
                )],
                risk: .readOnly,
                confidence: 0.91,
                createdAt: timestamp
            ),
            status: .running,
            assignments: [AgentAssignment(
                id: "atlas-assignment",
                runID: "atlas-run",
                projectID: project.id,
                agentID: agent.id,
                status: .working,
                currentTask: "Audit the current working copy",
                workingDirectory: projectRoot
            )],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let catalogResponse = GADHostIPCResponse(
            requestID: UUID(uuidString: "C0441852-630A-4D42-9BF6-68D223CDE802")!,
            hostVersion: "test",
            generatedAt: timestamp,
            isReadOnly: false,
            artifact: .localCatalog(.init(
                projects: [project],
                agents: [agent],
                resources: [resource]
            ))
        )
        let runResponse = GADHostIPCResponse(
            requestID: UUID(uuidString: "96550626-8B09-424C-B183-5CFA4A322E08")!,
            hostVersion: "test",
            generatedAt: timestamp,
            isReadOnly: false,
            artifact: .localRun(run)
        )

        let decodedCatalog = try GADHostIPCCodec.decodeResponse(
            GADHostIPCResponse.self,
            from: GADHostIPCCodec.encodeResponse(catalogResponse)
        )
        let decodedRun = try GADHostIPCCodec.decodeResponse(
            GADHostIPCResponse.self,
            from: GADHostIPCCodec.encodeResponse(runResponse)
        )

        #expect(decodedCatalog == catalogResponse)
        #expect(decodedRun == runResponse)
        guard case let .localCatalog(snapshot) = decodedCatalog.artifact,
              case let .localRun(decodedRecord) = decodedRun.artifact else {
            Issue.record("Expected local presentation artifacts")
            return
        }
        #expect(snapshot.projects.first?.rootURL == projectRoot)
        #expect(snapshot.agents.first?.sourceURL == agent.sourceURL)
        #expect(snapshot.resources.first?.url == resource.url)
        #expect(decodedRecord.assignments.first?.workingDirectory == projectRoot)
    }

    @Test("Snapshot responses have a separate bounded allowance from requests")
    func boundedSnapshotResponse() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let projection = DashboardProjection(
            generatedAt: timestamp,
            host: .init(
                id: HostID(rawValue: "host-1"),
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            ),
            draft: .init(text: String(repeating: "a", count: 160_000))
        )
        let response = GADHostIPCResponse(
            requestID: UUID(uuidString: "558015C0-94E3-43C5-8CA9-77E51480BA27")!,
            hostVersion: "test",
            generatedAt: timestamp,
            isReadOnly: true,
            artifact: .snapshot(projection)
        )

        let data = try GADHostIPCCodec.encodeResponse(response)
        let decoded = try GADHostIPCCodec.decodeResponse(GADHostIPCResponse.self, from: data)

        #expect(data.count > GADHostIPCCodec.maximumRequestBytes)
        #expect(data.count <= GADHostIPCCodec.maximumResponseBytes)
        #expect(decoded == response)
        #expect(throws: GADHostIPCCodecError.oversized) {
            try GADHostIPCCodec.decode(GADHostIPCResponse.self, from: data)
        }
    }

    @Test("Migration-mode host rejects semantic traffic while keeping ping available")
    func migrationModeFailsClosed() async {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: nil,
            mode: .migrationReadOnly,
            now: { timestamp }
        )

        let ping = await handler.handle(.init(issuedAt: timestamp, operation: .ping))
        let connect = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .connect(DeviceID(rawValue: "mac-ui"))
        ))

        #expect(ping.error == nil)
        #expect(ping.isReadOnly)
        #expect(connect.error?.contains("read-only migration mode") == true)
        #expect(connect.artifact == nil)
    }

    @Test("A terminal host activation failure is returned by ping")
    func migrationFailureIsReportedByPing() async {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: nil,
            mode: .migrationReadOnly,
            startupFailure: "The canonical-state backup could not be prepared.",
            now: { timestamp }
        )

        let ping = await handler.handle(.init(issuedAt: timestamp, operation: .ping))

        #expect(ping.isReadOnly)
        #expect(ping.error == "The canonical-state backup could not be prepared.")
    }

    @Test("The stable host router can install a validated handler without replacing the listener")
    func stableRouterInstallsValidatedHandler() async {
        let timestamp = Date.now
        let migration = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: nil,
            mode: .migrationReadOnly,
            now: { timestamp }
        )
        let router = GADHostIPCRequestRouter(handler: migration)
        let before = await router.handle(.init(
            issuedAt: timestamp,
            operation: .connect(DeviceID(rawValue: "mac-ui"))
        ))
        #expect(before.isReadOnly)

        let projection = DashboardProjection(
            generatedAt: timestamp,
            host: .init(
                id: HostID(rawValue: "host"),
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let coordinator = GADCoordinator(
            hostID: HostID(rawValue: "host"),
            initialProjection: projection,
            capabilities: [],
            authorizedDevices: [DeviceID(rawValue: "mac-ui")],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let authoritative = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            mode: .authoritative,
            now: { timestamp }
        )
        await router.install(authoritative)
        let after = await router.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(DeviceID(rawValue: "mac-ui"))
        ))
        #expect(!after.isReadOnly)
        #expect(after.artifact == .snapshot(projection))
    }

    @Test("Validation mode exposes an equivalent snapshot but rejects mutations until activation")
    func validationModeIsReadOnly() async throws {
        let timestamp = Date.now
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-1")
        let projection = DashboardProjection(
            generatedAt: timestamp,
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: projection,
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let gate = GADHostIPCActivationGate()
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            now: { timestamp }
        )

        try await gate.beginValidation()
        let snapshot = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(deviceID)
        ))
        #expect(snapshot.isReadOnly)
        #expect(snapshot.error == nil)
        #expect(snapshot.artifact == .snapshot(projection))

        let command = GADCommand(
            idempotencyKey: "must-not-run",
            hostEpoch: HostEpoch(rawValue: "epoch-1"),
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(30),
            payload: .refreshCodex
        )
        let rejected = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .send(command)
        ))
        #expect(rejected.isReadOnly)
        #expect(rejected.failureDisposition == .rejectedCapability)
        #expect(rejected.artifact == nil)

        try await gate.activate()
        let activated = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(deviceID)
        ))
        #expect(!activated.isReadOnly)
        await #expect(throws: GADHostIPCActivationError.self) {
            try await gate.beginValidation()
        }
    }

    @Test("Quiescing rejects new semantic work and can resume only after a failed handoff")
    func quiescingModeFailsClosed() async throws {
        let timestamp = Date.now
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-1")
        let projection = DashboardProjection(
            generatedAt: timestamp,
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: projection,
            capabilities: [],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let gate = GADHostIPCActivationGate(mode: .authoritative)
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            now: { timestamp }
        )

        try await gate.beginQuiescing()
        let rejected = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(deviceID)
        ))
        #expect(rejected.isReadOnly)
        #expect(rejected.failureDisposition == .rejectedCapability)

        let ping = await handler.handle(.init(issuedAt: timestamp, operation: .ping))
        #expect(ping.isReadOnly)
        #expect(ping.error == nil)

        try await gate.resumeAfterFailedQuiescing()
        let resumed = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(deviceID)
        ))
        #expect(!resumed.isReadOnly)
        #expect(resumed.artifact == .snapshot(projection))
    }

    @Test("Quiescing drains an admitted semantic command before rejecting later mutations")
    @MainActor
    func quiescingDrainsAdmittedSend() async throws {
        try await assertQuiescingDrains(.send)
    }

    @Test("Quiescing drains admitted Remote Access administration before rejecting later mutations")
    @MainActor
    func quiescingDrainsAdmittedRemoteAccessCommand() async throws {
        try await assertQuiescingDrains(.remoteAccessCommand)
    }

    @Test("Quiescing drains admitted local administration before rejecting later mutations")
    @MainActor
    func quiescingDrainsAdmittedLocalAdministration() async throws {
        try await assertQuiescingDrains(.localAdministration)
    }

    @Test("Shutdown quiescing rejects new work and waits for an admitted local mutation")
    @MainActor
    func shutdownQuiescingDrainsAdmittedMutation() async {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let hostID = HostID(rawValue: "host-shutdown-drain")
        let suspension = HostMutationSuspension()
        let gate = GADHostIPCActivationGate(mode: .authoritative)
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [],
            authorizedDevices: [],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            localAdministration: SuspendingLocalAdministration(suspension: suspension),
            now: { timestamp }
        )
        let request = GADHostIPCRequest(
            issuedAt: timestamp,
            operation: .localAdministration(.providerCredentialChanged(providerID: .claude))
        )

        let admitted = Task { await handler.handle(request) }
        await suspension.waitUntilStarted()
        let completion = HostMutationCompletion()
        let shutdown = Task {
            await gate.quiesceForShutdown()
            await completion.markComplete()
        }
        #expect(await waitForMode(.quiescingReadOnly, at: gate))
        #expect(!(await completion.isComplete))

        let rejected = await handler.handle(request)
        #expect(rejected.isReadOnly)
        #expect(rejected.failureDisposition == .rejectedCapability)

        await suspension.resume()
        #expect((await admitted.value).error == nil)
        await shutdown.value
        #expect(await completion.isComplete)
        await gate.quiesceForShutdown()
        #expect(await gate.currentMode() == .quiescingReadOnly)
    }

    @Test("The permanent-host shutdown request initiates quiescing without waiting on itself")
    @MainActor
    func permanentHostShutdownDoesNotDeadlockItsDrain() async {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let hostID = HostID(rawValue: "host-transfer-initiator")
        let gate = GADHostIPCActivationGate(mode: .authoritative)
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [],
            authorizedDevices: [],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            localAdministration: QuiescingShutdownAdministration(
                gate: gate,
                hostID: hostID,
                timestamp: timestamp
            ),
            now: { timestamp }
        )

        let response = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .localAdministration(.preparePermanentHostShutdown)
        ))

        #expect(response.error == nil)
        #expect(await gate.currentMode() == .quiescingReadOnly)
        guard case let .localReceipt(receipt) = response.artifact else {
            Issue.record("Expected the maintenance receipt")
            return
        }
        #expect(receipt.id == hostID.rawValue)
    }

    @Test("A duplicate permanent-host shutdown is rejected before local administration")
    @MainActor
    func duplicatePermanentHostShutdownIsRejected() async {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let hostID = HostID(rawValue: "host-exclusive-transfer")
        let deviceID = DeviceID(rawValue: "mac-ui")
        let gate = GADHostIPCActivationGate(mode: .authoritative)
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let suspension = HostMutationSuspension()
        let administration = SuspendingPermanentShutdownAdministration(
            suspension: suspension,
            hostID: hostID,
            timestamp: timestamp
        )
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            localAdministration: administration,
            now: { timestamp }
        )
        let request = GADHostIPCRequest(
            issuedAt: timestamp,
            operation: .localAdministration(.preparePermanentHostShutdown)
        )

        let admitted = Task { await handler.handle(request) }
        await suspension.waitUntilStarted()

        let duplicate = await handler.handle(request)
        #expect(duplicate.isReadOnly)
        #expect(duplicate.failureDisposition == .rejectedCapability)
        #expect(duplicate.artifact == nil)
        #expect(administration.invocationCount == 1)
        #expect(await gate.currentMode() == .quiescingReadOnly)

        await suspension.resume()
        let completed = await admitted.value
        #expect(completed.error == nil)
        #expect(administration.invocationCount == 1)
        #expect(await gate.currentMode() == .quiescingReadOnly)
    }

    @Test("Migration comparison ignores live observations and reports canonical mismatches")
    func migrationProjectionComparison() {
        let firstTimestamp = Date(timeIntervalSince1970: 1_000)
        let secondTimestamp = Date(timeIntervalSince1970: 2_000)
        let hostID = HostID(rawValue: "host-1")
        let expected = DashboardProjection(
            revision: StateRevision(rawValue: 4),
            generatedAt: firstTimestamp,
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: firstTimestamp
            ),
            draft: .init(revision: EntityRevision(rawValue: 2), text: "Continue work")
        )
        let transientlyDifferent = DashboardProjection(
            revision: expected.revision,
            generatedAt: secondTimestamp,
            host: .init(
                id: hostID,
                displayName: "Launch Agent Host Name",
                reachability: .degraded,
                lastUpdatedAt: secondTimestamp
            ),
            draft: expected.draft
        )
        #expect(GADHostMigrationProjectionComparator.compare(
            expected: expected,
            candidate: transientlyDifferent
        ).isEquivalent)

        let changedDraft = DashboardProjection(
            revision: expected.revision,
            generatedAt: secondTimestamp,
            host: transientlyDifferent.host,
            draft: .init(revision: expected.draft.revision, text: "Different work")
        )
        let comparison = GADHostMigrationProjectionComparator.compare(
            expected: expected,
            candidate: changedDraft
        )
        #expect(comparison.mismatchedSections == [.draft])

        let differentHost = DashboardProjection(
            revision: expected.revision,
            generatedAt: secondTimestamp,
            host: .init(
                id: HostID(rawValue: "host-2"),
                displayName: expected.host.displayName,
                reachability: .online,
                lastUpdatedAt: secondTimestamp
            ),
            draft: expected.draft
        )
        #expect(GADHostMigrationProjectionComparator.compare(
            expected: expected,
            candidate: differentHost
        ).mismatchedSections == [.hostIdentity])
    }

    @Test("Authoritative host dispatches connect, snapshot, command and bounded event replay")
    func authoritativeSemanticDispatch() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-1")
        let projection = DashboardProjection(
            generatedAt: timestamp,
            host: .init(
                id: hostID,
                displayName: "Test Mac",
                reachability: .online,
                lastUpdatedAt: timestamp
            )
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: HostEpoch(rawValue: "epoch-1"),
            initialProjection: projection,
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            mode: .authoritative,
            now: { timestamp }
        )

        let connected = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .connect(deviceID)
        ))
        guard case let .session(session) = connected.artifact else {
            Issue.record("Expected a semantic client session")
            return
        }
        #expect(session.hostID == hostID)
        #expect(!connected.isReadOnly)

        let snapshot = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .snapshot(deviceID)
        ))
        guard case let .snapshot(snapshotProjection) = snapshot.artifact else {
            Issue.record("Expected a sanitized dashboard projection")
            return
        }
        #expect(snapshotProjection == projection)

        let command = GADCommand(
            id: CommandID(rawValue: "command-1"),
            idempotencyKey: "local-draft-1",
            hostEpoch: session.hostEpoch,
            deviceID: deviceID,
            baseRevision: session.revision,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(30),
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Continue from the iPhone",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )
        let sent = await handler.handle(.init(issuedAt: timestamp, operation: .send(command)))
        guard case let .acknowledgement(acknowledgement) = sent.artifact else {
            Issue.record("Expected a canonical acknowledgement")
            return
        }
        #expect(acknowledgement.disposition == .accepted)

        let replayed = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .events(.init(deviceID: deviceID, afterRevision: .zero, maximumCount: 10))
        ))
        guard case let .deltas(deltas) = replayed.artifact else {
            Issue.record("Expected a bounded event batch")
            return
        }
        #expect(deltas.count == 1)
        #expect(deltas.first?.revision == acknowledgement.revision)
    }

    @Test("Local Goby client validates semantic artifacts and replays host events")
    func localGobyClientAdapter() async throws {
        let timestamp = Date.now
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-1")
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: HostEpoch(rawValue: "epoch-1"),
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let transport = HandlerHostIPCTransport(handler: GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            mode: .authoritative,
            now: { timestamp }
        ))
        let client = GADHostIPCGobyClient(
            transport: transport,
            deviceID: deviceID,
            idlePollInterval: .milliseconds(50)
        )

        let session = try await client.connect()
        let snapshot = try await client.snapshot()
        #expect(session.hostID == hostID)
        #expect(snapshot.host.id == hostID)

        let command = GADCommand(
            id: CommandID(rawValue: "command-client-1"),
            idempotencyKey: "local-client-draft-1",
            hostEpoch: session.hostEpoch,
            deviceID: deviceID,
            baseRevision: snapshot.revision,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(30),
            payload: .replaceDraft(.init(
                expectedRevision: snapshot.draft.revision,
                text: "Continue from the Mac UI",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )
        let acknowledgement = try await client.send(command)
        #expect(acknowledgement.disposition == .accepted)

        let stream = await client.events(after: .zero)
        var iterator = stream.makeAsyncIterator()
        let delta = await iterator.next()
        #expect(delta?.revision == acknowledgement.revision)
        #expect(delta?.originatingCommandID == command.id)

        await client.disconnect()
    }

    @Test("Large local event journals are delivered in reply-sized batches")
    func localEventReplayFitsResponseLimit() async throws {
        let timestamp = Date.now
        let deltas = (0..<7).map { index in
            GADStateDelta(
                hostEpoch: HostEpoch(rawValue: "epoch-1"), revision: .zero,
                occurredAt: timestamp, originatingCommandID: nil,
                changes: [.draft(GADDraftProjection(
                    text: String(repeating: String(index), count: 350_000)
                ))]
            )
        }
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test", coordinator: nil, mode: .authoritative,
            now: { timestamp }
        )
        let requestID = UUID()
        let oversized = GADHostIPCResponse(
            requestID: requestID, hostVersion: "test", generatedAt: timestamp,
            isReadOnly: false, artifact: .deltas(deltas)
        )
        #expect(throws: GADHostIPCCodecError.oversized) {
            try GADHostIPCCodec.encodeResponse(oversized)
        }
        var received = 0
        while received < deltas.count {
            let fitting = await handler.fittingEventPrefix(
                Array(deltas.dropFirst(received)), requestID: requestID,
                at: timestamp, isReadOnly: false
            )
            let reply = GADHostIPCResponse(
                requestID: requestID, hostVersion: "test", generatedAt: timestamp,
                isReadOnly: false, artifact: .deltas(fitting)
            )
            let data = try GADHostIPCCodec.encodeResponse(reply)
            #expect(data.count <= GADHostIPCCodec.maximumResponseBytes)
            guard !fitting.isEmpty else {
                Issue.record("The host did not return the next event batch")
                return
            }
            received += fitting.count
        }
        #expect(received == 7)
    }

    @Test("A brief local event-poll failure does not end the live stream")
    func localEventPollRetriesReadOnlyFailure() async {
        let deviceID = DeviceID(rawValue: "mac-ui")
        let transport = OneShotEventFailureTransport()
        let client = GADHostIPCGobyClient(
            transport: transport, deviceID: deviceID,
            idlePollInterval: .milliseconds(50)
        )
        let stream = await client.events(after: .zero)
        var iterator = stream.makeAsyncIterator()
        let delta = await iterator.next()
        #expect(delta?.revision == StateRevision.zero.advanced())
        let requestCount = await transport.eventRequestCount
        #expect(requestCount >= 2)
        await client.disconnect()
    }

    @Test("An oversized individual event falls back to a current-state resync")
    func oversizedLocalEventUsesResyncSnapshot() async throws {
        let timestamp = Date.now
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-1")
        let host = GADHostProjection(
            id: hostID, displayName: "Test Mac", reachability: .online,
            lastUpdatedAt: timestamp
        )
        let coordinator = GADCoordinator(
            hostID: hostID, hostEpoch: HostEpoch(rawValue: "epoch-1"),
            initialProjection: DashboardProjection(generatedAt: timestamp, host: host),
            capabilities: [.sharedDraft], authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(), now: { timestamp }
        )
        _ = await coordinator.synchronize(DashboardProjection(
            generatedAt: timestamp, host: host,
            draft: GADDraftProjection(text: String(repeating: "x", count: 2_200_000))
        ))
        _ = await coordinator.synchronize(DashboardProjection(generatedAt: timestamp, host: host))
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test", coordinator: coordinator, mode: .authoritative,
            now: { timestamp }
        )
        let reply = await handler.handle(.init(
            issuedAt: timestamp,
            operation: .events(.init(deviceID: deviceID, afterRevision: .zero))
        ))
        let data = try GADHostIPCCodec.encodeResponse(reply)
        #expect(data.count <= GADHostIPCCodec.maximumResponseBytes)
        guard case let .deltas(deltas) = reply.artifact else {
            Issue.record("The host did not return a resync delta")
            return
        }
        #expect(deltas.count == 1)
        #expect(deltas.first?.isResyncSnapshot == true)
        let currentRevision = await coordinator.currentProjection().revision
        #expect(deltas.first?.revision == currentRevision)
    }

    @Test("Local Goby client preserves revocation disposition")
    func localGobyClientPreservesRevocation() async {
        let timestamp = Date.now
        let allowedDeviceID = DeviceID(rawValue: "allowed-device")
        let revokedDeviceID = DeviceID(rawValue: "revoked-device")
        let hostID = HostID(rawValue: "host-1")
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [],
            authorizedDevices: [allowedDeviceID],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let transport = HandlerHostIPCTransport(handler: GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            mode: .authoritative,
            now: { timestamp }
        ))
        let client = GADHostIPCGobyClient(transport: transport, deviceID: revokedDeviceID)

        do {
            _ = try await client.connect()
            Issue.record("Expected the revoked device to be rejected")
        } catch let failure as GADCommandFailure {
            #expect(failure.disposition == .rejectedRevoked)
        } catch {
            Issue.record("Expected a typed GAD command failure, received \(error)")
        }
    }

    @Test("Same-Team local administration is typed and unavailable during validation")
    @MainActor
    func typedLocalAdministration() async throws {
        let timestamp = Date.now
        let administration = TestLocalAdministration()
        let gate = GADHostIPCActivationGate()
        let hostID = HostID(rawValue: "host-admin")
        let coordinator = GADCoordinator(
            hostID: hostID,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: GADHostProjection(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [],
            authorizedDevices: [],
            handler: ProjectionGADCommandHandler(),
            now: { timestamp }
        )
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            localAdministration: administration,
            now: { timestamp }
        )
        let transport = HandlerHostIPCTransport(handler: handler)
        let client = GADHostIPCAdministrationClient(transport: transport)

        try await gate.beginValidation()
        await #expect(throws: GADHostIPCClientError.self) {
            _ = try await client.remoteAccessSnapshot()
        }

        try await gate.activate()
        let initial = try await client.remoteAccessSnapshot()
        #expect(initial.phase == .listening)
        #expect(initial.pairedDevices.first?.name == "iPhone")

        let updated = try await client.apply(.renameDevice(id: "phone", name: "Travel Phone"))
        #expect(updated.pairedDevices.first?.name == "Travel Phone")
        #expect(administration.lastCommand == .renameDevice(id: "phone", name: "Travel Phone"))

        let artifact = try await client.applyLocal(
            .providerCredentialChanged(providerID: .claude)
        )
        #expect(artifact == .localReceipt(.init(
            id: "receipt",
            summary: "Applied",
            isUndoAvailable: false
        )))
        #expect(administration.lastLocalCommand == .providerCredentialChanged(providerID: .claude))

        let shutdown = try await client.preparePermanentHostShutdown()
        #expect(shutdown.id == "maintenance")
        #expect(administration.lastLocalCommand == .preparePermanentHostShutdown)
    }

    @MainActor
    private func assertQuiescingDrains(_ kind: SuspendedHostMutationKind) async throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_699_600)
        let deviceID = DeviceID(rawValue: "mac-ui")
        let hostID = HostID(rawValue: "host-mutation-drain")
        let hostEpoch = HostEpoch(rawValue: "epoch-mutation-drain")
        let suspension = HostMutationSuspension()
        let commandHandler = SuspendingGADCommandHandler(suspension: suspension)
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: hostEpoch,
            initialProjection: DashboardProjection(
                generatedAt: timestamp,
                host: .init(
                    id: hostID,
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: timestamp
                )
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: commandHandler,
            now: { timestamp }
        )
        let administration = SuspendingLocalAdministration(suspension: suspension)
        let gate = GADHostIPCActivationGate(mode: .authoritative)
        let handler = GADHostIPCRequestHandler(
            hostVersion: "test",
            coordinator: coordinator,
            activationGate: gate,
            localAdministration: administration,
            now: { timestamp }
        )
        let command = GADCommand(
            id: CommandID(rawValue: "command-mutation-drain"),
            idempotencyKey: "host-ipc-mutation-drain",
            hostEpoch: hostEpoch,
            deviceID: deviceID,
            baseRevision: .zero,
            issuedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(30),
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Drain this admitted command",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )
        let operation: GADHostIPCOperation = switch kind {
        case .send:
            .send(command)
        case .remoteAccessCommand:
            .remoteAccessCommand(.renameDevice(id: "phone", name: "Travel Phone"))
        case .localAdministration:
            .localAdministration(.providerCredentialChanged(providerID: .claude))
        }
        let request = GADHostIPCRequest(issuedAt: timestamp, operation: operation)

        let admitted = Task { await handler.handle(request) }
        await suspension.waitUntilStarted()

        let quiescingCompletion = HostMutationCompletion()
        let quiescing = Task {
            try await gate.beginQuiescing()
            await quiescingCompletion.markComplete()
        }
        #expect(await waitForMode(.quiescingReadOnly, at: gate))
        #expect(!(await quiescingCompletion.isComplete))

        let rejected = await handler.handle(request)
        #expect(rejected.isReadOnly)
        #expect(rejected.failureDisposition == .rejectedCapability)
        #expect(rejected.artifact == nil)

        await suspension.resume()
        let completed = await admitted.value
        #expect(completed.error == nil)
        try await quiescing.value
        #expect(await quiescingCompletion.isComplete)
    }

    private func waitForMode(
        _ expected: GADHostIPCMode,
        at gate: GADHostIPCActivationGate
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await gate.currentMode() == expected { return true }
            await Task.yield()
        }
        return false
    }
}

private actor HandlerHostIPCTransport: GADHostIPCTransporting {
    private let handler: any GADHostIPCRequestHandling

    init(handler: any GADHostIPCRequestHandling) {
        self.handler = handler
    }

    func exchange(_ request: GADHostIPCRequest) async -> GADHostIPCResponse {
        await handler.handle(request)
    }
}

private enum SuspendedHostMutationKind: Sendable {
    case send
    case remoteAccessCommand
    case localAdministration
}

private actor HostMutationSuspension {
    private var started = false
    private var resumed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStartWaiters { waiter.resume() }
        guard !resumed else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumed = true
        let pendingResumeWaiters = resumeWaiters
        resumeWaiters.removeAll()
        for waiter in pendingResumeWaiters { waiter.resume() }
    }
}

private actor HostMutationCompletion {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor SuspendingGADCommandHandler: GADCommandHandling {
    let suspension: HostMutationSuspension

    init(suspension: HostMutationSuspension) {
        self.suspension = suspension
    }

    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect {
        await suspension.suspend()
        return GADCommandEffect()
    }
}

@MainActor
private final class QuiescingShutdownAdministration: GADHostLocalAdministrationHandling {
    let gate: GADHostIPCActivationGate
    let hostID: HostID
    let timestamp: Date

    init(gate: GADHostIPCActivationGate, hostID: HostID, timestamp: Date) {
        self.gate = gate
        self.hostID = hostID
        self.timestamp = timestamp
    }

    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot {
        GADHostRemoteAccessSnapshot(relayURLText: "", phase: .disabled)
    }

    func applyRemoteAccessCommand(
        _ command: GADHostRemoteAccessCommand
    ) async -> GADHostRemoteAccessSnapshot {
        await remoteAccessSnapshot()
    }

    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        guard case .preparePermanentHostShutdown = command else {
            throw GADCommandFailure(.rejectedCapability, "Unexpected local command.")
        }
        return .localReceipt(.init(
            id: hostID.rawValue,
            summary: "Prepared",
            isUndoAvailable: false
        ))
    }
}

@MainActor
private final class SuspendingPermanentShutdownAdministration: GADHostLocalAdministrationHandling {
    let suspension: HostMutationSuspension
    let hostID: HostID
    let timestamp: Date
    private(set) var invocationCount = 0

    init(suspension: HostMutationSuspension, hostID: HostID, timestamp: Date) {
        self.suspension = suspension
        self.hostID = hostID
        self.timestamp = timestamp
    }

    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot {
        GADHostRemoteAccessSnapshot(relayURLText: "", phase: .disabled)
    }

    func applyRemoteAccessCommand(
        _ command: GADHostRemoteAccessCommand
    ) async -> GADHostRemoteAccessSnapshot {
        await remoteAccessSnapshot()
    }

    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        guard case .preparePermanentHostShutdown = command else {
            throw GADCommandFailure(.rejectedCapability, "Unexpected local command.")
        }
        invocationCount += 1
        await suspension.suspend()
        return .localReceipt(.init(
            id: hostID.rawValue,
            summary: "Prepared",
            isUndoAvailable: false
        ))
    }
}

@MainActor
private final class SuspendingLocalAdministration: GADHostLocalAdministrationHandling {
    let suspension: HostMutationSuspension

    init(suspension: HostMutationSuspension) {
        self.suspension = suspension
    }

    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot {
        snapshot()
    }

    func applyRemoteAccessCommand(
        _ command: GADHostRemoteAccessCommand
    ) async -> GADHostRemoteAccessSnapshot {
        await suspension.suspend()
        return snapshot()
    }

    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        await suspension.suspend()
        return .localReceipt(.init(id: "receipt", summary: "Applied", isUndoAvailable: false))
    }

    private func snapshot() -> GADHostRemoteAccessSnapshot {
        GADHostRemoteAccessSnapshot(
            relayURLText: "wss://relay.example.test",
            phase: .listening
        )
    }
}

@MainActor
private final class TestLocalAdministration: GADHostLocalAdministrationHandling {
    private(set) var lastCommand: GADHostRemoteAccessCommand?
    private(set) var lastLocalCommand: GADHostLocalCommand?
    private var deviceName = "iPhone"

    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot {
        GADHostRemoteAccessSnapshot(
            relayURLText: "wss://relay.example.test",
            phase: .listening,
            pairedDevices: [
                GADHostPairedDevice(
                    id: "phone",
                    name: deviceName,
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    isConnected: true
                )
            ]
        )
    }

    func applyRemoteAccessCommand(
        _ command: GADHostRemoteAccessCommand
    ) async -> GADHostRemoteAccessSnapshot {
        lastCommand = command
        if case let .renameDevice(_, name) = command { deviceName = name }
        return await remoteAccessSnapshot()
    }

    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        lastLocalCommand = command
        if case .preparePermanentHostShutdown = command {
            return .localReceipt(.init(
                id: "maintenance",
                summary: "Prepared",
                isUndoAvailable: false
            ))
        }
        return .localReceipt(.init(id: "receipt", summary: "Applied", isUndoAvailable: false))
    }
}

private actor OneShotEventFailureTransport: GADHostIPCTransporting {
    private(set) var eventRequestCount = 0
    private var delivered = false

    func exchange(_ request: GADHostIPCRequest) async throws -> GADHostIPCResponse {
        guard case .events = request.operation else {
            return GADHostIPCResponse(
                requestID: request.requestID, hostVersion: "test",
                generatedAt: .now, isReadOnly: false
            )
        }
        eventRequestCount += 1
        if eventRequestCount == 1 {
            throw GADHostIPCClientError.hostUnavailable("Temporary helper interruption")
        }
        let deltas: [GADStateDelta]
        if delivered {
            deltas = []
        } else {
            delivered = true
            deltas = [GADStateDelta(
                hostEpoch: HostEpoch(rawValue: "epoch-1"),
                revision: .zero.advanced(), occurredAt: .now,
                originatingCommandID: nil,
                changes: [.draft(GADDraftProjection(text: "Recovered"))]
            )]
        }
        return GADHostIPCResponse(
            requestID: request.requestID, hostVersion: "test",
            generatedAt: .now, isReadOnly: false, artifact: .deltas(deltas)
        )
    }
}

@Suite("Plan push approval wire")
struct PlanPushApprovalWireTests {
    @Test("The push approval is omitted when unset, and older payloads never allow a push")
    func pushApprovalIsAdditive() throws {
        let plain = try JSONEncoder().encode(GADPlanApproval(planID: "run", authorizationAssertion: "x"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("allowsPush"))
        #expect(try JSONDecoder().decode(GADPlanApproval.self, from: plain).allowsPush == nil)

        let allowed = try JSONEncoder().encode(GADPlanApproval(planID: "run", authorizationAssertion: "x", allowsPush: true))
        #expect(try JSONDecoder().decode(GADPlanApproval.self, from: allowed).allowsPush == true)
    }
}
