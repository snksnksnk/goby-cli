import CryptoKit
import Darwin
import Foundation

public enum GADHostOwnerRole: String, Codable, Equatable, Sendable {
    case legacyUI
    case hostHelper
    case standaloneCLI
}

public struct GADHostOwnershipMetadata: Codable, Equatable, Sendable {
    public let ownerID: String
    public let role: GADHostOwnerRole
    public let processIdentifier: Int32
    public let acquiredAt: Date

    public init(
        ownerID: String,
        role: GADHostOwnerRole,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        acquiredAt: Date = .now
    ) {
        self.ownerID = ownerID
        self.role = role
        self.processIdentifier = processIdentifier
        self.acquiredAt = acquiredAt
    }
}

public enum GADHostOwnershipError: LocalizedError, Sendable, Equatable {
    case alreadyOwned(GADHostOwnershipMetadata?)
    case notOwned
    case migrationInProgress
    case unsafeLeaseLocation
    case systemFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyOwned(owner):
            if let owner {
                "Goby state is already owned by the \(owner.role.rawValue) process (PID \(owner.processIdentifier)). Close the other owner or use its recovery controls."
            } else {
                "Goby state is already owned by another process. Close the other owner or use its recovery controls."
            }
        case .notOwned:
            "This process does not hold the Goby host ownership lease."
        case .migrationInProgress:
            "Goby is checkpointing its store for host migration. The ownership lease cannot be released yet."
        case .unsafeLeaseLocation:
            "The Goby host ownership lease is not a regular owner-only file in the expected store directory."
        case let .systemFailure(message):
            "The Goby host ownership lease failed: \(message)"
        }
    }
}

/// Process-wide ownership is enforced by a kernel advisory lock held for the lifetime of this actor.
/// The stable lock file is never replaced or deleted because doing so would create a second lock inode.
public actor GADHostOwnershipLease {
    private struct LeaseIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    public static let lockFileName = ".goby-host.lock"

    private let storeDirectory: URL
    private var descriptor: Int32?
    private var descriptorIdentity: LeaseIdentity?
    private var metadata: GADHostOwnershipMetadata?
    private var criticalOwnerID: String?

    public init(storeDirectory: URL) {
        self.storeDirectory = storeDirectory.standardizedFileURL
    }

    deinit {
        if let descriptor {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
    }

    @discardableResult
    public func acquire(ownerID: String, role: GADHostOwnerRole) throws -> GADHostOwnershipMetadata {
        if let metadata {
            guard metadata.ownerID == ownerID, metadata.role == role else {
                throw GADHostOwnershipError.alreadyOwned(metadata)
            }
            return metadata
        }
        try prepareStoreDirectory()
        let lockURL = storeDirectory.appending(path: Self.lockFileName)
        let path = lockURL.path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw GADHostOwnershipError.systemFailure(String(cString: strerror(errno)))
        }
        guard isSafeLeaseDescriptor(fd) else {
            _ = close(fd)
            throw GADHostOwnershipError.unsafeLeaseLocation
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            let existing = Self.readMetadata(from: lockURL)
            _ = close(fd)
            if lockError == EWOULDBLOCK {
                throw GADHostOwnershipError.alreadyOwned(existing)
            }
            throw GADHostOwnershipError.systemFailure(String(cString: strerror(lockError)))
        }
        guard let identity = leaseIdentity(of: fd),
              leasePathMatchesDescriptor(path: path, descriptor: fd, identity: identity) else {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw GADHostOwnershipError.unsafeLeaseLocation
        }

        let acquired = GADHostOwnershipMetadata(ownerID: ownerID, role: role)
        do {
            try writeMetadata(acquired, to: fd)
            guard leasePathMatchesDescriptor(path: path, descriptor: fd, identity: identity) else {
                throw GADHostOwnershipError.unsafeLeaseLocation
            }
        } catch {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw error
        }
        descriptor = fd
        descriptorIdentity = identity
        metadata = acquired
        return acquired
    }

    public func currentOwner() -> GADHostOwnershipMetadata? { metadata }

    public func requireOwnership(ownerID: String) throws -> GADHostOwnershipMetadata {
        guard let metadata,
              metadata.ownerID == ownerID,
              let descriptor,
              let descriptorIdentity else {
            throw GADHostOwnershipError.notOwned
        }
        let path = storeDirectory.appending(path: Self.lockFileName).path(percentEncoded: false)
        guard leasePathMatchesDescriptor(
            path: path,
            descriptor: descriptor,
            identity: descriptorIdentity
        ) else {
            throw GADHostOwnershipError.unsafeLeaseLocation
        }
        return metadata
    }

    public func beginMigrationCheckpoint(ownerID: String) throws {
        _ = try requireOwnership(ownerID: ownerID)
        guard criticalOwnerID == nil else { throw GADHostOwnershipError.migrationInProgress }
        criticalOwnerID = ownerID
    }

    public func endMigrationCheckpoint(ownerID: String) {
        guard criticalOwnerID == ownerID else { return }
        criticalOwnerID = nil
    }

    public func release() throws {
        guard let fd = descriptor else { throw GADHostOwnershipError.notOwned }
        guard criticalOwnerID == nil else { throw GADHostOwnershipError.migrationInProgress }
        guard flock(fd, LOCK_UN) == 0 else {
            throw GADHostOwnershipError.systemFailure(String(cString: strerror(errno)))
        }
        _ = close(fd)
        descriptor = nil
        descriptorIdentity = nil
        metadata = nil
    }

    private func prepareStoreDirectory() throws {
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        let result = storeDirectory.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw GADHostOwnershipError.unsafeLeaseLocation
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storeDirectory.path(percentEncoded: false)
        )
    }

    private func isSafeLeaseDescriptor(_ fd: Int32) -> Bool {
        var status = stat()
        return fstat(fd, &status) == 0
            && status.st_uid == geteuid()
            && (status.st_mode & S_IFMT) == S_IFREG
            && status.st_nlink == 1
            && fchmod(fd, S_IRUSR | S_IWUSR) == 0
    }

    private func leaseIdentity(of fd: Int32) -> LeaseIdentity? {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return nil }
        return LeaseIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func leasePathMatchesDescriptor(
        path: String,
        descriptor: Int32,
        identity: LeaseIdentity
    ) -> Bool {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              path.withCString({ lstat($0, &pathStatus) }) == 0 else {
            return false
        }
        return descriptorStatus.st_uid == geteuid()
            && pathStatus.st_uid == geteuid()
            && (descriptorStatus.st_mode & S_IFMT) == S_IFREG
            && (pathStatus.st_mode & S_IFMT) == S_IFREG
            && descriptorStatus.st_nlink == 1
            && pathStatus.st_nlink == 1
            && descriptorStatus.st_dev == identity.device
            && descriptorStatus.st_ino == identity.inode
            && pathStatus.st_dev == identity.device
            && pathStatus.st_ino == identity.inode
    }

    private func writeMetadata(_ metadata: GADHostOwnershipMetadata, to fd: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(metadata)
        data.append(0x0A)
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            throw GADHostOwnershipError.systemFailure(String(cString: strerror(errno)))
        }
        let wroteAllBytes = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAllBytes, fsync(fd) == 0 else {
            throw GADHostOwnershipError.systemFailure(String(cString: strerror(errno)))
        }
    }

    private static func readMetadata(from url: URL) -> GADHostOwnershipMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GADHostOwnershipMetadata.self, from: data)
    }
}

public struct GADHostBackupFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
}

public struct GADPreHostBackupReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let backupURL: URL
    public let files: [GADHostBackupFile]

    public init(
        id: String,
        createdAt: Date,
        backupURL: URL,
        files: [GADHostBackupFile]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.backupURL = backupURL
        self.files = files
    }
}

public enum GADHostMigrationError: LocalizedError, Sendable {
    case backupInsideStore
    case sourceChangedDuringBackup
    case unsafeStoreItem(String)
    case invalidBackup

    public var errorDescription: String? {
        switch self {
        case .backupInsideStore:
            "The pre-host backup must be outside the live Goby store."
        case .sourceChangedDuringBackup:
            "Goby state changed while the pre-host backup was being created. Host ownership was not transferred."
        case let .unsafeStoreItem(path):
            "The live Goby store contains an unsafe symbolic link at \(path). Host ownership was not transferred."
        case .invalidBackup:
            "The pre-host backup no longer matches its immutable manifest. Host ownership was not transferred."
        }
    }
}

/// Creates and validates immutable, atomic pre-host backups. It never mutates or restores the live store.
/// A failed helper start can therefore roll back by retaining the existing owner and unchanged source.
/// Operational directories may be excluded at the store root, but each excluded root must still be a
/// real directory rather than a symbolic link.
public actor GADPreHostBackupManager {
    public static let manifestFileName = "migration-manifest.json"

    private let fileManager: FileManager
    private let excludedTopLevelDirectoryNames: Set<String>

    public init(
        fileManager: FileManager = .default,
        excludedTopLevelDirectoryNames: Set<String> = []
    ) {
        self.fileManager = fileManager
        self.excludedTopLevelDirectoryNames = Set(
            excludedTopLevelDirectoryNames.filter(Self.isSafeTopLevelName)
        )
    }

    public func prepareTransfer(
        storeDirectory: URL,
        backupRoot: URL,
        lease: GADHostOwnershipLease,
        ownerID: String,
        checkpoint: @Sendable () async throws -> Void
    ) async throws -> GADPreHostBackupReceipt {
        try await lease.beginMigrationCheckpoint(ownerID: ownerID)
        do {
            let receipt = try await prepareTransferWhileLeaseIsPinned(
                storeDirectory: storeDirectory,
                backupRoot: backupRoot,
                checkpoint: checkpoint
            )
            await lease.endMigrationCheckpoint(ownerID: ownerID)
            return receipt
        } catch {
            await lease.endMigrationCheckpoint(ownerID: ownerID)
            throw error
        }
    }

    private func prepareTransferWhileLeaseIsPinned(
        storeDirectory: URL,
        backupRoot: URL,
        checkpoint: @Sendable () async throws -> Void
    ) async throws -> GADPreHostBackupReceipt {
        let source = storeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = backupRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !Self.isDescendant(root, of: source) else {
            throw GADHostMigrationError.backupInsideStore
        }

        try await checkpoint()
        let before = try manifest(
            for: source,
            excludingTopLevelDirectories: excludedTopLevelDirectoryNames
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path(percentEncoded: false)
        )

        let id = UUID().uuidString.lowercased()
        let staging = root.appending(path: ".pending-\(id)", directoryHint: .isDirectory)
        let destination = root.appending(path: "pre-host-\(id)", directoryHint: .isDirectory)
        do {
            try copyStore(from: source, to: staging)
            let copied = try manifest(for: staging)
            let after = try manifest(
                for: source,
                excludingTopLevelDirectories: excludedTopLevelDirectoryNames
            )
            guard before == after, copied == before else {
                throw GADHostMigrationError.sourceChangedDuringBackup
            }
            let receipt = GADPreHostBackupReceipt(
                id: id,
                createdAt: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)),
                backupURL: destination,
                files: copied
            )
            try writeManifest(receipt, to: staging)
            try makeReadOnly(staging)
            try fileManager.moveItem(at: staging, to: destination)
            return receipt
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func validate(_ receipt: GADPreHostBackupReceipt) throws {
        let manifestURL = receipt.backupURL.appending(path: Self.manifestFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(GADPreHostBackupReceipt.self, from: Data(contentsOf: manifestURL))
        guard stored == receipt, try manifest(for: receipt.backupURL) == receipt.files else {
            throw GADHostMigrationError.invalidBackup
        }
    }

    public func verifyRollbackSource(
        _ receipt: GADPreHostBackupReceipt,
        storeDirectory: URL,
        lease: GADHostOwnershipLease,
        ownerID: String
    ) async throws {
        _ = try await lease.requireOwnership(ownerID: ownerID)
        try validate(receipt)
        guard try manifest(
            for: storeDirectory.resolvingSymlinksInPath().standardizedFileURL,
            excludingTopLevelDirectories: excludedTopLevelDirectoryNames
        ) == receipt.files else {
            throw GADHostMigrationError.sourceChangedDuringBackup
        }
    }

    private func copyStore(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) where item.lastPathComponent != GADHostOwnershipLease.lockFileName {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if excludedTopLevelDirectoryNames.contains(item.lastPathComponent) {
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw GADHostMigrationError.unsafeStoreItem(item.lastPathComponent)
                }
                continue
            }
            if values.isSymbolicLink == true {
                throw GADHostMigrationError.unsafeStoreItem(item.lastPathComponent)
            }
            try fileManager.copyItem(at: item, to: destination.appending(path: item.lastPathComponent))
        }
    }

    private func manifest(
        for directory: URL,
        excludingTopLevelDirectories: Set<String> = []
    ) throws -> [GADHostBackupFile] {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        var files: [GADHostBackupFile] = []
        try appendManifestFiles(
            in: directory,
            relativePrefix: "",
            excludingTopLevelDirectories: excludingTopLevelDirectories,
            to: &files
        )
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func appendManifestFiles(
        in directory: URL,
        relativePrefix: String,
        excludingTopLevelDirectories: Set<String>,
        to files: inout [GADHostBackupFile]
    ) throws {
        let items = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for url in items {
            let relativePath = relativePrefix.isEmpty
                ? url.lastPathComponent
                : relativePrefix + "/" + url.lastPathComponent
            if relativePath == Self.manifestFileName || relativePath == GADHostOwnershipLease.lockFileName {
                continue
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if relativePrefix.isEmpty,
               excludingTopLevelDirectories.contains(url.lastPathComponent) {
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw GADHostMigrationError.unsafeStoreItem(relativePath)
                }
                continue
            }
            if values.isSymbolicLink == true {
                throw GADHostMigrationError.unsafeStoreItem(relativePath)
            }
            if values.isDirectory == true {
                try appendManifestFiles(
                    in: url,
                    relativePrefix: relativePath,
                    excludingTopLevelDirectories: excludingTopLevelDirectories,
                    to: &files
                )
                continue
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            files.append(.init(
                relativePath: relativePath,
                byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }
    }

    private nonisolated static func isSafeTopLevelName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func writeManifest(_ receipt: GADPreHostBackupReceipt, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(
            to: directory.appending(path: Self.manifestFileName),
            options: .atomic
        )
    }

    private func makeReadOnly(_ root: URL) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        var directories = [root]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                directories.append(url)
            } else {
                try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path(percentEncoded: false))
            }
        }
        for directory in directories.reversed() {
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false))
        }
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentPath = parent.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = candidate.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }
}
