import CryptoKit
import Foundation
import GobyApplication

/// Verifies full Codex operation bindings for automation grants and keeps the
/// separate manual-run grant limited to ordinary in-sandbox commands.
enum RunRuntimeApprovalPolicy {
    static func completeCodexOperationIsBound(_ approval: ProviderApprovalRequest) -> Bool {
        guard approval.providerID == .codex,
              approval.canAccept,
              approval.hasCompleteOperationBinding,
              let details = approval.details,
              let data = details.data(using: .utf8),
              let operation = try? JSONDecoder().decode(JSONValue.self, from: data),
              operation["schema"]?.stringValue == "goby.codex.approval-operation.v1",
              let method = operation["method"]?.stringValue,
              operation["request"]?.objectValue != nil else { return false }
        let expectedMethod: String = switch approval.kind {
        case .command: "item/commandExecution/requestApproval"
        case .fileChange: "item/fileChange/requestApproval"
        case .permissions: "item/permissions/requestApproval"
        }
        guard method == expectedMethod else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let canonical = try? encoder.encode(operation) else { return false }
        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == approval.operationDigest
    }

    static func commandIsWithinScope(
        _ approval: ProviderApprovalRequest, command: String
    ) -> Bool {
        guard approval.providerID == .codex, approval.kind == .command,
              approval.canAccept, approval.hasCompleteOperationBinding,
              let details = approval.details,
              let data = details.data(using: .utf8),
              let operation = try? JSONDecoder().decode(JSONValue.self, from: data),
              operation["schema"]?.stringValue == "goby.codex.approval-operation.v1",
              operation["method"]?.stringValue == "item/commandExecution/requestApproval",
              let request = operation["request"],
              request["command"]?.stringValue == command,
              noExpansion(request["additionalPermissions"]),
              noExpansion(request["networkApprovalContext"]) else { return false }

        let binding = CodexGateway.approvalOperationBinding(
            method: "item/commandExecution/requestApproval", params: request
        )
        guard binding.disclosureComplete,
              binding.operationDigest == approval.operationDigest else { return false }

        // Proposed policy amendments are inert here: Goby responds with the
        // one-shot `accept` decision and never installs a proposed amendment.
        return shellCommandIsOrdinary(command)
    }

    /// Explicit Git mutations and destructive shell commands need their own
    /// review. Build tools and ordinary shell wrappers remain eligible.
    static func shellCommandIsOrdinary(_ command: String) -> Bool {
        let lower = command.lowercased()
        let destructive = #"\b(?:gh|rm|rmdir|mv|sudo|osascript)\b(?=\s|['\"`]|$)"#
        let gitMutation = #"\bgit\b[^;&|\n]{0,200}\b(?:push|merge|rebase|reset|tag|checkout|switch|branch|remote|commit|add|rm|clean|stash|apply|cherry-pick|revert)\b"#
        return lower.range(of: destructive, options: .regularExpression) == nil
            && lower.range(of: gitMutation, options: .regularExpression) == nil
    }

    /// Run-uninterrupted grant for bridged providers (Claude, GitHub Copilot).
    /// The bridge already denied anything outside the working copy and its
    /// reviewed resources. Goby re-verifies the disclosed operation against its
    /// digest, then allows ordinary shell commands, in-folder edits, reads and
    /// web lookups. Destructive commands, Git mutations, MCP and other tools
    /// still pause for a person.
    static func bridgedOperationIsWithinScope(
        _ approval: ProviderApprovalRequest,
        workingDirectory: URL
    ) -> Bool {
        guard approval.providerID != .codex,
              approval.canAccept, approval.hasCompleteOperationBinding,
              let details = approval.details,
              SHA256.hash(data: Data(details.utf8)).map({ String(format: "%02x", $0) }).joined()
                == approval.operationDigest,
              let operation = try? JSONDecoder().decode(JSONValue.self, from: Data(details.utf8)) else {
            return false
        }
        switch approval.providerID {
        case .claude:
            guard let tool = operation["toolName"]?.stringValue else { return false }
            let input = operation["input"]
            switch tool {
            case "Bash":
                guard let command = input?["command"]?.stringValue else { return false }
                return shellCommandIsOrdinary(command)
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                guard let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue else {
                    return false
                }
                return isInside(path, workingDirectory)
            case "Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "TodoWrite":
                return true
            default:
                return false
            }
        case .githubCopilot:
            switch operation["kind"]?.stringValue {
            case "shell":
                guard let command = operation["fullCommandText"]?.stringValue else { return false }
                return shellCommandIsOrdinary(command)
            case "write":
                guard let path = operation["fileName"]?.stringValue else { return false }
                return isInside(path, workingDirectory)
            case "read", "url":
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func isInside(_ path: String, _ directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let target = URL(fileURLWithPath: path, relativeTo: directory)
            .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return target == root || target.hasPrefix(prefix)
    }

    private static func noExpansion(_ value: JSONValue?) -> Bool {
        value == nil || value == .null
    }
}
