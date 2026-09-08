import SwiftUI
import Charts

/// The menu bar dropdown. Uses `.window` style rather than `.menu` because a real
/// menu can't host a text field — and editing the limit inline is the point.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @FocusState private var limitFocused: Bool
    @State private var launchAtLogin = LoginItemManager.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpendHeader(store: store, compact: true) { limitFocused = true }

            if let alert = store.inlineAlert {
                InlineAlert(message: alert) { store.inlineAlert = nil }
            }

            LimitEditor(store: store, focus: $limitFocused)

            Divider()

            Sparkline(days: Array(store.snapshot.days.suffix(14)), limit: store.budget.dailyLimit)
                .frame(height: 38)

            if !store.snapshot.today.totals.byModel.isEmpty {
                Divider()
                BreakdownList(rows: store.snapshot.today.totals.modelsRanked, limit: 3)
                if store.snapshot.today.totals.subagentCost > 0 {
                    Text("includes \(Money.precise(store.snapshot.today.totals.subagentCost)) from subagents")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            KeepAwakeControls(manager: store.keepAwake)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openWindow(id: DoubleShotApp.dashboardWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Dashboard", systemImage: "chart.bar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        LoginItemManager.setEnabled(newValue)
                    }
                ))
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Menu bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { store.menuBarStyle },
                        set: { store.menuBarStyle = $0 }
                    )) {
                        ForEach(MenuBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.top, 2)

                HStack {
                    Button("Refresh") { store.refresh() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") {
                        store.keepAwake.shutdown()
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
                }
                .font(.callout)
            }

            if store.snapshot.hasScanned {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(12)
        .frame(width: 292)
        .onAppear {
            store.reloadBudgetFromDisk()
            // The sudoers rule is typically installed while the app is already running,
            // so re-probe every time the panel opens rather than trusting launch state.
            store.keepAwake.lid.refreshAvailability()
            store.refresh()
        }
    }

    private var footnote: String {
        let unpriced = store.snapshot.today.totals.unpriced
        var parts = ["updated \(RelativeTime.string(store.snapshot.generatedAt))"]
        if unpriced > 0 { parts.append("\(unpriced) msg on unknown rates") }
        return parts.joined(separator: " · ")
    }
}

struct KeepAwakeControls: View {
    @ObservedObject var manager: KeepAwakeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Keep awake").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(manager.isHolding ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(manager.statusDetail ?? "not holding")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Picker("", selection: Binding(
                get: { manager.mode },
                set: { manager.mode = $0 }
            )) {
                ForEach(KeepAwakeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if manager.mode == .on {
                HStack {
                    Text("Auto-off").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { manager.autoOffDuration },
                        set: { manager.autoOffDuration = $0 }
                    )) {
                        ForEach(AutoOffDuration.allCases) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)
                }
            }

            if manager.mode == .auto {
                Text("Holds while Claude is mid-turn — through long tool calls — and releases as soon as it's waiting on you. 45-minute backstop if a tool hangs.")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LidModeControls(lid: manager.lid)
        }
    }
}

/// Lid-close sleep can't be held off with a power assertion, so this is opt-in and
/// needs a one-time privileged setup step. See LidSleepController.
struct LidModeControls: View {
    @ObservedObject var lid: LidSleepController
    @State private var copied = false

    /// The script ships inside the app bundle, so this works for anyone who installed
    /// DoubleShot rather than only from a local checkout.
    private static var setupCommand: String {
        if let path = Bundle.main.path(forResource: "enable-lid-mode", ofType: "sh") {
            return "sudo bash \"\(path)\""
        }
        return "sudo ./scripts/enable-lid-mode.sh"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 2)

            Toggle("Keep running with lid closed", isOn: Binding(
                get: { lid.isEnabled },
                set: { lid.isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(!lid.isAvailable)

            if !lid.isAvailable {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Needs a one-time setup step — it requires root to change lid-sleep behaviour.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button(copied ? "Copied — paste in Terminal" : "Copy setup command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.setupCommand, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                        Button("Re-check") { lid.refreshAvailability() }
                            .controlSize(.small)
                    }
                }
            } else if lid.isArmed {
                Label {
                    Text("Lid sleep is OFF — your Mac stays awake when closed. Releases when Claude goes idle, or after 2 hours.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            } else if lid.hitCap {
                Text("Hit the 2-hour lid-closed cap; lid sleep restored. Toggle off and on to re-arm.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if lid.isEnabled {
                Text("Armed. Lid sleep will be disabled while Claude is working.")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = lid.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BreakdownList: View {
    let rows: [(name: String, cost: Double)]
    var limit: Int = .max

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.prefix(limit)), id: \.name) { row in
                HStack {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Money.precise(row.cost))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if rows.count > limit {
                HStack {
                    Text("+ \(rows.count - limit) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }
}

/// Compact bar chart for the panel.
struct Sparkline: View {
    let days: [DayUsage]
    let limit: Double

    var body: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.day, unit: .day),
                y: .value("Spend", day.cost)
            )
            .foregroundStyle(day.cost > limit && limit > 0 ? Color.red.opacity(0.75) : Color.accentColor.opacity(0.65))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
        .overlay(alignment: .bottomLeading) {
            Text("last \(days.count) days")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }
}

struct InlineAlert: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 10
            ? "just now"
            : formatter.localizedString(for: date, relativeTo: Date())
    }
}
