import Darwin
import Foundation
import Synchronization

public enum GADRepositoryLockError: LocalizedError, Sendable {
    case invalidRepository
    case unsafeLockFile
    case held(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: "Goby could not resolve this repository's Git common directory."
        case .unsafeLockFile: "The repository lock file is unsafe. Goby did not prepare a worktree."
        case let .held(owner): "Another Goby host (\(owner)) is working in this repository. Try again after it finishes."
        }
    }
}

public final class GADRepositoryLockLease: @unchecked Sendable {
    private let descriptor: Mutex<Int32?>

    fileprivate init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }
    deinit { release() }

    public func release() {
        let fd = descriptor.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let fd {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
    }
}

/// The stable lock file lives in the Git common directory shared by every
/// worktree and every Goby installation. It is never unlinked on release.
///
/// The lock excludes other hosts, not this one. One host holds one lease per
/// repository and shares it across its runs, so parallel requests in the same
/// repository (ADR-020) keep working; the lease is released with its last run.
public actor GADRepositoryAdvisoryLock {
    public static let fileName = ".goby-repository.lock"
    private var leasesByDirectory: [URL: GADRepositoryLockLease] = [:]
    private var reservationsByDirectory: [URL: Set<String>] = [:]

    public init() {}

    public func acquire(
        repositoryURL: URL,
        ownerLabel: String,
        reservationID: String = UUID().uuidString,
        maximumWait: Duration = .seconds(60)
    ) async throws -> GADRepositoryLockLease {
        let commonDirectory = try gitCommonDirectory(for: repositoryURL)
        if let existing = leasesByDirectory[commonDirectory] {
            reservationsByDirectory[commonDirectory, default: []].insert(reservationID)
            return existing
        }
        let lockURL = commonDirectory.appending(path: Self.fileName)
        let fd = open(lockURL.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GADRepositoryLockError.unsafeLockFile }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            _ = close(fd)
            throw GADRepositoryLockError.unsafeLockFile
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Another run of this host may have taken the lease while we waited.
            if let existing = leasesByDirectory[commonDirectory] {
                _ = close(fd)
                reservationsByDirectory[commonDirectory, default: []].insert(reservationID)
                return existing
            }
            guard errno == EWOULDBLOCK, clock.now < deadline else {
                let owner = readOwner(fd)
                _ = close(fd)
                throw GADRepositoryLockError.held(owner)
            }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { _ = close(fd); throw error }
        }
        let label = "\(ownerLabel) pid \(getpid())"
        guard ftruncate(fd, 0) == 0,
              label.withCString({ write(fd, $0, strlen($0)) }) == label.utf8.count else {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw GADRepositoryLockError.unsafeLockFile
        }
        var current = stat()
        guard lstat(lockURL.path(percentEncoded: false), &current) == 0,
              current.st_dev == status.st_dev,
              current.st_ino == status.st_ino,
              current.st_nlink == 1 else {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw GADRepositoryLockError.unsafeLockFile
        }
        let lease = GADRepositoryLockLease(descriptor: fd)
        leasesByDirectory[commonDirectory] = lease
        reservationsByDirectory[commonDirectory] = [reservationID]
        return lease
    }

    public func release(reservationID: String) {
        for (directory, reservations) in reservationsByDirectory where reservations.contains(reservationID) {
            var remaining = reservations
            remaining.remove(reservationID)
            if remaining.isEmpty {
                reservationsByDirectory.removeValue(forKey: directory)
                leasesByDirectory.removeValue(forKey: directory)?.release()
            } else {
                reservationsByDirectory[directory] = remaining
            }
        }
    }

    private func readOwner(_ fd: Int32) -> String {
        _ = lseek(fd, 0, SEEK_SET)
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0 else { return "unknown owner" }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
            .filter { $0.isASCII && !$0.isNewline }
    }

    private func gitCommonDirectory(for repositoryURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repositoryURL.path(percentEncoded: false),
            "rev-parse", "--path-format=absolute", "--git-common-dir"
        ]
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { throw GADRepositoryLockError.invalidRepository }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("/") else {
            throw GADRepositoryLockError.invalidRepository
        }
        return URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL
    }
}
