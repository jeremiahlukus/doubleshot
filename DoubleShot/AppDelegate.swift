import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: UsageStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no window on launch.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Power assertions outlive the process if we don't hand them back.
    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        store?.keepAwake.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
