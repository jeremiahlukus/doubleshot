import Foundation

/// Walks `~/.claude/projects` and prices every assistant response it finds.
///
/// Two things this does that a naive scan doesn't:
///
/// - **Recurses.** Subagent transcripts live at `<project>/<session>/subagents/agent-*.jsonl`,
///   a level deeper than session transcripts. A `*/*.jsonl` glob misses them entirely,
///   which silently drops all subagent fan-out — one of the largest cost drivers there is.
/// - **Reads incrementally.** Transcripts are append-only, so after the first pass each
///   refresh only parses bytes appended since last time. A file that shrank was rewritten
///   (compaction) and gets re-read from the top.
///
/// Not thread-safe: drive it from a single serial queue.
final class TranscriptScanner {

    private struct FileState {
        var size: UInt64
        /// Byte offset through which we've parsed complete lines.
        var offset: UInt64
        var entries: [UsageEntry]
    }

    let root: URL
    var pricing: PricingTable

    private var cache: [String: FileState] = [:]
    private var cachedWindowStart: Date?
    private let calendar = Calendar.current
    private let decoder = JSONDecoder()

    init(root: URL? = nil, pricing: PricingTable = .load()) {
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        self.pricing = pricing
    }

    /// Drop all cached parses. Use after a pricing change so costs are recomputed.
    func invalidate() {
        cache.removeAll()
        cachedWindowStart = nil
    }

    func scan(windowDays: Int) -> UsageSnapshot {
        let started = Date()
        let today = calendar.startOfDay(for: started)
        let windowStart = calendar.date(byAdding: .day, value: -(max(windowDays, 1) - 1), to: today) ?? today

        // Widening the window needs data we previously pruned.
        if let cached = cachedWindowStart, windowStart < cached {
            invalidate()
        }
        cachedWindowStart = windowStart

        var seenPaths = Set<String>()
        var newestWrite: Date?
        var stamps: [(path: String, modified: Date)] = []
        var filesScanned = 0
        var skipped = 0

        for file in transcriptFiles() {
            let path = file.path
            seenPaths.insert(path)

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value
            else { continue }
            let modified = (attrs[.modificationDate] as? Date) ?? .distantPast

            if newestWrite == nil || modified > newestWrite! { newestWrite = modified }
            stamps.append((path: path, modified: modified))

            // Every write to this file predates the window, so nothing in it can land
            // inside the window. Safe to skip without opening it.
            if modified < windowStart, cache[path] == nil {
                skipped += 1
                continue
            }

            var state = cache[path] ?? FileState(size: 0, offset: 0, entries: [])
            if size < state.size {
                state = FileState(size: 0, offset: 0, entries: [])  // rewritten
            }
            if size == state.size, cache[path] != nil {
                continue  // unchanged since last scan
            }

            let isSubagent = path.contains("/subagents/")
            filesScanned += 1
            var appended: [UsageEntry] = []

            let endOffset = autoreleasepool {
                LineReader.forEachLine(path: path, from: state.offset) { line, lineIndex in
                    guard let entry = self.entry(from: line,
                                                 path: path,
                                                 lineIndex: lineIndex,
                                                 isSubagent: isSubagent)
                    else { return }
                    appended.append(entry)
                }
            }

            state.entries.append(contentsOf: appended)
            state.offset = endOffset
            state.size = size
            cache[path] = state
        }

        // Forget files that were deleted, and entries that fell out of the window.
        for path in cache.keys where !seenPaths.contains(path) {
            cache.removeValue(forKey: path)
        }
        for (path, var state) in cache {
            let kept = state.entries.filter { $0.day >= windowStart }
            if kept.count != state.entries.count {
                state.entries = kept
                cache[path] = state
            }
        }

        var snapshot = aggregate(windowStart: windowStart, today: today)
        snapshot.lastActivity = newestWrite
        snapshot.activity = detectActivity(stamps: stamps)
        snapshot.generatedAt = Date()
        snapshot.scanDuration = Date().timeIntervalSince(started)
        snapshot.filesScanned = filesScanned
        snapshot.transcriptsSkipped = skipped
        return snapshot
    }

    // MARK: - Activity state

    /// Other transcripts written within this much of the newest one are considered part
    /// of the same live run.
    private static let cohortWindow: TimeInterval = 120
    private static let maxActivityFiles = 4
    /// Comfortably above the largest single record observed (~0.6 MB).
    private static let tailBytes = 2 << 20
    private static let tailRecords = 40

    /// Decide whether Claude is mid-turn from the tail of the live transcripts.
    ///
    /// Deliberately *not* filtered by "recent", because the whole point is to keep
    /// holding through a 40-minute tool call — during which nothing is written at all.
    private func detectActivity(stamps: [(path: String, modified: Date)]) -> ClaudeActivity {
        guard let newest = stamps.max(by: { $0.modified < $1.modified }) else { return .unknown }

        // A subagent that just finished doesn't mean its parent is idle, so look at every
        // transcript written at about the same time and let "working" win.
        let cohort = stamps
            .filter { newest.modified.timeIntervalSince($0.modified) <= Self.cohortWindow }
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxActivityFiles)

        var sawWaiting = false
        for file in cohort {
            switch classifyTail(path: file.path) {
            case .working: return .working
            case .waiting: sawWaiting = true
            case .unknown: continue
            }
        }
        return sawWaiting ? .waiting : .unknown
    }

    /// Walk backwards through the last records until one carries a usable state.
    private func classifyTail(path: String) -> ClaudeActivity {
        let lines = LineReader.tailLines(path: path, maxBytes: Self.tailBytes, limit: Self.tailRecords)
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            // A tool result is written the moment a tool returns; Claude is about to act on it.
            if object["toolUseResult"] != nil { return .working }

            switch object["type"] as? String {
            case "assistant":
                let message = object["message"] as? [String: Any]
                let stop = message?["stop_reason"] as? String
                // `tool_use` means a tool is running right now. `end_turn` means it was
                // handed back to you. A missing stop_reason is a turn still in flight,
                // so err towards working — a false "waiting" drops the assertion mid-run,
                // which is the exact failure this replaces.
                return (stop == "end_turn" || stop == "stop_sequence") ? .waiting : .working
            case "user":
                // A human message just landed, so Claude is about to start.
                return .working
            default:
                // system / attachment / queue-operation records carry no turn state.
                continue
            }
        }
        return .unknown
    }

    // MARK: - Parsing

    private func entry(from line: Data, path: String, lineIndex: Int, isSubagent: Bool) -> UsageEntry? {
        guard let record = try? decoder.decode(TranscriptRecord.self, from: line),
              record.type == "assistant",
              let usage = record.message?.usage,
              let stamp = record.timestamp,
              let when = ISO8601.parse(stamp)
        else { return nil }

        let priced = pricing.price(model: record.message?.model, usage: usage)
        if case .excluded = priced { return nil }

        var cost = 0.0
        var unpriced = false
        switch priced {
        case .priced(let value): cost = value
        case .unpriced: unpriced = true
        case .excluded: return nil
        }

        // The same API response shows up in several transcripts after resumed
        // sessions, sidechain copies and compaction rewrites. Dedup on the request
        // identity; with no id at all, stay unique so we never drop a real response.
        let model = PricingTable.normalize(record.message?.model) ?? "unknown"
        let identity = record.requestId ?? record.message?.id
        let dedupKey = identity.map { "\($0)|\(model)|\(usage.output)" } ?? "\(path)#\(lineIndex)"

        return UsageEntry(
            dedupKey: dedupKey,
            day: calendar.startOfDay(for: when),
            timestamp: when,
            model: model,
            projectPath: record.cwd ?? "unknown",
            cost: cost,
            tokens: usage.total,
            isSubagent: isSubagent,
            unpriced: unpriced
        )
    }

    private func aggregate(windowStart: Date, today: Date) -> UsageSnapshot {
        var seen = Set<String>()
        var byDay: [Date: Totals] = [:]
        var window = Totals()

        for state in cache.values {
            for entry in state.entries where entry.day >= windowStart {
                guard seen.insert(entry.dedupKey).inserted else { continue }
                byDay[entry.day, default: Totals()].add(entry)
                window.add(entry)
            }
        }

        var days: [DayUsage] = []
        var cursor = windowStart
        while cursor <= today {
            days.append(DayUsage(day: cursor, totals: byDay[cursor] ?? Totals()))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var snapshot = UsageSnapshot.empty(day: today)
        snapshot.days = days
        snapshot.window = window
        snapshot.today = DayUsage(day: today, totals: byDay[today] ?? Totals())
        return snapshot
    }

    private func transcriptFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            found.append(url)
        }
        return found
    }
}

// MARK: - Helpers

/// Streams a file's newline-delimited records without loading it into memory.
enum LineReader {
    private static let chunkSize = 1 << 20
    /// Cheap pre-filter: skip JSON parsing for lines that can't carry a usage block.
    private static let usageMarker = Data("\"usage\"".utf8)

    /// Calls `body` for each complete line starting at `from`, and returns the offset
    /// through which complete lines were consumed. A partially written trailing line
    /// leaves the offset behind it, so the next pass picks it up once finished.
    @discardableResult
    static func forEachLine(path: String, from offset: UInt64, _ body: (Data, Int) -> Void) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }

        var consumed = offset
        var lineIndex = 0
        var buffer = Data()

        // One pool per chunk, not per file. Each `read` hands back an autoreleased
        // Data, so a pool that spans the whole file retains every chunk of it — on a
        // 1 GB transcript that alone was ~1 GB of peak RSS.
        var reachedEnd = false
        while !reachedEnd {
            autoreleasepool {
                let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
                guard let chunk, !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                buffer.append(chunk)

                var searchFrom = buffer.startIndex
                while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
                    if newline > searchFrom {
                        let line = buffer.subdata(in: searchFrom..<newline)
                        if line.range(of: usageMarker) != nil {
                            // Individual lines reach ~0.6 MB; decoding one churns through
                            // enough temporaries to be worth its own pool.
                            autoreleasepool { body(line, lineIndex) }
                        }
                    }
                    consumed += UInt64(newline - searchFrom + 1)
                    lineIndex += 1
                    searchFrom = newline + 1
                }
                if searchFrom > buffer.startIndex {
                    buffer.removeSubrange(buffer.startIndex..<searchFrom)
                }
            }
        }
        return consumed
    }

    /// The last complete records in a file, oldest-first, reading at most `maxBytes`
    /// from the end. Returns empty rather than guessing if the window lands mid-record.
    static func tailLines(path: String, maxBytes: Int, limit: Int) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }

        let take = UInt64(min(Int(size), maxBytes))
        do { try handle.seek(toOffset: size - take) } catch { return [] }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var start = data.startIndex
        // Reading from the end usually cuts into a record; drop that partial first line.
        if take < size {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return [] }
            start = firstNewline + 1
        }

        var lines: [Data] = []
        var searchFrom = start
        while let newline = data[searchFrom...].firstIndex(of: 0x0A) {
            if newline > searchFrom { lines.append(data.subdata(in: searchFrom..<newline)) }
            searchFrom = newline + 1
        }
        // A transcript being written right now has no trailing newline yet.
        if searchFrom < data.endIndex {
            lines.append(data.subdata(in: searchFrom..<data.endIndex))
        }
        return Array(lines.suffix(limit))
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Transcript stamps are UTC, with or without fractional seconds.
    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
