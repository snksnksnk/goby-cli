import Foundation
import GobyApplication
import GobyDomain

public enum ProjectGitBranchError: LocalizedError, Equatable, Sendable {
    case repositoryRootChanged
    case detachedHeadChanged
    case currentBranchChanged(expected: String, actual: String)
    case dirtyWorkingCopy
    case branchUnavailable(String)
    case commandFailed(String)
    case commandTimedOut
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .repositoryRootChanged:
            "The registered folder no longer resolves to the same Git repository root. Refresh the project before switching branches."
        case .detachedHeadChanged:
            "The repository HEAD changed after branch review. Refresh the branch list and try again."
        case let .currentBranchChanged(expected, actual):
            "The current branch changed from \(expected) to \(actual). Refresh the branch list before switching."
        case .dirtyWorkingCopy:
            "This working copy has uncommitted or untracked changes. Commit, move, or stash them outside Goby before switching branches."
        case let .branchUnavailable(branch):
            "The local branch \(branch) is no longer available. Refresh the branch list and try again."
        case let .commandFailed(detail):
            "Git could not complete the branch operation. \(detail)"
        case .commandTimedOut:
            "Git did not finish the branch operation within ten seconds. The working copy was left for inspection."
        case .outputTooLarge:
            "Git returned more branch information than Goby can safely inspect at once."
        }
    }
}

public actor LocalProjectGitBranchManager: ProjectGitBranchManaging {
    private static let maximumOutputBytes = 1_048_576
    private static let commandTimeout: TimeInterval = 10

    public init() {}

    public func inspect(project: LabProject) async throws -> ProjectGitBranchSnapshot {
        try inspectRepository(project)
    }

    public func switchBranch(
        project: LabProject,
        approval: ProjectGitBranchSwitchApproval
    ) async throws -> ProjectGitBranchSnapshot {
        guard approval.projectID == project.id else {
            throw GobyApplicationError.invalidProjectGitBranchSwitch
        }
        let before = try inspectRepository(project)
        guard before.currentBranch == approval.expectedCurrentBranch else {
            if let expected = approval.expectedCurrentBranch,
               let actual = before.currentBranch {
                throw ProjectGitBranchError.currentBranchChanged(expected: expected, actual: actual)
            }
            throw ProjectGitBranchError.detachedHeadChanged
        }
        guard !before.hasUncommittedChanges else {
            throw ProjectGitBranchError.dirtyWorkingCopy
        }
        guard Self.isSafeBranchOperand(approval.destinationBranch),
              before.localBranches.contains(approval.destinationBranch) else {
            throw ProjectGitBranchError.branchUnavailable(approval.destinationBranch)
        }

        let commonDirectory = try approvedCommonDirectory(in: project.rootURL)
        _ = try runGit(
            ["switch", "--quiet", "--", approval.destinationBranch],
            in: project.rootURL,
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )
        let after = try inspectRepository(project)
        guard after.currentBranch == approval.destinationBranch else {
            throw ProjectGitBranchError.commandFailed(
                "The requested branch was not active after Git returned."
            )
        }
        return after
    }

    private func inspectRepository(_ project: LabProject) throws -> ProjectGitBranchSnapshot {
        let commonDirectory = try approvedCommonDirectory(in: project.rootURL)
        let rootOutput = try runGit(
            ["rev-parse", "--show-toplevel"],
            in: project.rootURL,
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )
        let resolvedRoot = URL(
            fileURLWithPath: rootOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).standardizedFileURL
        let registeredRoot = project.rootURL.standardizedFileURL
        guard Self.normalizedPath(resolvedRoot) == Self.normalizedPath(registeredRoot) else {
            throw ProjectGitBranchError.repositoryRootChanged
        }

        let branchResult = try runGitResult(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: registeredRoot,
            acceptedStatuses: [0, 1],
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )
        let branchName = branchResult.status == 0
            ? branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let branchOutput = try runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: registeredRoot,
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )
        var localBranches = branchOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter(Self.isSafeBranchOperand)
        if let branchName, !branchName.isEmpty, !localBranches.contains(branchName) {
            localBranches.append(branchName)
        }
        localBranches.sort {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let status = try runGit(
            ["status", "--porcelain=v1", "--untracked-files=normal"],
            in: registeredRoot,
            allowedLinkedWorktreeCommonDirectory: commonDirectory
        )

        let currentBranch = branchName?.isEmpty == false ? branchName : nil
        let remotes = try runGit(["remote"], in: registeredRoot, allowedLinkedWorktreeCommonDirectory: commonDirectory)
            .split(whereSeparator: \.isNewline).map(String.init)
        var pushRemote: String?
        if let currentBranch {
            let upstream = try runGitResult(
                ["config", "--get", "branch.\(currentBranch).remote"],
                in: registeredRoot,
                acceptedStatuses: [0, 1],
                allowedLinkedWorktreeCommonDirectory: commonDirectory
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            pushRemote = remotes.contains(upstream) ? upstream : (remotes.contains("origin") ? "origin" : nil)
        }

        return ProjectGitBranchSnapshot(
            projectID: project.id,
            currentBranch: currentBranch,
            localBranches: localBranches,
            hasUncommittedChanges: !status.isEmpty,
            pushRemote: pushRemote,
            changedFileCount: status.split(whereSeparator: \.isNewline).count
        )
    }

    private func runGit(
        _ arguments: [String],
        in directory: URL,
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws -> String {
        try runGitResult(
            arguments,
            in: directory,
            allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
        ).output
    }

    private static func isSafeBranchOperand(_ branch: String) -> Bool {
        !branch.isEmpty
            && !branch.hasPrefix("-")
            && !branch.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func runGitResult(
        _ arguments: [String],
        in directory: URL,
        acceptedStatuses: Set<Int32> = [0],
        allowedLinkedWorktreeCommonDirectory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        do {
            let result = try HardenedGitProcess.run(
                arguments: ["-C", directory.path(percentEncoded: false)] + arguments,
                currentDirectory: directory,
                timeout: Self.commandTimeout,
                maximumOutputBytes: Self.maximumOutputBytes,
                allowedLinkedWorktreeCommonDirectory: allowedLinkedWorktreeCommonDirectory
            )
            let output = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard acceptedStatuses.contains(result.status) else {
            throw ProjectGitBranchError.commandFailed(
                    output.isEmpty ? "Git exited with status \(result.status)." : output
            )
            }
            return (result.status, output)
        } catch HardenedGitProcessError.commandTimedOut {
            throw ProjectGitBranchError.commandTimedOut
        } catch HardenedGitProcessError.outputTooLarge {
            throw ProjectGitBranchError.outputTooLarge
        } catch {
            throw ProjectGitBranchError.commandFailed(error.localizedDescription)
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private func approvedCommonDirectory(in root: URL) throws -> URL? {
        do {
            return try HardenedGitProcess.linkedWorktreeCommonDirectory(in: root)
        } catch {
            throw ProjectGitBranchError.repositoryRootChanged
        }
    }
}
