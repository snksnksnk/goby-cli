import Foundation
import GobyApplication
import GobyDomain

/// Git remains on the host, behind the existing hardened process boundary.
public actor RunWorkspaceDiffReader {
    public init() {}
    public func read(run: RunRecord, projects: [LabProject]) throws -> String {
        var seen = Set<URL>()
        var sections: [String] = []
        for assignment in run.assignments {
            guard let root = assignment.workingDirectory, seen.insert(root).inserted else { continue }
            guard let identity = assignment.workingDirectoryIdentity,
                  identity.matchesCurrentObject(at: root),
                  let project = projects.first(where: { $0.id == assignment.projectID }),
                  project.fileSystemIdentity?.matchesCurrentObject(at: project.rootURL) == true else {
                throw GADCommandFailure(.rejectedPolicy, "This run's workspace identity changed. Goby refused to inspect it.")
            }
            let approvedCommonDirectory = try HardenedGitProcess.linkedWorktreeCommonDirectory(in: project.rootURL)
            let common = try HardenedGitProcess.run(
                arguments: ["-C", project.rootURL.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                currentDirectory: project.rootURL, timeout: 10, maximumOutputBytes: 16_384,
                allowedLinkedWorktreeCommonDirectory: approvedCommonDirectory
            )
            guard common.status == 0 else { throw GADCommandFailure(.failedRecoverable, "Git could not inspect this run's repository.") }
            let commonURL = URL(fileURLWithPath: common.output.trimmingCharacters(in: .whitespacesAndNewlines))
            let result = try HardenedGitProcess.run(
                arguments: ["-C", root.path, "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
                currentDirectory: root, timeout: 15, maximumOutputBytes: 512 * 1_024,
                allowedLinkedWorktreeCommonDirectory: commonURL
            )
            guard result.status == 0, identity.matchesCurrentObject(at: root) else {
                throw GADCommandFailure(.rejectedPolicy, "Git could not safely inspect the run workspace.")
            }
            sections.append("\(project.name) — current tracked workspace changes\n\(result.output.isEmpty ? "No tracked changes." : result.output)")
        }
        return sections.isEmpty ? "This run has no prepared workspace." : String(sections.joined(separator: "\n\n").prefix(512 * 1_024))
    }
}
