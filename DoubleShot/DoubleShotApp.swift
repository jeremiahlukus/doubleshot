import SwiftUI

@main
struct DoubleShotApp: App {
    static let dashboardWindowID = "dashboard"

    @StateObject private var store = UsageStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            // A pre-rendered NSImage is the only way to keep colour in the menu bar;
            // see StatusBarIcon for why.
            Image(nsImage: store.statusImage)
                .onAppear {
                    appDelegate.store = store
                    store.start()
                }
        }
        // .window rather than .menu: a real NSMenu can't host the limit text field.
        .menuBarExtraStyle(.window)

        Window("DoubleShot", id: Self.dashboardWindowID) {
            DashboardView(store: store)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
