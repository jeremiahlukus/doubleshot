import Foundation

/// The daily limit and alert thresholds.
///
/// Stored at `~/.claude/usage-budget.json`, deliberately the same file the
/// `claude_cost` statusline reads, so changing the limit here moves both.
/// Unknown keys in that file are preserved on write.
struct Budget: Equatable {
    var dailyLimit: Double = 50
    var thresholds: [Int] = [50, 80, 100]

    static let presets: [Double] = [25, 50, 100, 200]

    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/usage-budget.json")
    }

    static func load() -> Budget {
        var budget = Budget()
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return budget }

        if let limit = (root["daily_limit"] as? NSNumber)?.doubleValue, limit > 0 {
            budget.dailyLimit = limit
        }
        if let raw = root["thresholds"] as? [Any] {
            let parsed = raw.compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 > 0 }
            if !parsed.isEmpty { budget.thresholds = parsed.sorted() }
        }
        return budget
    }

    func save() throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        root["daily_limit"] = dailyLimit
        root["thresholds"] = thresholds

        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.url, options: .atomic)
    }

    /// Clamped to something a person could plausibly mean.
    static func sanitize(limit: Double) -> Double {
        guard limit.isFinite, limit > 0 else { return 1 }
        return min(max(limit, 1), 100_000)
    }
}
