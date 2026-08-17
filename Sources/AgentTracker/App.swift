import SwiftUI

@main
struct AgentTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    /// Mirrors the panel's tab selection so the menu bar icon follows it.
    @AppStorage(MenuTab.storageKey) private var selectedTab: MenuTab = .claude

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Image(systemName: selectedTab.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        // (The bundled .app also sets LSUIElement; this covers `swift run`.)
        NSApp.setActivationPolicy(.accessory)
    }
}
