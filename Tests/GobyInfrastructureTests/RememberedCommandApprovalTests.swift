import Foundation
import GobyApplication
import GobyDomain
import Synchronization
import Testing
@testable import GobyInfrastructure

struct RememberedCommandApprovalTests {
    @Test("Project switches pause and restore saved rules without losing them")
    func projectSwitchPersistence() async throws {
        let io = RuleMemoryIO()
        let store = KeychainRememberedCommandApprovals(stateIO: io)
        let project = sampleRule()
        let file = RememberedCommandApproval(
            providerID: .codex, projectID: project.projectID, projectName: project.projectName,
            fileChangeScope: .init(workingDirectory: "/tmp/project"),
            authorizationDigest: "file-authority"
        )
        let other = sampleRule(project: "other")
        try await store.save(project)
        try await store.save(file)
        try await store.save(other)

        try await store.setProjectEnabled(project.projectID, enabled: false)
        let paused = try await store.all()
        #expect(paused.filter { $0.projectID == project.projectID }.count == 2)
        #expect(paused.filter { $0.projectID == project.projectID }.allSatisfy { !$0.isEnabled })
        #expect(paused.first(where: { $0.projectID == other.projectID })?.isEnabled == true)
        let data = try #require(io.load())
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(document["version"] as? Int == 3)

        let restarted = KeychainRememberedCommandApprovals(stateIO: io)
        #expect(try await restarted.all().first(where: { $0.projectID == project.projectID })?.isEnabled == false)
        try await restarted.setProjectEnabled(project.projectID, enabled: true)
        #expect(try await restarted.all().allSatisfy(\.isEnabled))
        #expect(try await restarted.all().count == 3)
    }

    @Test("Paused project requests ask again; resuming restores only the saved exact rule")
    func projectSwitchStopsAutomaticDecision() async throws {
        let fixture = try RuleRunFixture()
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        try await fixture.orchestrator.respond(to: first, decision: .acceptAlways)
        try await fixture.orchestrator.setRememberedApprovalProjectEnabled("project", enabled: false)
        await fixture.runtime.emit(sequence: 2)
        let paused = try await fixture.pending()
        #expect(paused.summary == "git status --short")
        #expect(await fixture.runtime.decisions == [.accept])
        try await fixture.orchestrator.respond(to: paused, decision: .accept)
        try await fixture.orchestrator.setRememberedApprovalProjectEnabled("project", enabled: true)
        await fixture.runtime.emit(sequence: 3)
        try await eventually { await fixture.runtime.decisions == [.accept, .accept, .accept] }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        await fixture.runtime.emit(sequence: 4, command: "swift build")
        let newCommand = try await fixture.pending()
        #expect(newCommand.summary == "swift build")
        #expect(await fixture.runtime.decisions == [.accept, .accept, .accept])
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Run authorization accepts new in-scope commands but stops expanded or protected requests")
    func runAuthorization() async throws {
        let fixture = try RuleRunFixture(uninterrupted: true, initialCommand: "swift test")
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        try await eventually { await fixture.runtime.decisions == [.accept] }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        await fixture.runtime.emit(sequence: 2, command: "swift build")
        try await eventually { await fixture.runtime.decisions == [.accept, .accept] }
        await fixture.runtime.emit(sequence: 3, command: "zsh -lc 'swift test'")
        try await eventually { await fixture.runtime.decisions == [.accept, .accept, .accept] }
        await fixture.runtime.emit(sequence: 4, command: "git push origin main")
        let protected = try await fixture.pending()
        #expect(protected.summary == "git push origin main")
        #expect(await fixture.runtime.decisions == [.accept, .accept, .accept])
        try await fixture.orchestrator.respond(to: protected, decision: .decline)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value

        let expanded = commandRequest(command: "swift test", extra: [
            "additionalPermissions": .object(["network": .object(["enabled": .bool(true)])])
        ])
        let projected = ProviderApprovalRequest(
            id: expanded.id, assignmentID: expanded.assignmentID, kind: .command,
            summary: expanded.summary, details: expanded.details,
            operationDigest: expanded.operationDigest,
            rememberedCommandScope: CodexRememberedCommandScope.scope(for: expanded)
        )
        #expect(!RunRuntimeApprovalPolicy.commandIsWithinScope(projected, command: "swift test"))
    }

    @Test("A proposed reusable policy does not block a one-shot automatic allow")
    func proposedPolicyUsesOneShotDecision() async throws {
        let request = commandRequest(command: "swift test", extra: [
            "proposedExecpolicyAmendment": .array([.string("swift")]),
            "availableDecisions": .array([.string("accept"), .string("acceptWithExecpolicyAmendment")]),
        ])
        let projected = ProviderApprovalRequest(
            id: request.id, assignmentID: request.assignmentID, kind: .command,
            summary: request.summary, details: request.details,
            operationDigest: request.operationDigest,
            disclosureComplete: request.disclosureComplete
        )
        #expect(RunRuntimeApprovalPolicy.commandIsWithinScope(projected, command: "swift test"))
    }

    @Test("Shell wrappers cannot hide protected Git or destructive operations from a run grant")
    func shellWrappedProtectedCommands() {
        for command in ["zsh -lc 'git push origin main'", "bash -c 'rm -rf build'", "git -C . -c core.bare=false commit -m test"] {
            let request = commandRequest(command: command)
            let projected = ProviderApprovalRequest(
                id: request.id, assignmentID: request.assignmentID, kind: .command,
                summary: request.summary, details: request.details,
                operationDigest: request.operationDigest,
                disclosureComplete: request.disclosureComplete
            )
            #expect(!RunRuntimeApprovalPolicy.commandIsWithinScope(projected, command: command))
        }
    }

    @Test("An all-approval grant still requires a complete, unchanged Codex operation")
    func broadGrantRequiresExactOperationBinding() {
        let request = commandRequest(command: "swift test")
        let bound = ProviderApprovalRequest(
            id: request.id, assignmentID: request.assignmentID, kind: .command,
            summary: request.summary, details: request.details,
            operationDigest: request.operationDigest,
            disclosureComplete: request.disclosureComplete
        )
        #expect(RunRuntimeApprovalPolicy.completeCodexOperationIsBound(bound))
        let changed = ProviderApprovalRequest(
            id: request.id, assignmentID: request.assignmentID, kind: .command,
            summary: request.summary, details: request.details,
            operationDigest: String(repeating: "0", count: 64),
            disclosureComplete: true
        )
        #expect(!RunRuntimeApprovalPolicy.completeCodexOperationIsBound(changed))
        let wrongKind = ProviderApprovalRequest(
            id: request.id, assignmentID: request.assignmentID, kind: .permissions,
            summary: request.summary, details: request.details,
            operationDigest: request.operationDigest,
            disclosureComplete: true
        )
        #expect(!RunRuntimeApprovalPolicy.completeCodexOperationIsBound(wrongKind))
    }

    @Test("Run authorization allows in-folder edits and stops escaping patches")
    func runAuthorizationFileScope() async throws {
        let fixture = try RuleRunFixture(fileChanges: true, uninterrupted: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        try await eventually { await fixture.runtime.decisions == [.accept] }
        await fixture.runtime.emitFile(sequence: 2, path: "Sources/Another.swift")
        try await eventually { await fixture.runtime.decisions == [.accept, .accept] }
        await fixture.runtime.emitFile(sequence: 3, path: "../Outside.swift")
        _ = try await fixture.pending()
        #expect(await fixture.runtime.decisions == [.accept, .accept])
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Pushing an earlier run's branch starts no agent")
    func pushOnlyRunsNoAgent() async throws {
        let fixture = try RuleRunFixture(pushOnly: true)
        defer { fixture.remove() }
        try await fixture.orchestrator.execute(runID: fixture.run.id)
        try await eventually {
            await fixture.repository.record.assignments.first?.status == .completed
        }
        #expect(await fixture.runtime.started == false)
    }

    @Test("Run switch cannot auto-approve high-risk, ungranted automation, or separately approved Git work",
          arguments: ["risk", "automation", "git"])
    func runAuthorizationExclusions(boundary: String) async throws {
        let fixture = try RuleRunFixture(
            highRisk: boundary == "risk", separateGit: boundary == "git",
            automation: boundary == "automation", uninterrupted: true,
            initialCommand: "swift test"
        )
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        _ = try await fixture.pending()
        #expect(await fixture.runtime.decisions.isEmpty)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("An automation grant accepts distinct, expanded, protected and permission approvals until provenance changes")
    func automationRuntimeGrant() async throws {
        let fixture = try RuleRunFixture(automation: true, automationGrant: true,
                                         uninterrupted: true, initialCommand: "swift test")
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        try await eventually { await fixture.runtime.decisions == [.accept] }
        await fixture.runtime.emit(sequence: 2, command: "git push origin main")
        try await eventually { await fixture.runtime.decisions == [.accept, .accept] }
        await fixture.runtime.emitCommand(
            sequence: 3,
            command: "swift build",
            extra: ["additionalPermissions": .object(["network": .object(["enabled": .bool(true)])])]
        )
        try await eventually { await fixture.runtime.decisions == [.accept, .accept, .accept] }
        await fixture.runtime.emitPermissions(sequence: 4)
        try await eventually { await fixture.runtime.decisions == [.accept, .accept, .accept, .accept] }
        await fixture.runtime.emitFile(sequence: 5, path: "Sources/Automated.swift")
        try await eventually { await fixture.runtime.decisions == [.accept, .accept, .accept, .accept, .accept] }
        await fixture.repository.removeAutomationProvenance()
        await fixture.runtime.emit(sequence: 6, command: "swift test")
        _ = try await fixture.pending()
        #expect(await fixture.runtime.decisions == [.accept, .accept, .accept, .accept, .accept])
        let approvalJournal = await fixture.repository.record.journal.filter {
            $0.kind == .approval && $0.message.hasPrefix("Automatically accepted Codex")
        }
        #expect(approvalJournal.count == 5)
        #expect(approvalJournal.allSatisfy { !$0.message.contains("git push") })
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Revoking an automation grant during runtime lookup leaves its request pending")
    func automationGrantRevokedDuringLookup() async throws {
        let fixture = try RuleRunFixture(automation: true, automationGrant: true,
                                         uninterrupted: true, deferInitialApproval: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        try await eventually { await fixture.runtime.started }
        await fixture.resolver.holdNextRead()
        await fixture.runtime.emit(sequence: 1, command: "swift test")
        try await eventually { await fixture.resolver.readIsHeld }
        await fixture.repository.removeAutomationProvenance()
        await fixture.resolver.releaseRead()
        _ = try await fixture.pending()
        #expect(await fixture.runtime.decisions.isEmpty)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Only request-instance metadata may vary in a remembered Codex command")
    func exactAdapterScope() throws {
        let first = try #require(CodexRememberedCommandScope.scope(for: commandRequest()))
        let repeated = try #require(CodexRememberedCommandScope.scope(for: commandRequest(sequence: 2)))
        #expect(first == repeated)
        #expect(first != CodexRememberedCommandScope.scope(for: commandRequest(command: "git status --porcelain")))
        #expect(first != CodexRememberedCommandScope.scope(for: commandRequest(directory: "/tmp/other")))
        #expect(first != CodexRememberedCommandScope.scope(for: commandRequest(extra: ["additionalPermissions": .object(["network": .object(["enabled": .bool(true)])])])))
        #expect(CodexRememberedCommandScope.scope(for: commandRequest(extra: ["unknownExecutableField": .string("other")])) == nil)
        #expect(CodexRememberedCommandScope.scope(for: commandRequest(extra: ["availableDecisions": .array([.string("cancel")])])) == nil)
        let request = commandRequest()
        #expect(CodexRememberedCommandScope.scope(for: .init(
            id: request.id, assignmentID: request.assignmentID, kind: .command,
            summary: request.summary, details: request.details,
            operationDigest: String(repeating: "0", count: 64), disclosureComplete: true
        )) == nil)
    }

    @Test("Rules survive a store restart and revocation; corrupt or failed storage grants nothing")
    func persistenceAndRevocation() async throws {
        let io = RuleMemoryIO()
        let rule = sampleRule()
        let store = KeychainRememberedCommandApprovals(stateIO: io)
        try await store.save(rule)
        try await store.save(sampleRule())
        let restarted = KeychainRememberedCommandApprovals(stateIO: io)
        #expect(try await restarted.all() == [rule])
        try await restarted.revoke(rule.id)
        #expect(try await store.all().isEmpty)
        io.replace(Data("{bad document}".utf8))
        await #expect(throws: (any Error).self) { try await restarted.all() }
        io.replace(nil)
        io.failWrites()
        await #expect(throws: (any Error).self) { try await store.save(rule) }
        #expect(try await store.all().isEmpty)
    }

    @Test("Remembered authority cannot cross project, provider, working-copy or resource boundaries")
    func scopeBoundaries() {
        let rule = sampleRule()
        #expect(rule.covers(sampleRule()))
        #expect(!rule.covers(sampleRule(provider: .claude)))
        #expect(!rule.covers(sampleRule(project: "other-project")))
        #expect(!rule.covers(sampleRule(authority: "changed-working-copy-or-resources")))
        #expect(!rule.covers(sampleRule(command: "git status --short; echo different")))
    }

    @Test("Folder rules persist separately from command rules and reject unknown policy versions")
    func fileRulePersistence() async throws {
        let io = RuleMemoryIO()
        let store = KeychainRememberedCommandApprovals(stateIO: io)
        let command = sampleRule()
        let file = RememberedCommandApproval(providerID: .codex, projectID: "project", projectName: "Project",
            fileChangeScope: .init(workingDirectory: "/tmp/project"), authorizationDigest: "authority")
        try await store.save(command)
        try await store.save(file)
        let persisted = try #require(io.load())
        let document = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(document["version"] as? Int == 2)
        let restarted = KeychainRememberedCommandApprovals(stateIO: io)
        let rules = try await restarted.all()
        #expect(rules.count == 2)
        #expect(rules.contains { $0.covers(file) })
        #expect(!file.covers(command))
        #expect(!command.covers(file))
        let unknown = RememberedCommandApproval(providerID: .codex, projectID: "project", projectName: "Project",
            fileChangeScope: .init(workingDirectory: "/tmp/project", policyVersion: 2), authorizationDigest: "authority")
        await #expect(throws: (any Error).self) { try await restarted.save(unknown) }
        #expect(try await restarted.all().count == 2)
        try await restarted.revoke(file.id)
        #expect(try await restarted.all() == [command])
    }

    @Test("Always Allow stores only after delivery, repeats once per exact request and can be revoked", .timeLimit(.minutes(1)))
    func orchestratorLifecycle() async throws {
        let fixture = try RuleRunFixture()
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        #expect(await fixture.orchestrator.canRememberCommand(first))
        await fixture.runtime.setFailsResponse(true)
        await #expect(throws: (any Error).self) {
            try await fixture.orchestrator.respond(to: first, decision: .acceptAlways)
        }
        #expect(try await fixture.rules.all().isEmpty)
        #expect(await fixture.orchestrator.pendingApprovals() == [first])
        await fixture.runtime.setFailsResponse(false)
        try await fixture.orchestrator.respond(to: first, decision: .acceptAlways)
        let rule = try #require(try await fixture.rules.all().first)
        #expect(await fixture.runtime.decisions == [.accept])

        await fixture.runtime.emit(sequence: 2)
        try await eventually { await fixture.runtime.decisions.count == 2 }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        #expect(await fixture.runtime.decisions == [.accept, .accept])

        await fixture.runtime.emit(sequence: 3, command: "git diff")
        let different = try await fixture.pending()
        #expect(different.summary == "git diff")
        #expect(await fixture.runtime.decisions.count == 2)
        try await fixture.orchestrator.respond(to: different, decision: .accept)

        try await fixture.orchestrator.revokeRememberedCommandApproval(rule.id)
        await fixture.runtime.emit(sequence: 4)
        let revoked = try await fixture.pending()
        #expect(await fixture.runtime.decisions.count == 3)
        try await fixture.orchestrator.respond(to: revoked, decision: .decline)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("A request arriving during Always Allow delivery uses the saved rule", arguments: [false, true])
    func immediateRepeat(fileChanges: Bool) async throws {
        let fixture = try RuleRunFixture(fileChanges: fileChanges)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        await fixture.runtime.holdNextResponse()
        let response = Task { try await fixture.orchestrator.respond(to: first, decision: .acceptAlways) }
        try await eventually { await fixture.runtime.responseIsHeld }
        if fileChanges { await fixture.runtime.emitFile(sequence: 2) }
        else { await fixture.runtime.emit(sequence: 2) }
        try await eventually { await fixture.orchestrator.pendingApprovals().count == 2 }
        // The provider has already received acceptance, but its write has not returned.
        try await Task.sleep(for: .milliseconds(50))
        await fixture.runtime.releaseResponse()
        try await response.value
        try await eventually { await fixture.runtime.decisions == [.accept, .accept] }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        #expect(try await fixture.rules.all().count == 1)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("A failed Always Allow save releases waiting requests without granting them")
    func immediateRepeatWhenStorageFails() async throws {
        let io = RuleMemoryIO()
        let fixture = try RuleRunFixture(rules: KeychainRememberedCommandApprovals(stateIO: io))
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        await fixture.runtime.holdNextResponse()
        let response = Task { try await fixture.orchestrator.respond(to: first, decision: .acceptAlways) }
        try await eventually { await fixture.runtime.responseIsHeld }
        await fixture.runtime.emit(sequence: 2)
        try await eventually { await fixture.orchestrator.pendingApprovals().count == 2 }
        io.failWrites()
        await fixture.runtime.releaseResponse()
        await #expect(throws: (any Error).self) { try await response.value }
        try await eventually { await fixture.orchestrator.pendingApprovals().count == 1 }
        #expect(try await fixture.rules.all().isEmpty)
        #expect(await fixture.runtime.decisions == [.accept])
        let second = try await fixture.pending()
        try await fixture.orchestrator.respond(to: second, decision: .accept)
        #expect(await fixture.runtime.decisions == [.accept, .accept])
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Run-history failure cannot discard a successfully delivered remembered decision")
    func journalFailureKeepsRule() async throws {
        let fixture = try RuleRunFixture()
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        await fixture.runtime.holdNextResponse()
        let response = Task { try await fixture.orchestrator.respond(to: first, decision: .acceptAlways) }
        try await eventually { await fixture.runtime.responseIsHeld }
        await fixture.repository.setFailsSaves(true)
        await fixture.runtime.releaseResponse()
        do {
            try await response.value
            Issue.record("The run-history write should fail")
        } catch {
            #expect(error.localizedDescription.contains("Always Allow was saved"))
        }
        #expect(try await fixture.rules.all().count == 1)
        await fixture.repository.setFailsSaves(false)
        await fixture.runtime.emit(sequence: 2)
        try await eventually { await fixture.runtime.decisions == [.accept, .accept] }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("Progress updates during scheduled scope validation preserve remembered authority")
    func progressDoesNotChangeAuthority() async throws {
        let fixture = try RuleRunFixture(automation: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let approval = try await fixture.pending()
        try await eventually { await fixture.repository.record.status == .needsAttention }
        await fixture.authority.holdNextRead()
        let eligibility = Task { await fixture.orchestrator.canRememberCommand(approval) }
        try await eventually { await fixture.authority.readIsHeld }
        await fixture.runtime.emitProgress()
        try await eventually { await fixture.repository.record.assignments.first?.currentTask == "More progress" }
        await fixture.authority.releaseRead()
        #expect(await eligibility.value)
        try await fixture.orchestrator.respond(to: approval, decision: .acceptAlways)
        #expect(try await fixture.rules.all().count == 1)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("A restarted orchestrator reuses the saved exact command authority", .timeLimit(.minutes(1)))
    func restartUsesPersistedRule() async throws {
        let io = RuleMemoryIO()
        let first = try RuleRunFixture(rules: KeychainRememberedCommandApprovals(stateIO: io))
        defer { first.remove() }
        let execution = Task { try await first.orchestrator.execute(runID: first.run.id) }
        try await first.orchestrator.respond(to: first.pending(), decision: .acceptAlways)
        try await first.orchestrator.cancel(runID: first.run.id)
        _ = try? await execution.value
        let restarted = try RuleRunFixture(directory: first.directory,
            rules: KeychainRememberedCommandApprovals(stateIO: io))
        let next = Task { try await restarted.orchestrator.execute(runID: restarted.run.id) }
        try await eventually { await restarted.runtime.decisions == [.accept] }
        #expect(await restarted.orchestrator.pendingApprovals().isEmpty)
        try await restarted.orchestrator.cancel(runID: restarted.run.id)
        _ = try? await next.value
    }

    @Test("Scheduled rules survive later occurrences but cannot cross automation boundaries", arguments: ["same", "automation", "action", "revision", "authority", "manual", "manual-to-automation"], [false, true])
    func scheduledAuthorityBoundaries(boundary: String, fileChanges: Bool) async throws {
        let first = try RuleRunFixture(automation: boundary != "manual-to-automation", fileChanges: fileChanges)
        defer { first.remove() }
        let execution = Task { try await first.orchestrator.execute(runID: first.run.id) }
        let approval = try await first.pending()
        #expect(await first.orchestrator.canRememberCommand(approval))
        try await first.orchestrator.respond(to: approval, decision: .acceptAlways)
        let rule = try #require(try await first.rules.all().first)
        #expect(rule.automationName == (boundary == "manual-to-automation" ? nil : "Daily review"))
        try await first.orchestrator.cancel(runID: first.run.id)
        _ = try? await execution.value

        let next = try RuleRunFixture(automation: boundary != "manual", fileChanges: fileChanges,
            automationID: boundary == "automation" ? "other" : "automation",
            actionID: boundary == "action" ? "other-action" : "action",
            revision: boundary == "revision" ? 2 : 1,
            runID: "later-occurrence", authorityDigest: boundary == "authority" ? Data([2]) : Data([1]),
            directory: first.directory, rules: first.rules)
        let nextExecution = Task { try await next.orchestrator.execute(runID: next.run.id) }
        if boundary == "same" {
            try await eventually { await next.runtime.decisions == [.accept] }
            #expect(await next.orchestrator.pendingApprovals().isEmpty)
            try await next.orchestrator.revokeRememberedCommandApproval(rule.id)
            if fileChanges { await next.runtime.emitFile(sequence: 2) }
            else { await next.runtime.emit(sequence: 2) }
            _ = try await next.pending()
            #expect(await next.runtime.decisions == [.accept])
        } else {
            _ = try await next.pending()
            #expect(await next.runtime.decisions.isEmpty)
        }
        try await next.orchestrator.cancel(runID: next.run.id)
        _ = try? await nextExecution.value
    }

    @Test("Remembered folder edits allow changed patches, reject escaping paths, and revalidate before saving")
    func fileRuleLifecycle() async throws {
        let fixture = try RuleRunFixture(automation: true, fileChanges: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        #expect(first.rememberedFileChangeScope?.workingDirectory == fixture.directory.path)
        await fixture.runtime.setFailsResponse(true)
        await #expect(throws: (any Error).self) { try await fixture.orchestrator.respond(to: first, decision: .acceptAlways) }
        #expect(try await fixture.rules.all().isEmpty)
        await fixture.runtime.setFailsResponse(false)
        try await fixture.orchestrator.respond(to: first, decision: .acceptAlways)
        await fixture.runtime.emitFile(sequence: 2, path: "Other/New.swift", diff: "different contents")
        try await eventually { await fixture.runtime.decisions.count == 2 }
        #expect(await fixture.orchestrator.pendingApprovals().isEmpty)
        await fixture.runtime.emitFile(sequence: 3, path: "../Outside.swift")
        let outside = try await fixture.pending()
        #expect(outside.rememberedFileChangeScope == nil)
        #expect(!(await fixture.orchestrator.canRememberCommand(outside)))
        #expect(await fixture.runtime.decisions.count == 2)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("A symlink inserted after disclosure invalidates a pending Always Allow offer")
    func fileOfferRevalidatesPaths() async throws {
        let fixture = try RuleRunFixture(automation: true, fileChanges: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let first = try await fixture.pending()
        #expect(await fixture.orchestrator.canRememberCommand(first))
        try FileManager.default.createSymbolicLink(atPath: fixture.directory.appending(path: "Sources").path, withDestinationPath: "/tmp")
        #expect(!(await fixture.orchestrator.canRememberCommand(first)))
        await #expect(throws: (any Error).self) { try await fixture.orchestrator.respond(to: first, decision: .acceptAlways) }
        #expect(await fixture.runtime.decisions.isEmpty)
        #expect(try await fixture.rules.all().isEmpty)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("An automation losing its current authority cannot save or reuse a command rule", arguments: ["authority", "provenance"])
    func staleAutomationOffer(boundary: String) async throws {
        let fixture = try RuleRunFixture(automation: true)
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let approval = try await fixture.pending()
        #expect(await fixture.orchestrator.canRememberCommand(approval))
        // Save one exact command, then keep another offer open as authority changes.
        try await fixture.orchestrator.respond(to: approval, decision: .acceptAlways)
        await fixture.runtime.emit(sequence: 2, command: "git diff")
        let next = try await fixture.pending()
        #expect(await fixture.orchestrator.canRememberCommand(next))
        if boundary == "authority" { await fixture.authority.change() }
        else { await fixture.repository.removeAutomationProvenance() }
        #expect(!(await fixture.orchestrator.canRememberCommand(next)))
        await #expect(throws: (any Error).self) {
            try await fixture.orchestrator.respond(to: next, decision: .acceptAlways)
        }
        await fixture.runtime.emit(sequence: 3)
        try await eventually { await fixture.orchestrator.pendingApprovals().count == 2 }
        #expect(await fixture.runtime.decisions == [.accept])
        #expect(try await fixture.rules.all().count == 1)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }

    @Test("High-risk and separately approved Git runs cannot create remembered authority", arguments: ["risk", "git"])
    func separateApprovalRemainsSeparate(boundary: String) async throws {
        let fixture = try RuleRunFixture(highRisk: boundary == "risk", separateGit: boundary == "git")
        defer { fixture.remove() }
        let execution = Task { try await fixture.orchestrator.execute(runID: fixture.run.id) }
        let request = try await fixture.pending()
        #expect(!(await fixture.orchestrator.canRememberCommand(request)))
        await #expect(throws: (any Error).self) {
            try await fixture.orchestrator.respond(to: request, decision: .acceptAlways)
        }
        #expect(try await fixture.rules.all().isEmpty)
        try await fixture.orchestrator.cancel(runID: fixture.run.id)
        _ = try? await execution.value
    }
}

private func sampleRule(provider: AgentProviderID = .codex, project: ProjectID = "project",
                        authority: String = "authority", command: String = "git status --short") -> RememberedCommandApproval {
    .init(providerID: provider, projectID: project, projectName: "Project",
          scope: .init(command: command, workingDirectory: "/tmp/project", contextDigest: "permissions"),
          authorizationDigest: authority)
}

private func commandRequest(sequence: Int = 1, command: String = "git status --short",
                            directory: String = "/tmp/project", extra: [String: JSONValue] = [:]) -> CodexApprovalRequest {
    var request: [String: JSONValue] = [
        "command": .string(command), "cwd": .string(directory),
        "itemId": .string("item-\(sequence)"), "threadId": .string("thread-\(sequence)"),
        "turnId": .string("turn-\(sequence)"), "startedAtMs": .number(Double(sequence)),
        "reason": .string("Request \(sequence)"),
    ]
    request.merge(extra) { _, value in value }
    let binding = CodexGateway.approvalOperationBinding(method: "item/commandExecution/requestApproval", params: .object(request))
    return .init(id: "request-\(sequence)", assignmentID: "assignment", kind: .command,
                 summary: command, details: binding.details, operationDigest: binding.operationDigest,
                 disclosureComplete: binding.disclosureComplete)
}

private final class RuleMemoryIO: RememberedApprovalStateIO, Sendable {
    private struct State { var data: Data?; var fails = false }
    private let state = Mutex(State())
    func load() -> Data? { state.withLock { $0.data } }
    func save(_ data: Data) throws {
        try state.withLock {
            if $0.fails { throw RememberedCommandApprovalError.storage }
            $0.data = data
        }
    }
    func replace(_ data: Data?) { state.withLock { $0.data = data } }
    func failWrites() { state.withLock { $0.fails = true } }
}

private struct RuleRunFixture {
    let directory: URL
    let run: RunRecord
    let rules: KeychainRememberedCommandApprovals
    let runtime: RuleRuntime
    let resolver: RuleRuntimeResolver
    let orchestrator: ProviderRunOrchestrator
    let repository: RuleRepository
    let authority: RuleAutomationAuthority

    init(highRisk: Bool = false, separateGit: Bool = false, pushOnly: Bool = false, automation: Bool = false, automationGrant: Bool = false, fileChanges: Bool = false,
         uninterrupted: Bool = false, initialCommand: String = "git status --short", deferInitialApproval: Bool = false,
         automationID: AutomationID = "automation", actionID: AutomationActionID = "action", revision: Int = 1,
         runID: RunID = "run", authorityDigest: Data = Data([1]),
         directory existingDirectory: URL? = nil, rules existingRules: KeychainRememberedCommandApprovals? = nil) throws {
        directory = existingDirectory ?? FileManager.default.temporaryDirectory.appending(path: "goby-rule-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = LabProject(id: "project", name: "Project", rootURL: directory,
                                 platforms: [.general, .macOS, .iOS], isGitRepository: false,
                                 registeredAt: Date(timeIntervalSince1970: 1))
        let agent = AgentProfile(id: "agent", name: "Agent", summary: "Test", capabilities: [.routing], scope: .project(project.id))
        let binding = ProviderAgentBinding.migratedCodexBinding(for: agent)
        let plan = RoutingPlan(id: runID, interpretedGoal: "Inspect", routes: [
            ProjectRoute(projectID: project.id, agentIDs: [agent.id], reason: "Test")
        ], risk: highRisk ? .high : .readOnly, confidence: 1,
           gitOperations: pushOnly
               ? [.init(projectID: project.id, kind: .push, branch: "codex/goby-earlier", remote: "origin")]
               : separateGit
               // An agent run in a worktree that also carries a push; a push
               // alone runs no agent at all.
               ? [.init(projectID: project.id, kind: .createWorktree), .init(projectID: project.id, kind: .push)]
               : [])
        run = RunRecord(id: plan.id, plan: plan, status: .ready, assignments: [
            AgentAssignment(id: "assignment", runID: plan.id, projectID: project.id,
                            agentID: agent.id, status: .queued, currentTask: "Inspect")
        ], agentSnapshot: [agent], providerBindingSnapshot: [binding], projectSnapshot: [project],
           automationExecutionAuthorityDigest: automation ? authorityDigest : nil,
           automaticallyApproveRuntimeRequests: uninterrupted)
        let action = AutomationAction(id: actionID, instruction: "Inspect", target: .project(providerID: .codex, projectID: project.id))
        let definition = AutomationDefinition(id: automationID, name: "Daily review", schedule: .init(cadence: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC"), actions: [action], automaticallyApproveRuntimeRequests: automationGrant, revision: revision)
        let occurrence = AutomationOccurrence(automationID: automationID, definitionRevision: revision,
            actions: [action], trigger: .scheduled, scheduledAt: .now, status: .running,
            attempts: [.init(actionID: action.id, plan: plan, runID: run.id, status: .running)])
        repository = RuleRepository(lab: .init(projects: [project], agents: [agent]), record: run,
            automation: automation ? .init(definitions: [definition], occurrences: [occurrence]) : .init())
        authority = RuleAutomationAuthority(digest: authorityDigest)
        rules = existingRules ?? KeychainRememberedCommandApprovals(stateIO: RuleMemoryIO())
        runtime = RuleRuntime(directory: directory, fileChanges: fileChanges,
                              initialCommand: initialCommand, deferInitialApproval: deferInitialApproval)
        resolver = RuleRuntimeResolver(runtime: runtime)
        orchestrator = ProviderRunOrchestrator(catalog: repository, runs: repository,
            runtimes: resolver, workspaces: RuleWorkspace(),
            verifier: ProjectVerifier(), automationAuthority: authority, rememberedApprovals: rules, automationRepository: repository)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func pending() async throws -> ProviderApprovalRequest {
        try await eventually { !(await orchestrator.pendingApprovals().isEmpty) }
        return try #require(await orchestrator.pendingApprovals().first)
    }
}

private func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RememberedCommandApprovalError.unavailable
}

private actor RuleRepository: LabCatalogRepository, RunRepository, AutomationRepository {
    let lab: LabSnapshot
    var record: RunRecord
    var automation: AutomationSnapshot
    var failsSaves = false
    func setFailsSaves(_ value: Bool) { failsSaves = value }
    init(lab: LabSnapshot, record: RunRecord, automation: AutomationSnapshot) {
        self.lab = lab; self.record = record; self.automation = automation
    }
    func automationSnapshot() -> AutomationSnapshot { automation }
    func removeAutomationProvenance() { automation = .init() }
    func saveAutomation(_ automation: AutomationDefinition, replacing expected: AutomationDefinition?) {}
    func removeAutomation(id: AutomationID, replacing expected: AutomationDefinition) {}
    func saveAutomationOccurrence(_ occurrence: AutomationOccurrence, replacing expected: AutomationOccurrence?) {}
    func claimAutomationOccurrence(_ occurrence: AutomationOccurrence, advancing automation: AutomationDefinition, replacing expectedAutomation: AutomationDefinition) {}
    func snapshot() -> LabSnapshot { lab }
    func register(projects: [LabProject], agents: [AgentProfile]) {}
    func allRuns() -> [RunRecord] { [record] }
    func save(_ run: RunRecord) throws {
        if failsSaves { throw RememberedCommandApprovalError.storage }
        record = run
    }
}

private struct RuleWorkspace: WorkspacePreparing {
    func prepare(project: LabProject, for run: RunRecord) throws -> ProjectDirectoryPlacement {
        .init(rootURL: project.rootURL, fileSystemIdentity: try #require(project.fileSystemIdentity))
    }
    func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) -> String? { nil }
}

private actor RuleRuntimeResolver: AgentRuntimeResolving {
    let runtimeInstance: RuleRuntime
    var holdsRead = false
    var heldRead: CheckedContinuation<Void, Never>?
    var readIsHeld: Bool { heldRead != nil }
    init(runtime: RuleRuntime) { runtimeInstance = runtime }
    func holdNextRead() { holdsRead = true }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func providerIDs() -> [AgentProviderID] { [.codex] }
    func runtime(for providerID: AgentProviderID) async -> (any AgentRuntimeServing)? {
        if holdsRead {
            holdsRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return providerID == .codex ? runtimeInstance : nil
    }
}

private actor RuleRuntime: AgentRuntimeServing {
    nonisolated let providerID = AgentProviderID.codex
    let directory: URL
    let fileChanges: Bool
    let initialCommand: String
    let deferInitialApproval: Bool
    var started = false
    let eventsPair = AsyncStream<ProviderRunEvent>.makeStream()
    var failsResponse = false
    var holdsResponse = false
    var heldResponse: CheckedContinuation<Void, Never>?
    var responseIsHeld: Bool { heldResponse != nil }
    func holdNextResponse() { holdsResponse = true }
    func releaseResponse() { heldResponse?.resume(); heldResponse = nil }
    private(set) var decisions: [ProviderApprovalDecision] = []
    init(directory: URL, fileChanges: Bool, initialCommand: String, deferInitialApproval: Bool) {
        self.directory = directory; self.fileChanges = fileChanges
        self.initialCommand = initialCommand; self.deferInitialApproval = deferInitialApproval
    }
    func capabilities() -> ProviderCapabilities { .init([.execution, .interruption]) }
    func connectionState() -> ProviderConnectionState { .connected(version: "fixture") }
    func connect() -> ProviderConnectionState { connectionState() }
    func accountSnapshot() -> ProviderAccountSnapshot { .init(providerID: .codex, connectionState: connectionState()) }
    func recentTasks(projects: [LabProject]) -> [ProviderTaskActivity] { [] }
    func events() -> AsyncStream<ProviderRunEvent> { eventsPair.stream }
    func start(assignment: AgentAssignment, project: LabProject, agent: AgentProfile,
               binding: ProviderAgentBinding, instructions: [InstructionPack], resources: [SharedResource], risk: PlanRisk) -> ProviderExecutionHandle {
        started = true
        if !deferInitialApproval {
            if fileChanges { emitFile(sequence: 1) } else { emit(sequence: 1, command: initialCommand) }
        }
        return .init(providerID: .codex, taskID: "fixture-task")
    }
    func interrupt(assignmentID: AssignmentID) {}
    func respond(to approvalID: String, decision: ProviderApprovalDecision) throws { throw RememberedCommandApprovalError.unavailable }
    func respond(to approval: ProviderApprovalRequest, decision: ProviderApprovalDecision) async throws {
        if failsResponse { throw RememberedCommandApprovalError.unavailable }
        decisions.append(decision)
        if holdsResponse {
            holdsResponse = false
            await withCheckedContinuation { heldResponse = $0 }
        }
    }
    func emitFile(sequence: Int, path: String = "Sources/App.swift", diff: String = "new contents") {
        eventsPair.continuation.yield(.approvalRequired(fileApproval(sequence: sequence, path: path, diff: diff)))
    }
    func setFailsResponse(_ value: Bool) { failsResponse = value }
    func emitProgress() {
        eventsPair.continuation.yield(.progress(.codex, "assignment", fraction: 0.1, message: "More progress"))
    }
    func emit(sequence: Int, command: String = "git status --short") {
        emitCommand(sequence: sequence, command: command)
    }
    func emitCommand(sequence: Int, command: String, extra: [String: JSONValue] = [:]) {
        let request = commandRequest(sequence: sequence, command: command, directory: directory.path, extra: extra)
        eventsPair.continuation.yield(.approvalRequired(.init(
            id: request.id, assignmentID: request.assignmentID, kind: .command,
            summary: request.summary, details: request.details, operationDigest: request.operationDigest,
            disclosureComplete: request.disclosureComplete,
            rememberedCommandScope: CodexRememberedCommandScope.scope(for: request)
        )))
    }
    func emitPermissions(sequence: Int) {
        let request: JSONValue = .object([
            "cwd": .string(directory.path),
            "itemId": .string("item-\(sequence)"),
            "threadId": .string("thread-\(sequence)"),
            "turnId": .string("turn-\(sequence)"),
            "startedAtMs": .number(Double(sequence)),
            "permissions": .object(["network": .object(["enabled": .bool(true)])]),
        ])
        let binding = CodexGateway.approvalOperationBinding(
            method: "item/permissions/requestApproval",
            params: request,
            effectivePermissions: request["permissions"]
        )
        eventsPair.continuation.yield(.approvalRequired(.init(
            id: "request-\(sequence)", assignmentID: "assignment", kind: .permissions,
            summary: "Network access", details: binding.details,
            operationDigest: binding.operationDigest,
            disclosureComplete: binding.disclosureComplete
        )))
    }
}

private actor RuleAutomationAuthority: AutomationExecutionAuthorityProviding {
    var digest: Data
    init(digest: Data) { self.digest = digest }
    var holdsRead = false
    var heldRead: CheckedContinuation<Void, Never>?
    var readIsHeld: Bool { heldRead != nil }
    func holdNextRead() { holdsRead = true }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func automationExecutionAuthorityDigest() async -> Data {
        if holdsRead {
            holdsRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return digest
    }
    func change() { digest = Data([9]) }
}
