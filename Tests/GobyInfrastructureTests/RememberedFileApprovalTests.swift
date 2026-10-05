import Foundation
import GobyApplication
import GobyDomain
import Testing
@testable import GobyInfrastructure

struct RememberedFileApprovalTests {
    @Test("Folder offers require complete patches and reject traversal, deletion, renames and Git metadata")
    func patchBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-file-scope-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/App.swift", root.appending(path: "New.swift").path] {
            #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(path: path), directory: root) != nil)
        }
        for path in ["../Outside.swift", "Sources/../../Outside.swift", "/etc/hosts", root.path + "-other/App.swift", ".git/config", ".GIT/hooks/post-commit", "Sources/.git/config", "", ".", "bad\0path"] {
            #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(path: path), directory: root) == nil)
        }
        for kind: JSONValue in [.object(["type": .string("delete")]), .object(["type": .string("update"), "move_path": .string("Other.swift")]), .object(["type": .string("unknown")]), .object(["type": .string("update"), "extra": .bool(true)])] {
            #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(kind: kind), directory: root) == nil)
        }
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(grantRoot: "/"), directory: root) == nil)
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(grantRoot: root.path), directory: root) != nil)
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(digest: String(repeating: "0", count: 64)), directory: root) == nil)
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(extraChange: ["path": .string("../escape"), "kind": .object(["type": .string("add")]), "diff": .string("new")]), directory: root) == nil)
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(), directory: root, readOnlyRoots: [root.appending(path: "Sources")]) == nil)
        #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(path: "sources/App.swift"), directory: root, readOnlyRoots: [root.appending(path: "Sources")]) == nil)
    }

    @Test("A saved folder never treats linked files, dangling symlinks or directories as ordinary edits")
    func linkedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "goby-file-links-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "Real.swift")
        try Data("original".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Linked").path, withDestinationPath: "/tmp")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Dangling").path, withDestinationPath: root.appending(path: "Missing").path)
        try FileManager.default.linkItem(at: real, to: root.appending(path: "Hard.swift"))
        try FileManager.default.createDirectory(at: root.appending(path: "Folder"), withIntermediateDirectories: true)
        for path in ["Linked/New.swift", "Dangling/New.swift", "Dangling", "Hard.swift", "Real.swift", "Folder"] {
            #expect(CodexRememberedFileChangeScope.scope(for: fileApproval(path: path), directory: root) == nil)
        }
    }
}

func fileApproval(
    sequence: Int = 1, path: String = "Sources/App.swift", diff: String = "@@ -1 +1 @@\n-old\n+new",
    kind: JSONValue = .object(["type": .string("update")]), grantRoot: String? = nil,
    digest: String? = nil, extraChange: [String: JSONValue]? = nil
) -> ProviderApprovalRequest {
    var params: [String: JSONValue] = ["itemId": .string("file-\(sequence)"), "threadId": .string("thread"), "turnId": .string("turn"), "startedAtMs": .integer(sequence)]
    if let grantRoot { params["grantRoot"] = .string(grantRoot) }
    var changes: [JSONValue] = [.object(["path": .string(path), "kind": kind, "diff": .string(diff)])]
    if let extraChange { changes.append(.object(extraChange)) }
    let review: JSONValue = .object(["itemId": params["itemId"]!, "threadId": params["threadId"]!, "turnId": params["turnId"]!, "changes": .array(changes)])
    let binding = CodexGateway.approvalOperationBinding(method: "item/fileChange/requestApproval", params: .object(params), fileChangeReview: review)
    return ProviderApprovalRequest(id: "file-request-\(sequence)", assignmentID: "assignment", kind: .fileChange,
        summary: "Edit files", details: binding.details, operationDigest: digest ?? binding.operationDigest,
        disclosureComplete: binding.disclosureComplete)
}
