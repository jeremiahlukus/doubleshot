import Foundation
import AppKit
import Combine

enum SpendLevel {
    case ok, caution, warning, over

    static func forPercent(_ pct: Double) -> SpendLevel {
        switch pct {
        case ..<50: return .ok
        case ..<80: return .caution
        case ..<100: return .warning
        default: return .over
        }
    }
}

/// Owns the scan loop, the budget, threshold alerts, and the menu bar rendering.
///
/// Scanning happens on a serial background queue; everything published is
/// republished on the main queue.
final class UsageStore: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot = .empty()
    @Published private(set) var isScanning = false
    @Published private(set) var statusImage: NSImage = NSImage()
    @Published var inlineAlert: String?

    @Published private(set) var budget: Budget = .load()
    @Published var windowDays: Int = 30 {
        didSet {
            guard windowDays != oldValue else { return }
            refresh()
        }
    }

    let keepAwake = KeepAwakeManager()

    private let scanner = TranscriptScanner()
    private let notifier = BudgetNotifier()
    private let queue = DispatchQueue(label: "com.jparrack.doubleshot.scan", qos: .utility)
    private var refreshTimer: Timer?
    private var scanInFlight = false
    private var cancellables = Set<AnyCancellable>()

    /// Transcripts are appended constantly; incremental rescans are cheap.
    var refreshInterval: TimeInterval = 20

    init() {
        notifier.onFallback = { [weak self] message in
            self?.inlineAlert = message
        }
        notifier.requestAuthorizationIfNeeded()
        renderStatusImage()
        observeAppearanceChanges()

        // Nested ObservableObjects don't propagate, and the menu bar has to reflect
        // holding/armed state the moment it changes rather than on the next scan.
        for publisher in [keepAwake.objectWillChange, keepAwake.lid.objectWillChange] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.renderStatusImage() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Derived values

    var todayCost: Double { snapshot.today.cost }

    var percentOfLimit: Double {
        budget.dailyLimit > 0 ? todayCost / budget.dailyLimit * 100 : 0
    }

    var level: SpendLevel { SpendLevel.forPercent(percentOfLimit) }

    var progress: Double { min(max(percentOfLimit / 100, 0), 1) }

    var statusText: String {
        guard snapshot.hasScanned else { return "—" }
        return Defaults.showLimitInMenuBar
            ? "\(Money.precise(todayCost))/\(Money.string(budget.dailyLimit))"
            : Money.precise(todayCost)
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        // Auto-off deadlines and Auto-mode idling expire on wall-clock time, not on
        // scan results, so tick even when a scan is already running.
        keepAwake.tick()
        // The budget file is shared with the claude_cost statusline, so an edit made
        // outside the app needs to land here too — not just when the panel opens.
        reloadBudgetFromDisk()

        guard !scanInFlight else { return }
        scanInFlight = true
        isScanning = true

        let days = windowDays
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.scanner.scan(windowDays: days)
            DispatchQueue.main.async {
                self.scanInFlight = false
                self.isScanning = false
                self.snapshot = result
                self.keepAwake.update(lastActivity: result.lastActivity, activity: result.activity)
                self.notifier.evaluate(cost: result.today.cost, budget: self.budget)
                self.renderStatusImage()
            }
        }
    }

    // MARK: - Budget editing

    func setDailyLimit(_ raw: Double) {
        let limit = Budget.sanitize(limit: raw)
        guard limit != budget.dailyLimit else { return }
        budget.dailyLimit = limit
        persistBudget()
        // A raised limit should be able to alert again on the way back up.
        notifier.resetToday()
        notifier.evaluate(cost: todayCost, budget: budget)
        renderStatusImage()
    }

    func setThresholds(_ thresholds: [Int]) {
        let cleaned = thresholds.filter { $0 > 0 }.sorted()
        guard !cleaned.isEmpty, cleaned != budget.thresholds else { return }
        budget.thresholds = cleaned
        persistBudget()
    }

    private func persistBudget() {
        do {
            try budget.save()
        } catch {
            inlineAlert = "Couldn't save your limit to \(Budget.url.path): \(error.localizedDescription)"
        }
    }

    /// Pick up an edit made outside the app (the file is shared with the statusline).
    func reloadBudgetFromDisk() {
        let onDisk = Budget.load()
        guard onDisk != budget else { return }
        budget = onDisk
        renderStatusImage()
    }

    func reloadPricing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.scanner.pricing = .load()
            self.scanner.invalidate()
            let result = self.scanner.scan(windowDays: self.windowDays)
            DispatchQueue.main.async {
                self.snapshot = result
                self.renderStatusImage()
            }
        }
    }

    // MARK: - Menu bar rendering

    var menuBarStyle: MenuBarStyle {
        get { Defaults.menuBarStyle }
        set {
            guard newValue != Defaults.menuBarStyle else { return }
            Defaults.menuBarStyle = newValue
            renderStatusImage()
            objectWillChange.send()
        }
    }

    func renderStatusImage() {
        statusImage = StatusBarIcon.render(
            text: statusText,
            level: level,
            holdingAwake: keepAwake.isHolding,
            style: Defaults.menuBarStyle,
            lidArmed: keepAwake.lid.isArmed
        )
    }

    private func observeAppearanceChanges() {
        // Colours are baked into a non-template image, so a light/dark switch needs
        // a re-render rather than the system handling it for us.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderStatusImage()
        }
    }
}
