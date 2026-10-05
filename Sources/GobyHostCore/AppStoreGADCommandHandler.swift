import CryptoKit
import Foundation
import GobyApplication
import GobyDomain
import GobyInfrastructure
import GobyOperations
import GobyRemoteTransport
import Security

@MainActor
final class MobilePromptAttachmentUploadVault {
    struct Completed: Sendable {
        let attachmentID: UUID
        let kind: PromptAttachmentKind
        let displayName: String
        let data: Data
        let typeHint: String?
    }

    private struct Pending {
        let start: GADPromptAttachmentUploadStart
        var data = Data()
        var lastUpdatedAt: Date
    }

    private let lifetime: TimeInterval
    private var pendingByDevice: [DeviceID: Pending] = [:]
    private var expiryTasks: [DeviceID: Task<Void, Never>] = [:]

    init(lifetime: TimeInterval = MobilePromptAttachmentUploadVault.defaultLifetime) {
        precondition(lifetime > 0)
        self.lifetime = lifetime
    }

    func begin(
        _ start: GADPromptAttachmentUploadStart,
        deviceID: DeviceID,
        currentDraftRevision: EntityRevision,
        existingAttachmentIDs: Set<UUID>,
        attachmentCount: Int,
        now: Date = .now
    ) throws {
        let expiredDeviceIDs = pendingByDevice.compactMap { deviceID, pending in
            now.timeIntervalSince(pending.lastUpdatedAt) > lifetime ? deviceID : nil
        }
        for expiredDeviceID in expiredDeviceIDs {
            discard(for: expiredDeviceID)
        }
        guard start.expectedDraftRevision == currentDraftRevision else {
            throw GADCommandFailure(.rejectedStale, "The shared draft changed before this attachment transfer began.")
        }
        guard attachmentCount < Self.maximumDraftAttachmentCount,
              !existingAttachmentIDs.contains(start.attachmentID) else {
            throw GADCommandFailure(.rejectedPolicy, "This draft cannot accept another attachment identity.")
        }
        guard start.kind == .file || start.kind == .image,
              start.byteCount > 0,
              start.byteCount <= Self.maximumAttachmentBytes else {
            throw GADCommandFailure(.rejectedPolicy, "Mobile file and image attachments must be no larger than 25 MiB.")
        }
        guard !start.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              start.displayName.count <= 240,
              !start.displayName.contains("/"),
              !start.displayName.contains("\\"),
              !start.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (start.typeHint?.count ?? 0) <= 80,
              start.typeHint?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) != true,
              start.contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw GADCommandFailure(.rejectedPolicy, "The attachment metadata is invalid.")
        }
        if pendingByDevice[deviceID] == nil,
           pendingByDevice.count >= Self.maximumConcurrentUploads {
            throw GADCommandFailure(.failedRecoverable, "Too many mobile attachment transfers are active. Try again shortly.")
        }
        discard(for: deviceID)
        pendingByDevice[deviceID] = Pending(start: start, lastUpdatedAt: now)
        scheduleExpiry(
            for: deviceID,
            uploadID: start.uploadID,
            lastUpdatedAt: now
        )
    }

    func append(
        _ chunk: GADPromptAttachmentUploadChunk,
        deviceID: DeviceID,
        now: Date = .now
    ) throws {
        guard var pending = pendingByDevice[deviceID], pending.start.uploadID == chunk.uploadID else {
            throw GADCommandFailure(.rejectedStale, "This attachment transfer is no longer active.")
        }
        guard now.timeIntervalSince(pending.lastUpdatedAt) <= lifetime else {
            discard(for: deviceID)
            throw GADCommandFailure(.rejectedExpired, "This attachment transfer expired.")
        }
        guard !chunk.data.isEmpty,
              chunk.data.count <= Self.maximumChunkBytes,
              chunk.offset == pending.data.count,
              chunk.data.count <= pending.start.byteCount - pending.data.count else {
            discard(for: deviceID)
            throw GADCommandFailure(.rejectedPolicy, "The attachment chunk was oversized, out of order, or exceeded its declared size.")
        }
        pending.data.append(chunk.data)
        pending.lastUpdatedAt = now
        pendingByDevice[deviceID] = pending
        scheduleExpiry(
            for: deviceID,
            uploadID: pending.start.uploadID,
            lastUpdatedAt: now
        )
    }

    func consume(
        uploadID: UUID,
        deviceID: DeviceID,
        currentDraftRevision: EntityRevision,
        existingAttachmentIDs: Set<UUID>,
        now: Date = .now
    ) throws -> Completed {
        guard var pending = pendingByDevice[deviceID],
              pending.start.uploadID == uploadID else {
            throw GADCommandFailure(.rejectedStale, "This attachment transfer is no longer active.")
        }
        pendingByDevice.removeValue(forKey: deviceID)
        expiryTasks.removeValue(forKey: deviceID)?.cancel()
        guard now.timeIntervalSince(pending.lastUpdatedAt) <= lifetime else {
            clear(&pending.data)
            throw GADCommandFailure(.rejectedExpired, "This attachment transfer expired.")
        }
        guard pending.start.expectedDraftRevision == currentDraftRevision,
              !existingAttachmentIDs.contains(pending.start.attachmentID) else {
            clear(&pending.data)
            throw GADCommandFailure(.rejectedStale, "The shared draft changed while this attachment was transferring.")
        }
        guard pending.data.count == pending.start.byteCount,
              Self.sha256(pending.data) == pending.start.contentSHA256 else {
            clear(&pending.data)
            throw GADCommandFailure(.rejectedPolicy, "The attachment transfer was incomplete or failed its content check.")
        }
        return Completed(
            attachmentID: pending.start.attachmentID,
            kind: pending.start.kind,
            displayName: pending.start.displayName,
            data: pending.data,
            typeHint: pending.start.typeHint
        )
    }

    func cancel(uploadID: UUID, deviceID: DeviceID) {
        if pendingByDevice[deviceID]?.start.uploadID == uploadID {
            discard(for: deviceID)
        }
    }

    func revoke(_ deviceIDs: Set<DeviceID>) {
        for deviceID in deviceIDs {
            discard(for: deviceID)
        }
    }

    private func scheduleExpiry(
        for deviceID: DeviceID,
        uploadID: UUID,
        lastUpdatedAt: Date
    ) {
        expiryTasks.removeValue(forKey: deviceID)?.cancel()
        let delay = Duration.milliseconds(
            Int64((lifetime * 1_000).rounded(.up))
        )
        expiryTasks[deviceID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  let pending = self.pendingByDevice[deviceID],
                  pending.start.uploadID == uploadID,
                  pending.lastUpdatedAt == lastUpdatedAt else {
                return
            }
            self.discard(for: deviceID)
        }
    }

    private func discard(for deviceID: DeviceID) {
        expiryTasks.removeValue(forKey: deviceID)?.cancel()
        guard var pending = pendingByDevice.removeValue(forKey: deviceID) else {
            return
        }
        clear(&pending.data)
    }

    private func clear(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
        data.removeAll(keepingCapacity: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let maximumDraftAttachmentCount = 12
    static let maximumAttachmentBytes = 25 * 1_024 * 1_024
    static let maximumChunkBytes = 192 * 1_024
    static let maximumConcurrentUploads = 2
    static let defaultLifetime: TimeInterval = 10 * 60
}

@MainActor
public final class AppStoreGADCommandHandler: GADCommandHandling, @unchecked Sendable {
    private let store: AppStore
    private let hostID: HostID
    private let updateNotificationRegistration: UpdateNotificationRegistrationUseCase
    private let providerCredentials: any ProviderCredentialRepository
    private let remoteIdentifierAliasCodec: RemoteIdentifierAliasCodec
    private let builder = RemoteProjectionBuilder()
    private let adminPreviews = GADHostAdminPreviewVault()
    private let codexCatalogReviews = GADCodexCatalogReviewVault()
    private var localAttachmentSourceDevices: Set<DeviceID> = []
    private let mobileAttachmentUploadVault = MobilePromptAttachmentUploadVault()
    private var remoteIdentifierAliases = RemoteIdentifierAliasTable()
    private struct ApprovalDisclosureReceipt {
        let canonicalRequestDigest: String
        let opaqueToken: String
        let expiresAt: Date
        let allowsRemembering: Bool
    }
    private var approvalDisclosureReceipts: [DeviceID: [String: ApprovalDisclosureReceipt]] = [:]

    public init(
        store: AppStore,
        hostID: HostID,
        updateNotificationRegistration: UpdateNotificationRegistrationUseCase,
        providerCredentials: any ProviderCredentialRepository,
        remoteIdentifierAliasCodec: RemoteIdentifierAliasCodec
    ) {
        self.store = store
        self.hostID = hostID
        self.updateNotificationRegistration = updateNotificationRegistration
        self.providerCredentials = providerCredentials
        self.remoteIdentifierAliasCodec = remoteIdentifierAliasCodec
    }

    public func authorizeLocalAttachmentSources(for deviceID: DeviceID) {
        localAttachmentSourceDevices.insert(deviceID)
    }

    public func revokeAttachmentUploads(for deviceIDs: Set<DeviceID>) {
        mobileAttachmentUploadVault.revoke(deviceIDs)
        localAttachmentSourceDevices.subtract(deviceIDs)
    }

    public func apply(
        _ remotePayload: GADCommandPayload,
        to projection: DashboardProjection,
        deviceID: DeviceID
    ) async throws -> GADCommandEffect {
        let payload: GADCommandPayload
        do {
            payload = try remoteIdentifierAliasCodec.localizing(
                remotePayload,
                aliases: remoteIdentifierAliases
            )
        } catch {
            throw GADCommandFailure(
                .rejectedPolicy,
                "This request refers to an unknown or expired remote identifier. Refresh and try again."
            )
        }
        let callback = store.stateDidChange
        store.stateDidChange = nil
        var completedWithCanonicalEffect = false
        defer {
            store.stateDidChange = callback
            // A successful command returns a full canonical replacement to
            // the coordinator below. If validation or execution throws, no
            // effect is returned, so publish any authority quarantine or
            // asynchronous state change that occurred while callbacks were
            // intentionally suppressed.
            if !completedWithCanonicalEffect {
                callback?()
            }
        }

        var draftRevision = projection.draft.revision
        var artifact: GADCommandArtifact?
        let exactForbiddenValues = try await exactMobileForbiddenValues()

        switch payload {
        case let .replaceDraft(replacement):
            guard replacement.expectedRevision == projection.draft.revision else {
                throw GADCommandFailure(.rejectedStale, "The shared draft changed on another device.")
            }
            let previousAgentIDs = Set(store.promptAgentTargets.map(\.agentID))
            try apply(replacement, from: deviceID)
            draftRevision = draftRevision.advanced()
            await store.retireUnusedTemporaryAgents(among: previousAgentIDs)

        case let .beginPromptAttachmentUpload(start):
            try mobileAttachmentUploadVault.begin(
                start,
                deviceID: deviceID,
                currentDraftRevision: projection.draft.revision,
                existingAttachmentIDs: Set(projection.draft.attachments.map(\.id)),
                attachmentCount: projection.draft.attachments.count
            )

        case let .appendPromptAttachmentUpload(chunk):
            try mobileAttachmentUploadVault.append(chunk, deviceID: deviceID)

        case let .commitPromptAttachmentUpload(uploadID):
            let upload = try mobileAttachmentUploadVault.consume(
                uploadID: uploadID,
                deviceID: deviceID,
                currentDraftRevision: projection.draft.revision,
                existingAttachmentIDs: Set(projection.draft.attachments.map(\.id))
            )
            guard await store.addRemotePromptAttachment(
                id: upload.attachmentID,
                kind: upload.kind,
                displayName: upload.displayName,
                data: upload.data,
                typeHint: upload.typeHint
            ) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    "The Mac could not stage this attachment in its private Goby storage."
                )
            }
            draftRevision = draftRevision.advanced()

        case let .cancelPromptAttachmentUpload(uploadID):
            mobileAttachmentUploadVault.cancel(uploadID: uploadID, deviceID: deviceID)

        case let .controlRun(control):
            guard store.runs.contains(where: { $0.id == control.runID }) else {
                throw GADCommandFailure(.rejectedStale, "This run is no longer available.")
            }
            let action: ControlRunUseCase.Action = switch control.action {
            case .pause: .pause
            case .resume: .resume
            case .cancel: .cancel
            case .startNow: .startNow
            }
            guard await store.control(action, runID: control.runID, modelChange: control.modelChange) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not apply this run control. Refresh and try again."
                )
            }

        case let .rememberedApprovals(operation):
            guard localAttachmentSourceDevices.contains(deviceID) else {
                throw GADCommandFailure(.rejectedPolicy, "Manage remembered approvals on the authoritative Mac.")
            }
            switch operation {
            case .list:
                break
            case let .revoke(id):
                await store.revokeRememberedCommandApproval(id)
                if let message = store.rememberedApprovalsError {
                    throw GADCommandFailure(.failedRecoverable, message)
                }
            case let .setProjectEnabled(projectID, enabled):
                await store.setRememberedApprovalProjectEnabled(projectID, enabled: enabled)
                if let message = store.rememberedApprovalsError {
                    throw GADCommandFailure(.failedRecoverable, message)
                }
            }
            await store.refreshRememberedCommandApprovals()
            if let message = store.rememberedApprovalsError {
                throw GADCommandFailure(.failedRecoverable, message)
            }
            artifact = .rememberedApprovals(store.rememberedCommandApprovals)

        case let .requestApprovalDisclosure(id):
            guard let approval = store.pendingApprovals.first(where: { $0.routingID == id }) else {
                throw GADCommandFailure(.rejectedStale, "This approval is no longer pending.")
            }
            let isAuthoritativeLocalClient = localAttachmentSourceDevices.contains(deviceID)
            let disclosureContent = if isAuthoritativeLocalClient {
                AuthoritativeApprovalDisclosurePolicy.render(
                    summary: approval.summary,
                    details: approval.details,
                    exactForbiddenValues: exactForbiddenValues
                )
            } else {
                mobileApprovalDisclosureContent(
                    approval,
                    exactForbiddenValues: exactForbiddenValues
                )
            }
            guard approval.hasCompleteOperationBinding,
                  let disclosureContent else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    isAuthoritativeLocalClient
                        ? "This request contains secret material that Goby cannot safely show or approve."
                        : "This request contains scope or secret material that cannot be shown completely on a remote client. Decide it on the authoritative Mac."
                )
            }
            let rememberedScope: RememberedCommandScope?
            let rememberedFileScope: RememberedFileChangeScope?
            if isAuthoritativeLocalClient, await store.canRememberCommand(approval) {
                rememberedScope = approval.rememberedCommandScope
                rememberedFileScope = approval.rememberedFileChangeScope
            } else {
                rememberedScope = nil
                rememberedFileScope = nil
            }
            let canonicalRequestDigest = try Self.approvalRequestDigest(approval)
            let opaqueReceipt = try Self.makeOpaqueApprovalReceipt()
            let expiresAt = Date.now.addingTimeInterval(120)
            approvalDisclosureReceipts[deviceID, default: [:]][approval.routingID] = .init(
                canonicalRequestDigest: canonicalRequestDigest,
                opaqueToken: opaqueReceipt,
                expiresAt: expiresAt,
                allowsRemembering: rememberedScope != nil || rememberedFileScope != nil
            )
            artifact = .approvalDisclosure(GADApprovalDisclosure(
                approvalID: approval.routingID,
                requestDigest: opaqueReceipt,
                summary: disclosureContent.summary,
                details: disclosureContent.details,
                expiresAt: expiresAt,
                rememberedCommandScope: rememberedScope,
                rememberedFileChangeScope: rememberedFileScope
            ))

        case let .respondToApproval(response):
            guard let approval = store.pendingApprovals.first(where: {
                $0.routingID == response.approvalID
            }) else {
                throw GADCommandFailure(.rejectedStale, "This approval is no longer pending.")
            }
            if response.rememberCommand == true {
                guard localAttachmentSourceDevices.contains(deviceID), response.action == .allowOnce,
                      await store.canRememberCommand(approval) else {
                    throw GADCommandFailure(.rejectedPolicy, "Review an eligible command or file-edit request on the authoritative Mac before remembering it.")
                }
            }
            if response.action == .allowOnce || response.action == .allowForRun {
                guard approval.canAccept,
                      approval.hasCompleteOperationBinding else {
                    throw GADCommandFailure(
                        .rejectedPolicy,
                        "This approval is too large for complete remote review. Decide it on the authoritative Mac."
                    )
                }
                let canonicalRequestDigest = try Self.approvalRequestDigest(approval)
                guard let receipt = approvalDisclosureReceipts[deviceID]?[approval.routingID],
                      response.disclosureDigest == receipt.opaqueToken,
                      receipt.canonicalRequestDigest == canonicalRequestDigest,
                      receipt.expiresAt >= .now,
                      response.rememberCommand != true || receipt.allowsRemembering else {
                    throw GADCommandFailure(
                        .rejectedPolicy,
                        "Review the current exact approval request before allowing it."
                    )
                }
            }
            approvalDisclosureReceipts[deviceID]?.removeValue(forKey: approval.routingID)
            let decision: ProviderApprovalDecision = switch response.action {
            case .decline: .decline
            case .allowOnce: response.rememberCommand == true ? .acceptAlways : .accept
            case .allowForRun: .acceptAllForRun
            case .cancel: .cancel
            }
            guard await store.respond(to: approval, decision: decision) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The provider could not receive this decision. Review the pending request and try again."
                )
            }

        case let .reuseRequest(runID):
            guard let run = store.runs.first(where: { $0.id == runID }) else {
                throw GADCommandFailure(.rejectedStale, "This run is no longer available.")
            }
            store.reuseRequest(from: run)
            draftRevision = draftRevision.advanced()

        case .preparePlan:
            guard store.hasPromptContent else {
                throw GADCommandFailure(.rejectedPolicy, "Enter a request before reviewing its scope.")
            }
            await store.prepareRoutingPlan(
                alwaysReview: true,
                allowOneTimeRecurringRequest: true
            )
            if let suggestion = store.agentCreationSuggestion {
                throw GADCommandFailure(.rejectedPolicy, suggestion.message)
            }
            if store.proposedPlan == nil, let message = store.errorMessage {
                throw GADCommandFailure(.rejectedPolicy, message)
            }

        case let .updatePlan(update):
            try apply(update)

        case let .cancelPlan(planID):
            guard store.proposedPlan?.id == planID else {
                throw GADCommandFailure(.rejectedStale, "This plan is no longer pending.")
            }
            store.dismissPlan()

        case let .startRun(approval):
            guard let plan = store.proposedPlan, plan.id == approval.planID else {
                throw GADCommandFailure(.rejectedStale, "This plan changed; review the refreshed scope.")
            }
            guard !plan.routes.isEmpty, plan.routes.allSatisfy({ !$0.agentIDs.isEmpty }) else {
                throw GADCommandFailure(.rejectedPolicy, "Select at least one valid agent for every project.")
            }
            await store.stageProposedPlan(
                approved: true,
                automaticallyApproveRuntimeRequests: approval.automaticallyApproveRuntimeRequests,
                allowsPush: approval.allowsPush == true
            )
            guard store.proposedPlan?.id != plan.id,
                  store.runs.contains(where: { $0.id == plan.id }) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not queue this run. Review the plan and try again."
                )
            }

        case let .refreshProviders(providerIDs):
            await store.refreshProviderStatus(providerIDs: Set(providerIDs))

        case let .refreshProviderActivity(providerIDs):
            for providerID in Set(providerIDs).sorted() {
                await store.refreshMapActivity(providerID: providerID)
            }

        case let .updateNotificationRegistration(registration):
            try await updateNotificationRegistration(registration, for: deviceID)
            artifact = .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: registration == nil
                    ? "Disabled generic notifications for this device."
                    : "Enabled generic attention and completion notifications for this device.",
                isUndoAvailable: false
            ))

        case .revokeCurrentDevice:
            artifact = .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "The Mac accepted permanent revocation for this device.",
                isUndoAvailable: false
            ))

        case let .askTemporaryChat(question):
            do {
                try await store.hostAskTemporaryChat(
                    question.text,
                    chatID: question.chatID,
                    model: question.model,
                    providerID: question.providerID ?? .codex
                )
            } catch let error as TemporaryChatError {
                switch error {
                case .staleChat:
                    throw GADCommandFailure(.rejectedStale, error.localizedDescription)
                case .answering, .emptyQuestion:
                    throw GADCommandFailure(.rejectedPolicy, error.localizedDescription)
                case .notSignedIn, .unavailable:
                    throw GADCommandFailure(.failedRecoverable, error.localizedDescription)
                }
            } catch {
                throw GADCommandFailure(.failedRecoverable, error.localizedDescription)
            }

        case let .endTemporaryChat(chatID):
            await store.hostEndTemporaryChat(chatID)

        case let .dispatchManualHandoff(request):
            guard let run = store.runs.first(where: { $0.id == request.runID }),
                  let assignment = run.assignments.first(where: {
                      $0.id == request.sourceAssignmentID
                  }),
                  let link = store.lab.agentHandoffLinks.first(where: {
                      $0.id == request.linkID
                  }) else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This handoff is no longer available for review."
                )
            }
            guard await store.prepareAndQueueHandoff(link, from: assignment, in: run) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not queue the reviewed handoff."
                )
            }

        case .refreshCodex:
            await store.refreshCodexStatus()

        case let .saveProjectGroup(mutation):
            if let id = mutation.id,
               !store.lab.projectGroups.contains(where: { $0.id == id }) {
                throw GADCommandFailure(.rejectedStale, "This project group is no longer available.")
            }
            let saved = await store.saveProjectGroup(
                id: mutation.id,
                name: mutation.name,
                members: mutation.members
            )
            guard saved else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not save this project group."
                )
            }

        case let .setProjectTrust(mutation):
            // Trust lets edits start without review on every device, so only
            // the Mac's own dashboard may change it.
            guard localAttachmentSourceDevices.contains(deviceID) else {
                throw GADCommandFailure(.rejectedPolicy, "Change trusted projects on the Mac.")
            }
            if let projectID = mutation.projectID {
                guard store.lab.projects.contains(where: { $0.id == projectID }) else {
                    throw GADCommandFailure(.rejectedStale, "This project is no longer registered.")
                }
                store.setProjectTrusted(projectID, trusted: mutation.trusted)
            } else if !mutation.trusted {
                store.revokeAllProjectTrust()
            } else {
                throw GADCommandFailure(.rejectedPolicy, "Trust projects one at a time.")
            }

        case let .deleteProjectGroup(id):
            guard store.lab.projectGroups.contains(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This project group is no longer available.")
            }
            await store.removeProjectGroup(id)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .saveAutomation(mutation):
            let existing = store.automations.first { $0.id == mutation.automation.id }
            if let existing, existing.revision != mutation.expectedRevision {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation changed on another device. Review the refreshed version."
                )
            }
            if existing == nil, mutation.expectedRevision != nil {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation was deleted on another device."
                )
            }
            await store.saveAutomation(
                mutation.automation,
                expectedRevision: mutation.expectedRevision
            )
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .setAutomationState(mutation):
            guard store.automations.first(where: { $0.id == mutation.id })?.revision
                    == mutation.expectedRevision else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation changed on another device."
                )
            }
            await store.setAutomationState(
                id: mutation.id,
                state: mutation.state,
                expectedRevision: mutation.expectedRevision
            )
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .deleteAutomation(id, expectedRevision):
            guard store.automations.first(where: { $0.id == id })?.revision
                    == expectedRevision else {
                throw GADCommandFailure(.rejectedStale, "This automation changed or was deleted.")
            }
            await store.deleteAutomation(id: id, expectedRevision: expectedRevision)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case .runAutomationNow:
            throw GADCommandFailure(
                .rejectedStale,
                "This automation request is from an older view. Refresh and review the schedule."
            )

        case let .runAutomationNowChecked(request):
            guard store.automations.first(where: { $0.id == request.id })?.revision
                    == request.expectedRevision else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation changed. Review the refreshed schedule before running it."
                )
            }
            await store.runAutomationNow(id: request.id)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .reviewAndRunAutomationOccurrence(review):
            guard let occurrence = store.automationOccurrences.first(where: { $0.id == review.id }),
                  let plan = occurrence.currentReviewAttempt?.plan else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This automation action is no longer waiting for review."
                )
            }
            guard let binding = review.reviewBinding,
                  occurrence.currentReviewBinding == binding else {
                throw GADCommandFailure(.rejectedStale,
                    "This automation review changed or came from an older app. Update if needed, then reopen the current action review.")
            }
            if plan.requiresApproval, review.authorizationAssertion?.isEmpty != false {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "Confirm the disclosed operation scope before this automation action runs."
                )
            }
            await store.reviewAndRunAutomationOccurrence(
                id: review.id,
                reviewBinding: binding,
                approved: review.authorizationAssertion?.isEmpty == false || !plan.requiresApproval,
                selectedResourceIDs: Set(review.selectedResourceIDs)
            )
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .cancelAutomationOccurrence(id):
            guard store.automationOccurrences.contains(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This occurrence is no longer available.")
            }
            await store.cancelAutomationOccurrence(id: id)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }

        case let .requestInstructionEditor(id):
            guard let pack = store.instructionPacks.first(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This instruction pack is no longer available.")
            }
            artifact = .instructionEditor(GADInstructionEditor(
                id: pack.id,
                name: String(pack.name.prefix(160)),
                body: String(pack.body.prefix(64_000)),
                scope: pack.scope,
                version: pack.version,
                isEnabled: pack.isEnabled,
                expiresAt: Date.now.addingTimeInterval(120)
            ))

        case let .saveInstruction(mutation):
            let existing = mutation.id.flatMap { id in
                store.instructionPacks.first { $0.id == id }
            }
            if mutation.id != nil, existing == nil {
                throw GADCommandFailure(.rejectedStale, "This instruction pack is no longer available.")
            }
            if let existing, mutation.expectedRevision?.rawValue != UInt64(existing.version) {
                throw GADCommandFailure(.rejectedStale, "This instruction pack changed on another device.")
            }
            let saved = await store.applyRemoteInstructionMutation(
                id: mutation.id,
                expectedVersion: mutation.expectedRevision.map { Int($0.rawValue) },
                name: mutation.name,
                body: mutation.body,
                scope: mutation.scope,
                isEnabled: mutation.isEnabled
            )
            guard saved else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not save this instruction pack."
                )
            }

        case let .requestProviderBindingInstructionEditor(bindingID):
            guard let binding = store.lab.providerBindings.first(where: { $0.id == bindingID }) else {
                throw GADCommandFailure(.rejectedStale, "This provider binding is no longer available.")
            }
            artifact = .providerBindingInstructionEditor(.init(
                bindingID: binding.id,
                instructions: String((binding.instructionsOverride ?? "").prefix(64_000)),
                expiresAt: Date.now.addingTimeInterval(120)
            ))

        case let .saveProviderBindingInstructions(mutation):
            guard store.lab.providerBindings.contains(where: { $0.id == mutation.bindingID }) else {
                throw GADCommandFailure(.rejectedStale, "This provider binding is no longer available.")
            }
            let saved = await store.updateProviderInstructions([
                mutation.bindingID: String((mutation.instructions ?? "").prefix(64_000))
            ])
            guard saved else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not save these provider instructions."
                )
            }
            artifact = .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Updated the provider-specific instructions for future assignments. Existing runs and handoffs were unchanged.",
                isUndoAvailable: false
            ))

        case .requestCodexCatalogDiscovery:
            guard let plan = await store.prepareRemoteCodexCatalogDiscovery() else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The Mac could not inspect the current Codex catalog."
                )
            }
            let expiry = Date.now.addingTimeInterval(120)
            await codexCatalogReviews.issue(plan, deviceID: deviceID, expiresAt: expiry)
            artifact = .codexCatalogDiscovery(.init(
                projects: plan.projects.map { candidate in
                    .init(
                        id: candidate.id,
                        name: mobileSafeText(candidate.project.name, limit: 160),
                        platforms: candidate.project.platforms.sorted { $0.rawValue < $1.rawValue },
                        isGitRepository: candidate.project.isGitRepository,
                        evidence: [
                            candidate.inspectionLevel == .inspected
                                ? "Inspected from a Mac-authorized project folder"
                                : "Known to Codex; detailed folder inspection still requires the Mac",
                            candidate.project.isGitRepository ? "Git repository detected" : "No Git repository detected"
                        ]
                    )
                },
                agents: plan.agents.candidates.map { candidate in
                    .init(
                        id: candidate.id,
                        name: mobileSafeText(candidate.profile.name, limit: 160),
                        summary: mobileSafeText(candidate.profile.summary, limit: 600),
                        capabilities: candidate.profile.capabilities.sorted { $0.rawValue < $1.rawValue },
                        scope: mobileScope(candidate.profile.scope),
                        evidence: candidate.profile.sourceURL == nil
                            ? ["Goby-inferred role; no imported instruction body"]
                            : ["File-backed definition requires full review on the paired Mac"],
                        requiresMacReview: candidate.profile.sourceURL != nil
                    )
                },
                scannedProjectCount: plan.scannedProjectCount,
                scannedAgentCount: plan.scannedAgentCount,
                limitedProjectAccessCount: plan.limitedProjectAccessCount,
                warnings: plan.warnings.map { mobileSafeText($0, limit: 600) },
                expiresAt: expiry
            ))

        case let .requestAgentCatalogDiscovery(offset):
            guard let preparation = await store.prepareRemoteAgentCatalogDiscovery() else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The Mac could not inspect the current agent definitions."
                )
            }
            let plan = preparation.plan
            guard offset >= 0, offset <= plan.candidates.count else {
                throw GADCommandFailure(.rejectedPolicy, "The requested definition page is invalid.")
            }
            let page = Array(plan.candidates.dropFirst(offset).prefix(1))
            let nextOffset = offset + page.count < plan.candidates.count
                ? offset + page.count
                : nil
            artifact = .agentCatalogDiscovery(.init(
                candidates: try page.map { candidate in
                    .init(
                        id: candidate.id,
                        name: mobileSafeText(candidate.profile.name, limit: 160),
                        summary: mobileSafeText(candidate.profile.summary, limit: 600),
                        instructions: candidate.profile.instructions.map {
                            mobileSafeText($0, limit: 64_000, allowsKnownInstructionBody: true)
                        },
                        capabilities: candidate.profile.capabilities.sorted { $0.rawValue < $1.rawValue },
                        scope: mobileScope(candidate.profile.scope),
                        evidence: candidate.evidence.map { mobileSafeText($0, limit: 600) },
                        canRestructure: false,
                        requiresMacReview: (candidate.profile.instructions?.utf8.count ?? 0) > 64_000,
                        reviewHash: try agentReviewHash(candidate)
                    )
                },
                totalCandidateCount: plan.candidates.count,
                nextOffset: nextOffset,
                expiresAt: Date.now.addingTimeInterval(120)
            ))

        case let .requestProjectGitBranches(projectID):
            let snapshot: ProjectGitBranchSnapshot
            do {
                snapshot = try await store.inspectProjectGitBranches(projectID: projectID)
            } catch {
                throw GADCommandFailure(.failedRecoverable, error.localizedDescription)
            }
            artifact = .projectGitBranches(.init(
                projectID: snapshot.projectID,
                currentBranch: snapshot.currentBranch.map {
                    mobileSafeText($0, limit: 240)
                },
                localBranches: snapshot.localBranches.prefix(512).map {
                    mobileSafeText($0, limit: 240)
                },
                hasUncommittedChanges: snapshot.hasUncommittedChanges,
                expiresAt: Date.now.addingTimeInterval(120)
            ))

        case let .requestHostAdminPreview(request):
            artifact = .hostAdminPreview(try await hostAdminPreview(
                for: request,
                deviceID: deviceID,
                revision: projection.revision,
                reviewStateDigest: try hostAdminReviewStateDigest()
            ))

        case let .commitHostAdmin(commit):
            let request = try await adminPreviews.consume(
                commit,
                deviceID: deviceID,
                currentRevision: projection.revision,
                currentReviewStateDigest: try hostAdminReviewStateDigest()
            )
            artifact = try await commitHostAdmin(request, deviceID: deviceID)

        case let .followUp(followUp):
            guard store.runs.contains(where: { $0.id == followUp.runID }) else {
                throw GADCommandFailure(.rejectedStale, "This run is no longer available.")
            }
            guard await store.followUp(runID: followUp.runID, text: followUp.text) else {
                throw GADCommandFailure(
                    .failedIndeterminate,
                    store.errorMessage ?? "The Mac could not confirm delivery of the follow-up."
                )
            }
            artifact = .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Delivered the follow-up to every active assignment in this run.",
                isUndoAvailable: false
            ))
        }

        try await store.checkpointOperationalContinuity()
        let replacement = try await self.projection(
            replacing: projection,
            draftRevision: draftRevision
        )
        let safeArtifact = artifact.map {
            mobileSafeArtifact($0, exactForbiddenValues: exactForbiddenValues)
        }
        let remoteArtifact: GADCommandArtifact?
        if let safeArtifact {
            remoteArtifact = try aliasForRemote(safeArtifact)
        } else {
            remoteArtifact = nil
        }
        let effect = GADCommandEffect(
            changes: projection.changes(replacingWith: replacement),
            artifact: remoteArtifact
        )
        completedWithCanonicalEffect = true
        return effect
    }

    private func hostAdminPreview(
        for request: GADHostAdminRequest,
        deviceID: DeviceID,
        revision: StateRevision,
        reviewStateDigest: String
    ) async throws -> GADHostAdminPreview {
        var effects: [GADHostAdminEffect]
        let requiresAuthentication: Bool
        switch request {
        case let .addMissingAutomationAgents(plan):
            guard store.missingAutomationAgents(for: plan.occurrenceID) == plan,
                  let project = store.lab.projects.first(where: { $0.id == plan.projectID }) else {
                throw GADCommandFailure(.rejectedStale, "This automation or its missing agents changed. Reopen Resolve.")
            }
            effects = [
                .init(
                    id: "add-missing-automation-agents",
                    title: "Add \(plan.capabilities.count) missing Codex agents",
                    detail: "Create project-only specialists for \(project.name): \(plan.capabilitySummary). Existing definitions are preserved.",
                    isDestructive: false
                ),
                .init(
                    id: "review-automation-authority",
                    title: "Review schedules before resuming",
                    detail: "Adding agents pauses schedules and closes unfinished occurrences. Completed actions stay in history; no work starts automatically.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case let .createTemporaryAgent(intent):
            guard intent.agentID.rawValue.hasPrefix("temporary-agent-"),
                  !intent.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let project = store.lab.projects.first(where: { $0.id == intent.projectID }) else {
                throw GADCommandFailure(.rejectedStale, "The quick task needs an available project.")
            }
            effects = [.init(
                id: "create-temporary-agent",
                title: "Create a temporary agent",
                detail: "Create one task-specific Goby agent for \(project.name), given any notes earlier temporary agents left. The task still requires normal scope and permission review; the agent records handoff notes and is retired when its run ends.",
                isDestructive: false
            )]
            if !store.lab.projectProviderConfigurations.contains(where: {
                $0.projectID == intent.projectID && $0.providerIDs.contains(intent.providerID)
            }) {
                effects.append(.init(
                    id: "enable-temporary-agent-provider",
                    title: "Use \(intent.providerID.displayName) in \(project.name)",
                    detail: "Add \(intent.providerID.displayName) to this project's providers so the temporary agent can run. Other agents and providers are unchanged.",
                    isDestructive: false
                ))
            }
            requiresAuthentication = false

        case let .retireTemporaryAgent(agentID):
            guard store.lab.agents.contains(where: { $0.id == agentID && $0.isTemporary }) else {
                throw GADCommandFailure(.rejectedStale, "This temporary agent is no longer present.")
            }
            effects = [.init(
                id: "retire-temporary-agent",
                title: "Remove unused quick-task agent",
                detail: "Remove the temporary Goby agent and its provider binding. Existing run results remain available.",
                isDestructive: false
            )]
            requiresAuthentication = false

        case let .saveAgent(intent):
            guard intent.agentID == nil else {
                throw GADCommandFailure(.rejectedCapability, "Editing an existing file-backed agent is not enabled remotely yet.")
            }
            let name = intent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = intent.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !summary.isEmpty, !intent.capabilities.isEmpty else {
                throw GADCommandFailure(.rejectedPolicy, "A new agent needs a name, summary and at least one capability.")
            }
            let legacyProjectID: ProjectID? = switch intent.scope {
            case .global, .union: nil
            case let .project(projectID): projectID
            }
            guard intent.projectID == legacyProjectID else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "The reviewed agent availability does not match its compatibility scope. Refresh and review it again."
                )
            }
            let scopeDescription: String
            switch intent.scope {
            case let .project(projectID):
                guard let project = store.lab.projects.first(where: { $0.id == projectID }) else {
                    throw GADCommandFailure(.rejectedStale, "The selected project is no longer registered in Goby.")
                }
                scopeDescription = "only for \(String(project.name.prefix(120)))"
            case .global:
                scopeDescription = "for all registered projects"
            case .union:
                scopeDescription = "for the shared union catalog across registered projects"
            }
            effects = [
                .init(
                    id: "create-agent-definition",
                    title: "Create \(String(name.prefix(120)))",
                    detail: "Write a recoverable Goby-managed Codex definition \(scopeDescription).",
                    isDestructive: false
                ),
                .init(
                    id: "enable-agent-routing",
                    title: "Enable future routing",
                    detail: "Existing runs and provider snapshots remain unchanged.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case let .setAgentEnabled(agentID, enabled):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            effects = [
                .init(
                    id: "agent-routing",
                    title: enabled ? "Enable \(String(agent.name.prefix(120)))" : "Disable \(String(agent.name.prefix(120)))",
                    detail: "Change future Goby routing only. The definition and existing run snapshots stay unchanged.",
                    isDestructive: !enabled
                )
            ]
            requiresAuthentication = false

        case let .publishAgent(agentID):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            guard agent.codexRegistrationKey == nil else {
                throw GADCommandFailure(.rejectedPolicy, "This agent is already active in Codex.")
            }
            effects = [
                .init(
                    id: "publish-agent",
                    title: "Activate \(String(agent.name.prefix(120))) in Codex",
                    detail: "Add the namespaced registration for future Codex sessions without changing existing runs.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case let .deleteAgent(agentID):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            effects = [
                .init(
                    id: "archive-agent-definition",
                    title: "Delete \(String(agent.name.prefix(120)))",
                    detail: agent.sourceURL == nil
                        ? "Remove the Goby catalog entry. Run history remains available."
                        : "Archive its definition, remove its Codex registration and preserve run history for recovery.",
                    isDestructive: true
                )
            ]
            requiresAuthentication = true

        case .restoreLastDeletedAgent:
            guard let record = store.lastDeletedAgent else {
                throw GADCommandFailure(.rejectedStale, "There is no deleted agent available to restore.")
            }
            effects = [
                .init(
                    id: "restore-agent",
                    title: "Restore \(String(record.agent.name.prefix(120)))",
                    detail: "Restore the archived definition and its Goby catalog entry. Existing run history is unchanged.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case .undoLastAgentRestructure:
            guard !store.lastAppliedAgentRestructure.isEmpty else {
                throw GADCommandFailure(.rejectedStale, "There is no agent-file restructure available to undo.")
            }
            effects = [
                .init(
                    id: "undo-agent-restructure",
                    title: "Restore original agent definition files",
                    detail: "Use Goby's existing recovery archive; catalog history remains intact.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case let .removeProject(id):
            guard let project = store.lab.projects.first(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This project is no longer registered in Goby.")
            }
            let agentCount = store.lab.agents.filter { agent in
                if case let .project(projectID) = agent.scope { return projectID == id }
                return false
            }.count
            let groupCount = store.lab.projectGroups.filter { group in
                group.members.contains(where: { $0.projectID == id })
            }.count
            effects = [
                .init(
                    id: "remove-project",
                    title: "Remove \(String(project.name.prefix(120))) from Goby",
                    detail: "The project folder and Codex definitions remain unchanged and can be imported again.",
                    isDestructive: true
                ),
                .init(
                    id: "remove-related-metadata",
                    title: "Update related dashboard metadata",
                    detail: "Remove \(agentCount) project-scoped agent\(agentCount == 1 ? "" : "s") and update \(groupCount) linked group\(groupCount == 1 ? "" : "s").",
                    isDestructive: agentCount > 0 || groupCount > 0
                )
            ]
            requiresAuthentication = true

        case .exportRedactedDiagnostics:
            effects = [
                .init(
                    id: "redacted-diagnostics",
                    title: "Prepare a mobile-safe diagnostic report",
                    detail: "Exclude prompts, names, paths, outcomes, credentials, tokens and raw Codex logs.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = false

        case let .setResourceAccess(resourceID, access, enabled):
            guard let resource = store.sharedResources.first(where: { $0.id == resourceID }) else {
                throw GADCommandFailure(.rejectedStale, "This shared resource is no longer registered in Goby.")
            }
            let broadensAccess = (resource.access == .readOnly && access == .readWrite)
                || (!resource.isEnabled && enabled)
            effects = [
                .init(
                    id: "resource-availability",
                    title: enabled ? "Make \(String(resource.name.prefix(120))) available" : "Remove \(String(resource.name.prefix(120))) from future runs",
                    detail: enabled
                        ? "The folder may be selected for future plans; it is not added to the current plan automatically."
                        : "Existing run snapshots stay unchanged. The folder remains registered and can be restored.",
                    isDestructive: !enabled
                ),
                .init(
                    id: "resource-access",
                    title: "Use \(access.displayName.lowercased()) access",
                    detail: "macOS privacy controls and every Codex runtime approval remain authoritative.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = broadensAccess

        case let .switchProjectBranch(approval):
            guard let project = store.lab.projects.first(where: {
                $0.id == approval.projectID
            }) else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This project is no longer registered in Goby."
                )
            }
            let snapshot: ProjectGitBranchSnapshot
            do {
                snapshot = try await store.inspectProjectGitBranches(projectID: project.id)
            } catch {
                throw GADCommandFailure(.failedRecoverable, error.localizedDescription)
            }
            guard snapshot.currentBranch == approval.expectedCurrentBranch else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "The checked-out branch changed. Refresh and review the switch again."
                )
            }
            guard !snapshot.hasUncommittedChanges else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "This working copy has tracked or untracked changes. Goby will not stash or discard them."
                )
            }
            guard approval.destinationBranch != snapshot.currentBranch,
                  snapshot.localBranches.contains(approval.destinationBranch) else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "Choose a different existing local branch. Goby does not fetch or create branches here."
                )
            }
            effects = [
                .init(
                    id: "switch-project-branch",
                    title: "Switch \(String(project.name.prefix(120))) to \(String(approval.destinationBranch.prefix(120)))",
                    detail: "Check out this exact existing local branch. Goby will not stash, reset, merge, fetch, create, delete, or push anything.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true

        case let .createProject(intent):
            let (_, locationName) = try newProjectDraft(for: intent)
            let projectName = intent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let folderAction = switch intent.source {
            case .blank:
                "Create one new folder"
            case let .gitClone(repository):
                "Clone \(String(repository.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))) into a new folder"
            }
            let providerNames = Set(intent.providerIDs).sorted().map(\.displayName).joined(separator: ", ")
            let providerTitle = providerNames.isEmpty ? "Configure providers later" : "Configure \(providerNames)"
            effects = [
                .init(
                    id: "create-project-folder",
                    title: "Create \(String(projectName.prefix(120)))",
                    detail: "\(folderAction) named \(String(intent.directoryName.prefix(120))) inside the Mac-authorized location \(String(locationName.prefix(120))).",
                    isDestructive: false
                ),
                .init(
                    id: "configure-project",
                    title: providerTitle,
                    detail: "Register \(intent.agents.count) project agent\(intent.agents.count == 1 ? "" : "s") and \(intent.handoffLinks.count) reviewed, suggest-only handoff path\(intent.handoffLinks.count == 1 ? "" : "s").",
                    isDestructive: false
                )
            ]
            if let selection = intent.template,
               let template = ProjectTemplateCatalog.descriptor(
                   for: selection.id,
                   version: selection.version
               ) {
                effects.append(.init(
                    id: "apply-project-template",
                    title: "Apply \(String(template.name.prefix(120))) v\(template.version)",
                    detail: "Create exactly \(template.artifactCount) bundled scaffold files for \(template.frameworks.joined(separator: ", ")). No dependency installer, setup hook, or Git command will run.",
                    isDestructive: false
                ))
            }
            if let link = intent.link,
               let linkedProject = store.lab.projects.first(where: { $0.id == link.projectID }) {
                effects.append(.init(
                    id: "link-project",
                    title: "Link with \(String(linkedProject.name.prefix(120)))",
                    detail: "Coordinate routing through the reviewed project group roles; both folders keep separate Git, permissions, tests and recovery.",
                    isDestructive: false
                ))
            }
            requiresAuthentication = true

        case let .syncCodexCatalog(projectIDs, agentIDs):
            let validation = try await validatedCodexSelection(
                projectIDs: projectIDs,
                agentIDs: agentIDs,
                deviceID: deviceID
            )
            let selectedProjects = validation.projectIDs
            let selectedAgents = validation.agentIDs
            effects = []
            if !selectedProjects.isEmpty {
                effects.append(.init(
                    id: "import-codex-projects",
                    title: "Import \(selectedProjects.count) project change\(selectedProjects.count == 1 ? "" : "s")",
                    detail: "Register only the selected Codex-known projects. No project folder, Git repository or Codex task is changed.",
                    isDestructive: false
                ))
            }
            if !selectedAgents.isEmpty {
                effects.append(.init(
                    id: "import-inferred-agents",
                    title: "Import \(selectedAgents.count) inferred role\(selectedAgents.count == 1 ? "" : "s")",
                    detail: "Register only Goby-inferred roles that contain no imported instruction body. File-backed definitions stay on the Mac for complete trust review.",
                    isDestructive: false
                ))
            }
            requiresAuthentication = true

        case .restructureAgents:
            throw GADCommandFailure(
                .rejectedPolicy,
                "Restructuring executable agent files requires a complete local review on the Mac."
            )

        case let .importAgents(selections):
            let validation = try await validatedAgentSelection(selections)
            let selected = validation.selectedCandidates
            effects = [
                .init(
                    id: "import-agent-instruction-copies",
                    title: "Import \(selected.count) instruction-only agent cop\(selected.count == 1 ? "y" : "ies")",
                    detail: "Register only the displayed semantic instructions for future routing. Source files and executable tool configuration stay untrusted and unchanged.",
                    isDestructive: false
                )
            ]
            requiresAuthentication = true
        }
        return try await adminPreviews.issue(
            request: request,
            deviceID: deviceID,
            baseRevision: revision,
            effects: effects,
            requiresLocalAuthentication: requiresAuthentication,
            reviewStateDigest: reviewStateDigest
        )
    }

    private struct HostAdminReviewState: Encodable {
        let lab: LabSnapshot
        let resources: [SharedResource]
        let instructions: [InstructionPack]
        let automationDefinitions: [AutomationDefinition]
        let codexSyncPlan: CodexCatalogSyncPlan?
        let agentImportPlan: AgentImportPlan?
        let agentRestructurePreviews: [AgentDefinitionChangePreview]
        let lastAppliedAgentRestructure: [AgentDefinitionChangePreview]
        let lastDeletedAgent: DeletedAgentRecord?
    }

    private func hostAdminReviewStateDigest() throws -> String {
        let administrativeLab = LabSnapshot(
            projects: store.lab.projects.sorted { $0.id.rawValue < $1.id.rawValue },
            agents: store.lab.agents.sorted { $0.id.rawValue < $1.id.rawValue },
            projectGroups: store.lab.projectGroups.sorted { $0.id.rawValue < $1.id.rawValue },
            projectProviderConfigurations: store.lab.projectProviderConfigurations.sorted {
                $0.projectID.rawValue < $1.projectID.rawValue
            },
            providerBindings: store.lab.providerBindings.sorted { $0.id.rawValue < $1.id.rawValue },
            providerCollaborationSets: store.lab.providerCollaborationSets.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            agentHandoffLinks: store.lab.agentHandoffLinks.sorted { $0.id.rawValue < $1.id.rawValue },
            handoffs: []
        )
        let reviewState = HostAdminReviewState(
            lab: administrativeLab,
            resources: store.sharedResources.sorted { $0.id.rawValue < $1.id.rawValue },
            instructions: store.instructionPacks.sorted { $0.id.rawValue < $1.id.rawValue },
            automationDefinitions: store.automationSnapshot.definitions.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            codexSyncPlan: store.codexSyncPlan,
            agentImportPlan: store.agentImportPlan,
            agentRestructurePreviews: store.agentRestructurePreviews.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            lastAppliedAgentRestructure: store.lastAppliedAgentRestructure.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            lastDeletedAgent: store.lastDeletedAgent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(reviewState))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func commitHostAdmin(
        _ request: GADHostAdminRequest,
        deviceID: DeviceID
    ) async throws -> GADCommandArtifact {
        guard !store.isBusy else {
            throw GADCommandFailure(.failedRecoverable, "The Mac is finishing another dashboard change. Try again shortly.")
        }
        switch request {
        case let .addMissingAutomationAgents(plan):
            guard await store.addMissingAutomationAgents(plan) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not add the missing agents."
                )
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Added missing Codex specialists. Review the paused automation before resuming it.",
                isUndoAvailable: false
            ))

        case let .createTemporaryAgent(intent):
            guard await store.createTemporaryAgent(
                id: intent.agentID,
                projectID: intent.projectID,
                providerID: intent.providerID,
                task: intent.task
            ) else {
                throw GADCommandFailure(.failedRecoverable, store.errorMessage ?? "Goby could not create the temporary agent.")
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Created a temporary agent for this quick task.",
                isUndoAvailable: false
            ))

        case let .retireTemporaryAgent(agentID):
            guard await store.retireTemporaryAgent(agentID) else {
                throw GADCommandFailure(.failedRecoverable, store.errorMessage ?? "Goby could not retire the temporary agent.")
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Removed the temporary agent. Run history remains available.",
                isUndoAvailable: false
            ))

        case let .saveAgent(intent):
            guard intent.agentID == nil else {
                throw GADCommandFailure(.rejectedCapability, "Editing an existing file-backed agent is not enabled remotely yet.")
            }
            let scope: AgentScope = switch intent.scope {
            case .global: .global
            case .union: .union
            case let .project(projectID): .project(projectID)
            }
            guard await store.addAgent(
                name: String(intent.name.prefix(160)),
                summary: String(intent.summary.prefix(600)),
                instructions: intent.instructions.map { String($0.prefix(64_000)) },
                capabilities: Set(intent.capabilities),
                scope: scope,
                toolPreset: intent.toolPreset
            ) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not create this agent."
                )
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Created \(String(intent.name.prefix(120))) for future routing. Existing runs were unchanged.",
                isUndoAvailable: false
            ))

        case let .setAgentEnabled(agentID, enabled):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            await store.setAgent(agentID, enabled: enabled)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "\(enabled ? "Enabled" : "Disabled") \(String(agent.name.prefix(120))) for future routing.",
                isUndoAvailable: false
            ))

        case let .publishAgent(agentID):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            await store.publishAgent(agentID)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Activated \(String(agent.name.prefix(120))) in Codex for future sessions.",
                isUndoAvailable: false
            ))

        case let .deleteAgent(agentID):
            guard let agent = store.lab.agents.first(where: { $0.id == agentID }) else {
                throw GADCommandFailure(.rejectedStale, "This agent is no longer registered in Goby.")
            }
            await store.deleteAgent(agentID)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Deleted \(String(agent.name.prefix(120))) and preserved its recovery archive and run history.",
                isUndoAvailable: true
            ))

        case .restoreLastDeletedAgent:
            guard let record = store.lastDeletedAgent else {
                throw GADCommandFailure(.rejectedStale, "There is no deleted agent available to restore.")
            }
            await store.undoLastAgentDelete()
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Restored \(String(record.agent.name.prefix(120))) to Goby and its managed definition location.",
                isUndoAvailable: false
            ))

        case .undoLastAgentRestructure:
            guard !store.lastAppliedAgentRestructure.isEmpty else {
                throw GADCommandFailure(.rejectedStale, "There is no agent-file restructure available to undo.")
            }
            await store.undoLastAgentRestructure()
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Restored the original agent definition files from Goby's recovery archive.",
                isUndoAvailable: false
            ))

        case let .removeProject(id):
            guard let project = store.lab.projects.first(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This project is no longer registered in Goby.")
            }
            await store.removeProject(id)
            if let error = store.errorMessage {
                throw GADCommandFailure(.failedRecoverable, error)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Removed \(String(project.name.prefix(120))) from Goby. Its folder and Codex definitions were unchanged; import it again to recover the registration.",
                isUndoAvailable: false
            ))

        case .exportRedactedDiagnostics:
            guard await store.prepareDiagnosticExport(),
                  let report = store.diagnosticReport,
                  let data = String(report.prefix(256_000)).data(using: .utf8) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The Mac could not prepare the redacted diagnostic report."
                )
            }
            return .redactedDiagnostics(data)

        case let .setResourceAccess(resourceID, access, enabled):
            guard let resource = store.sharedResources.first(where: { $0.id == resourceID }) else {
                throw GADCommandFailure(.rejectedStale, "This shared resource is no longer registered in Goby.")
            }
            if enabled {
                let path = resource.url.path(percentEncoded: false)
                guard FileManager.default.isReadableFile(atPath: path),
                      access != .readWrite || FileManager.default.isWritableFile(atPath: path) else {
                    throw GADCommandFailure(
                        .failedRecoverable,
                        "The Mac can no longer use the requested folder access. Review that folder in Goby Settings on the Mac."
                    )
                }
            }
            guard await store.applyRemoteResourceSettings(id: resourceID, access: access, enabled: enabled) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not update this shared resource."
                )
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: enabled
                    ? "Updated \(String(resource.name.prefix(120))) to \(access.displayName.lowercased()) for future plans."
                    : "Removed \(String(resource.name.prefix(120))) from future plans. Its registration and past run snapshots were preserved.",
                isUndoAvailable: false
            ))

        case let .switchProjectBranch(approval):
            guard let project = store.lab.projects.first(where: {
                $0.id == approval.projectID
            }) else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "This project is no longer registered in Goby."
                )
            }
            let snapshot: ProjectGitBranchSnapshot
            do {
                snapshot = try await store.applyProjectGitBranchSwitch(approval)
            } catch {
                throw GADCommandFailure(.failedRecoverable, error.localizedDescription)
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Switched \(String(project.name.prefix(120))) to \(String((snapshot.currentBranch ?? approval.destinationBranch).prefix(120))). No work was stashed, reset, merged, fetched, deleted, or pushed.",
                isUndoAvailable: false
            ))

        case let .createProject(intent):
            let (draft, _) = try newProjectDraft(for: intent)
            guard await store.createProject(draft) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "Goby could not create this project."
                )
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Created \(String(intent.name.prefix(120))) on the paired Mac with its reviewed providers, agents, links and handoff paths.",
                isUndoAvailable: false
            ))

        case let .syncCodexCatalog(projectIDs, agentIDs):
            let validation = try await validatedCodexSelection(
                projectIDs: projectIDs,
                agentIDs: agentIDs,
                deviceID: deviceID
            )
            guard await store.applyRemoteCodexCatalogSync(
                projectIDs: validation.projectIDs,
                agentIDs: validation.agentIDs,
                plan: validation.plan
            ) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The selected Codex catalog changes could not be applied. Refresh and review again."
                )
            }
            await codexCatalogReviews.remove(deviceID: deviceID)
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Imported \(projectIDs.count) project change\(projectIDs.count == 1 ? "" : "s") and \(agentIDs.count) inferred role\(agentIDs.count == 1 ? "" : "s") from Codex.",
                isUndoAvailable: false
            ))

        case .restructureAgents:
            throw GADCommandFailure(
                .rejectedPolicy,
                "Restructuring executable agent files requires a complete local review on the Mac."
            )

        case let .importAgents(selections):
            let validation = try await validatedAgentSelection(selections)
            guard await store.applyRemoteAgentImport(
                agentIDs: validation.agentIDs,
                plan: validation.plan,
                restructurePreviews: validation.restructurePreviews,
                applyFileChanges: false
            ) else {
                throw GADCommandFailure(
                    .failedRecoverable,
                    store.errorMessage ?? "The selected agent definitions could not be imported. Discover and review them again."
                )
            }
            return .operationReceipt(.init(
                id: UUID().uuidString.lowercased(),
                summary: "Imported \(validation.agentIDs.count) instruction-only agent cop\(validation.agentIDs.count == 1 ? "y" : "ies"). Source files and executable tool configuration were not authorized or changed.",
                isUndoAvailable: false
            ))
        }
    }

    private func validatedCodexSelection(
        projectIDs: [ProjectID],
        agentIDs: [AgentID],
        deviceID: DeviceID
    ) async throws -> (
        projectIDs: Set<ProjectID>,
        agentIDs: Set<AgentID>,
        plan: CodexCatalogSyncPlan
    ) {
        guard let current = await store.prepareRemoteCodexCatalogDiscovery() else {
            throw GADCommandFailure(
                .failedRecoverable,
                store.errorMessage ?? "The Mac could not revalidate the selected Codex changes."
            )
        }
        let selection = try await codexCatalogReviews.validate(
            projectIDs: projectIDs,
            agentIDs: agentIDs,
            against: current,
            registeredProjectIDs: Set(store.lab.projects.map(\.id)),
            deviceID: deviceID
        )
        return (selection.projectIDs, selection.agentIDs, current)
    }

    private func validatedAgentSelection(
        _ selections: [GADAgentImportSelection]
    ) async throws -> (
        agentIDs: Set<AgentID>,
        selectedCandidates: [AgentImportCandidate],
        plan: AgentImportPlan,
        restructurePreviews: [AgentDefinitionChangePreview]
    ) {
        let agentIDs = Set(selections.map(\.agentID))
        guard !agentIDs.isEmpty, agentIDs.count == selections.count else {
            throw GADCommandFailure(.rejectedPolicy, "Select each available agent definition at most once.")
        }
        guard let preparation = await store.prepareRemoteAgentCatalogDiscovery() else {
            throw GADCommandFailure(
                .failedRecoverable,
                store.errorMessage ?? "The Mac could not revalidate the selected agent definitions."
            )
        }
        let candidatesByID = Dictionary(uniqueKeysWithValues: preparation.plan.candidates.map { ($0.id, $0) })
        var selected: [AgentImportCandidate] = []
        selected.reserveCapacity(selections.count)
        for selection in selections {
            guard selection.reviewHash.count == 64,
                  let candidate = candidatesByID[selection.agentID],
                  try agentReviewHash(candidate) == selection.reviewHash else {
                throw GADCommandFailure(
                    .rejectedStale,
                    "A selected agent definition changed after mobile review. Discover and review it again."
                )
            }
            guard (candidate.profile.instructions?.utf8.count ?? 0) <= 64_000 else {
                throw GADCommandFailure(
                    .rejectedPolicy,
                    "A selected instruction body exceeds the bounded mobile review limit. Review that definition on the paired Mac."
                )
            }
            selected.append(candidate)
        }
        return (
            agentIDs: agentIDs,
            selectedCandidates: selected,
            plan: preparation.plan,
            restructurePreviews: preparation.restructurePreviews
        )
    }

    private func agentReviewHash(_ candidate: AgentImportCandidate) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(candidate))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func newProjectDraft(
        for intent: GADCreateProjectIntent
    ) throws -> (draft: NewProjectDraft, locationName: String) {
        let resourceID = SharedResourceID(rawValue: intent.parentLocationID.rawValue)
        guard let resource = store.sharedResources.first(where: { $0.id == resourceID }),
              resource.isEnabled,
              resource.access == .readWrite else {
            throw GADCommandFailure(
                .rejectedStale,
                "This parent location is no longer authorized for writing. Review Shared Resources on the Mac."
            )
        }
        let path = resource.url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: path),
              resource.fileSystemIdentity?.kind == .directory,
              resource.fileSystemIdentity?.matchesCurrentObject(at: resource.url) == true else {
            throw GADCommandFailure(
                .failedRecoverable,
                "The Mac can no longer write to this location. Reauthorize it in Goby Settings on the Mac."
            )
        }

        let name = intent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = intent.directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = Set(intent.providerIDs)
        let source = try intent.source.validatedRemoteSource()
        guard !name.isEmpty, name.count <= 160,
              !directoryName.isEmpty, directoryName.count <= 240,
              directoryName != ".", directoryName != "..",
              !directoryName.contains("/"), !directoryName.contains(":"), !directoryName.contains("\0"),
              !intent.platforms.isEmpty,
              providers.isSubset(of: Set(AgentProviderID.builtIn)),
              intent.agents.count <= 32,
              intent.handoffLinks.count <= 64 else {
            throw GADCommandFailure(.rejectedPolicy, "The New Project request is incomplete or exceeds Goby's safe limits.")
        }
        if intent.template != nil, source != .blank {
            throw GADCommandFailure(.rejectedPolicy, "A bundled project template cannot be applied over a Git clone.")
        }
        if let template = intent.template {
            guard let descriptor = ProjectTemplateCatalog.descriptor(
                for: template.id,
                version: template.version
            ), Set(template.parameters.keys) == Set(descriptor.parameters.map(\.id)),
                  descriptor.parameters.allSatisfy({ parameter in
                      ProjectTemplateCatalog.normalizedParameterValue(
                          template.parameters[parameter.id] ?? "",
                          kind: parameter.kind
                      ) != nil
                  }) else {
                throw GADCommandFailure(.rejectedPolicy, "The selected bundled project template or its options are not available on this Mac.")
            }
        }
        if let link = intent.link,
           !store.lab.projects.contains(where: { $0.id == link.projectID }) {
            throw GADCommandFailure(.rejectedStale, "The linked project is no longer registered in Goby.")
        }
        if let link = intent.link,
           !store.lab.projectGroups.contains(where: { group in
               group.members.contains { $0.projectID == link.projectID }
           }),
           (link.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GADCommandFailure(.rejectedPolicy, "Enter a project-group name for the new project link.")
        }

        let agents = try intent.agents.map { agent -> NewProjectAgentDraft in
            let agentProviders = Set(agent.providerIDs)
            guard !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !agent.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !agent.capabilities.isEmpty,
                  agent.name.count <= 160,
                  agent.summary.count <= 600,
                  (agent.instructions?.count ?? 0) <= 64_000,
                  agent.capabilities.count <= AgentCapability.allCases.count,
                  agentProviders.isSubset(of: providers),
                  agent.providerInstructions.count <= agentProviders.count,
                  agent.providerInstructions.allSatisfy({ agentProviders.contains($0.key) && $0.value.count <= 64_000 }) else {
                throw GADCommandFailure(.rejectedPolicy, "A project agent is incomplete or exceeds Goby's safe limits.")
            }
            return NewProjectAgentDraft(
                name: agent.name,
                summary: agent.summary,
                instructions: agent.instructions,
                capabilities: Set(agent.capabilities),
                providerIDs: agentProviders,
                providerInstructions: agent.providerInstructions
            )
        }
        let normalizedAgentNames = Set(agents.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        guard normalizedAgentNames.count == agents.count else {
            throw GADCommandFailure(.rejectedPolicy, "Project agent names must be unique.")
        }
        let handoffs = try intent.handoffLinks.map { handoff -> NewProjectHandoffDraft in
            guard agents.indices.contains(handoff.sourceAgentIndex),
                  agents.indices.contains(handoff.destinationAgentIndex),
                  agents[handoff.sourceAgentIndex].providerIDs.contains(handoff.sourceProviderID),
                  agents[handoff.destinationAgentIndex].providerIDs.contains(handoff.destinationProviderID),
                  handoff.sourceAgentIndex != handoff.destinationAgentIndex
                    || handoff.sourceProviderID != handoff.destinationProviderID,
                  !handoff.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !handoff.conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !handoff.acceptedArtifacts.isEmpty,
                  !handoff.triggers.isEmpty,
                  (1...8).contains(handoff.maximumDepth) else {
                throw GADCommandFailure(.rejectedPolicy, "A handoff path has an invalid endpoint, purpose, artifact, trigger, or depth.")
            }
            return NewProjectHandoffDraft(
                sourceAgentIndex: handoff.sourceAgentIndex,
                sourceProviderID: handoff.sourceProviderID,
                destinationAgentIndex: handoff.destinationAgentIndex,
                destinationProviderID: handoff.destinationProviderID,
                purpose: String(handoff.purpose.prefix(600)),
                conditions: String(handoff.conditions.prefix(1_000)),
                acceptedArtifacts: Set(handoff.acceptedArtifacts),
                maximumDepth: handoff.maximumDepth,
                triggers: Set(handoff.triggers)
            )
        }
        let link = intent.link.map {
            NewProjectLinkDraft(
                projectID: $0.projectID,
                groupName: $0.groupName.map { String($0.prefix(160)) },
                projectRole: $0.projectRole,
                linkedProjectRole: $0.linkedProjectRole
            )
        }
        return (
            NewProjectDraft(
                name: name,
                directoryName: directoryName,
                parentURL: resource.url,
                parentFileSystemIdentity: resource.fileSystemIdentity,
                source: source,
                platforms: Set(intent.platforms),
                providerIDs: providers,
                agents: agents,
                link: link,
                collaborateAcrossProviders: intent.collaborateAcrossProviders,
                handoffLinks: handoffs,
                template: intent.template
            ),
            resource.name
        )
    }

    private func mobileScope(_ scope: AgentScope) -> GADAgentScopeProjection {
        switch scope {
        case .global: .global
        case .union: .union
        case let .project(id): .project(id)
        }
    }

    private func mobileSafeText(
        _ source: String,
        limit: Int,
        allowsKnownInstructionBody: Bool = false,
        exactForbiddenValues: [String] = []
    ) -> String {
        var result = source
        var forbidden = store.lab.projects.flatMap { project in
            [project.rootURL.path(percentEncoded: false)]
                + project.instructionFiles.map { $0.path(percentEncoded: false) }
                + project.testCommands
        }
        let agentForbidden = store.lab.agents.flatMap { agent in
            [agent.sourceURL?.path(percentEncoded: false), agent.codexRegistrationKey].compactMap { $0 }
                + (allowsKnownInstructionBody ? [] : [agent.instructions].compactMap { $0 })
        }
        forbidden.append(contentsOf: agentForbidden)
        forbidden.append(contentsOf: store.sharedResources.map { $0.url.path(percentEncoded: false) })
        forbidden.append(contentsOf: exactForbiddenValues)
        for value in forbidden.sorted(by: { $0.count > $1.count }) where value.count >= 3 {
            result = result.replacingOccurrences(of: value, with: "[redacted]")
        }
        return SensitiveTextRedactor.redact(
            result,
            exactForbiddenValues: exactForbiddenValues,
            limit: limit
        )
    }

    private func exactMobileForbiddenValues() async throws -> [String] {
        var values: [String] = []
        for providerID in AgentProviderID.builtIn {
            if let credential = try await providerCredentials.credential(for: providerID),
               credential.count >= 3 {
                values.append(credential)
            }
        }
        return values
    }

    private func mobileSafeArtifact(
        _ artifact: GADCommandArtifact,
        exactForbiddenValues: [String]
    ) -> GADCommandArtifact {
        switch artifact {
        case .rememberedApprovals:
            // This artifact can only be requested by an authenticated local Mac client.
            return artifact
        case let .approvalDisclosure(disclosure):
            // Approval text is rendered and size-checked exactly once before
            // the device-bound receipt is issued. Re-rendering here could
            // expand an alias differently or silently hide a suffix.
            return .approvalDisclosure(disclosure)

        case let .instructionEditor(editor):
            return .instructionEditor(.init(
                id: editor.id,
                name: mobileSafeText(
                    editor.name,
                    limit: 160,
                    exactForbiddenValues: exactForbiddenValues
                ),
                body: mobileSafeText(
                    editor.body,
                    limit: 64_000,
                    allowsKnownInstructionBody: true,
                    exactForbiddenValues: exactForbiddenValues
                ),
                scope: editor.scope,
                version: editor.version,
                isEnabled: editor.isEnabled,
                expiresAt: editor.expiresAt
            ))

        case let .providerBindingInstructionEditor(editor):
            return .providerBindingInstructionEditor(.init(
                bindingID: editor.bindingID,
                instructions: mobileSafeText(
                    editor.instructions,
                    limit: 64_000,
                    allowsKnownInstructionBody: true,
                    exactForbiddenValues: exactForbiddenValues
                ),
                expiresAt: editor.expiresAt
            ))

        case let .codexCatalogDiscovery(discovery):
            return .codexCatalogDiscovery(.init(
                projects: discovery.projects.map { project in
                    .init(
                        id: project.id,
                        name: mobileSafeText(
                            project.name,
                            limit: 160,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        platforms: project.platforms,
                        isGitRepository: project.isGitRepository,
                        evidence: project.evidence.map {
                            mobileSafeText($0, limit: 600, exactForbiddenValues: exactForbiddenValues)
                        }
                    )
                },
                agents: discovery.agents.map { agent in
                    .init(
                        id: agent.id,
                        name: mobileSafeText(
                            agent.name,
                            limit: 160,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        summary: mobileSafeText(
                            agent.summary,
                            limit: 600,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        capabilities: agent.capabilities,
                        scope: agent.scope,
                        evidence: agent.evidence.map {
                            mobileSafeText($0, limit: 600, exactForbiddenValues: exactForbiddenValues)
                        },
                        requiresMacReview: agent.requiresMacReview
                    )
                },
                scannedProjectCount: discovery.scannedProjectCount,
                scannedAgentCount: discovery.scannedAgentCount,
                limitedProjectAccessCount: discovery.limitedProjectAccessCount,
                warnings: discovery.warnings.map {
                    mobileSafeText($0, limit: 600, exactForbiddenValues: exactForbiddenValues)
                },
                expiresAt: discovery.expiresAt
            ))

        case let .agentCatalogDiscovery(discovery):
            return .agentCatalogDiscovery(.init(
                candidates: discovery.candidates.map { candidate in
                    .init(
                        id: candidate.id,
                        name: mobileSafeText(
                            candidate.name,
                            limit: 160,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        summary: mobileSafeText(
                            candidate.summary,
                            limit: 600,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        instructions: candidate.instructions.map {
                            mobileSafeText(
                                $0,
                                limit: 64_000,
                                allowsKnownInstructionBody: true,
                                exactForbiddenValues: exactForbiddenValues
                            )
                        },
                        capabilities: candidate.capabilities,
                        scope: candidate.scope,
                        evidence: candidate.evidence.map {
                            mobileSafeText($0, limit: 600, exactForbiddenValues: exactForbiddenValues)
                        },
                        canRestructure: candidate.canRestructure,
                        requiresMacReview: candidate.requiresMacReview,
                        reviewHash: candidate.reviewHash
                    )
                },
                totalCandidateCount: discovery.totalCandidateCount,
                nextOffset: discovery.nextOffset,
                expiresAt: discovery.expiresAt
            ))

        case let .projectGitBranches(discovery):
            return .projectGitBranches(.init(
                projectID: discovery.projectID,
                currentBranch: discovery.currentBranch.map {
                    mobileSafeText($0, limit: 240, exactForbiddenValues: exactForbiddenValues)
                },
                localBranches: discovery.localBranches.map {
                    mobileSafeText($0, limit: 240, exactForbiddenValues: exactForbiddenValues)
                },
                hasUncommittedChanges: discovery.hasUncommittedChanges,
                expiresAt: discovery.expiresAt
            ))

        case let .hostAdminPreview(preview):
            return .hostAdminPreview(.init(
                id: preview.id,
                hash: preview.hash,
                expiresAt: preview.expiresAt,
                requiresLocalAuthentication: preview.requiresLocalAuthentication,
                effects: preview.effects.map { effect in
                    .init(
                        id: effect.id,
                        title: mobileSafeText(
                            effect.title,
                            limit: 240,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        detail: mobileSafeText(
                            effect.detail,
                            limit: 1_200,
                            exactForbiddenValues: exactForbiddenValues
                        ),
                        isDestructive: effect.isDestructive
                    )
                }
            ))

        case let .operationReceipt(receipt):
            return .operationReceipt(.init(
                id: receipt.id,
                summary: mobileSafeText(
                    receipt.summary,
                    limit: 1_200,
                    exactForbiddenValues: exactForbiddenValues
                ),
                isUndoAvailable: receipt.isUndoAvailable
            ))

        case let .redactedDiagnostics(data):
            guard let source = String(data: data, encoding: .utf8) else {
                return .redactedDiagnostics(Data("Diagnostic content was unavailable.".utf8))
            }
            return .redactedDiagnostics(Data(mobileSafeText(
                source,
                limit: 256 * 1_024,
                exactForbiddenValues: exactForbiddenValues
            ).utf8))
        }
    }

    private func mobileApprovalDisclosureContent(
        _ approval: ProviderApprovalRequest,
        exactForbiddenValues: [String]
    ) -> MobileApprovalDisclosureContent? {
        let projectOrdinals = MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: store.lab.projects.map(\.id.rawValue)
        )
        let resourceOrdinals = MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: store.sharedResources.map(\.id.rawValue)
        )
        guard projectOrdinals.count == store.lab.projects.count,
              resourceOrdinals.count == store.sharedResources.count else {
            return nil
        }
        let aliases = store.lab.projects.map { project in
            let path = project.rootURL.path(percentEncoded: false)
            return (
                path: path,
                alias: MobileApprovalDisclosurePolicy.alias(
                    kind: .project,
                    displayName: project.name,
                    ordinal: projectOrdinals[project.id.rawValue] ?? 0
                )
            )
        } + store.sharedResources.map { resource in
            let path = resource.url.path(percentEncoded: false)
            return (
                path: path,
                alias: MobileApprovalDisclosurePolicy.alias(
                    kind: .sharedResource,
                    displayName: resource.name,
                    ordinal: resourceOrdinals[resource.id.rawValue] ?? 0
                )
            )
        }
        return MobileApprovalDisclosurePolicy.render(
            kind: approval.kind,
            summary: approval.summary,
            details: approval.details,
            aliases: aliases,
            exactForbiddenValues: exactForbiddenValues
        )
    }

    private static func approvalRequestDigest(_ approval: ProviderApprovalRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(approval)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func makeOpaqueApprovalReceipt() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GADCommandFailure(
                .failedRecoverable,
                "Goby could not create a secure one-use approval receipt."
            )
        }
        return Data(bytes).base64EncodedString()
    }

    public func projection(replacing current: DashboardProjection?) async throws -> DashboardProjection {
        let securedCurrent = try current.map(secureProjection)
        let revision = securedCurrent?.draft.revision ?? .zero
        let candidate = try await projection(replacing: securedCurrent, draftRevision: revision)
        let draftChanged = securedCurrent.map { $0.draft != candidate.draft } ?? false
        guard draftChanged else { return candidate }
        return try await projection(
            replacing: securedCurrent,
            draftRevision: revision.advanced()
        )
    }

    private func projection(
        replacing current: DashboardProjection?,
        draftRevision: EntityRevision
    ) async throws -> DashboardProjection {
        let timestamp = Date.now
        let exactForbiddenValues = try await exactMobileForbiddenValues()
        let localProjection = builder.build(
            host: GADHostProjection(
                id: hostID,
                displayName: ProcessInfo.processInfo.hostName,
                reachability: .online,
                lastUpdatedAt: timestamp
            ),
            revision: current?.revision ?? .zero,
            draft: GADDraftProjection(
                revision: draftRevision,
                text: store.prompt,
                attachments: store.promptAttachments.map(GADDraftAttachmentProjection.init),
                providerID: store.selectedProviderID,
                model: store.promptModelID,
                platform: promptPlatform,
                projectIDs: store.promptProjectIDs.sorted { $0.rawValue < $1.rawValue },
                agentTargets: store.promptAgentTargets.sorted {
                    if $0.projectID.rawValue == $1.projectID.rawValue {
                        return $0.agentID.rawValue < $1.agentID.rawValue
                    }
                    return $0.projectID.rawValue < $1.projectID.rawValue
                },
                groupID: store.promptProjectGroupID
            ),
            lab: store.lab,
            runs: store.runs,
            automations: store.automationSnapshot,
            approvals: store.pendingApprovals,
            resources: store.sharedResources,
            instructions: store.instructionPacks,
            plan: store.proposedPlan,
            planStartsWithoutReview: store.proposedPlanStartsWithoutReview,
            trustedProjectIDs: store.trustedProjectIDs,
            selectedResourceIDs: store.selectedRunResourceIDs,
            codexTasks: store.codexTasks,
            account: store.codexAccount,
            providerAccounts: store.providerAccounts,
            providerActivityFreshness: [.codex: store.codexActivityRefresh],
            providerCredentialConfigured: [
                .claude: store.claudeCredentialConfigured || store.claudeSubscriptionConfigured,
                .githubCopilot: store.copilotCredentialConfigured
            ],
            providerTasks: store.providerTasks,
            health: store.systemHealth,
            exactForbiddenValues: exactForbiddenValues,
            temporaryChat: store.temporaryChat,
            generatedAt: timestamp
        )
        return try aliasForRemote(localProjection)
    }

    public func secureProjection(_ projection: DashboardProjection) throws -> DashboardProjection {
        try aliasForRemote(projection)
    }

    public func secureCheckpoint(_ checkpoint: GADCoordinatorCheckpoint) throws -> GADCoordinatorCheckpoint {
        try aliasForRemote(checkpoint)
    }

    public func localizeLocalCommand(_ command: GADHostLocalCommand) throws -> GADHostLocalCommand {
        do {
            return try remoteIdentifierAliasCodec.localizing(command, aliases: remoteIdentifierAliases)
        } catch {
            throw GADCommandFailure(.rejectedStale, "This local item changed. Refresh the dashboard and try again.")
        }
    }

    public func aliasLocalArtifact(_ artifact: GADHostIPCArtifact) throws -> GADHostIPCArtifact {
        switch artifact {
        case .localCatalog, .localRun, .localProjectCandidates, .projectGitBranches:
            try aliasForRemote(artifact)
        default:
            artifact
        }
    }

    public func redactLocalOutput(_ source: String, limit: Int) async throws -> String {
        SensitiveTextRedactor.redact(source, exactForbiddenValues: try await exactMobileForbiddenValues(), limit: limit)
    }

    private func aliasForRemote<Value: Codable & Sendable>(_ value: Value) throws -> Value {
        let result = try remoteIdentifierAliasCodec.aliasing(value)
        remoteIdentifierAliases = remoteIdentifierAliasCodec.merging(
            remoteIdentifierAliases,
            with: result.aliases
        )
        return result.value
    }

    private func apply(_ replacement: GADDraftReplacement, from deviceID: DeviceID) throws {
        guard store.availableProviderIDs.contains(replacement.providerID) else {
            throw GADCommandFailure(.rejectedStale, "The selected provider is no longer available. Refresh and review the draft.")
        }
        if let groupID = replacement.groupID {
            guard store.lab.projectGroups.contains(where: { $0.id == groupID }) else {
                throw GADCommandFailure(.rejectedStale, "The selected project group changed. Refresh and review the draft.")
            }
        } else {
            let projectIDs = Set(replacement.projectIDs)
            let registeredProjectIDs = Set(store.lab.projects.map(\.id))
            guard projectIDs.isSubset(of: registeredProjectIDs),
                  replacement.agentTargets.allSatisfy({ target in
                      target.providerID == replacement.providerID
                          && projectIDs.contains(target.projectID)
                          && AgentRoutingMatcher.isEligible(target, in: store.lab)
                  }) else {
                throw GADCommandFailure(.rejectedStale, "The selected projects or agents changed. Refresh and review the draft.")
            }
        }
        store.selectProviderPlane(replacement.providerID)
        store.selectPromptModel(replacement.model)
        let scope: PromptScope = switch replacement.platform {
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        case .backend, .general, .none: .all
        }
        // Platform and exact targets are independent parts of a draft. Apply
        // the scope first because changing it clears project/agent selection.
        store.setPromptScope(scope)
        if let groupID = replacement.groupID {
            store.setPromptProjectGroup(groupID)
        } else {
            guard store.setPromptRecipients(
                projectIDs: Set(replacement.projectIDs),
                agentTargets: Set(replacement.agentTargets)
            ) else {
                throw GADCommandFailure(
                    .rejectedStale,
                    store.errorMessage ?? "The selected projects or agents changed. Review the recipients and try again."
                )
            }
        }
        store.prompt = String(replacement.text.prefix(32_000))
        store.replacePromptAttachments(
            replacement.attachments,
            allowingNewSources: localAttachmentSourceDevices.contains(deviceID)
        )
    }

    private var promptPlatform: ProjectPlatform? {
        switch store.promptScope {
        case .all: nil
        case .web: .web
        case .macOS: .macOS
        case .iOS: .iOS
        case .android: .android
        case .research: .research
        }
    }

    private func apply(_ update: GADPlanUpdate) throws {
        guard let plan = store.proposedPlan, plan.id == update.planID else {
            throw GADCommandFailure(.rejectedStale, "This plan changed; review the refreshed scope.")
        }
        guard !store.isBusy else {
            throw GADCommandFailure(.failedRecoverable, "Goby is finishing another action. Try saving the reviewed scope again.")
        }
        let selectedProjectIDs = Set(update.routes.map(\.projectID))
        guard selectedProjectIDs.count == update.routes.count,
              !update.routes.isEmpty else {
            throw GADCommandFailure(.rejectedPolicy, "Select at least one project.")
        }
        let projects = Dictionary(uniqueKeysWithValues: store.lab.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: store.lab.agents.map { ($0.id, $0) })
        var revisedRoutes: [ProjectRoute] = []
        for route in update.routes {
            guard projects[route.projectID] != nil,
                  !route.agentIDs.isEmpty,
                  Set(route.agentIDs).count == route.agentIDs.count else {
                throw GADCommandFailure(.rejectedPolicy, "Every selected project needs at least one valid agent.")
            }
            for agentID in route.agentIDs {
                guard let agent = agents[agentID], agent.isEnabled, agentCanWork(agent, in: route.projectID) else {
                    throw GADCommandFailure(.rejectedPolicy, "A selected agent is not available for that project.")
                }
            }
            // Resolve the entire requested provider scope before any setter
            // can remove an existing route or agent from the reviewed plan.
            let previousRoute = plan.routes.first { $0.projectID == route.projectID }
            let providerID = previousRoute?.providerID ?? store.selectedProviderID
            let model: String? = if let previousRoute {
                previousRoute.model
            } else {
                plan.routes.first?.model
            }
            do {
                let bindings = try ProviderBindingResolver.routeBindings(
                    agentIDs: route.agentIDs, providerID: providerID,
                    projectID: route.projectID, in: store.lab.providerBindings
                )
                revisedRoutes.append(ProjectRoute(
                    projectID: route.projectID, providerID: providerID,
                    model: model,
                    agentIDs: route.agentIDs, providerBindings: bindings,
                    reason: previousRoute?.agentIDs == route.agentIDs
                        ? (previousRoute?.reason ?? "Reviewed scope.")
                        : "Adjusted manually; \(route.agentIDs.count) agent\(route.agentIDs.count == 1 ? "" : "s") selected."
                ))
            } catch {
                throw GADCommandFailure(.rejectedPolicy, error.localizedDescription)
            }
        }
        let enabledResourceIDs = Set(store.sharedResources.filter(\.isEnabled).map(\.id))
        let requestedResourceIDs = Set(update.selectedResourceIDs)
        guard requestedResourceIDs.isSubset(of: enabledResourceIDs) else {
            throw GADCommandFailure(.rejectedPolicy, "A selected resource is no longer available.")
        }

        guard store.applyValidatedPlanScope(
            planID: update.planID, routes: revisedRoutes, resourceIDs: requestedResourceIDs
        ) else {
            throw GADCommandFailure(.failedRecoverable, "Goby could not save this reviewed scope. Refresh the plan and try again.")
        }
        guard let revised = store.proposedPlan,
              Set(revised.routes.map(\.projectID)) == selectedProjectIDs,
              update.routes.allSatisfy({ selection in
                  revised.routes.contains {
                      $0.projectID == selection.projectID && Set($0.agentIDs) == Set(selection.agentIDs)
                  }
              }), store.selectedRunResourceIDs == requestedResourceIDs else {
            throw GADCommandFailure(
                .failedRecoverable,
                store.errorMessage ?? "Goby could not save the complete reviewed scope. Refresh the plan and try again."
            )
        }
    }

    private func agentCanWork(_ agent: AgentProfile, in projectID: ProjectID) -> Bool {
        switch agent.scope {
        case .global, .union: true
        case let .project(scopedProjectID): scopedProjectID == projectID
        }
    }
}
