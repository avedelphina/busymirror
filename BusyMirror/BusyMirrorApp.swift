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

        // A plain Window rather than a Settings scene: this was originally
        // required because the app was LSUIElement (accessory) and got no
        // standard app menu for Cmd+,/SettingsLink to hook into. Now that
        // it's a standard app that menu exists, but openWindow(id:) already
        // works reliably (same mechanism as the main window) so there's no
        // reason to switch back.
        Window("Preferences", id: BusyMirrorSceneID.preferencesWindow) {
            PreferencesView()
                .environmentObject(appController)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentSize)
    }
}
