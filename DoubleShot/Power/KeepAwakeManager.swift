import Foundation
import IOKit.pwr_mgt

enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case off, on, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }
}

enum AutoOffDuration: Int, CaseIterable, Identifiable {
    case off = 0
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case twoHours = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .thirtyMinutes: return "30m"
        case .sixtyMinutes: return "60m"
        case .twoHours: return "2h"
        }
    }
}

/// Holds macOS power assertions so the machine won't sleep, either because you
/// asked (`.on`) or because Claude Code is mid-run (`.auto`).
///
/// Auto mode keys off recent writes to any transcript, which is what "a run is
/// happening" actually looks like on disk. It's a heuristic: a single long tool
/// call writes nothing while it runs, so `idleGrace` is deliberately generous.
final class KeepAwakeManager: ObservableObject {

    @Published private(set) var isHolding = false
    @Published private(set) var statusDetail: String?

    @Published var mode: KeepAwakeMode {
        didSet {
            guard mode != oldValue else { return }
            Defaults.keepAwakeMode = mode
            manualDeadline = nil
            reevaluate()
        }
    }

    @Published var autoOffDuration: AutoOffDuration {
        didSet {
            guard autoOffDuration != oldValue else { return }
            Defaults.autoOffDuration = autoOffDuration
            manualDeadline = nil
            reevaluate()
        }
    }

    /// Fallback for Auto mode when Claude's state can't be read from the transcript:
    /// how long after the last write to keep holding. Measured against 289k real gaps,
    /// 10 minutes covers 99.94% of mid-run quiet stretches.
    var idleGrace: TimeInterval = 10 * 60

    /// Backstop for a tool call that never returns. Without this, "hold while working"
    /// would keep the machine awake indefinitely on a hung command.
    var workingCap: TimeInterval = 45 * 60

    /// Lid-close sleep is a separate mechanism from power assertions; this extends
    /// whatever decision we just made to cover a closed lid.
    let lid = LidSleepController()

    private var displayAssertion: IOPMAssertionID?
    private var systemAssertion: IOPMAssertionID?
    private var lastActivity: Date?
    private var activity: ClaudeActivity = .unknown
    private var manualDeadline: Date?

    init() {
        mode = Defaults.keepAwakeMode
        autoOffDuration = Defaults.autoOffDuration
        lid.onEnabledChange = { [weak self] in self?.reevaluate() }
        reevaluate()
    }

    /// Feed in what the latest scan learned; drives Auto mode.
    func update(lastActivity: Date?, activity: ClaudeActivity) {
        self.lastActivity = lastActivity
        self.activity = activity
        reevaluate()
    }

    /// Called on a timer so manual auto-off and Auto-mode idling both expire on time.
    func tick() { reevaluate() }

    func shutdown() {
        // Order matters: lid sleep is global system state and must be restored even if
        // releasing assertions somehow fails.
        lid.shutdown()
        release()
    }

    // MARK: - Decision

    private func reevaluate() {
        decide()
        // Lid-close sleep follows the assertion decision: if we're keeping the machine
        // awake, and the user opted in, keep it awake with the lid shut too.
        lid.apply(shouldHold: isHolding)
    }

    private func decide() {
        switch mode {
        case .off:
            statusDetail = nil
            release()

        case .on:
            if autoOffDuration != .off {
                if manualDeadline == nil {
                    manualDeadline = Date().addingTimeInterval(TimeInterval(autoOffDuration.rawValue * 60))
                }
                if let deadline = manualDeadline, Date() >= deadline {
                    mode = .off  // didSet clears the deadline and releases
                    return
                }
                statusDetail = manualDeadline.map { "until \(Self.clock.string(from: $0))" }
            } else {
                manualDeadline = nil
                statusDetail = "held indefinitely"
            }
            hold()

        case .auto:
            manualDeadline = nil
            guard let last = lastActivity else {
                statusDetail = "no transcript activity"
                release()
                return
            }
            let idle = Date().timeIntervalSince(last)

            switch activity {
            case .working:
                // A long tool call writes nothing while it runs, so elapsed silence says
                // nothing about whether Claude is done — only the cap applies.
                if idle > workingCap {
                    statusDetail = "stalled \(Self.describe(idle)) — released"
                    release()
                } else {
                    statusDetail = idle < 90 ? "run active" : "working, quiet \(Self.describe(idle))"
                    hold()
                }

            case .waiting:
                // Releasing doesn't sleep the Mac, it just stops overriding the normal
                // idle rules — which still respect your keyboard and mouse.
                statusDetail = "waiting on you"
                release()

            case .unknown:
                if idle <= idleGrace {
                    statusDetail = "recent activity"
                    hold()
                } else {
                    statusDetail = "idle \(Self.describe(idle))"
                    release()
                }
            }
        }
    }

    // MARK: - Assertions

    private func hold() {
        guard displayAssertion == nil else { return }

        var display: IOPMAssertionID = 0
        var system: IOPMAssertionID = 0

        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DoubleShot: keep display awake" as CFString,
            &display
        )
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DoubleShot: keep system awake" as CFString,
            &system
        )

        guard displayResult == kIOReturnSuccess, systemResult == kIOReturnSuccess else {
            if displayResult == kIOReturnSuccess { IOPMAssertionRelease(display) }
            if systemResult == kIOReturnSuccess { IOPMAssertionRelease(system) }
            statusDetail = "could not take power assertion"
            return
        }

        displayAssertion = display
        systemAssertion = system
        isHolding = true
    }

    private func release() {
        if let display = displayAssertion { IOPMAssertionRelease(display) }
        if let system = systemAssertion { IOPMAssertionRelease(system) }
        displayAssertion = nil
        systemAssertion = nil
        isHolding = false
    }

    // MARK: - Formatting

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

/// Small typed wrapper over the handful of preferences we persist.
enum Defaults {
    private static let store = UserDefaults.standard

    static var keepAwakeMode: KeepAwakeMode {
        get { KeepAwakeMode(rawValue: store.string(forKey: "keepAwakeMode") ?? "") ?? .auto }
        set { store.set(newValue.rawValue, forKey: "keepAwakeMode") }
    }

    static var autoOffDuration: AutoOffDuration {
        get { AutoOffDuration(rawValue: store.integer(forKey: "autoOffDuration")) ?? .off }
        set { store.set(newValue.rawValue, forKey: "autoOffDuration") }
    }

    /// Defaults to `.adaptive`: a template image is the only thing that reliably
    /// contrasts with a menu bar whose background is your wallpaper, so colour is
    /// reserved for the pill, which brings its own background.
    /// Off by default — it changes global system state, so it must be opted into.
    static var lidModeEnabled: Bool {
        get { store.bool(forKey: "lidModeEnabled") }
        set { store.set(newValue, forKey: "lidModeEnabled") }
    }

    static var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: store.string(forKey: "menuBarStyle") ?? "") ?? .adaptive }
        set { store.set(newValue.rawValue, forKey: "menuBarStyle") }
    }

    static var showLimitInMenuBar: Bool {
        get { store.object(forKey: "showLimitInMenuBar") == nil ? true : store.bool(forKey: "showLimitInMenuBar") }
        set { store.set(newValue, forKey: "showLimitInMenuBar") }
    }

    static func firedThresholds(on day: String) -> Set<Int> {
        Set(store.array(forKey: "fired.\(day)") as? [Int] ?? [])
    }

    static func setFiredThresholds(_ values: Set<Int>, on day: String) {
        store.set(Array(values), forKey: "fired.\(day)")
    }

    /// Yesterday's alert state is noise; don't let it accumulate forever.
    static func pruneFiredThresholds(keeping day: String) {
        for key in store.dictionaryRepresentation().keys
        where key.hasPrefix("fired.") && key != "fired.\(day)" {
            store.removeObject(forKey: key)
        }
    }
}
