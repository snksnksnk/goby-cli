import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization

/// The host composition chooses this policy explicitly. The app's default
/// remains the location-bound validator used by existing signed builds.
public protocol ProviderRuntimeTrustPolicy: Sendable {
    func codexExecutableURL() -> URL
    func codexValidator() -> any CodexRuntimeValidating
    func validateProviderRuntime(bundleURL: URL, runtimeURLs: [URL]) throws
}

public struct AppProviderRuntimeTrustPolicy: ProviderRuntimeTrustPolicy {
    public init() {}
    public func codexExecutableURL() -> URL { InstalledCodexLocator.locate() }
    public func codexValidator() -> any CodexRuntimeValidating { CodexRuntimeIntegrityValidator() }
    public func validateProviderRuntime(bundleURL: URL, runtimeURLs: [URL]) throws {
        try ProviderRuntimeIntegrity.validateSignedBundle(at: bundleURL, protecting: runtimeURLs)
    }
}

/// What a distribution build of goby knows about its downloadable runtimes.
/// Source builds have none and fail closed. Values come from the generated,
/// signed release constant, never from a file next to the binary.
public enum StandaloneProviderRuntimeRelease {
    /// This Mac's architecture, as used in runtime package names.
    public static var architecture: String {
#if arch(arm64)
        "arm64"
#else
        "x86_64"
#endif
    }
#if GOBY_CLI_DISTRIBUTION
    public static var version: String { GobyCLICompiledRuntime.version }
    /// Per-architecture manifests: relative path → SHA-256 for every file.
    public static var manifests: [String: [String: String]] { GobyCLICompiledRuntime.manifests }
    /// "claude-arm64" → SHA-256 of that release package.
    public static var archives: [String: String] { GobyCLICompiledRuntime.archives }
    public static var downloadBase: URL? { URL(string: GobyCLICompiledRuntime.downloadBase) }
#else
    public static let version = "development"
    public static let manifests: [String: [String: String]] = [:]
    public static let archives: [String: String] = [:]
    public static let downloadBase: URL? = nil
#endif

    /// Runtimes live outside the Homebrew prefix, one folder per goby version.
    public static func root(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "Goby CLI Runtime/\(version)", directoryHint: .isDirectory)
    }
}

public struct StandaloneProviderRuntimeTrustPolicy: ProviderRuntimeTrustPolicy {
    public static var compiledManifest: [String: String] {
        StandaloneProviderRuntimeRelease.manifests[StandaloneProviderRuntimeRelease.architecture] ?? [:]
    }
    private let manifest: [String: String]

    public init(manifest: [String: String] = Self.compiledManifest) {
        self.manifest = manifest
    }

    public func codexExecutableURL() -> URL { StandaloneCodexLocator.locate() }
    public func codexValidator() -> any CodexRuntimeValidating {
        StandaloneCodexRuntimeIntegrityValidator()
    }

    /// Runtimes are installed one at a time, so only the components the
    /// runtime URLs belong to (their first path element under the root) are
    /// checked, each against every manifest entry for it. Nothing else may
    /// sit at the root, so no stray module can shadow a bridge dependency.
    public func validateProviderRuntime(bundleURL: URL, runtimeURLs: [URL]) throws {
        let root = bundleURL
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, !runtimeURLs.isEmpty else { throw ProviderRuntimeIntegrityError.invalidBundle }
        guard let canonicalRoot = Self.canonicalPath(root) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        let prefix = canonicalRoot + (canonicalRoot.hasSuffix("/") ? "" : "/")
        let logicalRoot = root.path(percentEncoded: false)
        let logicalPrefix = logicalRoot + (logicalRoot.hasSuffix("/") ? "" : "/")

        let allComponents = Set(manifest.keys.compactMap { $0.split(separator: "/").first.map(String.init) })
        let topLevel = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard topLevel.allSatisfy({ allComponents.contains($0) || $0 == Self.finderMetadata }) else { throw ProviderRuntimeIntegrityError.invalidBundle }

        var components = Set<String>()
        for runtimeURL in runtimeURLs {
            let path = runtimeURL.path(percentEncoded: false)
            guard path.hasPrefix(logicalPrefix),
                  let component = path.dropFirst(logicalPrefix.count).split(separator: "/").first.map(String.init),
                  allComponents.contains(component) else { throw ProviderRuntimeIntegrityError.invalidBundle }
            components.insert(component)
        }
        let expected = manifest.filter { key, _ in
            components.contains(key.split(separator: "/").first.map(String.init) ?? "")
        }

        var seen = Set<String>()
        for component in components.sorted() {
            let componentURL = root.appending(path: component)
            var info = stat()
            guard lstat(componentURL.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw ProviderRuntimeIntegrityError.invalidBundle }
            if info.st_mode & S_IFMT == S_IFREG {
                try check(file: componentURL, prefix: prefix, expected: expected, seen: &seen)
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR,
                  let files = FileManager.default.enumerator(at: componentURL,
                      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
            for case let file as URL in files {
                var fileInfo = stat()
                guard lstat(file.path, &fileInfo) == 0, fileInfo.st_mode & S_IFMT != S_IFLNK else { throw ProviderRuntimeIntegrityError.invalidBundle }
                if fileInfo.st_mode & S_IFMT == S_IFDIR { continue }
                // Finder metadata is not code and is never loaded.
                if file.lastPathComponent == Self.finderMetadata, fileInfo.st_mode & S_IFMT == S_IFREG { continue }
                guard fileInfo.st_mode & S_IFMT == S_IFREG else { throw ProviderRuntimeIntegrityError.invalidBundle }
                try check(file: file, prefix: prefix, expected: expected, seen: &seen)
            }
        }
        guard !expected.isEmpty, seen == Set(expected.keys) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        for runtimeURL in runtimeURLs {
            let path = runtimeURL.path(percentEncoded: false)
            guard seen.contains(String(path.dropFirst(logicalPrefix.count))),
                  Self.canonicalPath(runtimeURL) == prefix + String(path.dropFirst(logicalPrefix.count)) else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
        }
    }

    private static let finderMetadata = ".DS_Store"

    private func check(file: URL, prefix: String, expected: [String: String], seen: inout Set<String>) throws {
        guard let path = Self.canonicalPath(file), path.hasPrefix(prefix) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        let relative = String(path.dropFirst(prefix.count))
        guard let digest = expected[relative], digest.count == 64,
              try Self.sha256(of: file) == digest else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        seen.insert(relative)
    }

    /// Streams the file, so large native runtimes are not loaded whole.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Foundation normalizes /private/var aliases inconsistently between
    /// directory URLs and enumeration. POSIX paths retain filesystem identity.
    private static func canonicalPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }
}

public enum StandaloneCodexLocator {
    public static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let candidates = InstalledCodexLocator.approvedExecutableURLs + installationCandidates(home: home, fileManager: fileManager)
        let validator = StandaloneCodexRuntimeIntegrityValidator()
        return candidates.first { (try? validator.validate(executableURL: $0)) != nil }
            ?? InstalledCodexLocator.canonicalExecutableURL
    }
    /// Resolve known installer aliases only during discovery. Validation and
    /// launch both use the canonical native file, never a wrapper or symlink.
    public static func installationCandidates(
        home: URL,
        prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")],
        fileManager: FileManager = .default
    ) -> [URL] {
        func versions(_ directory: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        }
        var candidates = versions(home.appending(path: ".codex/packages/standalone/releases"))
            .map { $0.appending(path: "bin/codex") }
        for prefix in prefixes {
            let alias = prefix.appending(path: "bin/codex")
            if fileManager.fileExists(atPath: alias.path) { candidates.append(alias.resolvingSymlinksInPath()) }
            candidates += versions(prefix.appending(path: "Cellar/codex")).map { $0.appending(path: "bin/codex") }
            // npm's bin/codex.js is a launcher. Only signed native payloads
            // in its platform packages can satisfy the runtime policy.
            let modules = prefix.appending(path: "lib/node_modules/@openai")
            for target in ["aarch64-apple-darwin", "x86_64-apple-darwin"] {
                candidates.append(modules.appending(path: "codex/vendor/\(target)/codex/codex"))
                let platform = target.hasPrefix("aarch64") ? "darwin-arm64" : "darwin-x64"
                candidates.append(modules.appending(path: "codex/node_modules/@openai/codex-\(platform)/vendor/\(target)/codex/codex"))
                candidates.append(modules.appending(path: "codex-\(platform)/vendor/\(target)/codex/codex"))
            }
        }
        return candidates
    }

}

public final class StandaloneCodexRuntimeIntegrityValidator: CodexRuntimeValidating, @unchecked Sendable {
    private static let requirementExpression =
        "anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
    private let validatedIdentity = Mutex<CodexRuntimePathPolicy.FileIdentity?>(nil)
    private let assumeValidSignatureForTests: Bool

    public init() {
        assumeValidSignatureForTests = false
    }

#if DEBUG
    init(assumeValidSignatureForTests: Bool) {
        self.assumeValidSignatureForTests = assumeValidSignatureForTests
    }
#endif

    public func validate(executableURL: URL) throws {
        let initial = try CodexRuntimePathPolicy.validateExecutable(executableURL)
        if !assumeValidSignatureForTests {
            let requirement = try Self.requirement()
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(executableURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
                  let staticCode,
                  SecStaticCodeCheckValidity(
                    staticCode,
                    SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                    requirement
                  ) == errSecSuccess else {
                throw CodexRuntimeIntegrityError.invalidSignature
            }
        }
        let final = try CodexRuntimePathPolicy.validateExecutable(executableURL)
        guard initial == final else { throw CodexRuntimeIntegrityError.changedDuringValidation }
        validatedIdentity.withLock { $0 = final }
    }

    public func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {
        let expected = executableURL
        let validated = validatedIdentity.withLock { $0 }
        guard let validated,
              validated == (try CodexRuntimePathPolicy.validateExecutable(expected)) else {
            throw CodexRuntimeIntegrityError.changedDuringValidation
        }
        var path = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(processIdentifier, &path, UInt32(path.count))
        let processPath = String(
            decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard pathLength > 0,
              URL(fileURLWithPath: processPath).standardizedFileURL == expected else {
            throw CodexRuntimeIntegrityError.changedDuringValidation
        }
#if DEBUG
        if assumeValidSignatureForTests { return }
#endif
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(
                runningCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                try Self.requirement()
              ) == errSecSuccess else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }
    }

    private static func requirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementExpression as CFString, SecCSFlags(), &requirement
        ) == errSecSuccess, let requirement else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }
        return requirement
    }
}
