import Foundation

/// Dollars per million tokens.
struct ModelRate: Equatable {
    let input: Double
    let output: Double
    /// Explicit cache-read rate, for models that don't follow the usual 0.1x input.
    var cacheRead: Double? = nil
}

/// Multipliers applied to a model's *input* rate for cached tokens.
enum CacheMultiplier {
    static let write5m = 1.25
    static let write1h = 2.0
    static let read = 0.1
}

enum PricedResult {
    case priced(Double)
    /// A real billable message on a model we have no rate for.
    case unpriced
    /// Not a billable message at all (synthetic records for interrupts, errors).
    case excluded
}

/// Public Anthropic API list rates. These are an *equivalent*, not an invoice —
/// see the caveats in the README before quoting a number at anyone.
struct PricingTable {
    var standard: [String: ModelRate]
    var fast: [String: ModelRate]

    /// Model ids with no billable identity. Excluded outright rather than counted
    /// as "unpriced", which would otherwise flag every interrupt as a gap.
    static let excluded: Set<String> = ["<synthetic>"]

    /// Claude Code sometimes records a bare tier name instead of a full model id.
    static let aliases: [String: String] = [
        "opus": "claude-opus-5",
        "sonnet": "claude-sonnet-5",
        "haiku": "claude-haiku-4-5",
        "fable": "claude-fable-5",
    ]

    static let builtin = PricingTable(
        standard: [
            "claude-fable-5":    ModelRate(input: 10, output: 50),
            "claude-fable-5-1":  ModelRate(input: 10, output: 50, cacheRead: 0.25),
            "claude-mythos-5":   ModelRate(input: 10, output: 50),
            "claude-opus-5-5":   ModelRate(input: 4,  output: 20, cacheRead: 0.20),
            "claude-opus-5":     ModelRate(input: 5,  output: 25),
            "claude-opus-4-8":   ModelRate(input: 5,  output: 25),
            "claude-opus-4-7":   ModelRate(input: 5,  output: 25),
            "claude-opus-4-6":   ModelRate(input: 5,  output: 25),
            "claude-opus-4-5":   ModelRate(input: 5,  output: 25),
            "claude-sonnet-5-5": ModelRate(input: 2,  output: 10),
            "claude-sonnet-5":   ModelRate(input: 2,  output: 10),
            "claude-sonnet-4-6": ModelRate(input: 3,  output: 15),
            "claude-sonnet-4-5": ModelRate(input: 3,  output: 15),
            "claude-haiku-4-5":  ModelRate(input: 1,  output: 5),
        ],
        // Fast mode on the Opus tier bills at premium rates.
        fast: [
            "claude-opus-5-5": ModelRate(input: 8,  output: 40, cacheRead: 0.40),
            "claude-opus-5":   ModelRate(input: 10, output: 50),
            "claude-opus-4-8": ModelRate(input: 10, output: 50),
        ]
    )

    /// Strip the `[1m]` context suffix and any trailing 8-digit date snapshot,
    /// then resolve bare tier aliases. `claude-haiku-4-5-20251001` -> `claude-haiku-4-5`.
    static func normalize(_ raw: String?) -> String? {
        guard var model = raw?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        model = model.replacingOccurrences(of: "[1m]", with: "")
            .trimmingCharacters(in: .whitespaces)

        var parts = model.split(separator: "-").map(String.init)
        if parts.count > 2, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
            model = parts.joined(separator: "-")
        }
        return aliases[model] ?? model
    }

    func rate(for model: String, fastMode: Bool) -> ModelRate? {
        if fastMode, let premium = fast[model] { return premium }
        return standard[model]
    }

    func price(model rawModel: String?, usage: TokenUsage) -> PricedResult {
        guard let model = PricingTable.normalize(rawModel) else { return .excluded }
        if PricingTable.excluded.contains(model) { return .excluded }
        guard let rate = rate(for: model, fastMode: usage.isFast) else { return .unpriced }

        let dollars = (
            Double(usage.input) * rate.input
            + Double(usage.output) * rate.output
            + Double(usage.cacheWrite5m) * rate.input * CacheMultiplier.write5m
            + Double(usage.cacheWrite1h) * rate.input * CacheMultiplier.write1h
            + Double(usage.cacheRead) * (rate.cacheRead ?? rate.input * CacheMultiplier.read)
        ) / 1_000_000

        return .priced(dollars)
    }
}

// MARK: - User overrides

extension PricingTable {
    static var overrideURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DoubleShot/pricing.json")
    }

    /// Built-in rates, with any user overrides merged on top. Rates drift as models
    /// are released or repriced, and editing a JSON file beats rebuilding the app.
    /// An optional third element sets an explicit cache-read rate.
    ///
    /// ```json
    /// { "standard": { "claude-opus-5": [5.0, 25.0], "claude-opus-5-5": [4.0, 20.0, 0.2] },
    ///   "fast":     { "claude-opus-5": [10.0, 50.0] } }
    /// ```
    static func load() -> PricingTable {
        var table = builtin
        guard let data = try? Data(contentsOf: overrideURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return table }

        func merge(_ key: String, into dict: inout [String: ModelRate]) {
            guard let raw = root[key] as? [String: Any] else { return }
            for (model, value) in raw {
                guard let rates = value as? [Any], (2...3).contains(rates.count),
                      let input = numeric(rates[0]), let output = numeric(rates[1])
                else { continue }
                let cacheRead = rates.count == 3 ? numeric(rates[2]) : nil
                dict[model] = ModelRate(input: input, output: output, cacheRead: cacheRead)
            }
        }

        merge("standard", into: &table.standard)
        merge("fast", into: &table.fast)
        return table
    }

    private static func numeric(_ any: Any) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
