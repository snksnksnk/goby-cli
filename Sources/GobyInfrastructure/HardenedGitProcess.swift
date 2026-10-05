import Darwin
import Foundation

enum HardenedGitProcessError: LocalizedError, Sendable, Equatable {
    case commandCouldNotStart(String)
    case commandTimedOut
    case outputTooLarge
    case directoryBudgetExceeded
    case executableRepositoryConfiguration(String)
    case unsafeRepositoryMetadata

    var errorDescription: String? {
        switch self {
        case let .commandCouldNotStart(message): message
        case .commandTimedOut: "Git timed out before completing."
        case .outputTooLarge: "Git returned more output than Goby permits."
        case .directoryBudgetExceeded: "Git exceeded Goby's protected clone size or file-count limit."
        case let .executableRepositoryConfiguration(key):
            "Goby blocked executable Git configuration (\(key)). Disable the hook, filter, fsmonitor, diff helper, signing helper, or SSH command and review the operation again."
        case .unsafeRepositoryMetadata:
            "Goby could not prove that this repository's Git metadata remains inside the reviewed project boundary."
        }
    }
}

enum InstalledGitHubCLICredentialHelperLocator {
    static func locate(fileManager: FileManager = .default) -> URL? {
        for candidate in [
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh"),
        ] {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.isExecutableFile(atPath: resolved.path(percentEncoded: false)),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  HardenedGitProcess.isSafeCredentialHelperPath(resolved) else { continue }
            return resolved
        }
        return nil
    }
}

/// The single host-side execution boundary for Git. It deliberately does not
/// mutate user or repository configuration.
enum HardenedGitProcess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    struct DirectoryBudget: Sendable {
        let rootURL: URL
        let maximumBytes: Int64
        let maximumEntries: Int
    }

    private static let fixedArguments = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.attributesFile=/dev/null",
        "-c", "commit.gpgSign=false",
        "-c", "tag.gpgSign=false",
        "-c", "diff.external=",
    ]

    static func run(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval? = nil,
        maximumOutputBytes: Int = 16 * 1_048_576,
        directoryBudget: DirectoryBudget? = nil,
        preflightRepository: Bool = true,
        allowedLinkedWorktreeCommonDirectory: URL? = nil,
        credentialHelperURL: URL? = nil
    ) throws -> Result {
        if preflightRepository,
           FileManager.default.fileExists(
               atPath: currentDirectory.appending(path: ".git").path(percentEncoded: false)
           ) {
            try validateRepositoryIdentity(
                in: currentDirectory,
                allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
            )
            try validateRepositoryConfiguration(in: currentDirectory)
        }
        let credentialArguments = try credentialHelperArguments(for: credentialHelperURL)
        return try runRaw(
            arguments: credentialArguments + fixedArguments + arguments,
            currentDirectory: currentDirectory,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            directoryBudget: directoryBudget
        )
    }

    static func credentialHelperArguments(for helperURL: URL?) throws -> [String] {
        guard let helperURL else { return [] }
        let helper = helperURL.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)),
              let values = try? helper.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              isSafeCredentialHelperPath(helper) else {
            throw HardenedGitProcessError.commandCouldNotStart(
                "The selected Git credential helper is unavailable or unsafe."
            )
        }
        return [
            "-c", "credential.helper=",
            "-c", "credential.https://github.com.helper=!\(helper.path(percentEncoded: false)) auth git-credential",
        ]
    }

    static func isSafeCredentialHelperPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard url.isFileURL, path.hasPrefix("/"), !path.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._+-"))
        return path.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func validateRepositoryIdentity(
        in directory: URL,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws {
        let root = directory.standardizedFileURL
        let anchoredRoot = try AnchoredDirectory.openAbsolute(root)
        var markerInfo = stat()
        guard fstatat(anchoredRoot.descriptor, ".git", &markerInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let markerType = markerInfo.st_mode & S_IFMT
        guard markerType == S_IFDIR || markerType == S_IFREG else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }

        let topLevel = try repositoryPath(
            ["--show-toplevel"],
            in: root
        )
        let gitDirectory = try repositoryPath(
            ["--absolute-git-dir"],
            in: root
        )
        let commonDirectory = try repositoryPath(
            ["--path-format=absolute", "--git-common-dir"],
            in: root
        )
        guard samePath(topLevel, root) else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }

        if markerType == S_IFDIR {
            guard isContained(gitDirectory, in: root),
                  isContained(commonDirectory, in: root) else {
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
            try validateMetadataBoundary(
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory
            )
            return
        }

        guard let allowedLinkedWorktreeCommonDirectory else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let allowed = allowedLinkedWorktreeCommonDirectory.standardizedFileURL
        guard samePath(commonDirectory, allowed),
              isContained(gitDirectory, in: allowed.appending(path: "worktrees")) else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        _ = try AnchoredDirectory.openAbsolute(allowed)
        _ = try AnchoredDirectory.openAbsolute(gitDirectory)
        let markerContents = try anchoredRoot.read(".git", maximumBytes: 16 * 1_024)
        guard let markerText = String(data: markerContents, encoding: .utf8),
              markerText.hasPrefix("gitdir: ") else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let target = markerText
            .dropFirst("gitdir: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains("\n") else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let markerTarget = target.hasPrefix("/")
            ? URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: target, relativeTo: root).standardizedFileURL
        guard samePath(markerTarget, gitDirectory) else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        try validateMetadataBoundary(
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory
        )
    }

    static func linkedWorktreeCommonDirectory(in directory: URL) throws -> URL? {
        let root = directory.standardizedFileURL
        let anchoredRoot = try AnchoredDirectory.openAbsolute(root)
        var markerInfo = stat()
        guard fstatat(anchoredRoot.descriptor, ".git", &markerInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        if markerInfo.st_mode & S_IFMT == S_IFDIR { return nil }
        guard markerInfo.st_mode & S_IFMT == S_IFREG else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let commonDirectory = try repositoryPath(
            ["--path-format=absolute", "--git-common-dir"],
            in: root
        )
        try validateRepositoryIdentity(
            in: root,
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )
        return commonDirectory
    }

    private static func repositoryPath(_ arguments: [String], in directory: URL) throws -> URL {
        let result = try runRaw(
            arguments: fixedArguments + [
                "-C", directory.path(percentEncoded: false), "rev-parse",
            ] + arguments,
            currentDirectory: directory,
            timeout: 10,
            maximumOutputBytes: 16 * 1_024
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, output.hasPrefix("/"), !output.contains("\n") else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        return URL(fileURLWithPath: output, isDirectory: true)
            .standardizedFileURL
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let candidatePath = normalizedPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    /// Git resolves paths below `.git` itself, so validating only the marker
    /// leaves approved writes vulnerable to nested symlink redirection. This
    /// descriptor-relative walk checks the small mutable control trees in
    /// full, while keeping large object stores bounded to their directory
    /// roots plus the security-sensitive `pack` and `info` subtrees.
    private static func validateMetadataBoundary(
        gitDirectory: URL,
        commonDirectory: URL
    ) throws {
        let git = try AnchoredDirectory.openAbsolute(gitDirectory)
        let common = samePath(gitDirectory, commonDirectory)
            ? git
            : try AnchoredDirectory.openAbsolute(commonDirectory)

        // Git writes several transient files directly in these roots (for
        // example COMMIT_EDITMSG). Enumerate every direct entry so an unlisted
        // filename cannot hide a symlink or special-file redirect.
        var gitRootBudget = 4_096
        try validateDirectoryContents(
            git.descriptor,
            recurse: false,
            depthRemaining: 0,
            rejectHardLinks: true,
            allowedSocketNames: gitOwnedSocketNames,
            entryBudget: &gitRootBudget
        )
        if !samePath(gitDirectory, commonDirectory) {
            var commonRootBudget = 4_096
            try validateDirectoryContents(
                common.descriptor,
                recurse: false,
                depthRemaining: 0,
                rejectHardLinks: true,
                allowedSocketNames: gitOwnedSocketNames,
                entryBudget: &commonRootBudget
            )
        }

        try validateRegularEntries(
            ["HEAD", "index", "config", "config.worktree", "commondir", "gitdir"],
            in: git.descriptor
        )
        try validateRegularEntries(
            ["HEAD", "config", "packed-refs", "shallow"],
            in: common.descriptor
        )

        var controlBudget = 50_000
        for name in ["refs", "logs", "worktrees", "reftable"] {
            try validateDirectoryTree(
                named: name,
                in: common.descriptor,
                depthRemaining: 32,
                rejectHardLinks: true,
                entryBudget: &controlBudget
            )
        }
        try validateObjectStore(in: common.descriptor)

        // Submodule metadata is normally small. Walk it fully but retain a
        // strict bound so a hostile import cannot turn preflight into a UI or
        // host-service denial of service.
        var moduleBudget = 50_000
        try validateDirectoryTree(
            named: "modules",
            in: common.descriptor,
            depthRemaining: 64,
            entryBudget: &moduleBudget
        )
    }

    /// Sockets Git itself creates directly in a repository's Git directory.
    /// `core.fsmonitor=true` leaves the built-in monitor's IPC endpoint behind
    /// even after the daemon exits. Goby always runs Git with the monitor
    /// disabled, so Git never connects to it; only this exact name, as a
    /// socket, at the Git-directory root is accepted.
    private static let gitOwnedSocketNames: Set<String> = ["fsmonitor--daemon.ipc"]

    private static func validateRegularEntries(
        _ names: [String],
        in descriptor: Int32
    ) throws {
        for name in names {
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
        }
    }

    private static func validateObjectStore(in commonDescriptor: Int32) throws {
        guard let objects = try openOptionalDirectory(named: "objects", in: commonDescriptor) else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        defer { close(objects) }

        var rootBudget = 1_024
        try validateDirectoryContents(
            objects,
            recurse: false,
            depthRemaining: 0,
            rejectHardLinks: false,
            entryBudget: &rootBudget
        )

        // Loose objects live directly below one of 256 hexadecimal fanout
        // directories. Git opens those paths itself, so leaving their contents
        // opaque would let a repository smuggle a symlink or FIFO past the
        // no-follow preflight. Walk every possible fanout with one shared bound.
        var looseObjectBudget = 250_000
        for prefix in 0...255 {
            let name = String(format: "%02x", prefix)
            guard let fanout = try openOptionalDirectory(named: name, in: objects) else { continue }
            defer { close(fanout) }
            try validateDirectoryContents(
                fanout,
                recurse: false,
                depthRemaining: 0,
                allowDirectoriesWithoutRecursing: false,
                rejectHardLinks: false,
                entryBudget: &looseObjectBudget
            )
        }

        for name in ["pack", "info"] {
            var budget = 20_000
            try validateDirectoryTree(
                named: name,
                in: objects,
                depthRemaining: 4,
                rejectHardLinks: false,
                entryBudget: &budget
            )
        }
        if let info = try openOptionalDirectory(named: "info", in: objects) {
            defer { close(info) }
            for name in ["alternates", "http-alternates"] {
                var entry = stat()
                if fstatat(info, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw HardenedGitProcessError.unsafeRepositoryMetadata
                }
                guard errno == ENOENT else {
                    throw HardenedGitProcessError.unsafeRepositoryMetadata
                }
            }
        }
    }

    private static func validateDirectoryTree(
        named name: String,
        in parent: Int32,
        depthRemaining: Int,
        rejectHardLinks: Bool = false,
        entryBudget: inout Int
    ) throws {
        guard let directory = try openOptionalDirectory(named: name, in: parent) else { return }
        defer { close(directory) }
        try validateDirectoryContents(
            directory,
            recurse: true,
            depthRemaining: depthRemaining,
            rejectHardLinks: rejectHardLinks,
            entryBudget: &entryBudget
        )
    }

    private static func validateDirectoryContents(
        _ descriptor: Int32,
        recurse: Bool,
        depthRemaining: Int,
        allowDirectoriesWithoutRecursing: Bool = true,
        rejectHardLinks: Bool = false,
        allowedSocketNames: Set<String> = [],
        entryBudget: inout Int
    ) throws {
        let duplicated = dup(descriptor)
        guard duplicated >= 0, let stream = fdopendir(duplicated) else {
            if duplicated >= 0 { close(duplicated) }
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        defer { closedir(stream) }

        while true {
            errno = 0
            guard let entryPointer = readdir(stream) else {
                guard errno == 0 else {
                    throw HardenedGitProcessError.unsafeRepositoryMetadata
                }
                break
            }
            var rawName = entryPointer.pointee.d_name
            let name = withUnsafeBytes(of: &rawName) { bytes -> String in
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), entryBudget > 0 else {
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
            entryBudget -= 1

            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard !rejectHardLinks || info.st_nlink == 1 else {
                    throw HardenedGitProcessError.unsafeRepositoryMetadata
                }
                continue
            case S_IFDIR:
                guard recurse, depthRemaining > 0 else {
                    guard allowDirectoriesWithoutRecursing else {
                        throw HardenedGitProcessError.unsafeRepositoryMetadata
                    }
                    continue
                }
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw HardenedGitProcessError.unsafeRepositoryMetadata
                }
                do {
                    defer { close(child) }
                    try validateDirectoryContents(
                        child,
                        recurse: true,
                        depthRemaining: depthRemaining - 1,
                        allowDirectoriesWithoutRecursing: allowDirectoriesWithoutRecursing,
                        rejectHardLinks: rejectHardLinks,
                        entryBudget: &entryBudget
                    )
                }
            case S_IFSOCK where allowedSocketNames.contains(name):
                continue
            default:
                throw HardenedGitProcessError.unsafeRepositoryMetadata
            }
        }
    }

    private static func openOptionalDirectory(
        named name: String,
        in descriptor: Int32
    ) throws -> Int32? {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        let child = openat(
            descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
            throw HardenedGitProcessError.unsafeRepositoryMetadata
        }
        return child
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func validateRepositoryConfiguration(in directory: URL) throws {
        // Effective repository configuration includes config.worktree when
        // extensions.worktreeConfig is enabled. Query each repository scope
        // separately so our command-line safety overrides are not mistaken
        // for repository-defined executable settings. Older Git versions reject
        // --worktree in a multi-worktree repository unless the extension is on.
        let extensionSetting = try runRaw(
            arguments: fixedArguments + ["-C", directory.path(percentEncoded: false),
                "config", "--local", "--includes", "--type=bool", "--get", "extensions.worktreeConfig"],
            currentDirectory: directory, timeout: 10, maximumOutputBytes: 1_024
        )
        guard extensionSetting.status == 0 || extensionSetting.status == 1 else {
            throw HardenedGitProcessError.executableRepositoryConfiguration("unreadable worktree configuration setting")
        }
        let hasWorktreeConfiguration = extensionSetting.status == 0
            && extensionSetting.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let scopes = hasWorktreeConfiguration ? ["--local", "--worktree"] : ["--local"]
        for scope in scopes {
            let result = try runRaw(
                arguments: fixedArguments + [
                    "-C", directory.path(percentEncoded: false),
                    "config", scope, "--includes", "--name-only", "--get-regexp",
                    #"^(core\.hooksPath|core\.fsmonitor|core\.sshCommand|gpg\.program|filter\..*\.(clean|smudge|process)|diff\..*\.(command|textconv))$"#,
                ],
                currentDirectory: directory,
                timeout: 10,
                maximumOutputBytes: 64 * 1_024
            )
            guard result.status == 0 || result.status == 1 else {
                throw HardenedGitProcessError.executableRepositoryConfiguration("unreadable repository config")
            }
            if let key = result.output.split(whereSeparator: \Character.isNewline).first,
               !key.isEmpty {
                throw HardenedGitProcessError.executableRepositoryConfiguration(String(key))
            }
        }
    }

    private static func runRaw(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval?,
        maximumOutputBytes: Int,
        directoryBudget: DirectoryBudget? = nil
    ) throws -> Result {
        let process = Process()
        let pipe = Pipe()
        let timeoutState = HardenedGitTimeoutState()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = safeEnvironment()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { throw HardenedGitProcessError.commandCouldNotStart(error.localizedDescription) }

        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, timeoutState.beginTimeout() else { return }
                terminateAndEscalate(process)
            }
        }
        let budgetMonitor = directoryBudget.map { budget in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250))
            timer.setEventHandler {
                guard directoryUsageExceeds(budget),
                      process.isRunning,
                      timeoutState.beginDirectoryBudgetExceeded() else { return }
                terminateAndEscalate(process)
            }
            timer.resume()
            return timer
        }
        let handle = pipe.fileHandleForReading
        let output = HardenedGitOutputBuffer(maximumBytes: maximumOutputBytes)
        let drain = HardenedGitDrainState()
        // FileHandle's readabilityHandler runs on an implementation-owned
        // queue whose QoS can be lower than the user-initiated operation that
        // is waiting below. Own the drain queue so its priority is explicit
        // and the bounded completion wait cannot create a priority inversion.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drain.finish() }
            while true {
                let chunk: Data
                do {
                    guard let next = try handle.read(upToCount: 64 * 1_024),
                          !next.isEmpty else { return }
                    chunk = next
                } catch {
                    return
                }
                guard output.append(chunk) else {
                    if process.isRunning, timeoutState.beginOutputLimitExceeded() {
                        terminateAndEscalate(process)
                    }
                    return
                }
            }
        }

        // Wait for the direct Git process, not for EOF on a pipe that an
        // untrusted helper or descendant may have inherited. Every forced
        // termination escalates to SIGKILL so a child that ignores SIGTERM
        // cannot turn a bounded Git operation into an application freeze.
        process.waitUntilExit()
        budgetMonitor?.cancel()
        if !drain.waitForFinish(timeout: .now() + .milliseconds(250)) {
            try? handle.close()
            _ = drain.waitForFinish(timeout: .now() + .milliseconds(250))
        } else {
            try? handle.close()
        }
        let exceededAfterExit = directoryBudget.map(directoryUsageExceeds) ?? false
        switch timeoutState.finish(directoryBudgetExceeded: exceededAfterExit) {
        case .timedOut:
            throw HardenedGitProcessError.commandTimedOut
        case .directoryBudgetExceeded:
            throw HardenedGitProcessError.directoryBudgetExceeded
        case .outputLimitExceeded:
            throw HardenedGitProcessError.outputTooLarge
        case nil:
            break
        }
        guard !output.exceededLimit else { throw HardenedGitProcessError.outputTooLarge }
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output.snapshot(), as: UTF8.self)
        )
    }

    private static func terminateAndEscalate(_ process: Process) {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
            guard process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func directoryUsageExceeds(_ budget: DirectoryBudget) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: budget.rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return false }

        var entryCount = 0
        var byteCount: Int64 = 0
        for case let url as URL in enumerator {
            entryCount += 1
            if entryCount > budget.maximumEntries { return true }
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ]) else { return true }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, values.isDirectory != true else { continue }
            let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            byteCount += Int64(max(0, size))
            if byteCount > budget.maximumBytes { return true }
        }
        return false
    }

    private static func safeEnvironment() -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GCM_INTERACTIVE": "Never",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
        ]
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
            environment["TMPDIR"] = temporary
        }
        return environment
    }
}

private final class HardenedGitTimeoutState: @unchecked Sendable {
    enum TerminationReason {
        case timedOut
        case directoryBudgetExceeded
        case outputLimitExceeded
    }

    private let lock = NSLock()
    private var completed = false
    private var terminationReason: TerminationReason?

    func beginTimeout() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            guard terminationReason == nil else { return false }
            terminationReason = .timedOut
            return true
        }
    }

    func beginDirectoryBudgetExceeded() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            guard terminationReason == nil else { return false }
            terminationReason = .directoryBudgetExceeded
            return true
        }
    }

    func beginOutputLimitExceeded() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            guard terminationReason == nil else { return false }
            terminationReason = .outputLimitExceeded
            return true
        }
    }

    func finish(directoryBudgetExceeded: Bool) -> TerminationReason? {
        lock.withLock {
            completed = true
            if terminationReason == nil, directoryBudgetExceeded {
                terminationReason = .directoryBudgetExceeded
            }
            return terminationReason
        }
    }
}

private final class HardenedGitOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var didExceedLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard chunk.count <= maximumBytes - data.count else {
                didExceedLimit = true
                return false
            }
            data.append(chunk)
            return true
        }
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

private final class HardenedGitDrainState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false

    func finish() {
        let shouldSignal = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func waitForFinish(timeout: DispatchTime) -> Bool {
        if lock.withLock({ finished }) { return true }
        return semaphore.wait(timeout: timeout) == .success
    }
}
