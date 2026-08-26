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

        Settings {
            PreferencesView()
                .environmentObject(appController)
        }
    }
}
