import CryptoKit
import Foundation
import GobyApplication

enum CodexRememberedCommandScope {
    static func scope(for approval: CodexApprovalRequest) -> RememberedCommandScope? {
        guard approval.kind == .command, approval.canAccept, approval.disclosureComplete,
              let details = approval.details, let digest = approval.operationDigest,
              let data = details.data(using: .utf8),
              let operation = try? JSONDecoder().decode(JSONValue.self, from: data),
              operation["schema"]?.stringValue == "goby.codex.approval-operation.v1",
              operation["method"]?.stringValue == "item/commandExecution/requestApproval",
              let request = operation["request"],
              let command = request["command"]?.stringValue, !command.isEmpty,
              command.utf8.count <= 8_192,
              let directory = request["cwd"]?.stringValue, directory.hasPrefix("/") else { return nil }
        if let decisions = request["availableDecisions"], decisions != .null {
            guard case let .array(values) = decisions, values.contains(.string("accept")) else { return nil }
        }
        // Revalidate the adapter's complete schema and exact digest before
        // removing only non-executable request-instance metadata.
        let binding = CodexGateway.approvalOperationBinding(
            method: "item/commandExecution/requestApproval", params: request
        )
        guard binding.disclosureComplete, binding.operationDigest == digest,
              var stable = request.objectValue else { return nil }
        for key in ["itemId", "threadId", "turnId", "approvalId", "startedAtMs", "reason", "availableDecisions"] {
            stable.removeValue(forKey: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let canonical = try? encoder.encode(JSONValue.object(stable)) else { return nil }
        return RememberedCommandScope(
            command: command,
            workingDirectory: directory,
            contextDigest: SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        )
    }
}
