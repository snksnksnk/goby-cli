import Darwin
import Foundation

enum AnchoredFileMutationError: LocalizedError, Equatable, Sendable {
    case unsafeDirectory
    case unsafeName
    case missingFile
    case unexpectedFile
    case changedFile
    case fileTooLarge
    case operationFailed(Int32)
    case directoryComponentFailed(String, Int32)
    case pathNotContained(root: String, child: String)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory: "The authorized directory could not be opened without following symbolic links."
        case .unsafeName: "The requested file name is not safe."
        case .missingFile: "The reviewed file is no longer present."
        case .unexpectedFile: "A file now exists where the reviewed operation required an empty destination."
        case .changedFile: "The reviewed file changed before the operation could complete."
        case .fileTooLarge: "The reviewed file exceeds Goby's size limit."
        case let .operationFailed(code): "The anchored file operation failed with POSIX status \(code)."
        case let .directoryComponentFailed(component, code):
            "The anchored directory component \(component) failed with POSIX status \(code)."
        case let .pathNotContained(root, child):
            "The anchored child path \(child) is not inside \(root)."
        }
    }
}

/// Directory-descriptor boundary for security-sensitive definition mutations.
/// Every absolute component is opened with O_NOFOLLOW, and all later file work
/// is descriptor-relative so replacing a validated parent cannot redirect it.
final class AnchoredDirectory {
    private struct OpenedFile {
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    static func openAbsolute(
        _ directory: URL,
        createIfMissing: Bool = false,
        permissions: mode_t = 0o700
    ) throws -> AnchoredDirectory {
        let path = canonicalSystemRootAlias(
            directory.standardizedFileURL.path(percentEncoded: false)
        )
        guard path.hasPrefix("/") else { throw AnchoredFileMutationError.unsafeDirectory }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw AnchoredFileMutationError.operationFailed(errno) }
        do {
            for component in path.split(separator: "/").map(String.init) {
                try validate(component)
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, createIfMissing {
                    guard mkdirat(current, component, permissions) == 0 || errno == EEXIST else {
                        throw AnchoredFileMutationError.directoryComponentFailed(component, errno)
                    }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw AnchoredFileMutationError.directoryComponentFailed(component, errno) }
                close(current)
                current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw AnchoredFileMutationError.unsafeDirectory
            }
            let result = AnchoredDirectory(descriptor: current)
            current = -1
            return result
        } catch {
            if current >= 0 { close(current) }
            throw error
        }
    }

    func descendant(_ components: [String], create: Bool, permissions: mode_t = 0o700) throws -> AnchoredDirectory {
        var current = dup(descriptor)
        guard current >= 0 else { throw AnchoredFileMutationError.operationFailed(errno) }
        do {
            for component in components {
                try Self.validate(component)
                if create, mkdirat(current, component, permissions) != 0, errno != EEXIST {
                    throw AnchoredFileMutationError.operationFailed(errno)
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AnchoredFileMutationError.directoryComponentFailed(component, errno) }
                close(current)
                current = next
            }
            let result = AnchoredDirectory(descriptor: current)
            current = -1
            return result
        } catch {
            if current >= 0 { close(current) }
            throw error
        }
    }

    func contains(_ name: String) throws -> Bool {
        try Self.validate(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw AnchoredFileMutationError.operationFailed(errno)
    }

    func setPermissions(_ permissions: mode_t) throws {
        guard fchmod(descriptor, permissions) == 0 else {
            throw AnchoredFileMutationError.operationFailed(errno)
        }
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        try openedFile(name, maximumBytes: maximumBytes).data
    }

    func create(_ name: String, contents: Data, permissions: mode_t = 0o600) throws {
        try Self.validate(name)
        let file = openat(
            descriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard file >= 0 else {
            if errno == EEXIST { throw AnchoredFileMutationError.unexpectedFile }
            throw AnchoredFileMutationError.operationFailed(errno)
        }
        do {
            try Self.write(contents, to: file)
            guard fchmod(file, permissions) == 0, fsync(file) == 0 else {
                throw AnchoredFileMutationError.operationFailed(errno)
            }
            close(file)
        } catch {
            close(file)
            _ = unlinkat(descriptor, name, 0)
            throw error
        }
    }

    func remove(_ name: String, expectedContents: Data, maximumBytes: Int) throws {
        let opened = try openedFile(name, maximumBytes: maximumBytes)
        guard opened.data == expectedContents else { throw AnchoredFileMutationError.changedFile }
        try requireIdentity(opened, named: name)
        guard unlinkat(descriptor, name, 0) == 0 else {
            throw AnchoredFileMutationError.operationFailed(errno)
        }
    }

    func move(
        _ name: String,
        to destination: AnchoredDirectory,
        as destinationName: String,
        expectedContents: Data,
        maximumBytes: Int
    ) throws {
        try Self.validate(destinationName)
        let opened = try openedFile(name, maximumBytes: maximumBytes)
        guard opened.data == expectedContents else { throw AnchoredFileMutationError.changedFile }
        guard try !destination.contains(destinationName) else {
            throw AnchoredFileMutationError.unexpectedFile
        }
        try requireIdentity(opened, named: name)
        guard renameat(descriptor, name, destination.descriptor, destinationName) == 0 else {
            throw AnchoredFileMutationError.operationFailed(errno)
        }
    }

    func replace(
        _ name: String,
        contents: Data,
        expectedCurrent: Data,
        maximumBytes: Int,
        permissions: mode_t = 0o600
    ) throws {
        let opened = try openedFile(name, maximumBytes: maximumBytes)
        guard opened.data == expectedCurrent else { throw AnchoredFileMutationError.changedFile }
        let temporary = ".goby-replacement-\(UUID().uuidString.lowercased())"
        try create(temporary, contents: contents, permissions: permissions)
        do {
            try requireIdentity(opened, named: name)
            guard renameat(descriptor, temporary, descriptor, name) == 0 else {
                throw AnchoredFileMutationError.operationFailed(errno)
            }
        } catch {
            _ = unlinkat(descriptor, temporary, 0)
            throw error
        }
    }

    private func openedFile(_ name: String, maximumBytes: Int) throws -> OpenedFile {
        try Self.validate(name)
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { throw AnchoredFileMutationError.missingFile }
            throw AnchoredFileMutationError.operationFailed(errno)
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AnchoredFileMutationError.changedFile
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw AnchoredFileMutationError.fileTooLarge
        }
        var data = Data()
        while data.count <= maximumBytes {
            var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes - data.count + 1))
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw AnchoredFileMutationError.operationFailed(errno) }
            if count == 0 { break }
            if data.count + count > maximumBytes { throw AnchoredFileMutationError.fileTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return OpenedFile(data: data, device: info.st_dev, inode: info.st_ino)
    }

    private func requireIdentity(_ opened: OpenedFile, named name: String) throws {
        var current = stat()
        guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == opened.device,
              current.st_ino == opened.inode else {
            throw AnchoredFileMutationError.changedFile
        }
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw AnchoredFileMutationError.unsafeName
        }
    }

    /// macOS exposes `/var`, `/tmp`, and `/etc` as root-owned aliases into
    /// `/private`. Resolve only those fixed system aliases before the
    /// descriptor walk; every user-controlled component still uses
    /// `O_NOFOLLOW` and cannot redirect the reviewed directory.
    private static func canonicalSystemRootAlias(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where
            path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else { throw AnchoredFileMutationError.operationFailed(errno) }
                remaining -= count
                address = address.advanced(by: count)
            }
        }
    }
}

func relativePathComponents(_ child: URL, inside root: URL) throws -> [String] {
    let rootPath = canonicalAnchoredPath(root)
    let childPath = canonicalAnchoredPath(child)
    guard childPath.hasPrefix(rootPath + "/") else {
        throw AnchoredFileMutationError.pathNotContained(root: rootPath, child: childPath)
    }
    let suffix = childPath.dropFirst(rootPath.count + 1)
    let components = suffix.split(separator: "/").map(String.init)
    guard !components.isEmpty else { throw AnchoredFileMutationError.unsafeDirectory }
    return components
}

private func canonicalAnchoredPath(_ url: URL) -> String {
    let rawPath = url.standardizedFileURL.path(percentEncoded: false)
    let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
    for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
        return "/private" + path
    }
    return path
}
