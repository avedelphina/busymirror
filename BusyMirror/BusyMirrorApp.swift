import SwiftUI

@main
struct BusyMirrorApp: App {
    @StateObject private var appController = BusyMirrorAppController()

    var body: some Scene {
        Window("BusyMirror", id: BusyMirrorSceneID.mainWindow) {
            ContentView()
                .environmentObject(appController)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra("BusyMirror", systemImage: appController.isSyncing ? "arrow.triangle.2.circlepath.circle.fill" : "calendar.badge.clock") {
            BusyMirrorMenuBarView()
                .environmentObject(appController)
        }
    }
}
