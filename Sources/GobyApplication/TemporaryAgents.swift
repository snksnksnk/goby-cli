import Foundation
import GobyDomain

/// Stores host-local continuation notes that temporary agents leave for the
/// next temporary agent working in the same project. Notes never leave this
/// Mac except as part of a later agent's reviewed instructions.
public protocol TemporaryAgentNotesStoring: Sendable {
    /// Markdown for the project, or nil when no temporary agent has left notes.
    func notes(for projectID: ProjectID) async throws -> String?
    /// Appends one entry unless an entry for the same run is already present.
    func append(_ entry: TemporaryAgentNoteEntry, projectID: ProjectID, projectName: String) async throws
}

/// One finished temporary-agent run, rendered as a Markdown section.
public struct TemporaryAgentNoteEntry: Equatable, Sendable {
    public static let maximumBodyLength = 6_000

    public let runID: RunID
    public let agentName: String
    public let status: String
    public let request: String
    public let body: String
    public let recordedAt: Date

    public init(runID: RunID, agentName: String, status: String, request: String, body: String, recordedAt: Date) {
        self.runID = runID
        self.agentName = agentName
        self.status = status
        self.request = SensitiveTextRedactor.redactCredentials(request, limit: 1_000)
            .replacingOccurrences(of: "\n", with: " ")
        self.body = Self.demotingHeadings(
            in: SensitiveTextRedactor.redactCredentials(body, limit: Self.maximumBodyLength)
        )
        self.recordedAt = recordedAt
    }

    /// Only entry titles may start with `## `, so the file splits reliably
    /// even when an agent's answer contains its own headings.
    private static func demotingHeadings(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("#") else { return String(line) }
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? String(line) : "#### " + title
        }.joined(separator: "\n")
    }

    /// Marker that makes recording idempotent across restarts.
    public var marker: String { "<!-- goby-run: \(runID.rawValue) -->" }

    public var markdown: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        // Notes are read by the person at this Mac; show their local time.
        formatter.timeZone = .current
        return """
        ## \(formatter.string(from: recordedAt)) · \(agentName) · \(status)
        \(marker)

        **Request:** \(request)

        \(body)
        """
    }
}

/// A task-specific definition for a one-run temporary agent: a role suited to
/// the request and project, and instructions that carry earlier notes forward.
public struct TemporaryAgentBlueprint: Equatable, Sendable {
    public static let continuationNotesLimit = 12_000
    public static let handoffHeading = "## Handoff notes"

    public let name: String
    public let summary: String
    public let instructions: String
    public let capabilities: Set<AgentCapability>

    private struct Role {
        let name: String
        let focus: String
    }

    // Ordered by specificity: the first matching role names the agent.
    private static let keywordRoles: [([String], Role)] = [
        (["growth", "gain users", "get users", "more users", "acquisition", "marketing", "seo", "retention", "conversion", "analytics", "funnel", "campaign"],
         Role(name: "Growth Strategist", focus: "Ground recommendations in this project's product, metrics and launch state. Prioritize a small number of measurable experiments and say how each will be measured.")),
        (["security", "vulnerability", "threat", "privacy"],
         Role(name: "Security Specialist", focus: "Identify concrete risks with evidence, rate their severity and propose the smallest safe fix.")),
        (["release", "deploy", "ship", "app store", "play store", "testflight"],
         Role(name: "Release Specialist", focus: "Check readiness, signing, versioning and store requirements before recommending a release step.")),
        (["test", "regression", "flaky", "coverage"],
         Role(name: "Test Engineer", focus: "Reproduce the behavior, add or fix focused tests and report the exact commands and results.")),
        (["bug", "crash", "error", "fix", "broken", "fails", "failing"],
         Role(name: "Debugging Engineer", focus: "Find the root cause with evidence before changing code, then make the smallest correct fix and verify it.")),
        (["design", "icon", "logo", "branding", "ui", "ux", "layout"],
         Role(name: "Product Designer", focus: "Respect the existing design system and accessibility, and explain visual decisions briefly.")),
        (["documentation", "docs", "readme", "guide"],
         Role(name: "Technical Writer", focus: "Write accurate, concise documentation that matches the current code.")),
        (["review", "audit"],
         Role(name: "Code Reviewer", focus: "Report defects in order of severity with file and line references; do not rewrite unrelated code.")),
        (["research", "investigate", "compare", "evaluate"],
         Role(name: "Research Analyst", focus: "Cite the sources you used and separate verified facts from assumptions.")),
        (["plan", "strategy", "roadmap", "proposal"],
         Role(name: "Planning Specialist", focus: "Produce a prioritized, actionable plan with owners, order and success measures.")),
    ]

    private static let capabilityRoles: [(AgentCapability, Role)] = [
        (.iOS, Role(name: "iOS Engineer", focus: "Follow the project's Swift and SwiftUI conventions and build with its existing schemes.")),
        (.android, Role(name: "Android Engineer", focus: "Follow the project's Kotlin and Gradle conventions.")),
        (.macOS, Role(name: "macOS Engineer", focus: "Follow the project's Swift and AppKit or SwiftUI conventions.")),
        (.web, Role(name: "Web Engineer", focus: "Follow the project's web stack, build and test conventions.")),
        (.backend, Role(name: "Backend Engineer", focus: "Keep API contracts and data compatible, and test server changes.")),
    ]

    public static func make(
        goal: String,
        project: LabProject,
        continuationNotes: String? = nil
    ) -> TemporaryAgentBlueprint {
        let task = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = task.lowercased()
        let inferred = AgentRoutingMatcher.inferredCapabilities(from: task)
        let keywordRole = keywordRoles.first { terms, _ in
            terms.contains { containsTerm($0, in: normalized) }
        }?.1
        let platformRole = capabilityRoles.first { inferred.contains($0.0) }?.1
        let role = keywordRole ?? platformRole
            ?? Role(name: "Task Specialist", focus: "Work carefully within the existing project conventions.")

        let platforms = project.platforms.map(\.rawValue).sorted().joined(separator: ", ")
        let continuation = continuationNotes.map(boundedNotes).flatMap { $0.isEmpty ? nil : $0 }

        var sections = [
            "You are a temporary \(role.name) for \(project.name)\(platforms.isEmpty ? "" : " (\(platforms))"). Goby created you for one task and removes you when the run ends.",
            "Task: \(String(task.prefix(2_000)))",
            role.focus,
            "Work only on this task. If it asks for analysis, advice or a plan, answer without modifying project files. Ask only when a decision is genuinely ambiguous.",
        ]
        if let continuation {
            sections.append("""
            Earlier temporary agents in \(project.name) left these notes. Continue from them instead of repeating finished work, and say if they are outdated:

            \(continuation)
            """)
        }
        sections.append("End your final answer with a section titled `\(handoffHeading)` that lists what you did, key findings and decisions, files changed, and what remains. Goby saves it so another temporary agent can continue if needed.")

        return TemporaryAgentBlueprint(
            name: "Temporary \(role.name)",
            summary: "Temporary \(role.name.lowercased()) for one task in \(project.name).",
            instructions: sections.joined(separator: "\n\n"),
            capabilities: inferred.union([.routing])
        )
    }

    /// The final answer's handoff section, or nil when the agent omitted it.
    /// "Web Agent · parallel": a temporary copy for one request that runs
    /// while the original agent works on another.
    public static func parallelCopyName(of name: String) -> String {
        "\(name) · parallel"
    }

    public static func parallelCopyInstructions(
        template: AgentProfile,
        goal: String,
        continuationNotes: String?
    ) -> String {
        var sections = [
            template.instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "You are \(template.name): \(template.summary)",
            """
            You are a temporary parallel copy of \(template.name). The original agent is working on \
            another request in this project at the same time. Work only on this request: \
            \(String(goal.prefix(600))). Do not change files outside its scope.
            """,
        ]
        if let continuationNotes = continuationNotes.map(boundedNotes), !continuationNotes.isEmpty {
            sections.append("Notes earlier temporary agents left for this project:\n\(continuationNotes)")
        }
        sections.append("""
        When you finish, end your answer with a "## Handoff notes" section: what you changed, \
        what is unfinished, and anything the next agent should know.
        """)
        return sections.joined(separator: "\n\n")
    }

    public static func handoffSection(in outcome: String) -> String? {
        guard let range = outcome.range(of: handoffHeading, options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let section = outcome[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// Keeps the newest notes: entries are appended, so the tail is freshest.
    private static func boundedNotes(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > continuationNotesLimit else { return trimmed }
        let tail = String(trimmed.suffix(continuationNotesLimit))
        if let firstEntry = tail.range(of: "\n## ") {
            return "(Earlier notes omitted.)\n" + tail[firstEntry.lowerBound...].trimmingCharacters(in: .newlines)
        }
        return "(Earlier notes omitted.)\n" + tail
    }

    private static func containsTerm(_ term: String, in text: String) -> Bool {
        // Whole-word match so "ui" does not match "build" and "ship" not "relationship".
        let pattern = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Records a finished temporary-agent run in the project's continuation notes.
public struct RecordTemporaryAgentNotesUseCase: Sendable {
    private let store: any TemporaryAgentNotesStoring
    private let now: @Sendable () -> Date

    public init(store: any TemporaryAgentNotesStoring, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.now = now
    }

    public func callAsFunction(_ run: RunRecord) async throws {
        guard run.status.isFinished else { return }
        for agent in run.agentSnapshot where agent.isTemporary {
            for assignment in run.assignments where assignment.agentID == agent.id {
                guard let project = run.projectSnapshot.first(where: { $0.id == assignment.projectID }) else { continue }
                let outcome = assignment.statusReason ?? run.outcome ?? ""
                let body: String
                if let handoff = TemporaryAgentBlueprint.handoffSection(in: outcome) {
                    body = "### Handoff notes\n\(handoff)"
                } else if outcome.isEmpty {
                    body = "_The run ended without a reported result._"
                } else {
                    body = "### Result\n\(outcome)"
                }
                try await store.append(
                    TemporaryAgentNoteEntry(
                        runID: run.id,
                        agentName: agent.name,
                        status: assignment.status.rawValue,
                        request: run.plan.interpretedGoal,
                        body: body,
                        recordedAt: now()
                    ),
                    projectID: project.id,
                    projectName: project.name
                )
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
