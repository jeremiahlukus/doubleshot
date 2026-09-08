import Foundation

/// Keeps the Mac running with the lid closed.
///
/// Power assertions can't do this. `NoIdleSleep`/`NoDisplaySleep` only defer *idle*
/// sleep; closing the lid is a separate forced path in macOS, and `caffeinate` doesn't
/// stop it either. The only thing that does is `pmset -a disablesleep 1`, which needs
/// root — hence the narrow sudoers rule installed by `scripts/enable-lid-mode.sh`.
///
/// This flips **global system state**, so it is treated with more care than an
/// assertion, which dies with the process:
///
/// - A marker file is written *before* arming. If the app dies while armed, the next
///   launch sees the marker and restores lid sleep immediately.
/// - A hard cap disarms after `maxDuration` regardless of what Claude appears to be
///   doing, so a hung tool call can't hold a laptop awake in a bag all night.
/// - Arming is always visible in the menu bar.
final class LidSleepController: ObservableObject {

    /// Lid sleep is currently disabled by us.
    @Published private(set) var isArmed = false
    /// Whether the passwordless `pmset` rule is installed.
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String?
    /// True once the cap has fired, until Claude next goes idle.
    @Published private(set) var hitCap = false

    /// Set by KeepAwakeManager so ticking the checkbox arms straight away instead of
    /// waiting for the next scan tick — a 20-second delay reads as "it didn't work".
    var onEnabledChange: (() -> Void)?

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            Defaults.lidModeEnabled = isEnabled
            if !isEnabled { disarm() }
            onEnabledChange?()
        }
    }

    /// Backstop against cooking a closed laptop. Independent of the keep-awake
    /// working cap — this one is about thermals and battery, not run length.
    var maxDuration: TimeInterval = 2 * 3600

    private var armedAt: Date?

    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"

    static var markerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DoubleShot/lid-armed")
    }

    init() {
        isEnabled = Defaults.lidModeEnabled
        recoverIfPreviouslyArmed()
        refreshAvailability()
    }

    // MARK: - Lifecycle

    /// If a previous run died while armed, the system is still not sleeping on lid
    /// close. Put it back before doing anything else.
    private func recoverIfPreviouslyArmed() {
        guard FileManager.default.fileExists(atPath: Self.markerURL.path) else { return }
        NSLog("DoubleShot: found lid-armed marker from a previous run; restoring lid sleep")
        _ = run(disableSleep: false)
        clearMarker()
    }

    /// Asks sudo whether the command is permitted, without running it. Read-only, so
    /// it's safe to call whenever the UI appears — which matters, because installing
    /// the sudoers rule happens while the app is already running.
    func refreshAvailability() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudo)
        process.arguments = ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            isAvailable = false
            return
        }
        // Drain before waiting so a chatty sudo can't fill the pipe and deadlock.
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        isAvailable = process.terminationStatus == 0
        if isAvailable { lastError = nil }
    }

    /// Driven by KeepAwakeManager: `shouldHold` is whatever the assertion decision was.
    func apply(shouldHold: Bool) {
        guard isEnabled, isAvailable else {
            if isArmed { disarm() }
            return
        }

        guard shouldHold else {
            // Claude went idle, so the cap is allowed to reset.
            hitCap = false
            if isArmed { disarm() }
            return
        }

        if let armedAt, Date().timeIntervalSince(armedAt) > maxDuration {
            hitCap = true
            disarm()
            return
        }
        guard !hitCap else { return }

        arm()
    }

    func shutdown() {
        disarm()
    }

    // MARK: - Arming

    private func arm() {
        guard !isArmed else { return }
        // Marker first: a crash between here and the pmset call leaves a stale marker,
        // which is harmless. The reverse order could leave lid sleep off with nothing
        // recording that we did it.
        writeMarker()
        let result = run(disableSleep: true)
        guard result.ok else {
            clearMarker()
            lastError = result.message ?? "Could not disable lid sleep."
            isAvailable = false
            return
        }
        armedAt = Date()
        isArmed = true
        lastError = nil
    }

    private func disarm() {
        guard isArmed || FileManager.default.fileExists(atPath: Self.markerURL.path) else {
            armedAt = nil
            return
        }
        let result = run(disableSleep: false)
        if !result.ok {
            // Leave the marker in place so the next launch tries again.
            lastError = result.message ?? "Could not restore lid sleep."
            return
        }
        clearMarker()
        armedAt = nil
        isArmed = false
    }

    var armedDuration: TimeInterval? {
        armedAt.map { Date().timeIntervalSince($0) }
    }

    // MARK: - Plumbing

    private func run(disableSleep: Bool) -> (ok: Bool, message: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudo)
        // -n never prompts: without the sudoers rule this fails immediately rather
        // than hanging an accessory app on an invisible password prompt.
        process.arguments = ["-n", Self.pmset, "-a", "disablesleep", disableSleep ? "1" : "0"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output?.isEmpty == false ? output : nil)
    }

    private func writeMarker() {
        try? FileManager.default.createDirectory(
            at: Self.markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(Date().description.utf8).write(to: Self.markerURL, options: .atomic)
    }

    private func clearMarker() {
        try? FileManager.default.removeItem(at: Self.markerURL)
    }
}
