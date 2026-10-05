import Darwin
import Dispatch
import Foundation
import GobyApplication

public enum GobySocketError: LocalizedError, Sendable {
    case unavailable, unsafePath, foreignUser, oversized, truncated, invalidResponse, incompatibleVersion, startupTimedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The CLI host is unavailable. Retry or run goby host run."
        case .unsafePath: "The CLI socket directory or socket is unsafe, or its path is too long."
        case .foreignUser: "The CLI socket peer belongs to a different user."
        case .oversized: "The CLI socket frame exceeds its size limit."
        case .truncated: "The CLI socket connection ended before the complete frame arrived."
        case .invalidResponse: "The CLI host returned an invalid response."
        case .incompatibleVersion: "The CLI host is draining for an upgrade. Active work must finish before replacement."
        case .startupTimedOut: "The CLI host did not finish startup. If macOS is asking for CLI Keychain access, complete that dialog and retry. Use goby host run for foreground startup diagnostics."
        }
    }
}

/// Blocking POSIX I/O runs on dedicated dispatch queues, never the main actor
/// or Swift's cooperative executor. Each connection carries exactly one frame.
enum GobySocketIO {
    static func canonicalLocation(_ url: URL) -> URL {
        var ancestor = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        guard let path = realpath(ancestor.path, nil) else { return url }
        defer { free(path) }
        var resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        for component in missing { resolved.appendPathComponent(component) }
        return resolved
    }
    static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func secureDirectory(_ directory: URL) throws {
        var missing: [URL] = []
        var ancestor = directory
        var existing = stat()
        while lstat(ancestor.path, &existing) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { throw GobySocketError.unsafePath }
            missing.insert(ancestor, at: 0)
            ancestor.deleteLastPathComponent()
        }
        guard existing.st_mode & S_IFMT == S_IFDIR else { throw GobySocketError.unsafePath }
        // mkdir sets permissions atomically. Foundation's create-then-chmod
        // sequence exposed a transient nonprivate directory to racing clients.
        for url in missing {
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw GobySocketError.unsafePath }
        }
        // Inspect each component: a private final directory must not be reached
        // through a redirected parent. /var is a system symlink, so callers use
        // canonical paths resolved before selecting their storage namespace.
        var current = directory
        while current.path != "/" {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw GobySocketError.unsafePath
            }
            current.deleteLastPathComponent()
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else { throw GobySocketError.unsafePath }
    }

    static func address(_ url: URL) throws -> sockaddr_un {
        let bytes = Array(url.path.utf8) + [0]
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw GobySocketError.unsafePath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    static func peer(_ fd: Int32, expectedUID: uid_t = geteuid()) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { throw GobySocketError.foreignUser }
    }

    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Darwin accepts may inherit the listener's nonblocking flag. Frame
        // reads run off-executor and must wait for the client to send bytes.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func readFrame(_ fd: Int32, maximum: Int) throws -> Data {
        let header = try readExactly(fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximum else { throw GobySocketError.oversized }
        return try readExactly(fd, count: Int(length))
    }

    private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GobySocketError.truncated }
                offset += n
            }
        }
        return data
    }

    static func writeFrame(_ fd: Int32, data: Data, maximum: Int) throws {
        guard !data.isEmpty, data.count <= maximum else { throw GobySocketError.oversized }
        let size = UInt32(data.count)
        var frame = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        frame.append(data)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GobySocketError.unavailable }
                offset += n
            }
        }
    }

    static func connect(_ url: URL) throws -> Int32 {
        try secureDirectory(url.deletingLastPathComponent())
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw GobySocketError.unavailable }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { throw GobySocketError.unsafePath }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GobySocketError.unavailable }
        configure(fd)
        do {
            var address = try address(url)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw GobySocketError.unavailable }
            try peer(fd)
            return fd
        } catch { close(fd); throw error }
    }
}

public actor GobyUnixSocketTransport: GADHostIPCTransporting {
    public let socketURL: URL
    public init(socketURL: URL) { self.socketURL = socketURL }
    public func exchange(_ request: GADHostIPCRequest) async throws -> GADHostIPCResponse {
        let data = try GADHostIPCCodec.encode(request)
        let url = socketURL
        let bytes = try await GobySocketIO.offload {
            let fd = try GobySocketIO.connect(url)
            defer { close(fd) }
            try GobySocketIO.writeFrame(fd, data: data, maximum: GADHostIPCCodec.maximumRequestBytes)
            return try GobySocketIO.readFrame(fd, maximum: GADHostIPCCodec.maximumResponseBytes)
        }
        let response = try GADHostIPCCodec.decodeResponse(GADHostIPCResponse.self, from: bytes)
        guard response.requestID == request.requestID else { throw GobySocketError.invalidResponse }
        return response
    }
}

public actor GobyUnixSocketListener {
    private let socketURL: URL
    private let handler: any GADHostIPCRequestHandling
    private var source: DispatchSourceRead?
    private var descriptor: Int32?
    private var connections = 0
    private var identity: UInt64?

    public init(socketURL: URL, handler: any GADHostIPCRequestHandling) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        guard descriptor == nil else { return }
        try GobySocketIO.secureDirectory(socketURL.deletingLastPathComponent())
        var prior = stat()
        if lstat(socketURL.path, &prior) == 0 {
            guard prior.st_uid == geteuid(), prior.st_mode & S_IFMT == S_IFSOCK else { throw GobySocketError.unsafePath }
            // Only remove an orphan after the host's ownership lease has been
            // acquired by composition. A live endpoint is never overwritten.
            if let live = try? GobySocketIO.connect(socketURL) { close(live); throw GobySocketError.unavailable }
            guard unlink(socketURL.path) == 0 else { throw GobySocketError.unsafePath }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GobySocketError.unavailable }
        let stagingURL = socketURL.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(6)).sock")
        do {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var address = try GobySocketIO.address(stagingURL)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(stagingURL.path, 0o600) == 0, listen(fd, 32) == 0,
                  renameatx_np(AT_FDCWD, stagingURL.path, AT_FDCWD, socketURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw GobySocketError.unavailable
            }
            var info = stat()
            guard lstat(socketURL.path, &info) == 0 else { throw GobySocketError.unsafePath }
            identity = UInt64(info.st_ino)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in Task { await self?.acceptConnections() } }
            source.setCancelHandler { close(fd) }
            self.source = source
            descriptor = fd
            source.resume()
        } catch { close(fd); _ = unlink(stagingURL.path); throw error }
    }

    private func acceptConnections() {
        guard let descriptor else { return }
        while true {
            let fd = accept(descriptor, nil, nil)
            guard fd >= 0 else { return }
            guard connections < 32 else { close(fd); continue }
            do { try GobySocketIO.peer(fd) } catch { close(fd); continue }
            GobySocketIO.configure(fd)
            connections += 1
            Task { await serve(fd) }
        }
    }

    private func serve(_ fd: Int32) async {
        defer { close(fd); connections -= 1 }
        do {
            let data = try await GobySocketIO.offload {
                try GobySocketIO.readFrame(fd, maximum: GADHostIPCCodec.maximumRequestBytes)
            }
            let request = try GADHostIPCCodec.decode(GADHostIPCRequest.self, from: data)
            let response = await handler.handle(request)
            let encoded = try GADHostIPCCodec.encodeResponse(response)
            try await GobySocketIO.offload {
                try GobySocketIO.writeFrame(fd, data: encoded, maximum: GADHostIPCCodec.maximumResponseBytes)
            }
        } catch { /* Malformed, oversized and disconnected peers receive no data. */ }
    }

    public func stop() {
        descriptor = nil
        source?.cancel()
        source = nil
        var info = stat()
        if lstat(socketURL.path, &info) == 0, UInt64(info.st_ino) == identity {
            _ = unlink(socketURL.path)
        }
        identity = nil
    }
}
