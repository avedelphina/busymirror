import SwiftUI
import AppKit

enum BusyMirrorSceneID {
    static let mainWindow = "main-window"
}

@MainActor
final class BusyMirrorAppController: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var hasPendingSyncRequest = false
    @Published private(set) var syncRequestToken = UUID()
    @Published private(set) var isMainWindowVisible = false

    func requestSync() {
        hasPendingSyncRequest = true
        syncRequestToken = UUID()
    }

    func clearPendingSyncRequest() {
        hasPendingSyncRequest = false
    }

    func setSyncing(_ syncing: Bool) {
        isSyncing = syncing
    }

    func setMainWindowVisible(_ visible: Bool) {
        isMainWindowVisible = visible
    }

    func openMainWindow(using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: BusyMirrorSceneID.mainWindow)
    }
}

struct BusyMirrorMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appController: BusyMirrorAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BusyMirror")
                .font(.headline)

            Text(appController.isSyncing ? "Sync in progress." : "Use your saved routes or current selection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button(appController.isSyncing ? "Syncing…" : "Sync Now") {
                let shouldOpenWindow = !appController.isMainWindowVisible
                appController.requestSync()
                if shouldOpenWindow {
                    appController.openMainWindow(using: openWindow)
                }
            }
            .disabled(appController.isSyncing)

            Button("Open BusyMirror") {
                appController.openMainWindow(using: openWindow)
            }

            Divider()

            Button("Quit BusyMirror") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}
