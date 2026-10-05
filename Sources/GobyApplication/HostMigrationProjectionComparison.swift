import Foundation

public enum GADHostMigrationProjectionSection: String, CaseIterable, Equatable, Hashable, Sendable {
    case revision
    case hostIdentity
    case draft
    case projects
    case agents
    case projectGroups
    case resources
    case instructions
    case plan
    case runs
    case approvals
    case providerBindings
    case handoffLinks
    case handoffs
}

public struct GADHostMigrationProjectionComparison: Equatable, Sendable {
    public let mismatchedSections: [GADHostMigrationProjectionSection]

    public init(mismatchedSections: [GADHostMigrationProjectionSection]) {
        self.mismatchedSections = mismatchedSections
    }

    public var isEquivalent: Bool { mismatchedSections.isEmpty }
}

/// Compares the canonical, persisted portions of pre- and post-transfer
/// projections. Live reachability, health, account observations and external
/// provider task activity are intentionally excluded because they may change
/// while the helper starts.
public enum GADHostMigrationProjectionComparator {
    public static func compare(
        expected: DashboardProjection,
        candidate: DashboardProjection
    ) -> GADHostMigrationProjectionComparison {
        var mismatches: [GADHostMigrationProjectionSection] = []
        append(.revision, expected.revision == candidate.revision, to: &mismatches)
        // The durable host ID is the ownership boundary. `displayName` comes
        // from ProcessInfo and may legitimately differ between the foreground
        // app and its launch-agent helper, or after the Mac is renamed. It is
        // presentation metadata and must not prevent the same host from
        // recovering its canonical coordinator at launch.
        append(.hostIdentity, expected.host.id == candidate.host.id, to: &mismatches)
        append(.draft, expected.draft == candidate.draft, to: &mismatches)
        append(.projects, expected.projects == candidate.projects, to: &mismatches)
        append(.agents, expected.agents == candidate.agents, to: &mismatches)
        append(.projectGroups, expected.projectGroups == candidate.projectGroups, to: &mismatches)
        append(.resources, expected.resources == candidate.resources, to: &mismatches)
        append(.instructions, expected.instructions == candidate.instructions, to: &mismatches)
        append(.plan, expected.plan == candidate.plan, to: &mismatches)
        append(.runs, expected.runs == candidate.runs, to: &mismatches)
        append(.approvals, expected.approvals == candidate.approvals, to: &mismatches)
        append(
            .providerBindings,
            expected.providerBindings == candidate.providerBindings,
            to: &mismatches
        )
        append(.handoffLinks, expected.handoffLinks == candidate.handoffLinks, to: &mismatches)
        append(.handoffs, expected.handoffs == candidate.handoffs, to: &mismatches)
        return GADHostMigrationProjectionComparison(mismatchedSections: mismatches)
    }

    private static func append(
        _ section: GADHostMigrationProjectionSection,
        _ matches: Bool,
        to result: inout [GADHostMigrationProjectionSection]
    ) {
        if !matches { result.append(section) }
    }
}
