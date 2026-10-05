import Foundation
import GobyApplication
import GobyDomain

public actor ProjectVerifier: VerificationRunning {
    public init() {}

    public func verify(
        project: LabProject,
        workingDirectory: URL,
        evidence: [ProviderCommandExecutionEvidence]
    ) -> VerificationResult {
        let location = workingDirectory.standardizedFileURL.path(percentEncoded: false)
        guard !project.testCommands.isEmpty else {
            return VerificationResult(
                succeeded: true,
                summary: "No automated project check was detected. Goby did not launch a host process in \(location)."
            )
        }

        let workspace = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let trustedEvidence = evidence.filter { item in
            Self.trustedSources.contains(item.source) && Self.contains(item.workingDirectory, in: workspace)
        }
        var passed: [ProviderCommandExecutionEvidence] = []
        var failures: [String] = []

        for requiredCommand in project.testCommands {
            let normalizedRequired = Self.normalized(requiredCommand)
            let attempts = trustedEvidence.filter { item in
                ([item.command] + item.actionCommands).contains {
                    Self.normalized($0) == normalizedRequired
                }
            }
            guard let latest = attempts.last else {
                failures.append("Missing structured execution evidence for `\(requiredCommand)`.")
                continue
            }
            guard latest.status == .completed, latest.exitCode == 0 else {
                let exit = latest.exitCode.map(String.init) ?? "unavailable"
                failures.append("`\(requiredCommand)` ended with status \(latest.status.rawValue) and exit code \(exit).")
                continue
            }
            passed.append(latest)
        }

        guard failures.isEmpty else {
            return VerificationResult(
                succeeded: false,
                summary: "Verification evidence was incomplete or unsuccessful. " + failures.joined(separator: " ")
            )
        }

        let checks = passed.map { item in
            let duration = item.durationMilliseconds.map { " in \($0) ms" } ?? ""
            return "`\(item.command)` (exit 0\(duration))"
        }.joined(separator: ", ")
        let providerIDs = Set(passed.map(\.providerID))
        let source = providerIDs == [.codex]
            ? "Codex App Server"
            : providerIDs.sorted().map(\.displayName).joined(separator: ", ")
        return VerificationResult(
            succeeded: true,
            summary: "Verified from \(source) execution evidence inside the prepared workspace: \(checks). Goby did not re-execute project code on the host."
        )
    }

    public func verify(
        project: LabProject,
        workingDirectory: URL,
        evidence: [CodexCommandExecutionEvidence]
    ) -> VerificationResult {
        verify(
            project: project,
            workingDirectory: workingDirectory,
            evidence: evidence.map { item in
                ProviderCommandExecutionEvidence(
                    id: item.id,
                    providerID: .codex,
                    command: item.command,
                    actionCommands: item.actionCommands,
                    workingDirectory: item.workingDirectory,
                    status: item.status,
                    exitCode: item.exitCode,
                    durationMilliseconds: item.durationMilliseconds,
                    source: item.source
                )
            }
        )
    }

    private nonisolated static func normalized(_ command: String) -> String {
        command.split(whereSeparator: \Character.isWhitespace).map { token in
            guard token.count >= 2,
                  (token.first == "'" && token.last == "'" || token.first == "\"" && token.last == "\"") else {
                return String(token)
            }
            let contents = token.dropFirst().dropLast()
            // Discovery quotes simple path/argument tokens for shell safety;
            // Codex may execute the same argv without those optional quotes.
            // Keep quotes for whitespace, expansion and shell syntax.
            guard !contents.isEmpty,
                  contents.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }) else {
                return String(token)
            }
            return String(contents)
        }.joined(separator: " ")
    }

    private nonisolated static let trustedSources: Set<String> = [
        "agent",
        "unifiedExecStartup",
        "unifiedExecInteraction"
    ]

    private nonisolated static func contains(_ candidate: URL, in workspace: URL) -> Bool {
        let candidatePath = canonicalPath(candidate)
        let workspacePath = canonicalPath(workspace)
        return candidatePath == workspacePath || candidatePath.hasPrefix(workspacePath + "/")
    }

    private nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
