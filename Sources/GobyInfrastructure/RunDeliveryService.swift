import CryptoKit
import Darwin
import Foundation
import GobyApplication
import GobyDomain

/// Finished-run delivery reuses the hardened Git execution and approval policy.
/// Reviews are bounded, expire, and are consumed before awaiting mutation.
public actor RunDeliveryService {
    private struct Record: Sendable {
        let preview: GADRunDeliveryPreview
        let project: LabProject
        let identity: GADFileSystemIdentity
        let common: URL
        let stateDigest: String
        let plan: RoutingPlan
    }
    private var records: [String: Record] = [:]
    private let lock: GADRepositoryAdvisoryLock
    public init(lock: GADRepositoryAdvisoryLock = GADRepositoryAdvisoryLock()) { self.lock = lock }

    public func preview(run: RunRecord, projects: [LabProject], kind: GADRunDeliveryKind) throws -> GADRunDeliveryPreview {
        guard run.status == .completed else { throw failure("Only a completed, verified run can be delivered.") }
        let roots = Set(run.assignments.compactMap(\.workingDirectory))
        guard roots.count == 1, let root = roots.first,
              let assignment = run.assignments.first(where: { $0.workingDirectory == root }),
              let identity = assignment.workingDirectoryIdentity, identity.matchesCurrentObject(at: root),
              let source = projects.first(where: { $0.id == assignment.projectID }),
              source.fileSystemIdentity?.matchesCurrentObject(at: source.rootURL) == true else {
            throw failure("Choose a finished run with one unchanged repository workspace.")
        }
        let common = try commonDirectory(source.rootURL)
        let branch = try git(["symbolic-ref", "--quiet", "--short", "HEAD"], root: root, common: common).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.hasPrefix("-") else { throw failure("Delivery requires a named branch.") }
        let remote: String?
        if kind == .push {
            let remotes = try git(["remote"], root: root, common: common).split(whereSeparator: \.isNewline).map(String.init)
            guard remotes.contains("origin") || remotes.count == 1 else { throw failure("Push needs an unambiguous configured remote.") }
            remote = remotes.contains("origin") ? "origin" : remotes.first
        } else { remote = nil }
        let operation = PlannedGitOperation(projectID: source.id, kind: kind == .commit ? .commit : .push, branch: branch, remote: remote)
        let plan = RoutingPlan(interpretedGoal: "\(kind.rawValue.capitalized) the reviewed run workspace", routes: [], risk: .high,
                               confidence: 1, gitOperations: [operation])
        let project = LabProject(id: source.id, name: source.name, rootURL: root, platforms: source.platforms,
                                 isGitRepository: true, fileSystemIdentity: identity)
        let state = try snapshot(root: root, common: common, remote: remote)
        let head = try git(["rev-parse", "HEAD"], root: root, common: common).trimmingCharacters(in: .whitespacesAndNewlines)
        var destination = ""
        if let remote {
            let address = try git(["remote", "get-url", "--push", remote], root: root, common: common).trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URLComponents(string: address)?.host
                ?? (address.contains("@") ? address.split(separator: "@").last?.split(separator: ":").first.map(String.init) : nil)
            destination = "\nDestination: \(host ?? "local repository") · address SHA-256 \(hash(Data(address.utf8)))"
        }
        let summary = "HEAD: \(head)\n" + (try git(["status", "--short"], root: root, common: common)) + destination
            + (kind == .push ? "\nPush the reviewed HEAD to \(remote ?? "") / \(branch), without force or tags." : "\nCommit all reviewed tracked and untracked changes; ignore excluded files.")
        guard summary.utf8.count <= 48_000 else { throw failure("This delivery scope is too large for complete terminal review.") }
        let id = UUID().uuidString.lowercased()
        let expiry = Date.now.addingTimeInterval(120)
        let digest = hash(Data("\(id)\n\(state)\n\(kind.rawValue)\n\(branch)\n\(remote ?? "")".utf8))
        let preview = GADRunDeliveryPreview(id: id, digest: digest, kind: kind, projectName: source.name, branch: branch,
                                          remote: remote, summary: summary, expiresAt: expiry)
        records = records.filter { $0.value.preview.expiresAt > .now }
        guard records.count < 32 else { throw failure("Finish or wait for an earlier delivery review.") }
        records[id] = Record(preview: preview, project: project, identity: identity, common: common, stateDigest: state, plan: plan)
        return preview
    }

    public func execute(previewID: String, digest: String) async throws -> String {
        guard let record = records.removeValue(forKey: previewID), record.preview.digest == digest,
              record.preview.expiresAt > .now else { throw failure("This delivery review expired or changed. Review it again.") }
        let reservation = "cli-delivery-" + previewID
        _ = try await lock.acquire(repositoryURL: record.project.rootURL, ownerLabel: "Goby CLI delivery", reservationID: reservation, maximumWait: .seconds(5))
        do {
            guard record.identity.matchesCurrentObject(at: record.project.rootURL),
                  try snapshot(root: record.project.rootURL, common: record.common, remote: record.preview.remote) == record.stateDigest else {
                throw failure("The workspace, HEAD, index or remote changed after review. Nothing was delivered.")
            }
            let receipt = ApprovalReceipt(runID: record.plan.id, decision: .approved, operationIDs: Set(record.plan.gitOperations.map(\.id)))
            let run = RunRecord(id: record.plan.id, plan: record.plan, status: .completed, assignments: [], approvalReceipts: [receipt])
            let manager = GitWorkspaceManager(worktreesRoot: record.project.rootURL, approvals: ApprovalPolicy())
            let result = try await manager.finalize(project: record.project, workingDirectory: record.project.rootURL,
                for: run, commitMessage: nil, allowedLinkedWorktreeCommonDirectory: record.common)
            await lock.release(reservationID: reservation)
            return result ?? "No changes to deliver."
        } catch {
            await lock.release(reservationID: reservation)
            // Git output can contain private paths or remote credentials.
            if let failure = error as? GADCommandFailure { throw failure }
            throw GADCommandFailure(.failedRecoverable, "Git delivery failed. The workspace and any completed commit remain available for review.")
        }
    }
    private func snapshot(root: URL, common: URL, remote: String?) throws -> String {
        var data = Data(try git(["rev-parse", "HEAD"], root: root, common: common).utf8)
        data.append(Data(try git(["symbolic-ref", "--short", "HEAD"], root: root, common: common).utf8))
        data.append(Data(try git(["ls-files", "--stage", "-z"], root: root, common: common).utf8))
        let names = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], root: root, common: common).split(separator: "\0").map(String.init)
        guard names.count <= 10_000 else { throw failure("This workspace exceeds the delivery review file budget.") }
        var bytes = 0
        for name in Set(names).sorted() {
            let url = root.appending(path: name)
            guard url.path.hasPrefix(root.path + "/"), !name.split(separator: "/").contains("..") else {
                throw failure("A delivery file redirects outside its reviewed workspace.")
            }
            var ancestor = root
            for component in name.split(separator: "/") {
                ancestor.append(path: String(component))
                var info = stat()
                if lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw failure("A delivery file is reached through a symbolic link.") }
            }
            data.append(Data(name.utf8)); data.append(0)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                      let size = values.fileSize, size <= 16 * 1_024 * 1_024 else { throw failure("A delivery file exceeds the review budget or is not regular.") }
                bytes += size
                guard bytes <= 256 * 1_024 * 1_024 else { throw failure("This workspace exceeds the delivery byte budget.") }
                data.append(Data((try GADFileSystemIdentity.contentSHA256(at: url, maximumBytes: 16 * 1_024 * 1_024).unwrap()).utf8))
            }
        }
        if let remote {
            let url = try git(["remote", "get-url", "--push", remote], root: root, common: common).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = URLComponents(string: url), parsed.scheme != nil,
               parsed.user != nil || parsed.password != nil || parsed.query != nil || parsed.fragment != nil { throw failure("Use a remote without embedded credentials or query values.") }
            data.append(Data(url.utf8))
        }
        return hash(data)
    }
    private func commonDirectory(_ root: URL) throws -> URL {
        let approved = try HardenedGitProcess.linkedWorktreeCommonDirectory(in: root)
        let value = try HardenedGitProcess.run(arguments: ["-C", root.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            currentDirectory: root, timeout: 10, allowedLinkedWorktreeCommonDirectory: approved)
        guard value.status == 0 else { throw failure("The reviewed repository is unavailable.") }
        return URL(fileURLWithPath: value.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func git(_ arguments: [String], root: URL, common: URL) throws -> String {
        let value = try HardenedGitProcess.run(arguments: ["-C", root.path] + arguments, currentDirectory: root, timeout: 15,
            maximumOutputBytes: 2 * 1_024 * 1_024, allowedLinkedWorktreeCommonDirectory: common)
        guard value.status == 0 else { throw failure("Git could not inspect the reviewed workspace.") }
        return value.output
    }
    private func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> GADCommandFailure { .init(.rejectedPolicy, text) }
}

private extension Optional where Wrapped == String {
    func unwrap() throws -> String {
        guard let self else { throw GADCommandFailure(.rejectedPolicy, "A delivery file changed during review.") }
        return self
    }
}
