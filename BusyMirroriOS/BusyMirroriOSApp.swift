import SwiftUI
import BackgroundTasks

// ponytail: BGAppRefreshTask is best-effort only — iOS decides if/when it
// runs, no delivery guarantee. Foreground sync + pull via ContentView is
// the reliable path; this is a supplement, not a replacement.
private let refreshTaskID = "com.cqrenet.BusyMirroriOS.refresh"

@main
struct BusyMirroriOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            handleAppRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                scheduleAppRefresh()
            }
        }
    }
}

private func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    try? BGTaskScheduler.shared.submit(request)
}

private func handleAppRefresh(_ task: BGAppRefreshTask) {
    scheduleAppRefresh()

    let runTask = Task { @MainActor in
        await RouteStore.shared.runAll()
        task.setTaskCompleted(success: true)
    }
    task.expirationHandler = { runTask.cancel() }
}
