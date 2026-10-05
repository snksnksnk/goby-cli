import Foundation
import GobyDomain

/// Counts for one day's digest. Generic by design: no request text, project
/// or agent names ever leave the Mac in a notification.
public struct DailyDigest: Equatable, Sendable {
    public let finished: Int
    public let needsAttention: Int

    public var body: String {
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        if needsAttention > 0 {
            parts.append("\(needsAttention) \(needsAttention == 1 ? "needs" : "need") attention")
        }
        return parts.joined(separator: " · ")
    }

    /// Runs updated on `day` that finished, and runs still failed or waiting
    /// on the user. Nil when there is nothing worth a notification.
    public static func make(for runs: [RunRecord], on day: Date, calendar: Calendar = .current) -> DailyDigest? {
        let today = runs.filter { calendar.isDate($0.updatedAt, inSameDayAs: day) }
        let finished = today.filter { $0.status == .completed }.count
        let attention = runs.filter { $0.status == .failed || $0.status == .needsAttention }
            .filter { calendar.isDate($0.updatedAt, inSameDayAs: day) }
            .count
        guard finished > 0 || attention > 0 else { return nil }
        return DailyDigest(finished: finished, needsAttention: attention)
    }
}

/// Posts one counts-only digest each day at a fixed local time, while the
/// background host runs. It skips days with no activity and never posts
/// twice for the same day, even across host restarts.
public actor DailyDigestScheduler {
    public typealias RunsProvider = @Sendable () async -> [RunRecord]
    public typealias Poster = @Sendable (DailyDigest) async -> Void

    private let hour: Int
    private let runs: RunsProvider
    private let post: Poster
    private let defaults: UserDefaults
    private let calendar: Calendar
    private var task: Task<Void, Never>?
    static let lastPostedDayKey = "GobyDailyDigestLastPostedDay"

    public init(
        hour: Int = 18,
        defaultsSuiteName: String? = nil,
        calendar: Calendar = .current,
        runs: @escaping RunsProvider,
        post: @escaping Poster
    ) {
        self.hour = hour
        self.runs = runs
        self.post = post
        self.calendar = calendar
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.secondsUntilNextFire(after: .now)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self.fire(at: .now)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Seconds from `date` to the next digest time.
    func secondsUntilNextFire(after date: Date) -> TimeInterval {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        let next = today > date ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        return max(1, next.timeIntervalSince(date))
    }

    func fire(at date: Date) async {
        let dayKey = Self.dayKey(date, calendar: calendar)
        guard defaults.string(forKey: Self.lastPostedDayKey) != dayKey else { return }
        defaults.set(dayKey, forKey: Self.lastPostedDayKey)
        guard let digest = DailyDigest.make(for: await runs(), on: date, calendar: calendar) else { return }
        await post(digest)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
