import Foundation

/// Detects requests that need a scheduling decision before a one-time plan is prepared.
public enum RecurringRequestIntent {
    public static func requestsSchedule(_ prompt: String) -> Bool {
        let words = Set(prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !words.isDisjoint(with: ["recurring", "recuring", "repeated", "periodic"])
    }
}
