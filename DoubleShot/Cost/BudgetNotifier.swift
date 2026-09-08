import Foundation
import UserNotifications
import AppKit

/// Fires each configured threshold at most once per day.
///
/// These are alerts, not enforcement — nothing here can stop a request. Crossing
/// 100% gets you a notification, not a blocked prompt.
final class BudgetNotifier {

    /// Set when a threshold is crossed but the system won't deliver notifications,
    /// so the UI can show it inline instead of dropping the alert on the floor.
    var onFallback: ((String) -> Void)?

    private var authorized = false
    private var askedForAuthorization = false

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("DoubleShot: notification authorization failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self.authorized = granted }
        }
    }

    /// Forget today's fired thresholds — used when the limit changes, so a raised
    /// limit can alert again on the way back up.
    func resetToday() {
        let day = Self.dayKey.string(from: Date())
        Defaults.setFiredThresholds([], on: day)
    }

    func evaluate(cost: Double, budget: Budget) {
        guard budget.dailyLimit > 0 else { return }
        let day = Self.dayKey.string(from: Date())
        Defaults.pruneFiredThresholds(keeping: day)

        let pct = cost / budget.dailyLimit * 100
        var fired = Defaults.firedThresholds(on: day)

        // Only ever announce the highest threshold crossed, so a cold start that
        // lands past 100% doesn't stack three notifications at once.
        let crossed = budget.thresholds.filter { Double($0) <= pct && !fired.contains($0) }
        guard let highest = crossed.max() else { return }

        fired.formUnion(crossed)
        Defaults.setFiredThresholds(fired, on: day)
        deliver(threshold: highest, cost: cost, limit: budget.dailyLimit)
    }

    private func deliver(threshold: Int, cost: Double, limit: Double) {
        let title = threshold >= 100
            ? "Daily Claude Code limit reached"
            : "\(threshold)% of your daily Claude Code limit"
        let body = "\(Money.string(cost)) of \(Money.string(limit)) spent today (API-rate equivalent)."

        guard authorized else {
            NSSound.beep()
            onFallback?("\(title) — \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "doubleshot.threshold.\(threshold).\(Self.dayKey.string(from: Date()))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            NSLog("DoubleShot: notification delivery failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onFallback?("\(title) — \(body)") }
        }
    }
}

enum Money {
    private static let withCents: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f
    }()

    static func string(_ value: Double) -> String {
        // A limit is almost always a round number; showing "$50" beats "$50.00".
        let formatter = value == value.rounded() && abs(value) >= 1 ? whole : withCents
        return formatter.string(from: value as NSNumber) ?? "$0"
    }

    /// Always two decimals — for spend, where the cents are the point.
    static func precise(_ value: Double) -> String {
        withCents.string(from: value as NSNumber) ?? "$0.00"
    }
}
