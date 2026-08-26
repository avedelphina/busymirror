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

        // A plain Window (not a Settings scene) — LSUIElement (accessory)
        // apps don't get the standard app menu, so Cmd+, / the automatic
        // "Settings…" command has no menu to live in and SettingsLink has
        // nothing reliable to trigger. openWindow(id:) is the same mechanism
        // that already reliably opens the main window from the menu bar, so
        // reuse it here instead.
        Window("Preferences", id: BusyMirrorSceneID.preferencesWindow) {
            PreferencesView()
                .environmentObject(appController)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentSize)
    }
}
