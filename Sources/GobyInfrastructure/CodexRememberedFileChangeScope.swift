import Darwin
import Foundation
import GobyApplication
import GobyDomain

/// A folder grant is evaluated afresh for every exact, digest-bound patch.
/// It never becomes a provider-native session grant or a grantRoot response.
enum CodexRememberedFileChangeScope {
    static func scope(
        for approval: ProviderApprovalRequest, directory: URL,
        readOnlyRoots: [URL] = []
    ) -> RememberedFileChangeScope? {
        guard approval.providerID == .codex, approval.kind == .fileChange,
              approval.canAccept, approval.hasCompleteOperationBinding,
              let details = approval.details, let data = details.data(using: .utf8),
              data.count <= ApprovalDisclosureLimits.canonicalDetailsUTF8Limit,
              let operation = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = operation.objectValue,
              Set(object.keys) == ["schema", "method", "request", "changes"],
              operation["schema"]?.stringValue == "goby.codex.approval-operation.v1",
              operation["method"]?.stringValue == "item/fileChange/requestApproval",
              let request = operation["request"],
              case let .array(changes)? = operation["changes"], !changes.isEmpty,
              changes.count <= 512 else { return nil }
        let review: JSONValue = .object([
            "itemId": request["itemId"] ?? .null,
            "threadId": request["threadId"] ?? .null,
            "turnId": request["turnId"] ?? .null,
            "changes": .array(changes)
        ])
        let binding = CodexGateway.approvalOperationBinding(
            method: "item/fileChange/requestApproval", params: request, fileChangeReview: review
        )
        guard binding.disclosureComplete, binding.operationDigest == approval.operationDigest else { return nil }
        if let grantRoot = request["grantRoot"], grantRoot != .null {
            guard let path = grantRoot.stringValue,
                  checkedPath(path, in: directory, allowDirectory: true) != nil else { return nil }
        }
        for change in changes {
            guard let fields = change.objectValue, Set(fields.keys) == ["path", "kind", "diff"],
                  change["diff"]?.stringValue != nil,
                  let path = change["path"]?.stringValue,
                  let kind = change["kind"]?.objectValue,
                  Set(kind.keys).isSubset(of: ["type", "move_path"]),
                  let type = kind["type"]?.stringValue, ["add", "update"].contains(type),
                  kind["move_path"] == nil || kind["move_path"] == .null,
                  let target = checkedPath(path, in: directory),
                  !readOnlyRoots.contains(where: { contains(target, root: $0.resolvingSymlinksInPath()) }) else { return nil }
        }
        return RememberedFileChangeScope(workingDirectory: directory.path)
    }

    private static func contains(_ target: URL, root: URL) -> Bool {
        // Conservatively protect spelling variants on case-insensitive volumes.
        let base = root.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let path = target.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// Reject traversal and each symlink/hard-link component, including dangling
    /// symlinks and nonexistent descendants beneath a symlink. Ordinary new
    /// files/folders are allowed, but directories cannot be patch targets.
    private static func checkedPath(_ path: String, in directory: URL, allowDirectory: Bool = false) -> URL? {
        guard !path.isEmpty, !path.contains("\0"), !path.split(separator: "/").contains("..") else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/" else { return nil }
        let rawRoot = directory.standardizedFileURL.path
        let canonicalRoot = root.path
        let relative: String
        if path.hasPrefix("/") {
            if path == rawRoot || path == canonicalRoot { relative = "" }
            else if path.hasPrefix(rawRoot + "/") { relative = String(path.dropFirst(rawRoot.count + 1)) }
            else if path.hasPrefix(canonicalRoot + "/") { relative = String(path.dropFirst(canonicalRoot.count + 1)) }
            else { return nil }
        } else { relative = path }
        let components = relative.split(separator: "/").map(String.init).filter { $0 != "." }
        guard allowDirectory || !components.isEmpty,
              !components.contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == ".git" }) else { return nil }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        var cursor = root
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(component)
            var info = stat()
            if lstat(cursor.path, &info) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            guard info.st_dev == rootInfo.st_dev else { return nil }
            let kind = info.st_mode & S_IFMT
            if index < components.count - 1 {
                guard kind == S_IFDIR else { return nil }
            } else if kind == S_IFDIR {
                guard allowDirectory else { return nil }
            } else {
                guard kind == S_IFREG, info.st_nlink == 1, !allowDirectory else { return nil }
            }
        }
        return cursor
    }
}
