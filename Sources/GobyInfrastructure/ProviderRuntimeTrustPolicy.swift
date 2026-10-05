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

public struct StandaloneProviderRuntimeTrustPolicy: ProviderRuntimeTrustPolicy {
    /// Values are generated from the pinned release runtime before signing.
    /// Source builds fail closed. The distribution flag requires a generated
    /// Swift constant from the already signed, pinned payload, never a sidecar.
#if GOBY_CLI_DISTRIBUTION
    public static var compiledManifest: [String: String] { GobyCLICompiledRuntime.manifest }
#else
    public static let compiledManifest: [String: String] = [:]
#endif
    private let manifest: [String: String]

    public init(manifest: [String: String] = Self.compiledManifest) {
        self.manifest = manifest
    }

    public func codexExecutableURL() -> URL { StandaloneCodexLocator.locate() }
    public func codexValidator() -> any CodexRuntimeValidating {
        StandaloneCodexRuntimeIntegrityValidator()
    }

    public func validateProviderRuntime(bundleURL: URL, runtimeURLs: [URL]) throws {
        let root = bundleURL
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, !runtimeURLs.isEmpty else { throw ProviderRuntimeIntegrityError.invalidBundle }
        guard let canonicalRoot = Self.canonicalPath(root) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        let prefix = canonicalRoot + (canonicalRoot.hasSuffix("/") ? "" : "/")
        let logicalRoot = root.path(percentEncoded: false)
        let logicalPrefix = logicalRoot + (logicalRoot.hasSuffix("/") ? "" : "/")
        var seen = Set<String>()
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        for case let file as URL in files {
            guard let path = Self.canonicalPath(file), path.hasPrefix(prefix),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw ProviderRuntimeIntegrityError.invalidBundle }
            guard values.isRegularFile == true else {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw ProviderRuntimeIntegrityError.invalidBundle }
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            guard let expected = manifest[relative],
                  expected.count == 64,
                  let data = try? Data(contentsOf: file),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
            seen.insert(relative)
        }
        guard seen == Set(manifest.keys) else { throw ProviderRuntimeIntegrityError.invalidBundle }
        for runtimeURL in runtimeURLs {
            let runtime = runtimeURL
            let path = runtime.path(percentEncoded: false)
            guard path.hasPrefix(logicalPrefix),
                  seen.contains(String(path.dropFirst(logicalPrefix.count))),
                  Self.canonicalPath(runtime) == prefix + String(path.dropFirst(logicalPrefix.count)) else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
        }
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
