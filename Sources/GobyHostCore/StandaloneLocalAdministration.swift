import Foundation
import GobyApplication
import GobyDomain
import GobyInfrastructure
import GobyOperations

/// Same-user CLI administration. No relay, app lifecycle or credential bytes
/// enter this surface. Identifiers use the coordinator's existing alias space.
@MainActor
final class StandaloneLocalAdministration: GADHostLocalAdministrationHandling {
    private let store: AppStore
    private let commands: AppStoreGADCommandHandler
    private let diffReader = RunWorkspaceDiffReader()
    private let delivery = RunDeliveryService()
    init(store: AppStore, commands: AppStoreGADCommandHandler) {
        self.store = store
        self.commands = commands
    }
    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot {
        .init(relayURLText: "", phase: .disabled)
    }
    func applyRemoteAccessCommand(_ command: GADHostRemoteAccessCommand) async -> GADHostRemoteAccessSnapshot {
        .init(relayURLText: "", phase: .failed, failureMessage: "Remote Access is unavailable in the CLI.")
    }
    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact {
        let command = try commands.localizeLocalCommand(command)
        let artifact: GADHostIPCArtifact
        switch command {
        case .inspectLocalCatalog:
            artifact = .localCatalog(.init(projects: store.lab.projects, agents: store.lab.agents))
        case let .inspectLocalRun(id):
            guard let run = store.runs.first(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This run is no longer available.")
            }
            artifact = .localRun(run.localPresentationCopy)
        case let .inspectLocalRunDiff(id):
            guard let run = store.runs.first(where: { $0.id == id }) else {
                throw GADCommandFailure(.rejectedStale, "This run is no longer available.")
            }
            let diff = try await diffReader.read(run: run, projects: store.lab.projects)
            artifact = .localRunDiff(try await commands.redactLocalOutput(diff, limit: 512 * 1_024))
        case let .previewRunDelivery(id, kind):
            guard let run = store.runs.first(where: { $0.id == id }),
                  !store.runs.contains(where: { !$0.status.isFinished && $0.status != .draft }) else {
                throw GADCommandFailure(.rejectedPolicy, "Finish active work before reviewing Git delivery.")
            }
            let preview = try await delivery.preview(run: run, projects: store.lab.projects, kind: kind)
            artifact = .runDeliveryPreview(.init(id: preview.id, digest: preview.digest, kind: preview.kind,
                projectName: preview.projectName, branch: preview.branch, remote: preview.remote,
                summary: try await commands.redactLocalOutput(preview.summary, limit: 48_000), expiresAt: preview.expiresAt))
        case let .executeRunDelivery(id, digest):
            guard !store.runs.contains(where: { !$0.status.isFinished && $0.status != .draft }) else {
                throw GADCommandFailure(.rejectedPolicy, "Finish active work before delivering changes.")
            }
            let summary = try await delivery.execute(previewID: id, digest: digest)
            artifact = .localReceipt(.init(id: id, summary: try await commands.redactLocalOutput(summary, limit: 8_000), isUndoAvailable: false))
        case let .providerCredentialChanged(providerID):
            guard await store.providerCredentialDidChange(providerID) else { try checkError(); throw GADCommandFailure(.failedRecoverable, "Provider refresh failed.") }
            artifact = .localReceipt(.init(id: UUID().uuidString, summary: "Refreshed the provider's credential state.", isUndoAvailable: false))
        case let .inspectProjectBookmarks(bookmarks):
            await store.discover(urls: try resolve(bookmarks))
            try checkError()
            artifact = .localProjectCandidates(store.importCandidates.map {
                .init(id: $0.id, name: $0.project.name, rootURL: $0.project.rootURL,
                      platforms: $0.project.platforms.sorted { $0.rawValue < $1.rawValue },
                      frameworks: $0.project.frameworks, isGitRepository: $0.project.isGitRepository,
                      evidence: $0.evidence)
            })
        case let .registerProjectBookmarks(bookmarks, selectedProjectIDs):
            await store.discover(urls: try resolve(bookmarks))
            try checkError()
            let selected = Set(selectedProjectIDs)
            guard !selected.isEmpty, selected.isSubset(of: Set(store.importCandidates.map(\.id))) else {
                throw GADCommandFailure(.rejectedStale, "The selected repository changed. Inspect it again.")
            }
            store.selectedImportIDs = selected
            await store.registerSelectedProjects()
            try checkError()
            artifact = .localReceipt(.init(id: UUID().uuidString, summary: "Registered the reviewed repository.", isUndoAvailable: false))
        default:
            throw GADCommandFailure(.rejectedCapability, "This administration operation is unavailable in the CLI host.")
        }
        return try commands.aliasLocalArtifact(artifact)
    }
    private func resolve(_ bookmarks: [Data]) throws -> [URL] {
        guard (1...8).contains(bookmarks.count) else { throw GADCommandFailure(.rejectedPolicy, "Choose up to eight repositories.") }
        return try bookmarks.map {
            var stale = false
            let url = try URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            guard !stale, url.isFileURL else { throw GADCommandFailure(.rejectedPolicy, "This repository bookmark changed.") }
            return url
        }
    }
    private func checkError() throws {
        if let message = store.errorMessage { throw GADCommandFailure(.failedRecoverable, message) }
    }
}
