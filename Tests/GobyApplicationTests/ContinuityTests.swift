import Foundation
import Testing
import GobyDomain
@testable import GobyApplication

@Suite("GAD continuity")
struct ContinuityTests {
    @Test("Projected plans skip review only with safe executable scope and no shared folders")
    func projectedPlanAutomaticStartPolicy() {
        let route = GADPlanRouteProjection(
            projectID: "project", agentIDs: ["agent"], reason: "Exact project route"
        )
        func plan(
            risk: PlanRisk = .readOnly,
            confidence: Double = 0.9,
            routes: [GADPlanRouteProjection] = [route],
            resources: [SharedResourceID] = [],
            warnings: [String] = []
        ) -> GADPlanProjection {
            GADPlanProjection(
                id: "automatic-start-plan", goal: "Inspect", routes: routes,
                risk: risk, confidence: confidence, gitOperations: [],
                warnings: warnings, selectedResourceIDs: resources, createdAt: .now
            )
        }

        #expect(plan().canStartAutomatically)
        #expect(!plan(risk: .medium).canStartAutomatically)
        #expect(!plan(confidence: 0.7).canStartAutomatically)
        #expect(!plan(routes: []).canStartAutomatically)
        #expect(!plan(routes: [.init(projectID: "project", agentIDs: [], reason: "No agent")]).canStartAutomatically)
        #expect(!plan(resources: ["shared-folder"]).canStartAutomatically)
        #expect(!plan(warnings: ["Review scope"]).canStartAutomatically)
    }

    @Test("Device revocation drains its admitted command before completing")
    func deviceRevocationDrainsAdmittedCommand() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostID = HostID(rawValue: "host-revocation-drain")
        let deviceID = DeviceID(rawValue: "phone-revocation-drain")
        let survivorID = DeviceID(rawValue: "phone-still-authorized")
        let epoch = HostEpoch(rawValue: "epoch-revocation-drain")
        let suspension = RevocationCommandSuspension()
        let completion = RevocationCompletionProbe()
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now)
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID, survivorID],
            handler: RevocationSuspendingCommandHandler(suspension: suspension),
            now: { now }
        )
        let bufferedRevision = await coordinator.synchronize(DashboardProjection(
            generatedAt: now,
            host: .init(id: hostID, displayName: "Buffered Mac", reachability: .online, lastUpdatedAt: now)
        ))
        let revokedStream = await coordinator.events(deviceID: deviceID, after: .zero)
        let survivorStream = await coordinator.events(deviceID: survivorID, after: .zero)
        var revokedIterator = revokedStream.makeAsyncIterator()
        var survivorIterator = survivorStream.makeAsyncIterator()
        #expect(await survivorIterator.next()?.revision == bufferedRevision)
        let command = makeCommand(
            key: "revocation-drain",
            epoch: epoch,
            deviceID: deviceID,
            base: bufferedRevision,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Already admitted",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        )

        let commandTask = Task { await coordinator.send(command) }
        await suspension.waitUntilStarted()
        let revocationTask = Task {
            await coordinator.revoke(deviceID)
            await completion.markFinished()
        }

        for _ in 0..<100 {
            if (try? await coordinator.connect(deviceID: deviceID)) == nil { break }
            await Task.yield()
        }
        #expect((try? await coordinator.connect(deviceID: deviceID)) == nil)
        #expect(await completion.isFinished == false)
        await coordinator.authorize(deviceID)
        #expect((try? await coordinator.connect(deviceID: deviceID)) == nil)

        let synchronizedRevision = await coordinator.synchronize(DashboardProjection(
            generatedAt: now.addingTimeInterval(1),
            host: .init(
                id: hostID,
                displayName: "Updated Mac",
                reachability: .online,
                lastUpdatedAt: now.addingTimeInterval(1)
            )
        ))
        #expect(await revokedIterator.next() == nil)
        #expect(await survivorIterator.next()?.revision == synchronizedRevision)
        #expect(try await coordinator.connect(deviceID: survivorID).hostID == hostID)

        await suspension.resume()
        #expect(await commandTask.value.disposition == .accepted)
        await revocationTask.value
        #expect(await completion.isFinished)

        let rejected = await coordinator.send(makeCommand(
            key: "revocation-after-drain",
            epoch: epoch,
            deviceID: deviceID,
            base: StateRevision(rawValue: 1),
            payload: .replaceDraft(.init(
                expectedRevision: EntityRevision(rawValue: 1),
                text: "Must not run",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        ))
        #expect(rejected.disposition == .rejectedRevoked)
        await coordinator.authorize(deviceID)
        #expect(try await coordinator.connect(deviceID: deviceID).hostID == hostID)
    }

    @Test("Batch revocation removes every device before draining one admitted command")
    func batchRevocationRemovesAllAuthorityBeforeDrain() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostID = HostID(rawValue: "host-batch-revocation")
        let firstDevice = DeviceID(rawValue: "phone-a")
        let secondDevice = DeviceID(rawValue: "phone-b")
        let epoch = HostEpoch(rawValue: "epoch-batch-revocation")
        let suspension = RevocationCommandSuspension()
        let completion = RevocationCompletionProbe()
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now)
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [firstDevice, secondDevice],
            handler: RevocationSuspendingCommandHandler(suspension: suspension),
            now: { now }
        )
        let firstCommand = makeCommand(
            key: "batch-revocation-admitted",
            epoch: epoch,
            deviceID: firstDevice,
            base: .zero,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Already admitted",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        )

        let commandTask = Task { await coordinator.send(firstCommand) }
        await suspension.waitUntilStarted()
        let revocationTask = Task {
            await coordinator.revoke(Set([firstDevice, secondDevice]))
            await completion.markFinished()
        }

        for _ in 0..<100 {
            let firstRejected = (try? await coordinator.connect(deviceID: firstDevice)) == nil
            let secondRejected = (try? await coordinator.connect(deviceID: secondDevice)) == nil
            if firstRejected && secondRejected { break }
            await Task.yield()
        }
        #expect((try? await coordinator.connect(deviceID: firstDevice)) == nil)
        #expect((try? await coordinator.snapshot(deviceID: secondDevice)) == nil)
        let secondCommand = await coordinator.send(makeCommand(
            key: "batch-revocation-race",
            epoch: epoch,
            deviceID: secondDevice,
            base: .zero,
            payload: .preparePlan,
            now: now
        ))
        #expect(secondCommand.disposition == .rejectedRevoked)
        #expect(await completion.isFinished == false)

        await suspension.resume()
        #expect(await commandTask.value.disposition == .accepted)
        await revocationTask.value
        #expect(await completion.isFinished)
    }

    @Test("Ownership quiescing rejects new commands without consuming their retry identity")
    func ownershipQuiescingDrainsCommandAdmission() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now)
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { now }
        )
        let command = makeCommand(
            key: "ownership-retry",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Resume after ownership transfer",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        )

        await coordinator.quiesceCommands()
        let deferred = await coordinator.send(command)
        #expect(deferred.disposition == .failedRecoverable)
        #expect(deferred.revision == .zero)

        await coordinator.resumeCommands()
        let retried = await coordinator.send(command)
        #expect(retried.disposition == .accepted)
        #expect(retried.revision == StateRevision(rawValue: 1))
    }

    @Test("Coordinator applies a draft once, broadcasts it, and rejects stale replacement")
    func coordinatorDraftFlow() async throws {
        let fixture = makeCoordinator(capabilities: [.sharedDraft])
        let session = try await fixture.client.connect()
        let stream = await fixture.client.events(after: .zero)
        var iterator = stream.makeAsyncIterator()
        let attachment = PromptAttachment(
            id: UUID(uuidString: "24A4623D-6718-46CD-8388-0F6DD9589FE5")!,
            kind: .file,
            displayName: "Release.md",
            source: .localFile(URL(fileURLWithPath: "/private/host/Release.md")),
            byteCount: 512,
            typeHint: "MD"
        )
        let command = makeCommand(
            key: "draft-one",
            epoch: session.hostEpoch,
            deviceID: fixture.deviceID,
            base: session.revision,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Ship the beta",
                attachments: [attachment],
                projectIDs: ["project"],
                agentTargets: [],
                groupID: nil
            ))
        )

        let first = await fixture.client.send(command)
        let duplicate = await fixture.client.send(command)
        let delta = await iterator.next()

        #expect(first.disposition == .accepted)
        #expect(first.revision == StateRevision(rawValue: 1))
        #expect(duplicate == first)
        #expect(delta?.revision == first.revision)
        #expect(delta?.changes == [.draft(.init(
            revision: EntityRevision(rawValue: 1),
            text: "Ship the beta",
            attachments: [GADDraftAttachmentProjection(attachment)],
            platform: nil,
            projectIDs: ["project"],
            agentTargets: [],
            groupID: nil
        ))])

        let sameIdentityDifferentBody = GADCommand(
            id: command.id,
            idempotencyKey: command.idempotencyKey,
            hostEpoch: command.hostEpoch,
            deviceID: command.deviceID,
            baseRevision: command.baseRevision,
            issuedAt: command.issuedAt,
            expiresAt: command.expiresAt,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Different command body",
                projectIDs: ["project"],
                agentTargets: [],
                groupID: nil
            ))
        )
        #expect(await fixture.client.send(sameIdentityDifferentBody).disposition == .rejectedPolicy)

        let stale = makeCommand(
            key: "draft-stale",
            epoch: session.hostEpoch,
            deviceID: fixture.deviceID,
            base: first.revision,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "Overwrite",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            ))
        )
        #expect(await fixture.client.send(stale).disposition == .rejectedStale)
    }

    @Test("A retention-gap resync replaces automation state with the host snapshot")
    func retentionGapResyncIncludesAutomations() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostID = HostID(rawValue: "host-automation-resync")
        let deviceID = DeviceID(rawValue: "phone-automation-resync")
        let epoch = HostEpoch(rawValue: "epoch-automation-resync")
        let automation = AutomationDefinition(
            id: "daily-research",
            name: "Daily research",
            schedule: AutomationSchedule(
                cadence: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: "Europe/Nicosia"
            ),
            actions: [AutomationAction(
                instruction: "Research current changes",
                target: .project(providerID: .codex, projectID: "project")
            )]
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
                automations: AutomationSnapshot(definitions: [automation])
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            journalLimit: 1,
            now: { now }
        )

        let first = await coordinator.send(makeCommand(
            key: "automation-resync-one",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "One",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        ))
        _ = await coordinator.send(makeCommand(
            key: "automation-resync-two",
            epoch: epoch,
            deviceID: deviceID,
            base: first.revision,
            payload: .replaceDraft(.init(
                expectedRevision: EntityRevision(rawValue: 1),
                text: "Two",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        ))

        let stream = await coordinator.events(deviceID: deviceID, after: .zero)
        var iterator = stream.makeAsyncIterator()
        let delta = await iterator.next()

        #expect(delta?.isResyncSnapshot == true)
        #expect(delta?.changes.contains(.automations(
            AutomationSnapshot(definitions: [automation])
        )) == true)
    }

    @Test("Coordinator rejects future-issued and overlong command windows")
    func commandTimeWindowIsBounded() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let fixture = makeCoordinator(capabilities: [.sharedDraft])
        let session = try await fixture.client.connect()
        let payload = GADCommandPayload.replaceDraft(.init(
            expectedRevision: .zero,
            text: "Bounded command",
            projectIDs: [],
            agentTargets: [],
            groupID: nil
        ))
        let futureIssuedAt = now.addingTimeInterval(31)
        let future = GADCommand(
            idempotencyKey: "future",
            hostEpoch: session.hostEpoch,
            deviceID: fixture.deviceID,
            baseRevision: session.revision,
            issuedAt: futureIssuedAt,
            expiresAt: futureIssuedAt.addingTimeInterval(60),
            payload: payload
        )
        let overlong = GADCommand(
            idempotencyKey: "overlong",
            hostEpoch: session.hostEpoch,
            deviceID: fixture.deviceID,
            baseRevision: session.revision,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(121),
            payload: payload
        )

        #expect(await fixture.client.send(future).disposition == .rejectedExpired)
        #expect(await fixture.client.send(overlong).disposition == .rejectedExpired)
    }

    @Test("Coordinator redacts host paths and credentials from failure acknowledgements")
    func coordinatorRedactsFailureAcknowledgements() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let deviceID = DeviceID(rawValue: "phone")
        let coordinator = GADCoordinator(
            hostID: .init(rawValue: "host"),
            hostEpoch: .init(rawValue: "epoch"),
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: .init(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now)
            ),
            capabilities: [.sharedDraft],
            authorizedDevices: [deviceID],
            handler: PathFailureHandler(),
            now: { now }
        )
        let acknowledgement = await coordinator.send(makeCommand(
            key: "redacted-failure",
            epoch: .init(rawValue: "epoch"),
            deviceID: deviceID,
            base: .zero,
            payload: .replaceDraft(.init(
                expectedRevision: .zero,
                text: "trigger",
                projectIDs: [],
                agentTargets: [],
                groupID: nil
            )),
            now: now
        ))

        #expect(acknowledgement.disposition == .failedRecoverable)
        #expect(acknowledgement.message?.contains("/Users/alice") == false)
        #expect(acknowledgement.message?.contains("hunter2") == false)
        #expect(acknowledgement.message?.contains("[redacted-path]") == true)
        #expect(acknowledgement.message?.contains("[redacted-credential]") == true)
    }

    @Test("Run approval requires the exact run, current opaque execution and authentication")
    func approvalRunBinding() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let hostID: HostID = .init(rawValue: "host")
        let deviceID: DeviceID = .init(rawValue: "phone")
        let epoch: HostEpoch = .init(rawValue: "epoch")
        let approvalSession: ApprovalSessionID = .init(rawValue: "approval-session")
        let projection = DashboardProjection(
            generatedAt: now,
            host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            approvals: [.init(
                id: "approval",
                runID: "run",
                assignmentID: "assignment",
                kind: .command,
                summary: "Command approval requested",
                details: nil,
                actions: [.decline, .allowOnce, .allowForRun],
                approvalSessionID: approvalSession,
                expiresAt: now.addingTimeInterval(300)
            )]
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection,
            capabilities: [.runtimeApprovalRun],
            authorizedDevices: [deviceID],
            handler: ApprovalHandler(),
            now: { now }
        )

        let wrongSession = makeCommand(
            key: "wrong-session",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(.init(
                approvalID: "approval",
                runID: "run",
                assignmentID: "assignment",
                action: .allowForRun,
                approvalSessionID: .init(rawValue: "old-session"),
                authorizationAssertion: "authenticated"
            )),
            now: now
        )
        #expect(await coordinator.send(wrongSession).disposition == .rejectedStale)

        let wrongRun = makeCommand(
            key: "wrong-run",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(.init(
                approvalID: "approval",
                runID: "different-run",
                assignmentID: "assignment",
                action: .allowForRun,
                approvalSessionID: approvalSession,
                authorizationAssertion: "authenticated"
            )),
            now: now
        )
        #expect(await coordinator.send(wrongRun).disposition == .rejectedStale)

        let noAuthentication = makeCommand(
            key: "no-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(.init(
                approvalID: "approval",
                runID: "run",
                assignmentID: "assignment",
                action: .allowForRun,
                approvalSessionID: approvalSession
            )),
            now: now
        )
        #expect(await coordinator.send(noAuthentication).disposition == .rejectedPolicy)

        let accepted = makeCommand(
            key: "accepted",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(.init(
                approvalID: "approval",
                runID: "run",
                assignmentID: "assignment",
                action: .allowForRun,
                approvalSessionID: approvalSession,
                authorizationAssertion: "authenticated"
            )),
            now: now
        )
        #expect(await coordinator.send(accepted).disposition == .accepted)
        #expect(try await coordinator.snapshot(deviceID: deviceID).approvals.isEmpty)
    }

    @Test("An up-to-date envelope cannot approve a different automation action than displayed")
    func automationReviewBindsDisplayedAttempt() async throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        let oldAction = AutomationAction(id: "old-action", instruction: "Inspect", target: .project(providerID: .codex, projectID: "project"))
        let nextAction = AutomationAction(id: "next-action", instruction: "Change project", target: oldAction.target)
        let currentPlan = RoutingPlan(id: "next-plan", interpretedGoal: nextAction.instruction, routes: [.init(projectID: "project", agentIDs: ["agent"], reason: "Next action")], risk: .medium, confidence: 1, createdAt: now)
        let occurrence = AutomationOccurrence(id: "occurrence", automationID: "automation", definitionRevision: 1,
            actions: [oldAction, nextAction], trigger: .manual, scheduledAt: now, status: .needsAttention,
            currentActionIndex: 1, attempts: [.init(actionID: oldAction.id, status: .completed), .init(actionID: nextAction.id, plan: currentPlan, status: .waitingForReview)], createdAt: now, updatedAt: now)
        let projection = DashboardProjection(generatedAt: now, host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now), automations: .init(occurrences: [occurrence]))
        let coordinator = GADCoordinator(hostID: hostID, hostEpoch: epoch, initialProjection: projection, capabilities: [.automations], authorizedDevices: [deviceID], handler: AutomationReviewHandler(), now: { now })
        let staleBindings: [AutomationReviewBinding?] = [nil, .init(actionID: oldAction.id, planID: "old-plan"), .init(actionID: nextAction.id, planID: "old-plan")]
        for (index, binding) in staleBindings.enumerated() {
            let command = makeCommand(key: "stale-review-\(index)", epoch: epoch, deviceID: deviceID, base: .zero,
                payload: .reviewAndRunAutomationOccurrence(.init(id: occurrence.id, reviewBinding: binding, authorizationAssertion: "authenticated")), now: now)
            #expect(await coordinator.send(command).disposition == .rejectedStale)
        }
        let matching = makeCommand(key: "matching-review", epoch: epoch, deviceID: deviceID, base: .zero,
            payload: .reviewAndRunAutomationOccurrence(.init(id: occurrence.id, reviewBinding: .init(actionID: nextAction.id, planID: currentPlan.id), authorizationAssertion: "authenticated")), now: now)
        #expect(await coordinator.send(matching).disposition == .accepted)
    }

    @Test("Automation review rejects stale shared-folder scope before dispatch")
    func automationReviewRejectsStaleResourceScope() async throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        let action = AutomationAction(
            id: "action",
            instruction: "Inspect Research",
            target: .project(providerID: .codex, projectID: "project")
        )
        let plan = RoutingPlan(
            id: "automation-run",
            interpretedGoal: action.instruction,
            routes: [ProjectRoute(
                projectID: "project",
                agentIDs: ["agent"],
                reason: "Automation target"
            )],
            risk: .medium,
            confidence: 1,
            createdAt: now
        )
        let occurrence = AutomationOccurrence(
            id: "occurrence",
            automationID: "automation",
            definitionRevision: 1,
            actions: [action],
            trigger: .manual,
            scheduledAt: now,
            status: .needsAttention,
            attempts: [AutomationActionAttempt(
                actionID: action.id,
                plan: plan,
                status: .waitingForReview,
                updatedAt: now
            )],
            createdAt: now,
            updatedAt: now
        )
        let projection = DashboardProjection(
            generatedAt: now,
            host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            resources: [.init(
                id: "research",
                name: "Research",
                access: .readOnly,
                isEnabled: false
            )],
            automations: AutomationSnapshot(occurrences: [occurrence])
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection,
            capabilities: [.automations],
            authorizedDevices: [deviceID],
            handler: AutomationReviewHandler(),
            now: { now }
        )
        let command = makeCommand(
            key: "stale-automation-resource",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .reviewAndRunAutomationOccurrence(.init(
                id: occurrence.id,
                reviewBinding: occurrence.currentReviewBinding,
                authorizationAssertion: "authenticated",
                selectedResourceIDs: ["research"]
            )),
            now: now
        )

        let acknowledgement = await coordinator.send(command)

        #expect(acknowledgement.disposition == .rejectedStale)
        #expect(acknowledgement.message?.contains("shared-folder scope changed") == true)
    }

    @Test("Allow Once requires local device authentication")
    func approvalOnceAuthentication() async throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let hostID: HostID = .init(rawValue: "host")
        let deviceID: DeviceID = .init(rawValue: "phone")
        let epoch: HostEpoch = .init(rawValue: "epoch")
        let projection = DashboardProjection(
            generatedAt: now,
            host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            approvals: [.init(
                id: "approval-once",
                runID: "run",
                assignmentID: "assignment",
                kind: .command,
                summary: "Command approval requested",
                details: nil,
                actions: [.decline, .allowOnce],
                approvalSessionID: nil,
                expiresAt: now.addingTimeInterval(300)
            )]
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: projection,
            capabilities: [.runtimeApprovalOnce],
            authorizedDevices: [deviceID],
            handler: ApprovalHandler(),
            now: { now }
        )

        let response = GADApprovalResponse(
            approvalID: "approval-once",
            runID: "run",
            assignmentID: "assignment",
            action: .allowOnce
        )
        #expect(await coordinator.send(makeCommand(
            key: "once-without-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(response),
            now: now
        )).disposition == .rejectedPolicy)

        let authenticated = GADApprovalResponse(
            approvalID: response.approvalID,
            runID: response.runID,
            assignmentID: response.assignmentID,
            action: .allowOnce,
            authorizationAssertion: "user-presence-required"
        )
        #expect(await coordinator.send(makeCommand(
            key: "once-with-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .respondToApproval(authenticated),
            now: now
        )).disposition == .accepted)
    }

    @Test("A paired device must assert local authorization before enabling recurring automatic approvals")
    func automationGrantAuthentication() async throws {
        let now = Date(timeIntervalSince1970: 14_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        let definition = AutomationDefinition(
            id: "automatic",
            name: "Automatic review",
            schedule: AutomationSchedule(cadence: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC"),
            actions: [AutomationAction(
                id: "review", instruction: "Improve the project",
                target: .project(providerID: .codex, projectID: "project")
            )],
            automaticallyApproveRuntimeRequests: true
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now)
            ),
            capabilities: [.automations],
            authorizedDevices: [deviceID],
            handler: ApprovalHandler(),
            now: { now }
        )
        let command = makeCommand(
            key: "automatic-without-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .saveAutomation(.init(automation: definition, expectedRevision: nil)),
            now: now
        )
        #expect(await coordinator.send(command).disposition == .rejectedPolicy)
    }

    @Test("Sensitive plan start requires local device authentication")
    func planStartAuthentication() async throws {
        let now = Date(timeIntervalSince1970: 15_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        let plan = GADPlanProjection(
            id: "plan",
            goal: "Prepare the release",
            routes: [.init(projectID: "project", agentIDs: ["agent"], reason: "Release work")],
            risk: .medium,
            confidence: 0.9,
            gitOperations: [],
            warnings: [],
            selectedResourceIDs: [],
            createdAt: now
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: epoch,
            initialProjection: DashboardProjection(
                generatedAt: now,
                host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
                plan: plan
            ),
            capabilities: [.planReview],
            authorizedDevices: [deviceID],
            handler: PlanStartHandler(),
            now: { now }
        )

        let unauthenticated = makeCommand(
            key: "start-without-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .startRun(.init(planID: plan.id)),
            now: now
        )
        #expect(await coordinator.send(unauthenticated).disposition == .rejectedPolicy)

        let authenticated = makeCommand(
            key: "start-with-auth",
            epoch: epoch,
            deviceID: deviceID,
            base: .zero,
            payload: .startRun(.init(
                planID: plan.id,
                authorizationAssertion: "user-presence-required"
            )),
            now: now
        )
        #expect(await coordinator.send(authenticated).disposition == .accepted)
        #expect(try await coordinator.snapshot(deviceID: deviceID).plan == nil)
    }

    @Test("A host-approved trusted plan starts from any device without authentication")
    func trustedPlanStartsWithoutAuthentication() async throws {
        let now = Date(timeIntervalSince1970: 15_050)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let epoch = HostEpoch(rawValue: "epoch")
        func makePlan(trusted: Bool) -> GADPlanProjection {
            GADPlanProjection(
                id: "plan",
                goal: "Tighten the landing copy",
                routes: [.init(projectID: "project", agentIDs: ["agent"], reason: "Web work")],
                risk: .medium,
                confidence: 0.9,
                gitOperations: [.init(id: UUID(), projectID: "project", kind: .createWorktree, branch: "goby/copy", remote: nil)],
                warnings: [],
                selectedResourceIDs: [],
                createdAt: now,
                startsWithoutReview: trusted
            )
        }
        func makeCoordinator(_ plan: GADPlanProjection) -> GADCoordinator {
            GADCoordinator(
                hostID: hostID,
                hostEpoch: epoch,
                initialProjection: DashboardProjection(
                    generatedAt: now,
                    host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now),
                    plan: plan
                ),
                capabilities: [.planReview],
                authorizedDevices: [deviceID],
                handler: PlanStartHandler(),
                now: { now }
            )
        }

        let trusted = makeCoordinator(makePlan(trusted: true))
        let start = makeCommand(
            key: "trusted-start", epoch: epoch, deviceID: deviceID, base: .zero,
            payload: .startRun(.init(planID: "plan")), now: now
        )
        #expect(await trusted.send(start).disposition == .accepted)

        // Asking to auto-approve runtime requests is never covered by trust.
        let autoApproving = makeCoordinator(makePlan(trusted: true))
        let broad = makeCommand(
            key: "trusted-auto-approve", epoch: epoch, deviceID: deviceID, base: .zero,
            payload: .startRun(.init(planID: "plan", automaticallyApproveRuntimeRequests: true)), now: now
        )
        #expect(await autoApproving.send(broad).disposition == .rejectedPolicy)

        let untrusted = makeCoordinator(makePlan(trusted: false))
        #expect(await untrusted.send(start).disposition == .rejectedPolicy)
    }

    @Test("Trust flags are omitted from the wire unless set")
    func trustFlagsAreAdditive() throws {
        let now = Date(timeIntervalSince1970: 15_060)
        let plain = GADPlanProjection(
            id: "plan", goal: "Goal", routes: [], risk: .readOnly, confidence: 1,
            gitOperations: [], warnings: [], selectedResourceIDs: [], createdAt: now
        )
        let project = GADProjectProjection(id: "p", name: "P", platforms: [], frameworks: [], isGitRepository: true)
        let encoder = JSONEncoder()
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("startsWithoutReview"))
        #expect(!String(decoding: try encoder.encode(project), as: UTF8.self).contains("isTrusted"))
        let trustedProject = GADProjectProjection(id: "p", name: "P", platforms: [], frameworks: [], isGitRepository: true, isTrusted: true)
        let decoded = try JSONDecoder().decode(GADProjectProjection.self, from: try encoder.encode(trustedProject))
        #expect(decoded.isTrusted == true)
    }

    @Test("Plan start ignores only journal-proven background revisions")
    func planStartAllowsUnrelatedActivity() async throws {
        let now = Date(timeIntervalSince1970: 15_100)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "desktop")
        let epoch = HostEpoch(rawValue: "epoch")
        let plan = GADPlanProjection(
            id: "plan", goal: "Review analytics",
            routes: [.init(projectID: "project", agentIDs: ["agent"], reason: "Selected")],
            risk: .readOnly, confidence: 1, gitOperations: [], warnings: [],
            selectedResourceIDs: [], createdAt: now
        )
        let host = GADHostProjection(
            id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now
        )
        let coordinator = GADCoordinator(
            hostID: hostID, hostEpoch: epoch,
            initialProjection: DashboardProjection(generatedAt: now, host: host, plan: plan),
            capabilities: [.planReview], authorizedDevices: [deviceID],
            handler: PlanStartHandler(), now: { now }
        )
        _ = await coordinator.synchronize(DashboardProjection(
            generatedAt: now, host: .init(
                id: hostID, displayName: "Updated Mac", reachability: .online, lastUpdatedAt: now
            ), plan: plan
        ))
        let command = makeCommand(
            key: "start-after-background", epoch: epoch, deviceID: deviceID,
            base: .zero, payload: .startRun(.init(planID: plan.id)), now: now
        )
        #expect(await coordinator.send(command).disposition == .accepted)
    }

    @Test("Plan start rejects a stale review after the plan changes")
    func planStartRejectsChangedPlan() async throws {
        let now = Date(timeIntervalSince1970: 15_200)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "desktop")
        let epoch = HostEpoch(rawValue: "epoch")
        func plan(_ goal: String) -> GADPlanProjection {
            .init(
                id: "plan", goal: goal,
                routes: [.init(projectID: "project", agentIDs: ["agent"], reason: "Selected")],
                risk: .readOnly, confidence: 1, gitOperations: [], warnings: [],
                selectedResourceIDs: [], createdAt: now
            )
        }
        let host = GADHostProjection(
            id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now
        )
        let coordinator = GADCoordinator(
            hostID: hostID, hostEpoch: epoch,
            initialProjection: DashboardProjection(generatedAt: now, host: host, plan: plan("Original")),
            capabilities: [.planReview], authorizedDevices: [deviceID],
            handler: PlanStartHandler(), now: { now }
        )
        _ = await coordinator.synchronize(DashboardProjection(
            generatedAt: now, host: host, plan: plan("Changed")
        ))
        let command = makeCommand(
            key: "start-after-plan-change", epoch: epoch, deviceID: deviceID,
            base: .zero, payload: .startRun(.init(planID: "plan")), now: now
        )
        #expect(await coordinator.send(command).disposition == .rejectedStale)
    }

    @Test("The current protocol advertises provider activity and reviewed handoffs")
    func providerProtocolNegotiation() async throws {
        let fixture = makeCoordinator(capabilities: [
            .sharedDraft,
            .providerActivity,
            .manualHandoffs,
            .providerBindingInstructions
        ])
        let session = try await fixture.client.connect()

        #expect(session.protocolVersion == .current)
        #expect(session.capabilities.contains(.providerActivity))
        #expect(session.capabilities.contains(.manualHandoffs))
        #expect(session.capabilities.contains(.providerBindingInstructions))
    }

    @Test("The production host advertises every implemented mobile automation command")
    func productionHostAdvertisesAutomations() {
        #expect(GADCapability.productionHost.contains(.automations))
        #expect(GADCapability.productionHost.contains(.notifications))
        #expect(GADCapability.productionHost.contains(.runtimeApprovalOnce))
    }

    @Test("A v1 snapshot migrates its Codex state into provider-neutral sections")
    func legacySnapshotMigration() throws {
        let now = Date(timeIntervalSince1970: 19_000)
        let original = DashboardProjection(
            generatedAt: now,
            host: .init(
                id: .init(rawValue: "host"),
                displayName: "Mac",
                reachability: .online,
                lastUpdatedAt: now
            ),
            draft: .init(text: "Continue", providerID: .codex, projectIDs: ["project"]),
            projects: [.init(
                id: "project",
                name: "Atlas",
                platforms: [.iOS],
                frameworks: ["SwiftUI"],
                isGitRepository: true,
                providerIDs: [.codex]
            )],
            codexTasks: [.init(
                id: "legacy-task",
                projectID: "project",
                title: "Live work",
                summary: nil,
                status: .active,
                updatedAt: now
            )],
            account: .init(
                authenticated: true,
                planName: "Pro",
                usedPercent: 9,
                resetsAt: nil,
                secondaryUsedPercent: nil,
                secondaryResetsAt: nil
            )
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in ["providerAccounts", "providerTasks", "providerBindings", "handoffLinks", "handoffs"] {
            object.removeValue(forKey: key)
        }
        if var draft = object["draft"] as? [String: Any] {
            draft.removeValue(forKey: "providerID")
            object["draft"] = draft
        }
        if var projects = object["projects"] as? [[String: Any]], !projects.isEmpty {
            projects[0].removeValue(forKey: "providerIDs")
            object["projects"] = projects
        }

        let decoded = try JSONDecoder().decode(
            DashboardProjection.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.draft.providerID == .codex)
        #expect(decoded.projects.first?.providerIDs == [.codex])
        #expect(decoded.providerAccounts.first?.providerID == .codex)
        #expect(decoded.providerAccounts.first?.planName == "Pro")
        #expect(decoded.providerTasks.first?.providerID == .codex)
        #expect(decoded.providerTasks.first?.id == "legacy-task")
        #expect(decoded.providerTasks.first?.status == .working)
        #expect(decoded.providerBindings.isEmpty)
        #expect(decoded.handoffs.isEmpty)
    }

    @Test("Remote projection excludes paths, commands, instruction bodies and provider handles")
    func projectionRedaction() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let secretRoot = "/Users/example/Secret Project"
        let secretCommand = "npm run private-test"
        let secretInstruction = "Never reveal internal launch strategy"
        let secretAttachmentPath = "/Users/example/Private/Release.md"
        let secretSnippet = "private_release_token_placeholder"
        let secretProviderAccount = "claude-secret@example.com"
        let secretProviderTaskID = "claude-native-task-secret"
        let secretProviderAgentID = "claude-native-agent-secret"
        let secretApprovalID = "provider-native-approval-secret"
        let genericSecrets = "AWS_SECRET_ACCESS_KEY=verySecretMaterial123 postgres://alice:correct-horse@example.com/private eyJabcdefghijk.eyJlmnopqrstuvwxyz.abcdefghijklmnopqrstuvwxyz xoxb-123456789-secretvalue"
        let exactProviderCredential = "opaque-provider-material-314159"
        let project = LabProject(
            id: "project",
            name: "Atlas",
            rootURL: URL(fileURLWithPath: secretRoot),
            platforms: [.web],
            testCommands: [secretCommand],
            instructionFiles: [URL(fileURLWithPath: "\(secretRoot)/AGENTS.md")],
            isGitRepository: true
        )
        let agent = AgentProfile(
            id: "agent",
            name: "Web Agent",
            summary: "Works in \(secretRoot)",
            instructions: secretInstruction,
            capabilities: [.web],
            scope: .project(project.id),
            sourceURL: URL(fileURLWithPath: "\(secretRoot)/.codex/agents/web.toml"),
            codexRegistrationKey: "private_web"
        )
        let run = RunRecord(
            id: "run",
            plan: .init(
                interpretedGoal: "Run \(secretCommand) with \(secretAttachmentPath) and \(secretSnippet)",
                attachments: [
                    .init(
                        kind: .file,
                        displayName: "Release.md",
                        source: .localFile(URL(fileURLWithPath: secretAttachmentPath))
                    ),
                    .init(kind: .snippet, displayName: "Text snippet", source: .text(secretSnippet)),
                ],
                routes: [],
                risk: .readOnly,
                confidence: 1
            ),
            status: .running,
            assignments: [.init(
                id: "assignment",
                runID: "run",
                projectID: project.id,
                agentID: agent.id,
                status: .working,
                currentTask: "Working at \(secretRoot) \(genericSecrets)",
                workingDirectory: URL(fileURLWithPath: secretRoot),
                codexThreadID: "thread-secret",
                codexTurnID: "turn-secret"
            )],
            instructionSnapshot: [.init(name: "Private", body: secretInstruction, scope: .allProjects)],
            agentSnapshot: [agent],
            journal: [RunJournalEntry(
                kind: .assignmentChanged,
                message: "Working safely",
                assignmentID: "assignment",
                occurredAt: now
            )]
        )
        let approval = ProviderApprovalRequest(
            id: secretApprovalID,
            assignmentID: "assignment",
            kind: .command,
            summary: "Execute \(secretCommand)",
            details: secretRoot,
            approvalSessionID: .init(rawValue: "safe-session"),
            operationDigest: String(repeating: "a", count: 64),
            disclosureComplete: true
        )
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: .init(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero,
            draft: .init(
                text: "Continue with \(exactProviderCredential)",
                attachments: [.init(
                    id: UUID(),
                    kind: .file,
                    displayName: "\(exactProviderCredential).txt",
                    typeHint: "\(exactProviderCredential)-type"
                )],
                model: "model-\(exactProviderCredential)"
            ),
            lab: .init(
                projects: [project],
                agents: [agent],
                projectProviderConfigurations: [.init(
                    projectID: project.id,
                    providerIDs: [.codex, .claude]
                )],
                providerBindings: [.init(
                    providerID: .claude,
                    agentID: agent.id,
                    projectID: project.id,
                    nativeID: secretProviderAgentID,
                    capabilities: [.web],
                    instructionsOverride: secretInstruction
                )]
            ),
            runs: [run],
            approvals: [approval],
            resources: [.init(name: "Private Reference", url: URL(fileURLWithPath: "\(secretRoot)/Reference"))],
            instructions: [.init(name: "Private", body: secretInstruction, scope: .allProjects)],
            codexTasks: [.init(id: "raw-codex-id", projectID: project.id, title: "Task", status: .active, updatedAt: now)],
            account: .init(authenticated: true, displayName: "private@example.com", planName: "Pro", usedPercent: 5),
            providerAccounts: [.init(
                providerID: .claude,
                connectionState: .connected(version: "1"),
                displayName: secretProviderAccount,
                organizationName: "Private organization",
                planName: "Team",
                selectedModel: "claude-model",
                usage: [],
                observedAt: now
            )],
            providerTasks: [.init(
                identity: .init(providerID: .claude, nativeID: secretProviderTaskID),
                projectID: project.id,
                title: "Claude task",
                status: .working,
                updatedAt: now,
                agentRole: "Web Agent"
            )],
            health: .init(checks: []),
            exactForbiddenValues: [exactProviderCredential],
            generatedAt: now
        )
        let text = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)

        for forbidden in [
            secretRoot,
            secretCommand,
            secretInstruction,
            secretAttachmentPath,
            secretSnippet,
            "thread-secret",
            "turn-secret",
            "raw-codex-id",
            "private@example.com",
            secretProviderAccount,
            secretProviderTaskID,
            secretProviderAgentID,
            secretApprovalID,
            "verySecretMaterial123",
            "correct-horse",
            "eyJabcdefghijk.eyJlmnopqrstuvwxyz.abcdefghijklmnopqrstuvwxyz",
            "xoxb-123456789-secretvalue",
            exactProviderCredential,
        ] {
            #expect(!text.contains(forbidden))
        }
        #expect(projection.resources.first?.name == "Private Reference")
        #expect(projection.instructions.first?.name == "Private")
        #expect(projection.approvals.first?.details == nil)
        #expect(projection.approvals.first?.id == approval.routingID)
        #expect(projection.approvals.first?.operationDigest == nil)
        #expect(!text.contains(String(repeating: "a", count: 64)))
        #expect(projection.approvals.first?.actions.contains(.allowForRun) == false)
        #expect(projection.projects.first?.providerIDs == [.claude, .codex])
        #expect(projection.projects.first?.approvalOrdinal == 1)
        #expect(projection.resources.first?.approvalOrdinal == 1)
        #expect(projection.providerAccounts.first?.providerID == .claude)
        #expect(projection.providerTasks.first?.providerID == .claude)
        #expect(projection.providerTasks.first?.id != secretProviderTaskID)
        #expect(projection.providerTasks.first?.agentID == agent.id)
        #expect(projection.runs.first?.journal.first?.assignmentID == "assignment")
        #expect(projection.providerBindings.first?.providerID == .claude)
        #expect(projection.providerBindings.first?.hasInstructionsOverride == true)
    }

    @Test("Short agent metadata cannot erase an ordinary platform name from a draft")
    func shortAgentMetadataDoesNotRedactIOS() {
        let now = Date(timeIntervalSince1970: 20_100)
        let project = LabProject(
            id: "ios-project", name: "App", rootURL: URL(fileURLWithPath: "/tmp/goby-ios-project"),
            platforms: [.iOS], isGitRepository: false
        )
        let agent = AgentProfile(
            id: "ios-agent", name: "iOS", summary: "Checks iOS compatibility",
            instructions: "iOS", capabilities: [.iOS], scope: .project(project.id),
            codexRegistrationKey: "iOS"
        )
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero,
            draft: .init(text: "check if iOS is compatible with latest changes"),
            lab: .init(projects: [project], agents: [agent]), runs: [], approvals: [],
            resources: [], codexTasks: [], account: nil,
            health: .init(checks: []), generatedAt: now
        )
        #expect(projection.draft.text == "check if iOS is compatible with latest changes")
    }

    @Test("Projecting a plan request keeps the canonical draft text")
    func planSlashCommandSurvivesDraftProjection() {
        let now = Date(timeIntervalSince1970: 20_200)
        let request = "web analytics dont look good. build a /plan on how to attract users"
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: HostID(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero, draft: .init(text: request), lab: .empty,
            runs: [], approvals: [], resources: [], codexTasks: [], account: nil,
            health: .init(checks: []), generatedAt: now
        )

        #expect(projection.draft.text == request)
    }


    @Test("Duplicate-name project and resource ordinals correlate by stable identity")
    func projectionApprovalOrdinals() {
        let now = Date(timeIntervalSince1970: 21_000)
        let projects = [
            LabProject(
                id: "project-b",
                name: "App",
                rootURL: URL(fileURLWithPath: "/tmp/project-b"),
                platforms: [.general],
                isGitRepository: false
            ),
            LabProject(
                id: "project-a",
                name: "App",
                rootURL: URL(fileURLWithPath: "/tmp/project-a"),
                platforms: [.general],
                isGitRepository: false
            ),
        ]
        let resources = [
            SharedResource(id: "resource-b", name: "Reference", url: URL(fileURLWithPath: "/tmp/resource-b")),
            SharedResource(id: "resource-a", name: "Reference", url: URL(fileURLWithPath: "/tmp/resource-a")),
        ]
        let projection = RemoteProjectionBuilder().build(
            host: .init(id: .init(rawValue: "host"), displayName: "Mac", reachability: .online, lastUpdatedAt: now),
            revision: .zero,
            lab: .init(projects: projects, agents: []),
            runs: [],
            approvals: [],
            resources: resources,
            codexTasks: [],
            account: nil,
            health: .init(checks: []),
            generatedAt: now
        )

        #expect(Dictionary(uniqueKeysWithValues: projection.projects.map {
            ($0.id.rawValue, $0.approvalOrdinal)
        }) == ["project-a": 1, "project-b": 2])
        #expect(Dictionary(uniqueKeysWithValues: projection.resources.map {
            ($0.id.rawValue, $0.approvalOrdinal)
        }) == ["resource-a": 1, "resource-b": 2])
    }

    @Test("Remote New Project accepts only credential-free public HTTPS sources")
    func remoteNewProjectSourcePolicy() throws {
        #expect(try GADNewProjectSourceIntent.gitClone(
            repository: "  https://github.com/example/project.git  "
        ).validatedRemoteSource() == .gitClone(
            repository: "https://github.com/example/project.git"
        ))
        #expect(try GADNewProjectSourceIntent.blank.validatedRemoteSource() == .blank)

        let rejected = [
            "/Users/example/private-repository",
            "file:///Users/example/private-repository",
            "ssh://git@example.com/project.git",
            "git@example.com:project.git",
            "https://user:secret@example.com/project.git",
            "https://example.com/project.git?token=secret",
            "https://localhost/project.git",
            "https://127.0.0.1/project.git",
            "https://192.168.1.10/project.git",
            "https://git.internal/project.git",
        ]
        for repository in rejected {
            #expect(throws: GADCommandFailure.self) {
                try GADNewProjectSourceIntent.gitClone(repository: repository)
                    .validatedRemoteSource()
            }
        }
    }

    private func makeCoordinator(capabilities: Set<GADCapability>) -> (client: LocalGobyClient, deviceID: DeviceID) {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostID = HostID(rawValue: "host")
        let deviceID = DeviceID(rawValue: "phone")
        let projection = DashboardProjection(
            generatedAt: now,
            host: .init(id: hostID, displayName: "Mac", reachability: .online, lastUpdatedAt: now)
        )
        let coordinator = GADCoordinator(
            hostID: hostID,
            hostEpoch: .init(rawValue: "epoch"),
            initialProjection: projection,
            capabilities: capabilities,
            authorizedDevices: [deviceID],
            handler: ProjectionGADCommandHandler(),
            now: { now }
        )
        return (LocalGobyClient(coordinator: coordinator, deviceID: deviceID), deviceID)
    }

    private func makeCommand(
        key: String,
        epoch: HostEpoch,
        deviceID: DeviceID,
        base: StateRevision,
        payload: GADCommandPayload,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GADCommand {
        GADCommand(
            id: .init(rawValue: key),
            idempotencyKey: key,
            hostEpoch: epoch,
            deviceID: deviceID,
            baseRevision: base,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60),
            payload: payload
        )
    }
}

private actor RevocationCommandSuspension {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private actor RevocationCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private struct RevocationSuspendingCommandHandler: GADCommandHandling {
    let suspension: RevocationCommandSuspension

    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect {
        await suspension.suspend()
        guard case let .replaceDraft(replacement) = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported")
        }
        return GADCommandEffect(changes: [.draft(.init(
            revision: replacement.expectedRevision.advanced(),
            text: replacement.text,
            attachments: replacement.attachments.map(GADDraftAttachmentProjection.init),
            platform: replacement.platform,
            projectIDs: replacement.projectIDs,
            agentTargets: replacement.agentTargets,
            groupID: replacement.groupID
        ))])
    }
}

private struct ApprovalHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        guard case .respondToApproval = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported")
        }
        return GADCommandEffect(changes: [.approvals([])])
    }
}

private struct PlanStartHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        guard case .startRun = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported")
        }
        return GADCommandEffect(changes: [.plan(nil)])
    }
}

private struct AutomationReviewHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        guard case .reviewAndRunAutomationOccurrence = payload else {
            throw GADCommandFailure(.rejectedCapability, "Unsupported")
        }
        return GADCommandEffect(changes: [])
    }
}

private struct PathFailureHandler: GADCommandHandling {
    func apply(
        _ payload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) throws -> GADCommandEffect {
        throw GADCommandFailure(
            .failedRecoverable,
            "Agent changed at /Users/alice/Secret Project/.codex/agents/reviewer.toml; password is hunter2"
        )
    }
}
