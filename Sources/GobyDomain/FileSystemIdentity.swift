import Darwin
import Foundation
import CryptoKit

public enum GADFileSystemObjectKind: String, Codable, Hashable, Sendable {
    case regularFile
    case directory
}

/// Stable identity captured when a user authorizes a file-system capability.
/// Revalidation rejects renamed/replaced paths and symlink substitutions.
public struct GADFileSystemIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: GADFileSystemObjectKind
    public let volumeUUIDString: String?

    public init(
        device: UInt64,
        inode: UInt64,
        kind: GADFileSystemObjectKind,
        volumeUUIDString: String? = nil
    ) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.volumeUUIDString = volumeUUIDString?.uppercased()
    }

    public static func capture(_ url: URL) -> GADFileSystemIdentity? {
        var info = stat()
        guard url.isFileURL,
              lstat(fileSystemPath(for: url), &info) == 0 else { return nil }
        return capture(info, volumeUUIDString: volumeUUIDString(at: url))
    }

    public static func capture(fileDescriptor: Int32) -> GADFileSystemIdentity? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return nil }
        return capture(
            info,
            volumeUUIDString: volumeUUIDString(fileDescriptor: fileDescriptor)
        )
    }

    private static func capture(
        _ info: stat,
        volumeUUIDString: String?
    ) -> GADFileSystemIdentity? {
        let objectType = info.st_mode & S_IFMT
        let kind: GADFileSystemObjectKind
        switch objectType {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        default: return nil
        }
        return GADFileSystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            kind: kind,
            volumeUUIDString: volumeUUIDString
        )
    }

    public func matchesCurrentObject(at url: URL) -> Bool {
        guard let current = Self.capture(url) else { return false }
        return matches(current)
    }

    public func matches(fileDescriptor: Int32) -> Bool {
        guard let current = Self.capture(fileDescriptor: fileDescriptor) else { return false }
        return matches(current)
    }

    /// Converts a legacy device/inode authorization into the mount-stable
    /// volume UUID form after a macOS Data-volume remount. The path is still
    /// opened without following its final component and must retain the exact
    /// inode and object type; other substitutions continue to fail closed.
    public func migratedMountStableIdentity(at url: URL) -> GADFileSystemIdentity? {
        guard volumeUUIDString == nil,
              let current = Self.capture(url),
              current.volumeUUIDString != nil,
              current.inode == inode,
              current.kind == kind else { return nil }
        return current
    }

    public static func contentSHA256(
        at url: URL,
        maximumBytes: Int = 25 * 1_024 * 1_024
    ) -> String? {
        let descriptor = open(fileSystemPath(for: url), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumBytes,
              let data = try? handle.readToEnd(),
              data.count == Int(info.st_size) else {
            try? handle.close()
            return nil
        }
        try? handle.close()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// POSIX treats a trailing slash as a request to resolve the final object
    /// as a directory, which can make `lstat` follow a symbolic link. URL
    /// directory hints commonly add that slash, so remove it before every
    /// identity-sensitive syscall while preserving the filesystem root.
    private static func fileSystemPath(for url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Compares captured objects using the same mount-stable authorization
    /// policy as path and descriptor checks. Structural equality also includes
    /// the boot-local device number and must not be used for authorization.
    public func matches(_ current: GADFileSystemIdentity) -> Bool {
        guard current.inode == inode, current.kind == kind else { return false }
        if let volumeUUIDString {
            guard let currentVolumeUUID = current.volumeUUIDString else {
                return current.device == device
            }
            return currentVolumeUUID == volumeUUIDString
        }
        if current.volumeUUIDString != nil {
            // Records created before the volume UUID field existed used a
            // boot-local APFS device number. The exact inode/type match is the
            // one-time compatibility bridge; callers can persist `current`.
            return true
        }
        return current.device == device
    }

    private static func volumeUUIDString(at url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private static func volumeUUIDString(fileDescriptor: Int32) -> String? {
        volumeUUIDString(at: URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)"))
    }
}
