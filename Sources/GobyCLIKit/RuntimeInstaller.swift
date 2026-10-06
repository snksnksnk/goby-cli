import CryptoKit
import Foundation
import GobyInfrastructure

/// Downloads Claude and Copilot runtimes on demand.
///
/// The signed goby binary carries the SHA-256 of every runtime package and of
/// every file inside it. A package is accepted only if its bytes match, then
/// extracted into a staging folder, checked file by file, and moved into place
/// in one step. The host checks the same manifest again before every launch.
public struct GobyRuntimeInstaller: Sendable {
    public enum Component: String, CaseIterable, Sendable {
        case claude, copilot

        public var directory: String { self == .claude ? "ClaudeAgentSDKBridge" : "CopilotSDKBridge" }
        public var displayName: String { self == .claude ? "Claude" : "Copilot" }
        /// Rough download size, for the prompt.
        public var approximateMegabytes: Int { self == .claude ? 200 : 80 }

        public init?(provider: String) {
            switch provider.lowercased() {
            case "claude": self = .claude
            case "copilot", "github-copilot": self = .copilot
            default: return nil
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case installed
        case notInstalled
        /// This build carries no runtime packages (a source build).
        case unavailable
    }

    public let root: URL
    let version: String
    let architecture: String
    let manifest: [String: String]
    let archives: [String: String]
    let downloadBase: URL?
    let session: URLSession
    static let maximumArchiveBytes: Int64 = 900 * 1_024 * 1_024

    public init(root: URL = StandaloneProviderRuntimeRelease.root(),
                version: String = StandaloneProviderRuntimeRelease.version,
                architecture: String = StandaloneProviderRuntimeRelease.architecture,
                manifest: [String: String] = StandaloneProviderRuntimeTrustPolicy.compiledManifest,
                archives: [String: String] = StandaloneProviderRuntimeRelease.archives,
                downloadBase: URL? = Self.configuredDownloadBase(),
                session: URLSession = .shared) {
        self.root = root; self.version = version; self.architecture = architecture
        self.manifest = manifest; self.archives = archives; self.downloadBase = downloadBase; self.session = session
    }

    /// GOBY_RUNTIME_DOWNLOAD_BASE lets a release be checked before upload.
    /// The package hashes compiled into goby still decide what is accepted.
    public static func configuredDownloadBase(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["GOBY_RUNTIME_DOWNLOAD_BASE"], let url = URL(string: override),
           url.scheme == "https" || url.isFileURL { return url }
        return StandaloneProviderRuntimeRelease.downloadBase
    }

    public func packageName(_ component: Component) -> String {
        "goby-runtime-\(component.rawValue)-\(version)-\(architecture).tar.gz"
    }

    func entryURLs(_ component: Component, in base: URL) -> [URL] {
        let folder = base.appending(path: component.directory, directoryHint: .isDirectory)
        return [folder.appending(path: "bin/node"), folder.appending(path: "index.js")]
    }

    public func status(_ component: Component) -> Status {
        guard archives["\(component.rawValue)-\(architecture)"] != nil else { return .unavailable }
        let policy = StandaloneProviderRuntimeTrustPolicy(manifest: manifest)
        return (try? policy.validateProviderRuntime(bundleURL: root, runtimeURLs: entryURLs(component, in: root))) != nil
            ? .installed : .notInstalled
    }

    /// Installs one runtime. `progress` receives (bytes so far, total if known).
    public func install(_ component: Component,
                        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws {
        guard let expected = archives["\(component.rawValue)-\(architecture)"], let downloadBase else {
            throw GobyTerminalError("This goby build doesn't include downloadable runtimes. Install goby with Homebrew to use \(component.displayName).", code: 4)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.deletingLastPathComponent()
            .appending(path: ".staging-\(component.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appending(path: packageName(component))
        let source = downloadBase.appending(path: packageName(component))
        let digest = try await download(source, to: archive, progress: progress)
        guard digest == expected else {
            throw GobyTerminalError("The \(component.displayName) runtime download didn't match this goby release, so it wasn't installed. Try again; if it keeps happening, your network may be altering downloads.", code: 4)
        }

        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.extract(archive, into: unpacked)
        let policy = StandaloneProviderRuntimeTrustPolicy(manifest: manifest)
        do {
            try policy.validateProviderRuntime(bundleURL: unpacked, runtimeURLs: entryURLs(component, in: unpacked))
        } catch {
            throw GobyTerminalError("The \(component.displayName) runtime package didn't match its signed manifest, so it wasn't installed.", code: 4)
        }

        // Swap in place: the old copy moves aside first, then is removed.
        let destination = root.appending(path: component.directory, directoryHint: .isDirectory)
        let previous = staging.appending(path: "previous", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.moveItem(at: destination, to: previous) }
        do {
            try fileManager.moveItem(at: unpacked.appending(path: component.directory, directoryHint: .isDirectory), to: destination)
        } catch {
            if fileManager.fileExists(atPath: previous.path) { try? fileManager.moveItem(at: previous, to: destination) }
            throw error
        }
        removeOtherVersions()
    }

    public func remove(_ component: Component) throws {
        let destination = root.appending(path: component.directory, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }

    /// Runtimes of older goby versions are no longer used after an upgrade.
    func removeOtherVersions() {
        let parent = root.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for entry in entries where entry != root.lastPathComponent
            && entry.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil {
            try? FileManager.default.removeItem(at: parent.appending(path: entry))
        }
    }

    private func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var received: Int64 = 0
        if url.isFileURL {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                received += Int64(chunk.count)
                guard received <= Self.maximumArchiveBytes else { throw GobyTerminalError("The runtime download is larger than expected.", code: 4) }
                hasher.update(data: chunk); try handle.write(contentsOf: chunk); progress(received, nil)
            }
        } else {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GobyTerminalError("Couldn't download the runtime (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your connection and try again.", code: 3)
            }
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            var buffer = Data(); buffer.reserveCapacity(1_024 * 1_024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1_024 * 1_024 {
                    received += Int64(buffer.count)
                    guard received <= Self.maximumArchiveBytes else { throw GobyTerminalError("The runtime download is larger than expected.", code: 4) }
                    hasher.update(data: buffer); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                    progress(received, total)
                }
            }
            received += Int64(buffer.count)
            hasher.update(data: buffer); try handle.write(contentsOf: buffer)
            progress(received, total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The system tar, with no ownership or permission surprises.
    static func extract(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GobyTerminalError("The runtime package couldn't be unpacked.", code: 1) }
    }
}
