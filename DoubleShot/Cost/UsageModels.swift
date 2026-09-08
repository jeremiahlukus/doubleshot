import Foundation

/// One assistant message's token counts, flattened from the transcript's `usage` block.
///
/// `input_tokens` in a transcript is the *uncached remainder only*, so the real
/// prompt size is `input + cacheWrite5m + cacheWrite1h + cacheRead`. Reading only
/// `input_tokens` undercounts badly.
struct TokenUsage {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var isFast = false

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

extension TokenUsage: Decodable {
    private enum Key: String, CodingKey {
        case input_tokens, output_tokens
        case cache_creation_input_tokens, cache_read_input_tokens
        case cache_creation, speed
    }

    private enum CacheKey: String, CodingKey {
        case ephemeral_5m_input_tokens, ephemeral_1h_input_tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input_tokens) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output_tokens) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens) ?? 0
        isFast = (try c.decodeIfPresent(String.self, forKey: .speed)) == "fast"

        // Cache writes are split by TTL: 5-minute writes bill at 1.25x input,
        // 1-hour writes at 2x. Lumping them together misprices cache-heavy work.
        let lump = try c.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens) ?? 0
        if let cache = try? c.nestedContainer(keyedBy: CacheKey.self, forKey: .cache_creation) {
            let w5 = try cache.decodeIfPresent(Int.self, forKey: .ephemeral_5m_input_tokens) ?? 0
            let w1 = try cache.decodeIfPresent(Int.self, forKey: .ephemeral_1h_input_tokens) ?? 0
            // A present-but-empty breakdown still has to account for the lump sum,
            // otherwise those writes silently cost nothing.
            if w5 == 0 && w1 == 0 && lump > 0 {
                cacheWrite5m = lump
            } else {
                cacheWrite5m = w5
                cacheWrite1h = w1
            }
        } else {
            cacheWrite5m = lump
        }
    }
}

/// The subset of a transcript line we care about. Everything else (content,
/// diagnostics, git branch) is ignored by the decoder.
struct TranscriptRecord: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let cwd: String?

    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: TokenUsage?
    }
}

/// What Claude Code is doing right now, read off the tail of the live transcripts.
///
/// This is what drives Auto keep-awake. A timeout can only guess; the transcript
/// actually says whether a tool is running or the turn was handed back to you.
enum ClaudeActivity: Equatable {
    /// Mid-turn: a tool call is running, or a response is in flight.
    case working
    /// The turn ended. Claude is waiting on the human.
    case waiting
    /// No transcripts, or nothing in the tail that carries state.
    case unknown
}

/// One priced assistant response.
struct UsageEntry {
    let dedupKey: String
    let day: Date
    let timestamp: Date
    let model: String
    let projectPath: String
    let cost: Double
    let tokens: Int
    let isSubagent: Bool
    let unpriced: Bool
}

/// Aggregated spend over some span of entries.
struct Totals {
    var cost: Double = 0
    var tokens: Int = 0
    var subagentCost: Double = 0
    var unpriced: Int = 0
    var byModel: [String: Double] = [:]
    var byProject: [String: Double] = [:]
    var responses: Int = 0

    mutating func add(_ entry: UsageEntry) {
        responses += 1
        tokens += entry.tokens
        guard !entry.unpriced else {
            unpriced += 1
            return
        }
        cost += entry.cost
        if entry.isSubagent { subagentCost += entry.cost }
        byModel[entry.model, default: 0] += entry.cost
        byProject[entry.projectPath, default: 0] += entry.cost
    }

    var modelsRanked: [(name: String, cost: Double)] {
        byModel.sorted { $0.value > $1.value }.map { (Self.shortModel($0.key), $0.value) }
    }

    var projectsRanked: [(name: String, cost: Double)] {
        byProject.sorted { $0.value > $1.value }.map { (Self.shortProject($0.key), $0.value) }
    }

    /// `claude-opus-5` reads as `opus-5` once you know they're all Claude.
    static func shortModel(_ id: String) -> String {
        id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
    }

    static func shortProject(_ path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }
}

struct DayUsage: Identifiable {
    let day: Date
    var totals: Totals

    var id: Date { day }
    var cost: Double { totals.cost }
}

struct UsageSnapshot {
    /// Ascending, gap-filled across the whole window so charts have no holes.
    var days: [DayUsage] = []
    /// Aggregate across the entire window.
    var window: Totals = Totals()
    var today: DayUsage
    /// Newest write to any transcript — the liveness signal for Auto keep-awake.
    var lastActivity: Date?
    /// Whether Claude is mid-turn or waiting on you.
    var activity: ClaudeActivity = .unknown
    var generatedAt: Date = .distantPast
    var scanDuration: TimeInterval = 0
    var filesScanned: Int = 0
    var transcriptsSkipped: Int = 0

    static func empty(day: Date = Calendar.current.startOfDay(for: Date())) -> UsageSnapshot {
        UsageSnapshot(today: DayUsage(day: day, totals: Totals()))
    }

    var hasScanned: Bool { generatedAt != .distantPast }

    var peakDay: DayUsage? { days.max { $0.cost < $1.cost } }

    var averageDailyCost: Double {
        days.isEmpty ? 0 : window.cost / Double(days.count)
    }

    func daysOver(limit: Double) -> Int {
        guard limit > 0 else { return 0 }
        return days.filter { $0.cost > limit }.count
    }
}
