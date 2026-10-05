import Foundation
import GobyApplication
import GobyInfrastructure
import Testing

@Suite("Mac host ownership migration")
struct HostOwnershipMigrationTests {
    @Test("A retained foreground repository cannot race helper backup after the lease moves")
    func retiredForegroundCannotRaceBackup() async throws {
        let parent = temporaryDirectory(named: "retired-owner")
        let live = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        let foregroundLease = GADHostOwnershipLease(storeDirectory: live)
        try await foregroundLease.acquire(ownerID: "foreground", role: .legacyUI)
        let foregroundStore = PersistentStore(directoryURL: live)
        try await foregroundStore.saveOperationalContinuity(.init(draftText: "Previous"))
        try await foregroundStore.saveOperationalContinuity(.init(draftText: "Final draft"))
        await foregroundStore.suspendWrites()
        try await foregroundLease.release()

        let helperLease = GADHostOwnershipLease(storeDirectory: live)
        try await helperLease.acquire(ownerID: "helper", role: .hostHelper)
        let manager = GADPreHostBackupManager()
        let backup = try await manager.prepareTransfer(
            storeDirectory: live, backupRoot: backups, lease: helperLease, ownerID: "helper"
        ) {
            await #expect(throws: GADPersistenceOwnershipError.writesSuspended) {
                try await foregroundStore.saveOperationalContinuity(.init(draftText: "Late callback"))
            }
        }
        try await manager.validate(backup)
        try await manager.verifyRollbackSource(backup, storeDirectory: live, lease: helperLease, ownerID: "helper")
        #expect(try await PersistentStore(directoryURL: live).loadOperationalContinuity().draftText == "Final draft")

        // A failed helper transition restores the same owner only after the
        // helper releases and the foreground reacquires the kernel lease.
        try await helperLease.release()
        try await foregroundLease.acquire(ownerID: "foreground", role: .legacyUI)
        await foregroundStore.resumeWrites()
        try await foregroundStore.saveOperationalContinuity(.init(draftText: "Resumed foreground"))
        try await manager.validate(backup)
        try await foregroundLease.release()
    }

    /// Regression, 30 September 2026: the temporary chat's Codex home was
    /// written inside the store with an `auth.json` symbolic link, so every
    /// host takeover failed its backup and the app fell back in-process.
    @Test("A leftover temporary chat folder in the store no longer blocks host takeover")
    func temporaryChatFolderDoesNotBlockBackup() async throws {
        let parent = temporaryDirectory(named: "temporary-chat-backup")
        let live = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        let home = live.appending(path: "TemporaryChat/CodexHome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: parent.appending(path: "auth.json"))
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: "auth.json"), withDestinationURL: parent.appending(path: "auth.json")
        )
        try await PersistentStore(directoryURL: live).saveOperationalContinuity(.init(draftText: "Kept"))
        let lease = GADHostOwnershipLease(storeDirectory: live)
        try await lease.acquire(ownerID: "helper", role: .hostHelper)
        defer { Task { try? await lease.release() } }

        await #expect(throws: GADHostMigrationError.self) {
            _ = try await GADPreHostBackupManager().prepareTransfer(
                storeDirectory: live, backupRoot: backups, lease: lease, ownerID: "helper"
            ) {}
        }
        let manager = GADPreHostBackupManager(excludedTopLevelDirectoryNames: ["Worktrees", "TemporaryChat"])
        let backup = try await manager.prepareTransfer(
            storeDirectory: live, backupRoot: backups, lease: lease, ownerID: "helper"
        ) {}
        try await manager.validate(backup)
        #expect(!backup.files.contains { $0.relativePath.hasPrefix("TemporaryChat") })
    }

    @Test("The temporary chat keeps its Codex home outside Goby's backed-up data")
    func temporaryChatHomeIsOutsideStore() {
        let support = CodexTemporaryChatService.defaultSupportDirectory().path(percentEncoded: false)
        #expect(support.contains("/Caches/") || support.hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
        #expect(!support.contains("Application Support"))
    }

    @Test("A second state owner fails closed until the first lease is released")
    func leaseExcludesSecondWriter() async throws {
        let directory = temporaryDirectory(named: "lease")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = GADHostOwnershipLease(storeDirectory: directory)
        let second = GADHostOwnershipLease(storeDirectory: directory)

        let owner = try await first.acquire(ownerID: "legacy", role: .legacyUI)
        #expect(owner.ownerID == "legacy")
        await #expect(throws: GADHostOwnershipError.self) {
            try await first.acquire(ownerID: "helper", role: .hostHelper)
        }
        await #expect(throws: GADHostOwnershipError.self) {
            try await second.acquire(ownerID: "helper", role: .hostHelper)
        }

        try await first.release()
        let helper = try await second.acquire(ownerID: "helper", role: .hostHelper)
        #expect(helper.role == .hostHelper)
        try await second.release()

        let lockPath = directory.appending(path: GADHostOwnershipLease.lockFileName).path(percentEncoded: false)
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: lockPath)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(mode == 0o600)
    }

    @Test("A failed helper transfer retains an unchanged source and validated immutable backup")
    func failedTransferRollsBackWithoutSecondStore() async throws {
        let parent = temporaryDirectory(named: "migration")
        let store = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let catalog = Data(#"{"version":1,"projects":[],"agents":[]}"#.utf8)
        try catalog.write(to: store.appending(path: "catalog.json"))

        let lease = GADHostOwnershipLease(storeDirectory: store)
        try await lease.acquire(ownerID: "legacy", role: .legacyUI)
        let manager = GADPreHostBackupManager()
        let checkpointed = CheckpointProbe()
        let receipt = try await manager.prepareTransfer(
            storeDirectory: store,
            backupRoot: backups,
            lease: lease,
            ownerID: "legacy"
        ) {
            await checkpointed.mark()
        }

        #expect(await checkpointed.wasMarked())
        try await manager.validate(receipt)
        try await manager.verifyRollbackSource(
            receipt,
            storeDirectory: store,
            lease: lease,
            ownerID: "legacy"
        )
        #expect(try Data(contentsOf: store.appending(path: "catalog.json")) == catalog)

        await #expect(throws: GADHostOwnershipError.self) {
            try await GADHostOwnershipLease(storeDirectory: store).acquire(ownerID: "helper", role: .hostHelper)
        }
        try await lease.release()
    }

    @Test("Managed worktrees remain outside the immutable state backup")
    func managedWorktreesAreExcludedFromStateBackup() async throws {
        let parent = temporaryDirectory(named: "worktree-exclusion")
        let store = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let catalogURL = store.appending(path: "catalog.json")
        try Data("canonical-state".utf8).write(to: catalogURL)

        let worktrees = store.appending(path: "Worktrees", directoryHint: .isDirectory)
        let nested = worktrees.appending(path: "run/project/node_modules/.bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: nested.appending(path: "tool"),
            withDestinationURL: URL(fileURLWithPath: "../tool.js")
        )

        let lease = GADHostOwnershipLease(storeDirectory: store)
        try await lease.acquire(ownerID: "legacy", role: .legacyUI)
        let manager = GADPreHostBackupManager(
            excludedTopLevelDirectoryNames: ["Worktrees"]
        )
        let receipt = try await manager.prepareTransfer(
            storeDirectory: store,
            backupRoot: backups,
            lease: lease,
            ownerID: "legacy",
            checkpoint: {}
        )

        #expect(FileManager.default.fileExists(
            atPath: receipt.backupURL.appending(path: "catalog.json").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: receipt.backupURL.appending(path: "Worktrees").path(percentEncoded: false)
        ))
        try await manager.validate(receipt)

        try Data("workspace-change".utf8).write(
            to: worktrees.appending(path: "run/project/new-file.txt")
        )
        try await manager.verifyRollbackSource(
            receipt,
            storeDirectory: store,
            lease: lease,
            ownerID: "legacy"
        )

        try Data("changed-canonical-state".utf8).write(to: catalogURL)
        do {
            try await manager.verifyRollbackSource(
                receipt,
                storeDirectory: store,
                lease: lease,
                ownerID: "legacy"
            )
            Issue.record("Changing canonical state should invalidate rollback verification.")
        } catch GADHostMigrationError.sourceChangedDuringBackup {
            // Expected.
        } catch {
            Issue.record("Unexpected rollback verification error: \(error)")
        }
        try await lease.release()
    }

    @Test("An excluded workspace root cannot be a symbolic link")
    func symbolicWorktreesRootIsRejected() async throws {
        let parent = temporaryDirectory(named: "worktree-root-symlink")
        let store = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        let external = parent.appending(path: "External", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("canonical-state".utf8).write(to: store.appending(path: "catalog.json"))
        try FileManager.default.createSymbolicLink(
            at: store.appending(path: "Worktrees"),
            withDestinationURL: external
        )

        let lease = GADHostOwnershipLease(storeDirectory: store)
        try await lease.acquire(ownerID: "legacy", role: .legacyUI)
        let manager = GADPreHostBackupManager(
            excludedTopLevelDirectoryNames: ["Worktrees"]
        )

        do {
            _ = try await manager.prepareTransfer(
                storeDirectory: store,
                backupRoot: backups,
                lease: lease,
                ownerID: "legacy",
                checkpoint: {}
            )
            Issue.record("A symbolic worktree root should fail closed.")
        } catch let GADHostMigrationError.unsafeStoreItem(path) {
            #expect(path == "Worktrees")
        } catch {
            Issue.record("Unexpected worktree-root validation error: \(error)")
        }
        try await lease.release()
    }

    @Test("The ownership lease cannot be released during checkpoint and backup")
    func migrationPinsTheLease() async throws {
        let parent = temporaryDirectory(named: "pinned-migration")
        let store = parent.appending(path: "Live", directoryHint: .isDirectory)
        let backups = parent.appending(path: "Backups", directoryHint: .isDirectory)
        defer { removeReadOnlyTree(parent, backupRoot: backups) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: store.appending(path: "state.json"))

        let lease = GADHostOwnershipLease(storeDirectory: store)
        try await lease.acquire(ownerID: "legacy", role: .legacyUI)
        let gate = CheckpointGate()
        let manager = GADPreHostBackupManager()
        let transfer = Task {
            try await manager.prepareTransfer(
                storeDirectory: store,
                backupRoot: backups,
                lease: lease,
                ownerID: "legacy"
            ) {
                await gate.checkpoint()
            }
        }

        await gate.waitUntilStarted()
        await #expect(throws: GADHostOwnershipError.self) {
            try await lease.release()
        }
        await gate.resume()
        let receipt = try await transfer.value
        try await manager.validate(receipt)
        try await lease.release()
    }

    @Test("Lease ownership fails closed when the locked pathname is replaced")
    func replacedLeasePathInvalidatesOwnership() async throws {
        let directory = temporaryDirectory(named: "replaced-lease")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = GADHostOwnershipLease(storeDirectory: directory)
        let second = GADHostOwnershipLease(storeDirectory: directory)
        try await first.acquire(ownerID: "legacy", role: .legacyUI)

        let lock = directory.appending(path: GADHostOwnershipLease.lockFileName)
        let displaced = directory.appending(path: ".displaced-host.lock")
        try FileManager.default.moveItem(at: lock, to: displaced)
        try Data().write(to: lock, options: .withoutOverwriting)
        let replacement = try await second.acquire(ownerID: "helper", role: .hostHelper)
        #expect(replacement.role == .hostHelper)

        await #expect(throws: GADHostOwnershipError.unsafeLeaseLocation) {
            try await first.requireOwnership(ownerID: "legacy")
        }

        try await second.release()
        try await first.release()
    }

    @Test("A hard-linked lease file is never accepted")
    func hardLinkedLeaseIsRejected() async throws {
        let directory = temporaryDirectory(named: "hard-linked-lease")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appending(path: GADHostOwnershipLease.lockFileName)
        let link = directory.appending(path: ".linked-host.lock")
        try Data().write(to: lock, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: lock, to: link)

        await #expect(throws: GADHostOwnershipError.unsafeLeaseLocation) {
            try await GADHostOwnershipLease(storeDirectory: directory).acquire(
                ownerID: "legacy",
                role: .legacyUI
            )
        }
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "goby-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func removeReadOnlyTree(_ root: URL, backupRoot: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: backupRoot.path(percentEncoded: false)
        )
        if let enumerator = FileManager.default.enumerator(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path(percentEncoded: false)
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private actor CheckpointProbe {
    private var marked = false

    func mark() { marked = true }
    func wasMarked() -> Bool { marked }
}

private actor CheckpointGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func checkpoint() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
