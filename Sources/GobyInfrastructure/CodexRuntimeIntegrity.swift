import Darwin
import Foundation
import Security
import Synchronization

public protocol CodexRuntimeValidating: Sendable {
    func validate(executableURL: URL) throws
    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws
}

public extension CodexRuntimeValidating {
    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {
        _ = processIdentifier
        _ = executableURL
    }
}

public enum CodexRuntimeIntegrityError: LocalizedError, Equatable, Sendable {
    case unavailable
    case untrustedLocation
    case symbolicLink
    case invalidExecutable
    case invalidSignature
    case changedDuringValidation

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The canonical OpenAI Codex runtime is unavailable. Install the verified ChatGPT app in /Applications."
        case .untrustedLocation:
            "Goby refused a Codex runtime outside the canonical OpenAI application bundle."
        case .symbolicLink:
            "Goby refused a Codex runtime reached through a symbolic link."
        case .invalidExecutable:
            "The canonical OpenAI Codex runtime is not a regular executable file."
        case .invalidSignature:
            "The ChatGPT application signature, Team ID, bundle identity, or sealed Codex runtime is invalid."
        case .changedDuringValidation:
            "The Codex runtime changed while Goby was validating it. Try again after the ChatGPT update finishes."
        }
    }
}

public enum InstalledCodexLocator {
    public static let canonicalBundleURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app",
        isDirectory: true
    )
    static let canonicalCLIBundleURL = canonicalBundleURL
        .appending(path: "Contents/Resources/codex-cli/CodexCLI.app", directoryHint: .isDirectory)
    public static let canonicalExecutableURL = canonicalCLIBundleURL
        .appending(path: "Contents/MacOS/codex", directoryHint: .notDirectory)
    public static let legacyExecutableURL = canonicalBundleURL
        .appending(path: "Contents/Resources/codex", directoryHint: .notDirectory)

    static let approvedExecutableURLs = [canonicalExecutableURL, legacyExecutableURL]

    /// A development checkout can opt into one exact local runtime. This code
    /// and environment switch are absent from release builds.
    public static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
#if DEBUG
        if let developmentExecutable = explicitDevelopmentExecutable(in: environment) {
            return developmentExecutable
        }
#else
        _ = environment
#endif
        return approvedExecutableURLs.first {
            fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false))
        } ?? canonicalExecutableURL
    }

#if DEBUG
    static let developmentExecutableEnvironmentKey = "GOBY_DEVELOPMENT_CODEX_EXECUTABLE"

    static func explicitDevelopmentExecutable(in environment: [String: String]) -> URL? {
        guard let value = environment[developmentExecutableEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
#endif
}

/// Validates the outer OpenAI application seal immediately before every Codex
/// process launch. The resource seal covers the embedded Codex executable.
public struct CodexRuntimeIntegrityValidator: CodexRuntimeValidating {
    private static let expectedBundleIdentifier = "com.openai.codex"
    private static let expectedExecutableIdentifier = "codex"
    private static let expectedTeamIdentifier = "2DC432GLL2"

#if DEBUG
    private let developmentExecutableURL: URL?
#endif

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
#if DEBUG
        developmentExecutableURL = InstalledCodexLocator.explicitDevelopmentExecutable(
            in: environment
        )
#else
        _ = environment
#endif
    }

    public func validate(executableURL: URL) throws {
        let executable = executableURL.standardizedFileURL
#if DEBUG
        if executable == developmentExecutableURL {
            _ = try CodexRuntimePathPolicy.validateExecutable(executable)
            return
        }
#endif
        guard executableURL.isFileURL,
              InstalledCodexLocator.approvedExecutableURLs.contains(executable) else {
            throw CodexRuntimeIntegrityError.untrustedLocation
        }

        let initialIdentity = try CodexRuntimePathPolicy.validateExecutable(executable)
        try Self.validateOpenAIBundle(InstalledCodexLocator.canonicalBundleURL)
        try Self.validateOpenAIExecutable(executable)
        let finalIdentity = try CodexRuntimePathPolicy.validateExecutable(executable)
        guard initialIdentity == finalIdentity else {
            throw CodexRuntimeIntegrityError.changedDuringValidation
        }
    }

    public func validateRunningProcess(
        processIdentifier: Int32,
        executableURL: URL
    ) throws {
#if DEBUG
        if executableURL.standardizedFileURL == developmentExecutableURL {
            return
        }
#endif
        let expected = executableURL.standardizedFileURL
        guard InstalledCodexLocator.approvedExecutableURLs.contains(expected) else {
            throw CodexRuntimeIntegrityError.untrustedLocation
        }
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier)
        ] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode
        ) == errSecSuccess,
              let runningCode else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }

        let expression = "anchor apple generic and identifier \"\(Self.expectedExecutableIdentifier)\" and certificate leaf[subject.OU] = \"\(Self.expectedTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                  runningCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            runningCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }
        var path: CFURL?
        let expectedStaticCodePath = expected == InstalledCodexLocator.canonicalExecutableURL
            ? InstalledCodexLocator.canonicalCLIBundleURL
            : expected
        var processPath = [CChar](repeating: 0, count: 4_096)
        let processPathLength = proc_pidpath(processIdentifier, &processPath, UInt32(processPath.count))
        let processExecutablePath = String(
            decoding: processPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard SecCodeCopyPath(staticCode, SecCSFlags(), &path) == errSecSuccess,
              let runningURL = path as URL?,
              runningURL.standardizedFileURL == expectedStaticCodePath,
              processPathLength > 0,
              URL(fileURLWithPath: processExecutablePath).standardizedFileURL == expected else {
            throw CodexRuntimeIntegrityError.changedDuringValidation
        }
    }

    private static func validateOpenAIBundle(_ bundleURL: URL) throws {
        let expression = "anchor apple generic and identifier \"\(expectedBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        try validateCode(
            at: bundleURL,
            expression: expression,
            expectedIdentifier: expectedBundleIdentifier,
            checksNestedCode: true
        )
    }

    private static func validateOpenAIExecutable(_ executableURL: URL) throws {
        let expression = "anchor apple generic and identifier \"\(expectedExecutableIdentifier)\" and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        try validateCode(
            at: executableURL,
            expression: expression,
            expectedIdentifier: expectedExecutableIdentifier,
            checksNestedCode: false
        )
    }

    private static func validateCode(
        at url: URL,
        expression: String,
        expectedIdentifier: String,
        checksNestedCode: Bool
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }

        var rawFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if checksNestedCode { rawFlags |= kSecCSCheckNestedCode }
        let flags = SecCSFlags(rawValue: rawFlags)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              values[kSecCodeInfoIdentifier] as? String == expectedIdentifier,
              values[kSecCodeInfoTeamIdentifier] as? String == expectedTeamIdentifier else {
            throw CodexRuntimeIntegrityError.invalidSignature
        }
    }
}

enum CodexRuntimePathPolicy {
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    static func validateExecutable(_ executableURL: URL) throws -> FileIdentity {
        let path = executableURL.path(percentEncoded: false)
        guard executableURL.isFileURL, path.hasPrefix("/") else {
            throw CodexRuntimeIntegrityError.untrustedLocation
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw CodexRuntimeIntegrityError.invalidExecutable }
        var current = ""
        var finalStatus = stat()
        for (index, component) in components.enumerated() {
            current += "/\(component)"
            var status = stat()
            let result = current.withCString { lstat($0, &status) }
            guard result == 0 else { throw CodexRuntimeIntegrityError.unavailable }
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw CodexRuntimeIntegrityError.symbolicLink
            }
            if index < components.count - 1 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw CodexRuntimeIntegrityError.invalidExecutable
                }
            } else {
                finalStatus = status
            }
        }

        guard (finalStatus.st_mode & S_IFMT) == S_IFREG,
              finalStatus.st_size > 0,
              finalStatus.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw CodexRuntimeIntegrityError.invalidExecutable
        }
        return FileIdentity(
            device: UInt64(finalStatus.st_dev),
            inode: UInt64(finalStatus.st_ino),
            size: Int64(finalStatus.st_size),
            modificationSeconds: Int64(finalStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(finalStatus.st_mtimespec.tv_nsec)
        )
    }

}
