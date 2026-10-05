import Foundation

public enum AutomationState: String, Codable, CaseIterable, Sendable {
    case active
    case paused

    public var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        }
    }
}

public enum AutomationCadence: Codable, Hashable, Sendable {
    case daily(hour: Int, minute: Int)
    /// Uses the Calendar weekday convention: Sunday is 1 and Saturday is 7.
    case weekly(weekday: Int, hour: Int, minute: Int)

    public var hour: Int {
        switch self {
        case let .daily(hour, _), let .weekly(_, hour, _): hour
        }
    }

    public var minute: Int {
        switch self {
        case let .daily(_, minute), let .weekly(_, _, minute): minute
        }
    }

    public var weekday: Int? {
        switch self {
        case .daily: nil
        case let .weekly(weekday, _, _): weekday
        }
    }
}

public struct AutomationSchedule: Codable, Hashable, Sendable {
    public let cadence: AutomationCadence
    public let timeZoneIdentifier: String

    public init(cadence: AutomationCadence, timeZoneIdentifier: String) {
        self.cadence = cadence
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public func nextDate(after date: Date) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.hour = cadence.hour
        components.minute = cadence.minute
        components.second = 0
        components.weekday = cadence.weekday
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

public enum AutomationTarget: Codable, Hashable, Sendable {
    case project(providerID: AgentProviderID, projectID: ProjectID)
    case agent(AgentRouteTarget)

    public var providerID: AgentProviderID {
        switch self {
        case let .project(providerID, _): providerID
        case let .agent(target): target.providerID
        }
    }

    public var projectID: ProjectID {
        switch self {
        case let .project(_, projectID): projectID
        case let .agent(target): target.projectID
        }
    }

    public var agentID: AgentID? {
        switch self {
        case .project: nil
        case let .agent(target): target.agentID
        }
    }

    public func routeRequest(for instruction: String) -> RouteRequest {
        switch self {
        case let .project(providerID, projectID):
            RouteRequest(
                prompt: instruction,
                scope: .projects([projectID]),
                providerID: providerID
            )
        case let .agent(target):
            RouteRequest(
                prompt: instruction,
                scope: .projects([target.projectID]),
                providerID: target.providerID,
                agentTarget: target
            )
        }
    }
}

public struct AutomationAction: Codable, Hashable, Identifiable, Sendable {
    public let id: AutomationActionID
    public let instruction: String
    public let target: AutomationTarget

    public init(
        id: AutomationActionID = .make(),
        instruction: String,
        target: AutomationTarget
    ) {
        self.id = id
        self.instruction = instruction
        self.target = target
    }
}

public struct AutomationDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: AutomationID
    public let name: String
    public let schedule: AutomationSchedule
    public let actions: [AutomationAction]
    public let state: AutomationState
    /// User-selected, revision-bound authorization for every complete Codex approval.
    public let automaticallyApproveRuntimeRequests: Bool
    public let nextRunAt: Date?
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: AutomationID = .make(),
        name: String,
        schedule: AutomationSchedule,
        actions: [AutomationAction],
        state: AutomationState = .active,
        automaticallyApproveRuntimeRequests: Bool = false,
        nextRunAt: Date? = nil,
        revision: Int = 1,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.actions = actions
        self.state = state
        self.automaticallyApproveRuntimeRequests = automaticallyApproveRuntimeRequests
        self.nextRunAt = nextRunAt
        self.revision = max(1, revision)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, schedule, actions, state, automaticallyApproveRuntimeRequests
        case nextRunAt, revision, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(AutomationID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            schedule: try values.decode(AutomationSchedule.self, forKey: .schedule),
            actions: try values.decode([AutomationAction].self, forKey: .actions),
            state: try values.decode(AutomationState.self, forKey: .state),
            automaticallyApproveRuntimeRequests: try values.decodeIfPresent(Bool.self, forKey: .automaticallyApproveRuntimeRequests) ?? false,
            nextRunAt: try values.decodeIfPresent(Date.self, forKey: .nextRunAt),
            revision: try values.decode(Int.self, forKey: .revision),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(schedule, forKey: .schedule)
        try values.encode(actions, forKey: .actions)
        try values.encode(state, forKey: .state)
        // The authenticated automation document signs canonical encoded bytes.
        // Omitting the new default retains the exact pre-grant payload on upgrade.
        if automaticallyApproveRuntimeRequests {
            try values.encode(true, forKey: .automaticallyApproveRuntimeRequests)
        }
        try values.encodeIfPresent(nextRunAt, forKey: .nextRunAt)
        try values.encode(revision, forKey: .revision)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    public func updatingScheduleReference(_ date: Date) -> AutomationDefinition {
        AutomationDefinition(
            id: id,
            name: name,
            schedule: schedule,
            actions: actions,
            state: state,
            automaticallyApproveRuntimeRequests: automaticallyApproveRuntimeRequests,
            nextRunAt: state == .active ? schedule.nextDate(after: date) : nil,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func settingAutomaticRuntimeApproval(_ enabled: Bool) -> AutomationDefinition {
        AutomationDefinition(
            id: id,
            name: name,
            schedule: schedule,
            actions: actions,
            state: state,
            automaticallyApproveRuntimeRequests: enabled,
            nextRunAt: nextRunAt,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum AutomationTrigger: String, Codable, Sendable {
    case scheduled
    case manual
}

public enum AutomationOccurrenceStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case needsAttention
    case completed
    case failed
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running, .needsAttention: false
        }
    }
}

public enum AutomationActionStatus: String, Codable, Sendable {
    case pending
    case waitingForReview
    case running
    case needsAttention
    case completed
    case failed
    case cancelled
}

/// The immutable action and plan actually displayed for a manual decision.
/// An occurrence ID alone can outlive several different action reviews.
public struct AutomationReviewBinding: Codable, Hashable, Sendable {
    public let actionID: AutomationActionID
    public let planID: RunID

    public init(actionID: AutomationActionID, planID: RunID) {
        self.actionID = actionID
        self.planID = planID
    }
}

public struct AutomationActionAttempt: Codable, Hashable, Identifiable, Sendable {
    public var id: AutomationActionID { actionID }

    public let actionID: AutomationActionID
    public let plan: RoutingPlan?
    public let runID: RunID?
    public let status: AutomationActionStatus
    public let message: String?
    public let updatedAt: Date

    public init(
        actionID: AutomationActionID,
        plan: RoutingPlan? = nil,
        runID: RunID? = nil,
        status: AutomationActionStatus = .pending,
        message: String? = nil,
        updatedAt: Date = .now
    ) {
        self.actionID = actionID
        self.plan = plan
        self.runID = runID
        self.status = status
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct AutomationOccurrence: Codable, Hashable, Identifiable, Sendable {
    public let id: AutomationOccurrenceID
    public let automationID: AutomationID
    /// Immutable display identity retained even after the schedule is deleted.
    /// Optional so automation stores written by earlier beta builds remain decodable.
    public let automationName: String?
    public let definitionRevision: Int
    /// Immutable snapshot: edits to a definition never alter an occurrence in flight.
    public let actions: [AutomationAction]
    public let trigger: AutomationTrigger
    public let scheduledAt: Date
    public let status: AutomationOccurrenceStatus
    public let currentActionIndex: Int
    public let attempts: [AutomationActionAttempt]
    public let message: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var currentReviewAttempt: AutomationActionAttempt? {
        guard actions.indices.contains(currentActionIndex),
              let attempt = attempts.first(where: {
                  $0.actionID == actions[currentActionIndex].id && $0.status == .waitingForReview
              }), attempt.plan != nil else { return nil }
        return attempt
    }

    public var currentReviewBinding: AutomationReviewBinding? {
        guard let attempt = currentReviewAttempt, let plan = attempt.plan else { return nil }
        return AutomationReviewBinding(actionID: attempt.actionID, planID: plan.id)
    }

    public init(
        id: AutomationOccurrenceID = .make(),
        automationID: AutomationID,
        automationName: String? = nil,
        definitionRevision: Int,
        actions: [AutomationAction],
        trigger: AutomationTrigger,
        scheduledAt: Date,
        status: AutomationOccurrenceStatus = .queued,
        currentActionIndex: Int = 0,
        attempts: [AutomationActionAttempt] = [],
        message: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.automationID = automationID
        self.automationName = automationName
        self.definitionRevision = definitionRevision
        self.actions = actions
        self.trigger = trigger
        self.scheduledAt = scheduledAt
        self.status = status
        self.currentActionIndex = currentActionIndex
        self.attempts = attempts
        self.message = message
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AutomationSnapshot: Codable, Hashable, Sendable {
    public let definitions: [AutomationDefinition]
    public let occurrences: [AutomationOccurrence]

    public init(
        definitions: [AutomationDefinition] = [],
        occurrences: [AutomationOccurrence] = []
    ) {
        self.definitions = definitions
        self.occurrences = occurrences
    }

    public static let empty = AutomationSnapshot()
}
