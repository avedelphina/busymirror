import SwiftUI
import AppKit
import EventKit
import ServiceManagement

enum BusyMirrorSceneID {
    static let mainWindow = "main-window"
}

@MainActor
final class BusyMirrorAppController: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var hasPendingSyncRequest = false
    @Published private(set) var syncRequestToken = UUID()
    @Published private(set) var isMainWindowVisible = false
    @Published private(set) var lastRunFailed = false
    @Published private(set) var autoSyncArmed = false

    init() {
        refreshLastRunStatus()
    }

    /// Re-reads the shared lastRun* UserDefaults keys. Call after any run —
    /// interactive, CLI, or auto-sync — writes them, so the menu bar icon and
    /// dropdown reflect the outcome regardless of which path produced it.
    func refreshLastRunStatus() {
        guard let atISO = UserDefaults.standard.string(forKey: "lastRunAtISO"), !atISO.isEmpty else {
            lastRunFailed = false
            return
        }
        lastRunFailed = (UserDefaults.standard.object(forKey: "lastRunOK") as? Bool) == false
    }

    /// Human-readable "last sync" line for the menu bar dropdown. Computed on
    /// demand (not published) since the dropdown's content is rebuilt each
    /// time it's opened.
    var lastRunStatusText: String {
        guard let atISO = UserDefaults.standard.string(forKey: "lastRunAtISO"), !atISO.isEmpty,
              let date = ISO8601DateFormatter().date(from: atISO) else {
            return "No sync yet."
        }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        let ok = (UserDefaults.standard.object(forKey: "lastRunOK") as? Bool) != false
        return ok ? "Last sync: \(relative)" : "Last sync failed: \(relative)"
    }

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

    // MARK: - Event-driven background sync
    //
    // Owned here (not by ContentView) because this controller lives for the
    // whole process, independent of the main window's lifecycle. ContentView's
    // own EKEventStoreChanged observer is torn down in .onDisappear when the
    // window closes — fine for keeping the UI's calendar list fresh while
    // open, but useless for background operation, which is the entire point
    // of replacing the old hourly launchd poll. This runs regardless of
    // whether the window is open, closed, or never opened this session.

    private let backgroundStore = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    private let settingsDefaultsKey = "settings.v2"
    private let legacyRoutesDefaultsKey = "routes.v1"
    private let launchAgentLabel = "com.cqrenet.BusyMirror.saved-routes"

    private var launchAgentURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("LaunchAgents/\(launchAgentLabel).plist", isDirectory: false)
    }

    /// Call once at app launch. Only activates if calendar access has already
    /// been granted in a prior session — never prompts on its own, since a
    /// permission dialog with no window open would be confusing. First-run
    /// consent stays ContentView's job.
    func bootstrapBackgroundSync() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = status == .fullAccess
        } else {
            hasAccess = status == .authorized
        }
        guard hasAccess else { return }
        armAutoSyncIfPossible()
    }

    /// Re-check whether auto-sync should activate. Safe to call repeatedly
    /// (e.g. from ContentView whenever the saved routes list changes) — it
    /// only does anything the first time routes go from empty to non-empty.
    func armAutoSyncIfPossible() {
        guard !autoSyncArmed else { return }
        guard !loadRoutesFromDefaults().isEmpty else { return }
        autoSyncArmed = true

        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
            AppLogStore.append("[auto-sync] Registered as login item.")
        }
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            removeLegacyLaunchdSchedule()
        }
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: backgroundStore, queue: .main
            ) { [weak self] _ in
                self?.scheduleAutoSync(reason: "calendar changed")
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.scheduleAutoSync(reason: "system woke from sleep")
            }
        }
        if fallbackTask == nil {
            fallbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    self?.scheduleAutoSync(reason: "periodic fallback check")
                }
            }
        }
        AppLogStore.append("[auto-sync] Armed: watching for calendar changes.")
    }

    private func removeLegacyLaunchdSchedule() {
        let domain = "gui/\(getuid())"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", domain, launchAgentURL.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: launchAgentURL)
        AppLogStore.append("[auto-sync] Removed launchd schedule (superseded by change-driven sync).")
    }

    /// Debounces bursts of EKEventStoreChanged notifications into one sync.
    private func scheduleAutoSync(reason: String) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.runAutoSync(reason: reason)
        }
    }

    private func loadRoutesFromDefaults() -> [Route] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: settingsDefaultsKey),
           let snap = try? JSONDecoder().decode(ContentView.SettingsPayload.self, from: data) {
            return snap.routes
        }
        if let legacyData = defaults.data(forKey: legacyRoutesDefaultsKey),
           let routes = try? JSONDecoder().decode([Route].self, from: legacyData) {
            return routes
        }
        return []
    }

    private func runAutoSync(reason: String) async {
        guard !isSyncing else { return }
        let routes = loadRoutesFromDefaults()
        guard !routes.isEmpty else { return }

        guard let snap = UserDefaults.standard.data(forKey: settingsDefaultsKey),
              let settings = try? JSONDecoder().decode(ContentView.SettingsPayload.self, from: snap) else {
            return
        }

        setSyncing(true)
        AppLogStore.append("[auto-sync] Triggered by \(reason).")
        var errorCount = 0
        let engine = MirrorEngine(log: { s in
            AppLogStore.append("[auto-sync] \(s)")
            let lower = s.lowercased()
            if lower.contains("error") || lower.contains("fail") { errorCount += 1 }
        })

        let calendars = backgroundStore.calendars(for: .event)
        func calendar(id: String) -> EKCalendar? { calendars.first { $0.calendarIdentifier == id } }

        var ranAnyRoute = false
        var sessionGuard = Set<String>()
        for route in routes {
            guard let sourceCal = calendar(id: route.sourceID) else { continue }
            let validTargetIDs = route.targetIDs.filter { $0 != route.sourceID }
            let targets = validTargetIDs.compactMap(calendar(id:))
            guard !targets.isEmpty else { continue }
            ranAnyRoute = true
            let config = MirrorConfig(
                daysBack: settings.daysBack,
                daysForward: settings.daysForward,
                mergeGapMin: max(0, route.mergeGapHours * 60),
                hideDetails: route.privacy,
                copyDescription: route.copyNotes,
                mirrorAllDay: route.allDay,
                overlapMode: route.overlap,
                titlePrefix: settings.titlePrefix,
                placeholderTitle: settings.placeholderTitle,
                filterByWorkHours: settings.filterByWorkHours,
                workHoursStart: settings.workHoursStart,
                workHoursEnd: settings.workHoursEnd,
                excludedTitleFilterTerms: settings.excludedTitleFilters.map { $0.lowercased() },
                excludedOrganizerFilterTerms: settings.excludedOrganizerFilters.map { $0.lowercased() },
                mirrorAcceptedOnly: settings.mirrorAcceptedOnly,
                autoDeleteMissing: settings.autoDeleteMissing,
                writeEnabled: true,
                syncReminders: route.syncReminders
            )
            await engine.runMirror(store: backgroundStore, config: config, sourceCalendar: sourceCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: true)
        }

        let summary = ranAnyRoute ? "auto-sync (\(reason)): ran \(routes.count) saved route(s)" : "auto-sync (\(reason)): no route had a valid source+target"
        AppLogStore.append("[auto-sync] \(summary)")
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: "lastRunAtISO")
        UserDefaults.standard.set(errorCount == 0, forKey: "lastRunOK")
        UserDefaults.standard.set(summary, forKey: "lastRunSummary")
        refreshLastRunStatus()
        setSyncing(false)
    }
}

struct BusyMirrorMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appController: BusyMirrorAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BusyMirror")
                .font(.headline)

            Text(appController.isSyncing ? "Sync in progress." : appController.lastRunStatusText)
                .font(.subheadline)
                .foregroundStyle(appController.lastRunFailed ? .red : .secondary)

            Text(appController.autoSyncArmed ? "Auto-sync: watching for calendar changes." : "Auto-sync: not active (add a saved route to enable).")
                .font(.caption)
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

            Button("Preferences…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
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
