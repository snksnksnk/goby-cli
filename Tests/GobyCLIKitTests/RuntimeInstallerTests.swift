import CryptoKit
import Foundation
import Testing
@testable import GobyCLIKit
import GobyInfrastructure

@Suite("On-demand provider runtimes", .serialized)
struct RuntimeInstallerTests {
    /// A release folder with one Claude package and the manifest goby would carry.
    struct Release {
        let root: URL
        let downloads: URL
        let runtimes: URL
        let manifest: [String: String]
        let archiveDigest: String
        func installer(archives: [String: String]? = nil, manifest: [String: String]? = nil) -> GobyRuntimeInstaller {
            GobyRuntimeInstaller(root: runtimes.appending(path: "1.2.3"), version: "1.2.3", architecture: "arm64",
                                 manifest: manifest ?? self.manifest, archives: archives ?? ["claude-arm64": archiveDigest],
                                 downloadBase: downloads)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func makeRelease() throws -> Release {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-runtime-\(UUID().uuidString)").resolvingSymlinksInPath()
        let package = root.appending(path: "package/ClaudeAgentSDKBridge")
        try FileManager.default.createDirectory(at: package.appending(path: "bin"), withIntermediateDirectories: true)
        let files = ["bin/node": "#!/bin/sh\necho node\n", "index.js": "console.log('bridge')\n", "bridge.js": "module.exports = {}\n"]
        var manifest: [String: String] = [:]
        for (path, text) in files {
            try Data(text.utf8).write(to: package.appending(path: path))
            manifest["ClaudeAgentSDKBridge/" + path] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.appending(path: "bin/node").path)
        let downloads = root.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let archive = downloads.appending(path: "goby-runtime-claude-1.2.3-arm64.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", root.appending(path: "package").path, "ClaudeAgentSDKBridge"]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run(); tar.waitUntilExit()
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        return Release(root: root, downloads: downloads, runtimes: root.appending(path: "runtimes"), manifest: manifest, archiveDigest: digest)
    }

    @Test("A matching package installs, verifies, and runs from the per-version folder")
    func installs() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let installer = release.installer()
        #expect(installer.status(.claude) == .notInstalled)
        try await installer.install(.claude)
        #expect(installer.status(.claude) == .installed)
        let node = installer.root.appending(path: "ClaudeAgentSDKBridge/bin/node")
        #expect(FileManager.default.isExecutableFile(atPath: node.path))
        // Copilot isn't installed, and that doesn't affect Claude.
        #expect(installer.status(.copilot) == .unavailable)
    }

    @Test("A package whose bytes differ from the signed hash is refused")
    func rejectsChangedPackage() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let installer = release.installer(archives: ["claude-arm64": String(repeating: "0", count: 64)])
        await #expect(throws: GobyTerminalError.self) { try await installer.install(.claude) }
        #expect(!FileManager.default.fileExists(atPath: installer.root.appending(path: "ClaudeAgentSDKBridge").path))
    }

    @Test("A package whose files differ from the signed manifest is refused")
    func rejectsChangedFiles() async throws {
        let release = try makeRelease(); defer { release.remove() }
        var manifest = release.manifest
        manifest["ClaudeAgentSDKBridge/index.js"] = String(repeating: "f", count: 64)
        let installer = release.installer(manifest: manifest)
        await #expect(throws: GobyTerminalError.self) { try await installer.install(.claude) }
        #expect(installer.status(.claude) == .notInstalled)
    }

    @Test("A file changed after install makes the runtime invalid again")
    func detectsTamperingAfterInstall() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let installer = release.installer()
        try await installer.install(.claude)
        try Data("console.log('changed')\n".utf8).write(to: installer.root.appending(path: "ClaudeAgentSDKBridge/index.js"))
        #expect(installer.status(.claude) == .notInstalled)
        // Reinstalling repairs it.
        try await installer.install(.claude)
        #expect(installer.status(.claude) == .installed)
    }

    @Test("Stray files beside the runtimes are refused, Finder metadata is not")
    func strayFiles() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let installer = release.installer()
        try await installer.install(.claude)
        try Data().write(to: installer.root.appending(path: ".DS_Store"))
        #expect(installer.status(.claude) == .installed)
        try FileManager.default.createDirectory(at: installer.root.appending(path: "node_modules"), withIntermediateDirectories: true)
        #expect(installer.status(.claude) == .notInstalled)
    }

    @Test("Removing deletes the runtime; older goby versions' runtimes are cleaned up on install")
    func removeAndCleanup() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let old = release.runtimes.appending(path: "1.0.0")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let unrelated = release.runtimes.appending(path: "notes")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let installer = release.installer()
        try await installer.install(.claude)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try installer.remove(.claude)
        #expect(installer.status(.claude) == .notInstalled)
    }

    @Test("A source build has nothing to download and says so")
    func sourceBuild() async throws {
        let release = try makeRelease(); defer { release.remove() }
        let installer = release.installer(archives: [:])
        #expect(installer.status(.claude) == .unavailable)
        await #expect(throws: GobyTerminalError.self) { try await installer.install(.claude) }
    }

    @Test("Download overrides accept only https or local files")
    func overrides() {
        #expect(GobyRuntimeInstaller.configuredDownloadBase(environment: ["GOBY_RUNTIME_DOWNLOAD_BASE": "http://example.com/x"]) == StandaloneProviderRuntimeRelease.downloadBase)
        #expect(GobyRuntimeInstaller.configuredDownloadBase(environment: ["GOBY_RUNTIME_DOWNLOAD_BASE": "https://example.com/x"])?.host == "example.com")
    }
}
