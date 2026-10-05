import Foundation

/// Decides whether two requests in the same project can run side by side.
///
/// Requests run in parallel unless one would interfere with the other:
/// - both change files in the same working copy (neither has its own
///   worktree), or
/// - both change files and name the same file, or
/// - the newer request builds on the earlier one ("after that", "continue …").
///
/// A conflicting request waits for the earlier one; a parallel request whose
/// agent is busy gets a temporary copy of that agent.
public enum ParallelRequestPolicy {
    public struct Conflict: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case sharedWorkingCopy
            case sameFiles([String])
            case buildsOnEarlierRequest
        }

        public let kind: Kind

        /// Completes "Waits for “…” to finish: <reason>."
        public var reason: String {
            switch kind {
            case .sharedWorkingCopy:
                "both change files in the same project folder"
            case let .sameFiles(files):
                "both change \(Self.list(files))"
            case .buildsOnEarlierRequest:
                "this request builds on it"
            }
        }

        private static func list(_ files: [String]) -> String {
            let shown = files.prefix(3).map { "`\($0)`" }
            let more = files.count > 3 ? " and \(files.count - 3) more" : ""
            return shown.joined(separator: ", ") + more
        }
    }

    /// Every wait reason starts with this, so clients can offer Run Anyway.
    public static let waitReasonPrefix = "Waits for “"

    public static func isWaitingForConflict(status: AgentStatus, reason: String?) -> Bool {
        status == .queued && reason?.hasPrefix(waitReasonPrefix) == true
    }

    /// Why `later` must wait for `earlier` in `projectID`, or nil when they
    /// can run side by side.
    public static func conflict(
        later: RoutingPlan,
        earlier: RoutingPlan,
        in projectID: ProjectID
    ) -> Conflict? {
        guard later.routes.contains(where: { $0.projectID == projectID }),
              earlier.routes.contains(where: { $0.projectID == projectID }) else { return nil }
        if buildsOnEarlierRequest(later.interpretedGoal) {
            return Conflict(kind: .buildsOnEarlierRequest)
        }
        let laterWrites = later.risk != .readOnly
        let earlierWrites = earlier.risk != .readOnly
        guard laterWrites, earlierWrites else { return nil }
        if !hasIsolatedWorktree(later, in: projectID), !hasIsolatedWorktree(earlier, in: projectID) {
            return Conflict(kind: .sharedWorkingCopy)
        }
        let shared = mentionedFiles(in: later.interpretedGoal)
            .intersection(mentionedFiles(in: earlier.interpretedGoal))
        if !shared.isEmpty {
            return Conflict(kind: .sameFiles(shared.sorted()))
        }
        return nil
    }

    /// A run with its own worktree cannot touch another run's files.
    public static func hasIsolatedWorktree(_ plan: RoutingPlan, in projectID: ProjectID) -> Bool {
        plan.gitOperations.contains { $0.projectID == projectID && $0.kind == .createWorktree }
    }

    /// File names and paths named in a request, lowercased: `Sources/App.swift`,
    /// `README.md`, `src/checkout/`. Plain words and URLs are ignored.
    public static func mentionedFiles(in text: String) -> Set<String> {
        // Colons are not separators, so URLs stay whole and are skipped.
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"(),;<>[]{}"))
        var files = Set<String>()
        for raw in text.components(separatedBy: separators) {
            var token = raw.lowercased()
            while let last = token.last, ".!?:".contains(last), !token.hasSuffix("/") {
                token.removeLast()
            }
            guard token.count >= 3, !token.contains("://"), !token.hasPrefix("www.") else { continue }
            let isPath = token.contains("/") && token.rangeOfCharacter(from: .letters) != nil
            // "name.ext" with a short alphanumeric extension; "e.g" and
            // version numbers like "v1.2" are not files.
            let lastName = token.split(separator: "/").last.map(String.init) ?? token
            let parts = lastName.split(separator: ".", omittingEmptySubsequences: false)
            let base = parts.dropLast().joined(separator: ".")
            let fileExtension = parts.count > 1 ? String(parts.last!) : ""
            let hasFileExtension = (1...8).contains(fileExtension.count)
                && (base.count >= 2 || base.hasPrefix(".") == false && base.isEmpty && lastName.count > 3)
                && fileExtension.allSatisfy { $0.isLetter || $0.isNumber }
                && fileExtension.contains(where: \.isLetter)
            if isPath || hasFileExtension { files.insert(token) }
        }
        return files
    }

    static let continuationPhrases = [
        "after that", "after this", "once that", "once this", "when that's done", "when that is done",
        "when this is done", "then continue", "continue the", "continue from", "continue where",
        "follow up on", "build on", "building on", "on top of that", "on top of the previous",
        "after the previous", "after the current", "wait for the",
    ]

    public static func buildsOnEarlierRequest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return continuationPhrases.contains { lowered.contains($0) }
    }
}
