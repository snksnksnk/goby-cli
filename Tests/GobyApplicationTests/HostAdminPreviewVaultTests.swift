import Foundation
import GobyDomain
import Testing
@testable import GobyApplication

@Suite("Host administration preview vault")
struct HostAdminPreviewVaultTests {
    private let phone = DeviceID(rawValue: "phone")

    @Test("Host administration commands use the reviewed state instead of the global projection revision")
    func commandRevisionPolicy() {
        #expect(!GADCommandPayload.requestHostAdminPreview(.exportRedactedDiagnostics).requiresExactBaseRevision)
        #expect(!GADCommandPayload.commitHostAdmin(.init(
            previewID: "preview",
            previewHash: "hash",
            authorizationAssertion: nil
        )).requiresExactBaseRevision)
    }

    @Test("A preview commits exactly once with the reviewed hash and revision")
    func exactOneTimeCommit() async throws {
        let timestamp = Date(timeIntervalSince1970: 50_000)
        let vault = GADHostAdminPreviewVault(now: { timestamp })
        let request = GADHostAdminRequest.removeProject(.init(rawValue: "project"))
        let preview = try await vault.issue(
            request: request,
            deviceID: phone,
            baseRevision: .init(rawValue: 4),
            effects: [.init(id: "remove", title: "Remove project", detail: "Folder remains unchanged.", isDestructive: true)],
            requiresLocalAuthentication: true
        )

        let accepted = try await vault.consume(
            .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: "authenticated"),
            deviceID: phone,
            currentRevision: .init(rawValue: 4)
        )
        #expect(accepted == request)
        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: "authenticated"),
                deviceID: phone,
                currentRevision: .init(rawValue: 4)
            )
        }
    }

    @Test("A changed hash consumes and rejects the preview")
    func alteredHashRejected() async throws {
        let vault = GADHostAdminPreviewVault()
        let preview = try await vault.issue(
            request: .exportRedactedDiagnostics,
            deviceID: phone,
            baseRevision: .zero,
            effects: [],
            requiresLocalAuthentication: false
        )

        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: preview.id, previewHash: "altered", authorizationAssertion: nil),
                deviceID: phone,
                currentRevision: .zero
            )
        }
    }

    @Test("A stable review state permits an unrelated canonical revision advance")
    func stableReviewStatePermitsRevisionAdvance() async throws {
        let vault = GADHostAdminPreviewVault()
        let request = GADHostAdminRequest.saveAgent(.init(
            agentID: nil,
            projectID: .init(rawValue: "project"),
            name: "Research",
            summary: "General research",
            instructions: nil,
            capabilities: [.research]
        ))
        let preview = try await vault.issue(
            request: request,
            deviceID: phone,
            baseRevision: .init(rawValue: 8),
            effects: [],
            requiresLocalAuthentication: false,
            reviewStateDigest: "stable-administration-state"
        )

        let accepted = try await vault.consume(
            .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: nil),
            deviceID: phone,
            currentRevision: .init(rawValue: 9),
            currentReviewStateDigest: "stable-administration-state"
        )
        #expect(accepted == request)
    }

    @Test("A changed review state rejects the preview even at the same revision")
    func changedReviewStateRejected() async throws {
        let vault = GADHostAdminPreviewVault()
        let preview = try await vault.issue(
            request: .exportRedactedDiagnostics,
            deviceID: phone,
            baseRevision: .init(rawValue: 8),
            effects: [],
            requiresLocalAuthentication: false,
            reviewStateDigest: "before"
        )

        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: nil),
                deviceID: phone,
                currentRevision: .init(rawValue: 8),
                currentReviewStateDigest: "after"
            )
        }
    }

    @Test("Authentication is enforced without consuming a valid preview")
    func authentication() async throws {
        let vault = GADHostAdminPreviewVault()
        let preview = try await vault.issue(
            request: .removeProject(.init(rawValue: "project")),
            deviceID: phone,
            baseRevision: .init(rawValue: 2),
            effects: [],
            requiresLocalAuthentication: true
        )

        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: nil),
                deviceID: phone,
                currentRevision: .init(rawValue: 2)
            )
        }
        let accepted = try await vault.consume(
            .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: "authenticated"),
            deviceID: phone,
            currentRevision: .init(rawValue: 2)
        )
        #expect(accepted == .removeProject(.init(rawValue: "project")))
    }

    @Test("A preview from one paired device cannot be committed by another")
    func deviceBinding() async throws {
        let vault = GADHostAdminPreviewVault()
        let preview = try await vault.issue(
            request: .exportRedactedDiagnostics,
            deviceID: .init(rawValue: "first-phone"),
            baseRevision: .zero,
            effects: [],
            requiresLocalAuthentication: false
        )

        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: preview.id, previewHash: preview.hash, authorizationAssertion: nil),
                deviceID: .init(rawValue: "second-phone"),
                currentRevision: .zero
            )
        }
    }

    @Test("A newer preview supersedes the same device and operation class")
    func supersedesMatchingPreview() async throws {
        let vault = GADHostAdminPreviewVault()
        let first = try await vault.issue(
            request: .removeProject(.init(rawValue: "first")),
            deviceID: phone,
            baseRevision: .zero,
            effects: [],
            requiresLocalAuthentication: true
        )
        let secondRequest = GADHostAdminRequest.removeProject(.init(rawValue: "second"))
        let second = try await vault.issue(
            request: secondRequest,
            deviceID: phone,
            baseRevision: .zero,
            effects: [],
            requiresLocalAuthentication: true
        )

        await #expect(throws: GADCommandFailure.self) {
            try await vault.consume(
                .init(previewID: first.id, previewHash: first.hash, authorizationAssertion: "authenticated"),
                deviceID: phone,
                currentRevision: .zero
            )
        }
        let accepted = try await vault.consume(
            .init(previewID: second.id, previewHash: second.hash, authorizationAssertion: "authenticated"),
            deviceID: phone,
            currentRevision: .zero
        )
        #expect(accepted == secondRequest)
    }

    @Test("Oversized administration requests are rejected before retention")
    func oversizedRequestRejected() async {
        let vault = GADHostAdminPreviewVault()
        let request = GADHostAdminRequest.saveAgent(.init(
            agentID: nil,
            projectID: nil,
            name: "Large",
            summary: "Fixture",
            instructions: String(repeating: "x", count: 300 * 1_024),
            capabilities: [.routing]
        ))

        await #expect(throws: GADCommandFailure.self) {
            try await vault.issue(
                request: request,
                deviceID: phone,
                baseRevision: .zero,
                effects: [],
                requiresLocalAuthentication: false
            )
        }
    }
}
