@preconcurrency import UserNotifications
import Foundation
import GobyApplication
import GobyDomain

public actor LocalRunNotifier: RunNotifying, AutomationNotifying {
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    public init(
        center: UNUserNotificationCenter = .current(),
        defaultsSuiteName: String? = nil
    ) {
        self.center = center
        if let defaultsSuiteName,
           let suiteDefaults = UserDefaults(suiteName: defaultsSuiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
    }

    public func notify(for run: RunRecord) async {
        guard notificationsEnabled, [.completed, .failed, .needsAttention].contains(run.status) else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: run.status)
        content.body = notificationBody(for: run.status)
        content.sound = run.status == .completed ? nil : .default
        // Finished work arrives quietly; failures and decisions still alert.
        // Every Goby notification shares one group in Notification Center.
        content.interruptionLevel = run.status == .completed ? .passive : .active
        content.threadIdentifier = Self.threadIdentifier
        let request = UNNotificationRequest(
            identifier: "goby.run.\(run.id.rawValue).\(run.status.rawValue)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    public func notify(for occurrence: AutomationOccurrence) async {
        guard notificationsEnabled, occurrence.status == .needsAttention else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Goby automation needs attention"
        content.body = "Open Goby to review the scheduled action before it runs."
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = Self.threadIdentifier
        let request = UNNotificationRequest(
            identifier: "goby.automation.\(occurrence.id.rawValue).\(occurrence.currentActionIndex).attention",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    static let threadIdentifier = "goby.activity"

    /// The evening summary: counts only, delivered quietly in Goby's group.
    public func notifyDailyDigest(_ digest: DailyDigest) async {
        guard notificationsEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Goby today"
        content.body = digest.body
        content.interruptionLevel = .passive
        content.threadIdentifier = Self.threadIdentifier
        let request = UNNotificationRequest(
            identifier: "goby.digest.\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private var notificationsEnabled: Bool {
        defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    private func notificationTitle(for status: RunStatus) -> String {
        switch status {
        case .completed: "Goby finished a run"
        case .failed: "Goby run failed"
        case .needsAttention: "Goby needs a decision"
        default: "Goby run update"
        }
    }

    private func notificationBody(for status: RunStatus) -> String {
        switch status {
        case .completed: "Open Goby to review the consolidated result."
        case .failed: "Open Goby to review the failure and recovery options."
        case .needsAttention: "Open Goby to review the required decision."
        default: "Open Goby to review this run."
        }
    }
}
