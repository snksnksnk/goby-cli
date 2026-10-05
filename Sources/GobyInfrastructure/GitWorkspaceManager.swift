import Foundation
import GobyApplication
import GobyDomain

public enum WorkspaceError: LocalizedError, Sendable {
    case missingApprovedOperation(GitOperationKind, ProjectID)
    case missingBranch(ProjectID)
    case unsafeWorktree(URL)
    case repositoryDataUnavailable(URL, String)
    case incompleteWorktree(URL, String)
    case changedWorktreeRequiresReview(URL, String)
    case commandFailed(command: String, status: Int32, output: String)
    case branchChanged(expected: String, actual: String?)
    case pushFailed(remote: String, branch: String, committed: String?, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .missingApprovedOperation(kind, projectID):
            "The approved plan does not include \(kind.rawValue) for \(projectID.rawValue)."
        case let .missingBranch(projectID):
            "No approved branch name exists for \(projectID.rawValue)."
        case let .unsafeWorktree(url):
            "The prepared working copy failed Goby's repository and path checks: \(url.path(percentEncoded: false))."
        case let .repositoryDataUnavailable(url, detail):
            "Git repository data is not fully available locally at \(url.path(percentEncoded: false)): \(detail)"
        case let .incompleteWorktree(url, detail):
            "The Git worktree at \(url.path(percentEncoded: false)) is still incomplete after recovery: \(detail)"
        case let .changedWorktreeRequiresReview(url, detail):
            "The Git worktree at \(url.path(percentEncoded: false)) contains tracked changes that Goby will not discard automatically: \(detail)"
        case let .commandFailed(command, status, output):
            "\(command) failed with status \(status): \(output)"
        case let .branchChanged(expected, actual):
            "The project folder is on \(actual ?? "no branch") now, not \(expected) as reviewed. Nothing was committed; review the plan again."
        case let .pushFailed(remote, branch, committed, detail):
            [committed, "Pushing \(branch) to \(remote) failed: \(detail)"].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

public actor GitWorkspaceManager: WorkspacePreparing {
    private static let commandTimeout: TimeInterval = 60
    private static let maximumCloudObjectEntries = 100_000
    private static let maximumUnavailableCloudFiles = 4_096
    private static let maximumUnavailableCloudBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumPackWarmFiles = 256
    private static let maximumPackWarmBytes = 64 * 1_024 * 1_024
    private static let maximumPackWarmBytesPerFile = 1 * 1_024 * 1_024
    private static let conservativeObjectReadConfiguration = [
        "-c", "core.packedGitWindowSize=1m",
        "-c", "core.packedGitLimit=64m",
    ]
    private static let transientCheckoutRetryDelays: [Duration] = [
        .milliseconds(750),
        .seconds(2),
        .seconds(5),
    ]

    private let worktreesRoot: URL
    private let approvals: any ApprovalChecking
    private let fileManager: FileManager
    private let repositoryLock: GADRepositoryAdvisoryLock
    private let repositoryLockOwnerLabel: String
    private let holdsRepositoryLockThroughRun: Bool

    public init(
        worktreesRoot: URL,
        approvals: any ApprovalChecking,
        fileManager: FileManager = .default,
        repositoryLock: GADRepositoryAdvisoryLock = GADRepositoryAdvisoryLock(),
        repositoryLockOwnerLabel: String = "Goby app host",
        holdsRepositoryLockThroughRun: Bool = false
    ) {
        self.worktreesRoot = worktreesRoot
        self.approvals = approvals
        self.fileManager = fileManager
        self.repositoryLock = repositoryLock
        self.repositoryLockOwnerLabel = repositoryLockOwnerLabel
        self.holdsRepositoryLockThroughRun = holdsRepositoryLockThroughRun
    }

    public func prepare(project: LabProject, for run: RunRecord) async throws -> ProjectDirectoryPlacement {
        guard project.isGitRepository else {
            return try authorizedPlacement(at: project.rootURL, expectedIdentity: project.fileSystemIdentity)
        }
        let projectOperations = run.plan.gitOperations.filter { $0.projectID == project.id }
        guard !projectOperations.isEmpty else {
            return try authorizedPlacement(at: project.rootURL, expectedIdentity: project.fileSystemIdentity)
        }
        let receipt = run.approvalReceipts.first(where: { $0.decision == .approved })
        try await approvals.validate(plan: run.plan, receipt: receipt)

        let operations = projectOperations
        // A commit-only request commits the user's own changes where they are.
        if run.plan.runsInProjectFolder(of: project.id) {
            return try authorizedPlacement(at: project.rootURL, expectedIdentity: project.fileSystemIdentity)
        }
        guard operations.contains(where: { $0.kind == .createWorktree }) else {
            throw WorkspaceError.missingApprovedOperation(.createWorktree, project.id)
        }
        guard let branch = operations.first(where: { $0.kind == .createBranch })?.branch else {
            throw WorkspaceError.missingBranch(project.id)
        }

        let repositoryLease = try await repositoryLock.acquire(
            repositoryURL: project.rootURL,
            ownerLabel: repositoryLockOwnerLabel,
            reservationID: run.id.rawValue
        )
        _ = repositoryLease
        defer {
            if !holdsRepositoryLockThroughRun {
                Task { await repositoryLock.release(reservationID: run.id.rawValue) }
            }
        }

        try secureWorktreesRoot()
        let runDirectory = worktreesRoot.appending(path: run.id.rawValue, directoryHint: .isDirectory)
        let worktree = runDirectory.appending(path: project.id.rawValue, directoryHint: .isDirectory)
        guard isContainedWithoutSymlinks(worktree, in: worktreesRoot) else {
            throw WorkspaceError.unsafeWorktree(worktree)
        }
        try await prepareGitObjectStorage(in: project.rootURL)
        if fileManager.fileExists(atPath: worktree.path(percentEncoded: false)) {
            if let existingAssignment = run.assignments.first(where: {
                $0.projectID == project.id && normalizedPath($0.workingDirectory ?? project.rootURL) == normalizedPath(worktree)
            }) {
                guard let expectedIdentity = existingAssignment.workingDirectoryIdentity else {
                    throw WorkspaceError.unsafeWorktree(worktree)
                }
                try validate(worktree: worktree, for: project, branch: branch)
                return try authorizedPlacement(at: worktree, expectedIdentity: expectedIdentity)
            } else {
                // A failed `git worktree add` can leave a registered directory
                // before Goby has exposed it to an assignment. Complete that
                // approved checkout rather than accepting a partial tree.
                do {
                    try completeInterruptedCheckout(worktree, for: project, branch: branch)
                } catch {
                    guard Self.isTransientWorktreeFailure(error) else { throw error }
                    try await recoverTransientCheckout(
                        worktree,
                        project: project,
                        branch: branch,
                        initialError: error
                    )
                }
            }
            return try authorizedPlacement(at: worktree)
        }
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        guard isContainedWithoutSymlinks(worktree, in: worktreesRoot) else {
            throw WorkspaceError.unsafeWorktree(worktree)
        }
        let branchAlreadyExists = try localBranchExists(branch, in: project.rootURL)
        do {
            _ = try addWorktree(
                worktree,
                branch: branch,
                branchAlreadyExists: branchAlreadyExists,
                repository: project.rootURL
            )
        } catch {
            if Self.isTransientWorktreeFailure(error) {
                try await recoverTransientCheckout(
                    worktree,
                    project: project,
                    branch: branch,
                    initialError: error
                )
                return try authorizedPlacement(at: worktree)
            }
            // Git creates the branch before checking out every file. If checkout
            // is interrupted, retry once from that approved branch without
            // inventing a new branch or removing the partial result.
            guard !branchAlreadyExists,
                  !fileManager.fileExists(atPath: worktree.path(percentEncoded: false)),
                  (try? localBranchExists(branch, in: project.rootURL)) == true else {
                throw error
            }
            _ = try addWorktree(
                worktree,
                branch: branch,
                branchAlreadyExists: true,
                repository: project.rootURL
            )
        }
        try validate(worktree: worktree, for: project, branch: branch)
        return try authorizedPlacement(at: worktree)
    }

    public func releaseRepositoryLocks(for runID: RunID) async {
        await repositoryLock.release(reservationID: runID.rawValue)
    }

    private func authorizedPlacement(
        at url: URL,
        expectedIdentity: GADFileSystemIdentity? = nil
    ) throws -> ProjectDirectoryPlacement {
        guard let identity = GADFileSystemIdentity.capture(url),
              identity.kind == .directory,
              expectedIdentity == nil || expectedIdentity?.matches(identity) == true else {
            throw WorkspaceError.unsafeWorktree(url)
        }
        return ProjectDirectoryPlacement(rootURL: url, fileSystemIdentity: identity)
    }

    static func isTransientWorktreeFailure(_ error: any Error) -> Bool {
        guard case let WorkspaceError.commandFailed(_, _, output) = error else { return false }
        let detail = output.lowercased()
        return detail.contains("operation timed out")
            || detail.contains("mmap failed: operation canceled")
            || detail.contains("mmap failed: operation cancelled")
            || detail.contains("resource temporarily unavailable")
            || detail.contains("device not configured")
    }

    static func gitArguments(
        _ arguments: [String],
        conservativeObjectReads: Bool
    ) -> [String] {
        guard conservativeObjectReads else { return arguments }
        return conservativeObjectReadConfiguration + arguments
    }

    static func orderedGitPackFiles(from urls: [URL]) -> [URL] {
        let supportedExtensions = Set(["bitmap", "idx", "mtimes", "pack", "promisor", "rev"])
        return urls
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return supportedExtensions.contains(url.pathExtension.lowercased())
                    || name == "multi-pack-index"
                    || name.hasPrefix("multi-pack-index-")
            }
            .sorted { lhs, rhs in
                let lhsIsPack = lhs.pathExtension.lowercased() == "pack"
                let rhsIsPack = rhs.pathExtension.lowercased() == "pack"
                if lhsIsPack != rhsIsPack { return !lhsIsPack }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    static func needsCloudDownload(
        isUbiquitous: Bool,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        isUbiquitous && downloadingStatus == .notDownloaded
    }

    static func readFileFully(at file: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            byteCount += Int64(data.count)
        }
        return byteCount
    }

    public func finalize(project: LabProject, workingDirectory: URL, for run: RunRecord) async throws -> String? {
        try await finalize(project: project, workingDirectory: workingDirectory, for: run, commitMessage: nil)
    }

    public func finalize(
        project: LabProject, workingDirectory: URL, for run: RunRecord, commitMessage: String?,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) async throws -> String? {
        guard project.isGitRepository else { return nil }
        guard run.plan.gitOperations.contains(where: { $0.projectID == project.id }) else { return nil }
        let receipt = run.approvalReceipts.first(where: { $0.decision == .approved })
        try await approvals.validate(plan: run.plan, receipt: receipt)
        let approvedCommonDirectory = try gitCommonDirectory(for: project.rootURL,
            allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory)
        if run.plan.runsInProjectFolder(of: project.id) {
            return try finalizeWorkingCopy(
                project: project,
                workingDirectory: workingDirectory,
                run: run,
                commitMessage: commitMessage,
                commonDirectory: approvedCommonDirectory
            )
        }
        guard run.plan.gitOperations.contains(where: { $0.projectID == project.id && $0.kind == .commit }) else {
            throw WorkspaceError.missingApprovedOperation(.commit, project.id)
        }

        let status = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", workingDirectory.path(percentEncoded: false), "status", "--porcelain"],
            currentDirectory: workingDirectory,
            allowedLinkedWorktreeCommonDirectory: approvedCommonDirectory
        )
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No file changes to commit."
        }
        _ = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", workingDirectory.path(percentEncoded: false), "add", "-A"],
            currentDirectory: workingDirectory,
            allowedLinkedWorktreeCommonDirectory: approvedCommonDirectory
        )
        let summary = String(run.id.rawValue.prefix(12))
        let output = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", workingDirectory.path(percentEncoded: false), "commit", "-m", "Goby run \(summary)"],
            currentDirectory: workingDirectory,
            allowedLinkedWorktreeCommonDirectory: approvedCommonDirectory
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits the user's changes on the reviewed branch in the project
    /// folder, then pushes that branch to the reviewed remote when the push
    /// was approved. Goby runs both; the agent only wrote the message.
    private func finalizeWorkingCopy(
        project: LabProject,
        workingDirectory: URL,
        run: RunRecord,
        commitMessage: String?,
        commonDirectory: URL
    ) throws -> String {
        guard normalizedPath(workingDirectory) == normalizedPath(project.rootURL) else {
            throw WorkspaceError.unsafeWorktree(workingDirectory)
        }
        let operations = run.plan.gitOperations.filter { $0.projectID == project.id }
        let commitOperation = operations.first(where: { $0.kind == .commit })
        guard let branch = commitOperation?.branch ?? operations.first(where: { $0.kind == .push })?.branch,
              Self.isSafeRefOperand(branch) else {
            throw WorkspaceError.missingBranch(project.id)
        }
        let root = project.rootURL.path(percentEncoded: false)
        func git(_ arguments: [String]) throws -> String {
            try runProcess(
                executable: "/usr/bin/git",
                arguments: ["-C", root] + arguments,
                currentDirectory: project.rootURL,
                allowedLinkedWorktreeCommonDirectory: commonDirectory
            )
        }
        var summary: [String] = []
        if commitOperation != nil {
        let currentBranch = (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else {
            throw WorkspaceError.branchChanged(expected: branch, actual: currentBranch)
        }

        let changedFiles = try git(["status", "--porcelain"])
            .split(whereSeparator: \.isNewline).count
        if changedFiles == 0 {
            summary.append("No uncommitted changes on \(branch), so there was nothing new to commit.")
        } else {
            _ = try git(["add", "-A"])
            let identity = try commitIdentityArguments(in: project.rootURL, commonDirectory: commonDirectory)
            _ = try runProcess(
                executable: "/usr/bin/git",
                arguments: identity + ["-C", root, "commit", "--quiet", "-m",
                                       Self.commitMessage(commitMessage, projectName: project.name)],
                currentDirectory: project.rootURL,
                allowedLinkedWorktreeCommonDirectory: commonDirectory
            )
            let head = try git(["log", "-1", "--format=%h %s"]).trimmingCharacters(in: .whitespacesAndNewlines)
            summary.append("Committed \(changedFiles) \(changedFiles == 1 ? "file" : "files") on \(branch): \(head)")
        }
        } else {
            // Pushing a branch an earlier run committed: it must still exist.
            guard (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])) != nil else {
                throw WorkspaceError.missingBranch(project.id)
            }
        }

        guard let push = operations.first(where: { $0.kind == .push }) else {
            return summary.joined(separator: "\n")
        }
        let committed = summary.joined(separator: "\n")
        guard push.branch == branch, let remote = push.remote, Self.isSafeRefOperand(remote) else {
            throw WorkspaceError.pushFailed(
                remote: push.remote ?? "its remote", branch: branch, committed: committed,
                detail: "the reviewed push does not match the committed branch."
            )
        }
        let remoteURL = (try? git(["remote", "get-url", "--push", remote]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let credentialHelper = LocalProjectDirectoryCreator.isGitHubHTTPSRepository(remoteURL)
            ? InstalledGitHubCLICredentialHelperLocator.locate()
            : nil
        let result: HardenedGitProcess.Result
        do {
            result = try HardenedGitProcess.run(
                arguments: ["-C", root, "push", remote, "refs/heads/\(branch):refs/heads/\(branch)"],
                currentDirectory: project.rootURL,
                timeout: Self.pushTimeout,
                maximumOutputBytes: 1_048_576,
                allowedLinkedWorktreeCommonDirectory: commonDirectory,
                credentialHelperURL: credentialHelper
            )
        } catch {
            throw WorkspaceError.pushFailed(
                remote: remote, branch: branch, committed: committed, detail: error.localizedDescription
            )
        }
        guard result.status == 0 else {
            var detail = String(result.output.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            if credentialHelper == nil, LocalProjectDirectoryCreator.isGitHubHTTPSRepository(remoteURL) {
                detail += " Sign in with `gh auth login` so Goby can push to GitHub."
            }
            throw WorkspaceError.pushFailed(remote: remote, branch: branch, committed: committed, detail: detail)
        }
        summary.append("Pushed \(branch) to \(remote).")
        return summary.joined(separator: "\n")
    }

    private static let pushTimeout: TimeInterval = 180

    /// The folder's uncommitted changes for the commit-message agent, read
    /// by Goby so the agent needs no commands: status, a diff summary and a
    /// bounded diff. Nil when Git cannot read them.
    static func workingCopyChanges(in root: URL, diffLimit: Int = 40_000) -> String? {
        func git(_ arguments: [String]) -> String? {
            guard let result = try? HardenedGitProcess.run(
                arguments: ["-C", root.path(percentEncoded: false)] + arguments,
                currentDirectory: root,
                timeout: 30,
                maximumOutputBytes: 4 * 1_048_576
            ), result.status == 0 else { return nil }
            return result.output
        }
        guard let status = git(["status", "--porcelain=v1", "--untracked-files=all"]),
              let stat = git(["diff", "HEAD", "--stat"]),
              let diff = git(["diff", "HEAD", "--no-color", "--no-ext-diff"]) else { return nil }
        let boundedDiff = diff.count > diffLimit
            ? String(diff.prefix(diffLimit)) + "\n… diff truncated; use the summary above for the rest."
            : diff
        return """
        Changed files (`git status --porcelain`; `??` is a new file):
        \(status.trimmingCharacters(in: .newlines))

        Summary (`git diff HEAD --stat`):
        \(stat.trimmingCharacters(in: .newlines))

        Diff (`git diff HEAD`):
        \(boundedDiff.trimmingCharacters(in: .newlines))
        """
    }

    static func isSafeRefOperand(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.contains("..")
            && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value != 127 && !"~^:?*[\\".unicodeScalars.contains($0) }
    }

    /// The agent's reply, cleaned of Markdown fences, or a plain fallback.
    static func commitMessage(_ proposed: String?, projectName: String) -> String {
        let lines = (proposed ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Update \(projectName)" : String(message.prefix(4_000))
    }

    /// Goby's Git runs without the user's global settings, so a commit takes
    /// the user's name and email from there unless the repository sets its own.
    private func commitIdentityArguments(in repository: URL, commonDirectory: URL) throws -> [String] {
        var arguments: [String] = []
        for key in ["user.name", "user.email"] {
            let local = try runProcessResult(
                executable: "/usr/bin/git",
                arguments: ["-C", repository.path(percentEncoded: false), "config", "--get", key],
                currentDirectory: repository,
                allowedLinkedWorktreeCommonDirectory: commonDirectory
            )
            guard local.status != 0 || local.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let value = Self.globalGitValue(key) else { continue }
            arguments += ["-c", "\(key)=\(value)"]
        }
        return arguments
    }

    /// Reads one value from the user's global Git configuration. Reading
    /// configuration runs nothing it names.
    static func globalGitValue(_ key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["config", "--global", "--get", key]
        var environment = ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0"]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.count > 200 || value.contains("\n") ? nil : value
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws -> String {
        let result = try runProcessResult(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
        )
        guard result.status == 0 else {
            throw WorkspaceError.commandFailed(
                command: ([executable] + arguments).joined(separator: " "),
                status: result.status,
                output: String(result.output.suffix(4_000))
            )
        }
        return String(result.output.suffix(12_000))
    }

    private func localBranchExists(_ branch: String, in repository: URL) throws -> Bool {
        let arguments = [
            "-C", repository.path(percentEncoded: false),
            "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"
        ]
        let result = try runProcessResult(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: repository
        )
        switch result.status {
        case 0:
            return true
        case 1:
            return false
        default:
            throw WorkspaceError.commandFailed(
                command: (["/usr/bin/git"] + arguments).joined(separator: " "),
                status: result.status,
                output: String(result.output.suffix(4_000))
            )
        }
    }

    private func addWorktree(
        _ worktree: URL,
        branch: String,
        branchAlreadyExists: Bool,
        repository: URL,
        conservativeObjectReads: Bool = false
    ) throws -> String {
        let repositoryPath = repository.path(percentEncoded: false)
        let worktreePath = worktree.path(percentEncoded: false)
        let arguments = branchAlreadyExists
            ? ["-C", repositoryPath, "worktree", "add", worktreePath, branch]
            : ["-C", repositoryPath, "worktree", "add", "-b", branch, worktreePath]
        return try runProcess(
            executable: "/usr/bin/git",
            arguments: Self.gitArguments(
                arguments,
                conservativeObjectReads: conservativeObjectReads
            ),
            currentDirectory: repository
        )
    }

    private func recoverTransientCheckout(
        _ worktree: URL,
        project: LabProject,
        branch: String,
        initialError: any Error
    ) async throws {
        var lastError = initialError

        for attempt in 0...Self.transientCheckoutRetryDelays.count {
            if attempt > 0 {
                try await Task.sleep(for: Self.transientCheckoutRetryDelays[attempt - 1])
            }

            do {
                if fileManager.fileExists(atPath: worktree.path(percentEncoded: false)) {
                    try completeInterruptedCheckout(
                        worktree,
                        for: project,
                        branch: branch,
                        conservativeObjectReads: true
                    )
                } else {
                    let branchExists = try localBranchExists(branch, in: project.rootURL)
                    _ = try addWorktree(
                        worktree,
                        branch: branch,
                        branchAlreadyExists: branchExists,
                        repository: project.rootURL,
                        conservativeObjectReads: true
                    )
                }
                return
            } catch {
                lastError = error
                guard Self.isTransientWorktreeFailure(error) else { throw error }
            }
        }

        throw lastError
    }

    private func prepareGitObjectStorage(in repository: URL) async throws {
        let commonDirectory = try gitCommonDirectory(
            for: repository,
            conservativeObjectReads: true
        )
        let objectDirectory = commonDirectory.appending(path: "objects", directoryHint: .isDirectory)
        try await materializeUnavailableGitObjects(in: objectDirectory)
        try await warmGitPackFiles(in: objectDirectory)
    }

    private func materializeUnavailableGitObjects(in objectDirectory: URL) async throws {
        let unavailable = try unavailableCloudFiles(in: objectDirectory)
        guard !unavailable.isEmpty else { return }

        for (index, file) in unavailable.enumerated() {
            try Task.checkCancellation()
            try await materializeGitObject(file)
            if index.isMultiple(of: 128) {
                await Task.yield()
            }
        }
    }

    private func materializeGitObject(_ file: URL) async throws {
        var lastError: (any Error)?

        for attempt in 0...Self.transientCheckoutRetryDelays.count {
            if attempt > 0 {
                try await Task.sleep(for: Self.transientCheckoutRetryDelays[attempt - 1])
            }

            do {
                guard try Self.readFileFully(at: file) > 0 else {
                    throw WorkspaceError.repositoryDataUnavailable(
                        file,
                        "The Git object file is empty."
                    )
                }
                // Desktop-managed iCloud metadata can remain `notDownloaded`
                // briefly after bytes are available. A complete successful read
                // is the authoritative readiness check Git needs.
                return
            } catch {
                lastError = error
            }
        }

        let detail = lastError.map { String(describing: $0) } ?? "The file could not be read."
        throw WorkspaceError.repositoryDataUnavailable(file, detail)
    }

    private func unavailableCloudFiles(in objectDirectory: URL) throws -> [URL] {
        let objectDirectoryValues = try objectDirectory.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard objectDirectoryValues.isUbiquitousItem == true else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: objectDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .fileSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var unavailable: [URL] = []
        var visitedEntries = 0
        var unavailableBytes: Int64 = 0
        for case let file as URL in enumerator {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumCloudObjectEntries else {
                throw WorkspaceError.repositoryDataUnavailable(
                    objectDirectory,
                    "The iCloud Git object tree exceeds Goby's \(Self.maximumCloudObjectEntries)-entry materialization limit. Move the repository to a fully local folder."
                )
            }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Self.needsCloudDownload(
                      isUbiquitous: values.isUbiquitousItem == true,
                      downloadingStatus: values.ubiquitousItemDownloadingStatus
                  ) else { continue }
            unavailable.append(file)
            unavailableBytes += Int64(values.fileSize ?? 0)
            guard unavailable.count <= Self.maximumUnavailableCloudFiles,
                  unavailableBytes <= Self.maximumUnavailableCloudBytes else {
                throw WorkspaceError.repositoryDataUnavailable(
                    objectDirectory,
                    "The unavailable iCloud Git data exceeds Goby's 4,096-file or 2-GiB materialization limit. Download the repository fully in Finder before retrying."
                )
            }
        }
        return unavailable.sorted {
            $0.path(percentEncoded: false) < $1.path(percentEncoded: false)
        }
    }

    private func warmGitPackFiles(in objectDirectory: URL) async throws {
        let packDirectory = objectDirectory.appending(path: "pack", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: packDirectory.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }

        let files = try Self.orderedGitPackFiles(
            from: fileManager.contentsOfDirectory(
                at: packDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        )
        var remainingBytes = Self.maximumPackWarmBytes
        for file in files.prefix(Self.maximumPackWarmFiles) where remainingBytes > 0 {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let perFileLimit = file.pathExtension.lowercased() == "pack"
                ? min(4_096, remainingBytes)
                : min(Self.maximumPackWarmBytesPerFile, remainingBytes)
            let readBytes = try await warmGitPackFile(file, maximumBytes: perFileLimit)
            remainingBytes -= readBytes
        }
    }

    private func warmGitPackFile(_ file: URL, maximumBytes: Int) async throws -> Int {
        var lastError: (any Error)?

        for attempt in 0...Self.transientCheckoutRetryDelays.count {
            if attempt > 0 {
                try await Task.sleep(for: Self.transientCheckoutRetryDelays[attempt - 1])
            }

            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var readBytes = 0
                while readBytes < maximumBytes {
                    let data = try handle.read(upToCount: min(64 * 1_024, maximumBytes - readBytes))
                    guard let data, !data.isEmpty else { break }
                    readBytes += data.count
                }
                return readBytes
            } catch {
                lastError = error
            }
        }

        let detail = lastError.map { String(describing: $0) } ?? "The file could not be read."
        throw WorkspaceError.repositoryDataUnavailable(file, detail)
    }

    private func completeInterruptedCheckout(
        _ worktree: URL,
        for project: LabProject,
        branch: String,
        conservativeObjectReads: Bool = false
    ) throws {
        let approvedCommonDirectory = try gitCommonDirectory(for: project.rootURL)
        try validate(
            worktree: worktree,
            for: project,
            branch: branch,
            conservativeObjectReads: conservativeObjectReads
        )
        let status = try trackedStatus(
            in: worktree,
            conservativeObjectReads: conservativeObjectReads,
            allowedLinkedWorktreeCommonDirectory: approvedCommonDirectory
        )
        guard status.isEmpty else {
            throw WorkspaceError.changedWorktreeRequiresReview(
                worktree,
                String(status.suffix(2_000))
            )
        }
    }

    private func trackedStatus(
        in worktree: URL,
        conservativeObjectReads: Bool = false,
        allowedLinkedWorktreeCommonDirectory: URL
    ) throws -> String {
        try runProcess(
            executable: "/usr/bin/git",
            arguments: Self.gitArguments(
                [
                    "-C", worktree.path(percentEncoded: false),
                    "status", "--porcelain", "--untracked-files=no",
                ],
                conservativeObjectReads: conservativeObjectReads
            ),
            currentDirectory: worktree,
            allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcessResult(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        guard executable == "/usr/bin/git" else {
            return (126, "Goby refused a non-Git executable at the Git boundary.")
        }
        do {
            let result = try HardenedGitProcess.run(
                arguments: arguments,
                currentDirectory: currentDirectory,
                timeout: Self.commandTimeout,
                allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
            )
            return (result.status, result.output)
        } catch {
            return (126, error.localizedDescription)
        }
    }

    private func secureWorktreesRoot() throws {
        try fileManager.createDirectory(
            at: worktreesRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: worktreesRoot.path(percentEncoded: false)
        )
        guard !isSymbolicLink(worktreesRoot) else {
            throw WorkspaceError.unsafeWorktree(worktreesRoot)
        }
    }

    private func validate(
        worktree: URL,
        for project: LabProject,
        branch: String,
        conservativeObjectReads: Bool = false
    ) throws {
        guard isContainedWithoutSymlinks(worktree, in: worktreesRoot),
              isDirectory(worktree) else {
            throw WorkspaceError.unsafeWorktree(worktree)
        }
        let projectCommonDirectory = try gitCommonDirectory(
            for: project.rootURL,
            conservativeObjectReads: conservativeObjectReads
        )
        let topLevel = try runProcess(
            executable: "/usr/bin/git",
            arguments: Self.gitArguments(
                ["-C", worktree.path(percentEncoded: false), "rev-parse", "--show-toplevel"],
                conservativeObjectReads: conservativeObjectReads
            ),
            currentDirectory: worktree,
            allowedLinkedWorktreeCommonDirectory: projectCommonDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranch = try runProcess(
            executable: "/usr/bin/git",
            arguments: Self.gitArguments(
                ["-C", worktree.path(percentEncoded: false), "branch", "--show-current"],
                conservativeObjectReads: conservativeObjectReads
            ),
            currentDirectory: worktree,
            allowedLinkedWorktreeCommonDirectory: projectCommonDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeCommonDirectory = try gitCommonDirectory(
            for: worktree,
            conservativeObjectReads: conservativeObjectReads,
            allowedLinkedWorktreeCommonDirectory: projectCommonDirectory
        )
        guard normalizedPath(URL(fileURLWithPath: topLevel).resolvingSymlinksInPath()) == normalizedPath(worktree.resolvingSymlinksInPath()),
              currentBranch == branch,
              normalizedPath(projectCommonDirectory) == normalizedPath(worktreeCommonDirectory) else {
            throw WorkspaceError.unsafeWorktree(worktree)
        }
    }

    private func gitCommonDirectory(
        for repository: URL,
        conservativeObjectReads: Bool = false,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws -> URL {
        let output = try runProcess(
            executable: "/usr/bin/git",
            arguments: Self.gitArguments(
                ["-C", repository.path(percentEncoded: false), "rev-parse", "--git-common-dir"],
                conservativeObjectReads: conservativeObjectReads
            ),
            currentDirectory: repository,
            allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = output.hasPrefix("/")
            ? URL(fileURLWithPath: output, isDirectory: true)
            : repository.appending(path: output, directoryHint: .isDirectory)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isContainedWithoutSymlinks(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = normalizedPath(root.standardizedFileURL)
        let candidatePath = normalizedPath(candidate.standardizedFileURL)
        guard candidatePath.hasPrefix(rootPath + "/") else { return false }
        var current = root.standardizedFileURL
        for component in candidatePath.dropFirst(rootPath.count).split(separator: "/") {
            current.append(path: String(component))
            if fileManager.fileExists(atPath: current.path(percentEncoded: false)), isSymbolicLink(current) {
                return false
            }
        }
        return true
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
