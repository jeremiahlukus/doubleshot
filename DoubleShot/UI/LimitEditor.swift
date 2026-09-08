import SwiftUI

/// Editable daily limit: type a number, or hit a preset.
///
/// Committing writes through to `~/.claude/usage-budget.json`, so the limit you set
/// here is the same one the `claude_cost` statusline reads.
struct LimitEditor: View {
    @ObservedObject var store: UsageStore
    /// Owned by the caller so the header's limit can act as a shortcut into this field.
    var focus: FocusState<Bool>.Binding
    var showPresets = true

    @State private var draft: String = ""

    private var focused: Bool { focus.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Daily limit")
                    .foregroundStyle(.secondary)

                HStack(spacing: 2) {
                    Text("$").foregroundStyle(.secondary)
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .frame(width: 58)
                        .focused(focus)
                        .onSubmit(commit)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(focused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                )

                if focused {
                    Button("Set", action: commit)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if showPresets {
                HStack(spacing: 4) {
                    ForEach(Budget.presets, id: \.self) { preset in
                        Button(Money.string(preset)) {
                            focus.wrappedValue = false
                            store.setDailyLimit(preset)
                            draft = Self.format(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(store.budget.dailyLimit == preset ? .accentColor : .secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        // Seed the field, and keep it in step with edits made elsewhere — but never
        // yank the text out from under someone mid-type.
        .onAppear { syncDraft() }
        .task(id: store.budget.dailyLimit) { syncDraft() }
    }

    private func syncDraft() {
        guard !focused else { return }
        draft = Self.format(store.budget.dailyLimit)
    }

    private func commit() {
        let cleaned = draft
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)

        if let value = Double(cleaned), value > 0 {
            store.setDailyLimit(value)
        }
        // Reflect what was actually stored, including clamping.
        draft = Self.format(store.budget.dailyLimit)
        focus.wrappedValue = false
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

/// The `$13.47 / $50   27%` header, with the limit as a shortcut into editing it.
struct SpendHeader: View {
    @ObservedObject var store: UsageStore
    var compact = false
    var onTapLimit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.snapshot.hasScanned ? Money.precise(store.todayCost) : "—")
                    .font(.system(size: compact ? 22 : 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)

                Text("/")
                    .font(.system(size: compact ? 15 : 19))
                    .foregroundStyle(.tertiary)

                Button(Money.string(store.budget.dailyLimit)) {
                    onTapLimit?()
                }
                .buttonStyle(.plain)
                .font(.system(size: compact ? 15 : 19, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Click to change your daily limit")

                Spacer(minLength: 8)

                Text(store.snapshot.hasScanned ? "\(Int(store.percentOfLimit.rounded()))%" : "")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            ProgressBar(progress: store.progress, tint: tint)
                .frame(height: compact ? 6 : 8)

            HStack(spacing: 6) {
                Text("today, API-rate equivalent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if store.isScanning && !store.snapshot.hasScanned {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("scanning transcripts…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var tint: Color { Color(nsColor: StatusBarIcon.color(for: store.level)) }
}

struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geo.size.width * progress, progress > 0 ? 3 : 0))
            }
        }
    }
}
