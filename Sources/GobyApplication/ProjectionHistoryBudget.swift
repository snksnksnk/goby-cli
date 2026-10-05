import Foundation
import GobyDomain

/// Keeps retained history from exhausting routine transport/cache frames.
/// This changes display windows only; it never writes or deletes host records.
public enum ProjectionHistoryBudget {
    // Leave room for identifier aliases, envelope metadata, and encrypted-frame
    // base64 expansion under the existing 1 MiB remote frame limit.
    public static let maximumProjectionBytes = 512 * 1_024

    private enum HistoricalRecord {
        case run(GADRunProjection)
        case occurrence(AutomationOccurrence)

        var updatedAt: Date {
            switch self {
            case let .run(run): run.updatedAt
            case let .occurrence(occurrence): occurrence.updatedAt
            }
        }

        var sortKey: String {
            switch self {
            case let .run(run): "run-\(run.id.rawValue)"
            case let .occurrence(occurrence): "occurrence-\(occurrence.id.rawValue)"
            }
        }
    }

    public static func apply(
        to projection: DashboardProjection,
        totalRunCount: Int,
        totalOccurrenceCount: Int
    ) -> DashboardProjection {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        func byteCount<T: Encodable>(_ value: T) -> Int {
            (try? encoder.encode(value).count) ?? maximumProjectionBytes
        }

        let activeOccurrences = projection.automations.occurrences.filter { !$0.status.isFinished }
        var retainedRunIDs = Set(projection.runs.filter { !$0.status.isFinished }.map(\.id))
        retainedRunIDs.formUnion(projection.approvals.map(\.runID))
        retainedRunIDs.formUnion(activeOccurrences.flatMap { $0.attempts.compactMap(\.runID) })
        for handoff in projection.handoffs where handoff.state != .completed && handoff.state != .cancelled {
            retainedRunIDs.insert(handoff.runID)
            if let destinationID = handoff.destinationRunID { retainedRunIDs.insert(destinationID) }
        }
        var retainedOccurrenceIDs = Set(activeOccurrences.map(\.id))
        let runsByID = Dictionary(uniqueKeysWithValues: projection.runs.map { ($0.id, $0) })
        let runBytes = Dictionary(uniqueKeysWithValues: projection.runs.map { ($0.id, byteCount($0) + 1) })

        func replacingHistory() -> DashboardProjection {
            let runs = projection.runs.filter { retainedRunIDs.contains($0.id) }
            let occurrences = projection.automations.occurrences.filter { retainedOccurrenceIDs.contains($0.id) }
            let omittedRuns = max(0, totalRunCount - runs.count)
            let omittedOccurrences = max(0, totalOccurrenceCount - occurrences.count)
            let host = GADHostProjection(
                id: projection.host.id,
                displayName: projection.host.displayName,
                reachability: projection.host.reachability,
                lastUpdatedAt: projection.host.lastUpdatedAt,
                omittedHistoryRunCount: omittedRuns > 0 ? omittedRuns : nil,
                omittedAutomationOccurrenceCount: omittedOccurrences > 0 ? omittedOccurrences : nil,
                temporaryChat: projection.host.temporaryChat
            )
            return projection.applying(
                [.host(host), .runs(runs), .automations(.init(
                    definitions: projection.automations.definitions, occurrences: occurrences
                ))],
                revision: projection.revision, generatedAt: projection.generatedAt
            )
        }

        // Active work, pending approvals and continuation sources are never
        // evicted to make room for historical display records.
        var remaining = max(0, maximumProjectionBytes - byteCount(replacingHistory()) - 1_024)
        let historicalRuns: [HistoricalRecord] = projection.runs
            .filter { !retainedRunIDs.contains($0.id) }.map { .run($0) }
        let historicalOccurrences: [HistoricalRecord] = projection.automations.occurrences
            .filter { !retainedOccurrenceIDs.contains($0.id) }.map { .occurrence($0) }
        let candidates: [HistoricalRecord] = (historicalRuns + historicalOccurrences).sorted {
            $0.updatedAt == $1.updatedAt ? $0.sortKey < $1.sortKey : $0.updatedAt > $1.updatedAt
        }
        for candidate in candidates {
            switch candidate {
            case let .run(run):
                guard !retainedRunIDs.contains(run.id) else { continue }
                let size = runBytes[run.id] ?? maximumProjectionBytes
                guard size <= remaining else { continue }
                retainedRunIDs.insert(run.id)
                remaining -= size
            case let .occurrence(occurrence):
                let requiredRuns = Set(occurrence.attempts.compactMap(\.runID))
                    .subtracting(retainedRunIDs)
                // Keep a historical occurrence and its projected run targets
                // together so Open Run never points to an evicted history row.
                guard requiredRuns.allSatisfy({ runsByID[$0] != nil }) else { continue }
                let size = byteCount(occurrence) + 1 + requiredRuns.reduce(0) { $0 + (runBytes[$1] ?? 0) }
                guard size <= remaining else { continue }
                retainedOccurrenceIDs.insert(occurrence.id)
                retainedRunIDs.formUnion(requiredRuns)
                remaining -= size
            }
        }
        return replacingHistory()
    }
}
