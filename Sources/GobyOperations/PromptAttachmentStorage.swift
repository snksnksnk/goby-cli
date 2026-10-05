import Darwin
import Foundation

/// Descriptor-anchored private storage for staged prompt attachments.
///
/// Every operation opens the directory with `O_NOFOLLOW` and addresses direct
/// children with `*at` APIs. A pathname replacement therefore cannot redirect
/// cleanup or creation into another directory.
nonisolated enum PromptAttachmentStorage {
    struct Usage: Equatable, Sendable {
        let fileCount: Int
        let byteCount: Int64
    }

    private static let maximumFileCount = 2_048
    private static let maximumByteCount: Int64 = 512 * 1_024 * 1_024

    static func defaultRoot(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
#if DEBUG
        if let fixtureRoot = environment["GOBY_UI_TEST_DATA_ROOT"], !fixtureRoot.isEmpty {
            // A malformed fixture path must never fall back to user storage.
            guard fixtureRoot.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: fixtureRoot, isDirectory: true)
                .appending(path: "PromptAttachments", directoryHint: .isDirectory)
                .standardizedFileURL
        }
#endif
        return applicationSupportDirectory?
            .appending(path: "Goby Agentic Dashboard", directoryHint: .isDirectory)
            .appending(path: "PromptAttachments", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    static func openOrCreateDefaultRoot(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL, descriptor: Int32)? {
        openOrCreateRoot(defaultRoot(
            applicationSupportDirectory: applicationSupportDirectory, environment: environment
        ))
    }

    static func openOrCreateRoot(_ directory: URL?) -> (url: URL, descriptor: Int32)? {
        guard let root = directory?.standardizedFileURL,
              root.lastPathComponent == "PromptAttachments" else { return nil }
        let appDirectory = root.deletingLastPathComponent()
        let applicationSupportFD = openDirectory(atPath: appDirectory.deletingLastPathComponent().path)
        guard applicationSupportFD >= 0, validateDirectory(applicationSupportFD) else {
            if applicationSupportFD >= 0 { close(applicationSupportFD) }
            return nil
        }
        defer { close(applicationSupportFD) }
        guard let appFD = openOrCreateChildDirectory(
            parent: applicationSupportFD,
            name: appDirectory.lastPathComponent
        ) else { return nil }
        defer { close(appFD) }
        guard let rootFD = openOrCreateChildDirectory(
            parent: appFD,
            name: "PromptAttachments"
        ) else { return nil }
        _ = fchmod(rootFD, mode_t(0o700))
        return (root, rootFD)
    }

    static func openExistingRoot(_ root: URL) -> Int32? {
        let descriptor = openDirectory(atPath: root.standardizedFileURL.path)
        guard descriptor >= 0, validateDirectory(descriptor) else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
        return descriptor
    }

    static func usage(descriptor: Int32) -> Usage? {
        guard let entries = entries(descriptor: descriptor),
              entries.count <= maximumFileCount else { return nil }
        var bytes: Int64 = 0
        for entry in entries {
            guard isOwnedRegularFile(entry.info), entry.info.st_size >= 0 else { return nil }
            bytes += entry.info.st_size
            guard bytes <= maximumByteCount else { return nil }
        }
        return Usage(fileCount: entries.count, byteCount: bytes)
    }

    static func hasCapacity(descriptor: Int32, addingByteCount: Int) -> Bool {
        guard addingByteCount >= 0, let usage = usage(descriptor: descriptor) else { return false }
        return usage.fileCount < maximumFileCount
            && usage.byteCount + Int64(addingByteCount) <= maximumByteCount
    }

    static func write(
        _ data: Data,
        fileExtension: String,
        root: URL,
        descriptor: Int32
    ) -> URL? {
        guard hasCapacity(descriptor: descriptor, addingByteCount: data.count) else { return nil }
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let name = UUID().uuidString + suffix
        let fileFD = name.withCString {
            openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fileFD >= 0 else { return nil }
        var succeeded = false
        defer {
            close(fileFD)
            if !succeeded {
                name.withCString { _ = unlinkat(descriptor, $0, 0) }
            }
        }
        let writeSucceeded = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fileFD, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard writeSucceeded, fsync(fileFD) == 0 else { return nil }
        var info = stat()
        guard fstat(fileFD, &info) == 0,
              isOwnedRegularFile(info),
              info.st_size == off_t(data.count) else {
            return nil
        }
        guard rootStillReferences(descriptor: descriptor, at: root) else { return nil }
        succeeded = true
        return root.appending(path: name, directoryHint: .notDirectory)
    }

    static func sweep(
        root: URL,
        descriptor: Int32,
        retaining referencedURLs: Set<URL>
    ) {
        guard let entries = entries(descriptor: descriptor), entries.count <= maximumFileCount else { return }
        let normalizedRoot = root.standardizedFileURL
        let retainedNames = Set(referencedURLs.compactMap { url -> String? in
            let normalized = url.standardizedFileURL
            guard normalized.deletingLastPathComponent() == normalizedRoot else { return nil }
            return normalized.lastPathComponent
        })
        for entry in entries where !retainedNames.contains(entry.name) {
            guard isOwnedRegularFile(entry.info) else { continue }
            entry.name.withCString { _ = unlinkat(descriptor, $0, 0) }
        }
    }

    static func removeDirectChild(root: URL, descriptor: Int32, url: URL) {
        let normalized = url.standardizedFileURL
        guard normalized.deletingLastPathComponent() == root.standardizedFileURL else { return }
        let name = normalized.lastPathComponent
        var info = stat()
        let result = name.withCString {
            fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, isOwnedRegularFile(info) else { return }
        name.withCString { _ = unlinkat(descriptor, $0, 0) }
    }

    private struct Entry {
        let name: String
        let info: stat
    }

    private static func entries(descriptor: Int32) -> [Entry]? {
        // dup() shares a directory cursor with the original descriptor. A prior
        // capacity check would leave later checks or cleanup at end-of-directory.
        // Open a fresh cursor relative to the already verified directory instead.
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return nil
        }
        defer { closedir(directory) }
        var result: [Entry] = []
        while let pointer = readdir(directory) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.contains("/") else { continue }
            var info = stat()
            let status = name.withCString {
                fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { return nil }
            result.append(Entry(name: name, info: info))
            guard result.count <= maximumFileCount else { return nil }
        }
        return result
    }

    private static func openDirectory(atPath path: String) -> Int32 {
        path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    private static func openOrCreateChildDirectory(parent: Int32, name: String) -> Int32? {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor >= 0 {
            guard validateDirectory(descriptor) else {
                close(descriptor)
                return nil
            }
            return descriptor
        }
        guard errno == ENOENT else { return nil }
        let creation = name.withCString { mkdirat(parent, $0, mode_t(0o700)) }
        guard creation == 0 || errno == EEXIST else { return nil }
        let created = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard created >= 0, validateDirectory(created) else {
            if created >= 0 { close(created) }
            return nil
        }
        return created
    }

    private static func validateDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0 else { return false }
        return true
    }

    private static func rootStillReferences(descriptor: Int32, at root: URL) -> Bool {
        guard let reopened = openExistingRoot(root) else { return false }
        defer { close(reopened) }
        var originalInfo = stat()
        var reopenedInfo = stat()
        return fstat(descriptor, &originalInfo) == 0
            && fstat(reopened, &reopenedInfo) == 0
            && originalInfo.st_dev == reopenedInfo.st_dev
            && originalInfo.st_ino == reopenedInfo.st_ino
    }

    private static func isOwnedRegularFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
            && info.st_uid == geteuid()
            && info.st_nlink == 1
            && info.st_mode & mode_t(0o022) == 0
    }
}
