import GobyDomain

/// Shared macOS/iOS editor policy for preserving exact automation scope.
///
/// A catalog refresh can make an existing project/provider/agent target
/// unavailable while its editor is open. Keep that exact selection visible
/// and invalid instead of silently substituting another eligible route.
public struct AutomationTargetChoice: Hashable, Identifiable, Sendable {
    public let target: AutomationTarget
    public let isAvailable: Bool

    public var id: AutomationTarget { target }

    public init(target: AutomationTarget, isAvailable: Bool) {
        self.target = target
        self.isAvailable = isAvailable
    }
}

public enum AutomationTargetChoicePolicy {
    public static func choices(
        preserving currentTarget: AutomationTarget,
        availableTargets: [AutomationTarget]
    ) -> [AutomationTargetChoice] {
        var seen = Set<AutomationTarget>()
        let available = availableTargets.filter { seen.insert($0).inserted }
        let currentIsAvailable = seen.contains(currentTarget)
        let choices = available.map {
            AutomationTargetChoice(target: $0, isAvailable: true)
        }
        guard !currentIsAvailable else { return choices }
        return [AutomationTargetChoice(target: currentTarget, isAvailable: false)] + choices
    }

    public static func isAvailable(
        _ target: AutomationTarget,
        in availableTargets: [AutomationTarget]
    ) -> Bool {
        availableTargets.contains(target)
    }
}
