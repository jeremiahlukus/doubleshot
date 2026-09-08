import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @FocusState private var limitFocused: Bool

    private static let ranges = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let alert = store.inlineAlert {
                    InlineAlert(message: alert) { store.inlineAlert = nil }
                }
                historySection
                kpiRow
                breakdowns
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            store.reloadBudgetFromDisk()
            store.keepAwake.lid.refreshAvailability()
            store.refresh()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                SpendHeader(store: store) { limitFocused = true }
                LimitEditor(store: store, focus: $limitFocused)
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                KeepAwakeControls(manager: store.keepAwake)
            }
            .frame(width: 220)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily spend").font(.headline)
                Spacer()
                Picker("", selection: Binding(
                    get: { store.windowDays },
                    set: { store.windowDays = $0 }
                )) {
                    ForEach(Self.ranges, id: \.self) { days in
                        Text("\(days)d").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Chart {
                ForEach(store.snapshot.days) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Spend", day.cost)
                    )
                    .foregroundStyle(barColor(for: day))
                }

                if store.budget.dailyLimit > 0 {
                    RuleMark(y: .value("Limit", store.budget.dailyLimit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("limit \(Money.string(store.budget.dailyLimit))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Money.string(amount))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xAxisStride)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 200)
        }
    }

    private var kpiRow: some View {
        HStack(spacing: 12) {
            KPITile(label: "Window total", value: Money.precise(store.snapshot.window.cost))
            KPITile(label: "Average / day", value: Money.precise(store.snapshot.averageDailyCost))
            KPITile(label: "Peak day", value: Money.precise(store.snapshot.peakDay?.cost ?? 0),
                    detail: store.snapshot.peakDay.map { Self.shortDate.string(from: $0.day) })
            KPITile(label: "Days over limit",
                    value: "\(store.snapshot.daysOver(limit: store.budget.dailyLimit))",
                    detail: "of \(store.snapshot.days.count)")
        }
    }

    private var breakdowns: some View {
        HStack(alignment: .top, spacing: 16) {
            BreakdownCard(
                title: "By model",
                subtitle: "last \(store.windowDays) days",
                rows: store.snapshot.window.modelsRanked,
                total: store.snapshot.window.cost
            )
            BreakdownCard(
                title: "By project",
                subtitle: "last \(store.windowDays) days",
                rows: store.snapshot.window.projectsRanked,
                total: store.snapshot.window.cost
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                if store.isScanning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Text(scanSummary)
                Spacer()
                Button("Refresh") { store.refresh() }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("API-rate equivalents from local transcripts, not an invoice. `/usage` is authoritative for plan limits and actual credit consumption. Usage from other machines, the web app, or the desktop app isn't counted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if store.snapshot.window.subagentCost > 0 {
                Text("\(Money.precise(store.snapshot.window.subagentCost)) of this window came from subagent transcripts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private var scanSummary: String {
        guard store.snapshot.hasScanned else { return "Scanning transcripts…" }
        var parts = [
            "\(store.snapshot.window.responses) responses",
            "updated \(RelativeTime.string(store.snapshot.generatedAt))",
            String(format: "%.0fms scan", store.snapshot.scanDuration * 1000),
        ]
        if store.snapshot.window.unpriced > 0 {
            parts.append("\(store.snapshot.window.unpriced) on unknown rates")
        }
        return parts.joined(separator: " · ")
    }

    private var xAxisStride: Int {
        switch store.windowDays {
        case ...7: return 1
        case ...30: return 5
        default: return 14
        }
    }

    private func barColor(for day: DayUsage) -> Color {
        guard store.budget.dailyLimit > 0 else { return .accentColor }
        let level = SpendLevel.forPercent(day.cost / store.budget.dailyLimit * 100)
        return Color(nsColor: StatusBarIcon.color(for: level))
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

struct KPITile: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct BreakdownCard: View {
    let title: String
    let subtitle: String
    let rows: [(name: String, cost: Double)]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }

            if rows.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows.prefix(8), id: \.name) { row in
                        VStack(alignment: .leading, spacing: 3) {
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

                            ProgressBar(
                                progress: total > 0 ? row.cost / total : 0,
                                tint: Color.accentColor.opacity(0.55)
                            )
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
