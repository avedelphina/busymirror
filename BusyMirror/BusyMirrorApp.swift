import SwiftUI

@main
struct BusyMirrorApp: App {
    @StateObject private var appController = BusyMirrorAppController()

    private var menuBarIcon: String {
        if appController.isSyncing { return "arrow.triangle.2.circlepath.circle.fill" }
        if appController.lastRunFailed { return "exclamationmark.triangle.fill" }
        return "calendar.badge.clock"
    }

    var body: some Scene {
        Window("BusyMirror", id: BusyMirrorSceneID.mainWindow) {
            ContentView()
                .environmentObject(appController)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra("BusyMirror", systemImage: menuBarIcon) {
            BusyMirrorMenuBarView()
                .environmentObject(appController)
        }

        // A real Settings scene: now that the app is standard (not
        // LSUIElement), this gets the conventional Cmd+, and a "Preferences…"
        // item in the app's own menu for free — the location people actually
        // look, unlike a plain Window which only opens from wherever we
        // explicitly put a button for it.
        Settings {
            PreferencesView()
                .environmentObject(appController)
        }
    }
}
