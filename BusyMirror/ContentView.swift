import SwiftUI
import EventKit
import AppKit


enum OverlapMode: String, CaseIterable, Identifiable, Codable {
    case allow, skipCovered, fillGaps
    var id: String { rawValue }
}

enum ScheduleMode: String, CaseIterable, Identifiable {
    case hourly, daily, weekdays
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        }
    }
}


struct Route: Identifiable, Hashable, Codable {
    let id = UUID()
    var sourceID: String
    var targetIDs: Set<String>
    var privacy: Bool              // true = hide details for this source
    var copyNotes: Bool            // copy description when privacy is OFF
    var syncReminders: Bool        // copy source event alarms into placeholder
    var mergeGapHours: Int         // per-route merge gap (hours)
    var overlap: OverlapMode       // per-route overlap behavior
    var allDay: Bool               // per-route mirror all-day
    enum CodingKeys: String, CodingKey { case sourceID, targetIDs, privacy, copyNotes, syncReminders, mergeGapHours, overlap, allDay }

    init(sourceID: String, targetIDs: Set<String>, privacy: Bool, copyNotes: Bool, syncReminders: Bool, mergeGapHours: Int, overlap: OverlapMode, allDay: Bool) {
        self.sourceID = sourceID
        self.targetIDs = targetIDs
        self.privacy = privacy
        self.copyNotes = copyNotes
        self.syncReminders = syncReminders
        self.mergeGapHours = mergeGapHours
        self.overlap = overlap
        self.allDay = allDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try c.decode(String.self, forKey: .sourceID)
        self.targetIDs = try c.decode(Set<String>.self, forKey: .targetIDs)
        self.privacy = try c.decode(Bool.self, forKey: .privacy)
        self.copyNotes = try c.decode(Bool.self, forKey: .copyNotes)
        self.syncReminders = try c.decodeIfPresent(Bool.self, forKey: .syncReminders) ?? false
        self.mergeGapHours = try c.decode(Int.self, forKey: .mergeGapHours)
        self.overlap = try c.decode(OverlapMode.self, forKey: .overlap)
        self.allDay = try c.decode(Bool.self, forKey: .allDay)

    }
}

struct ContentView: View {
    @EnvironmentObject private var appController: BusyMirrorAppController
    @State private var store = EKEventStore()
    @State private var hasAccess = false
    @State private var calendars: [EKCalendar] = []
    @State private var sourceIndex: Int = 0
    @State private var targetSelections = Set<Int>()   // indices in calendars
    // Stable selection storage by persistent identifiers (survives reordering)
    @State private var sourceID: String? = nil
    @State private var targetIDs = Set<String>()
    @State private var routes: [Route] = []
    @AppStorage("daysForward") private var daysForward: Int = 7
    @AppStorage("daysBack") private var daysBack: Int = 1
    @AppStorage("mergeGapHours") private var mergeGapHours: Int = 0
    private var mergeGapMin: Int { max(0, mergeGapHours * 60) }
    @AppStorage("hideDetails") private var hideDetails: Bool = true        // Privacy ON by default -> use "Busy"
    @AppStorage("copyDescription") private var copyDescription: Bool = false   // Only applies when hideDetails == false
    @AppStorage("syncReminders") private var syncReminders: Bool = false       // Copy source alarms into mirrored placeholders
    @AppStorage("mirrorAllDay") private var mirrorAllDay: Bool = false
    @AppStorage("overlapMode") private var overlapModeRaw: String = OverlapMode.allow.rawValue
    @AppStorage("filterByWorkHours") private var filterByWorkHours: Bool = false
    @AppStorage("workHoursStart") private var workHoursStart: Int = 9
    @AppStorage("workHoursEnd") private var workHoursEnd: Int = 17
    @AppStorage("scheduleMode") private var scheduleModeRaw: String = ScheduleMode.weekdays.rawValue
    @AppStorage("scheduleHour") private var scheduleHour: Int = 8
    @AppStorage("scheduleMinute") private var scheduleMinute: Int = 0
    @AppStorage("scheduleWeekdaysOnly") private var scheduleWeekdaysOnly: Bool = true
    @AppStorage("scheduleIntervalHours") private var scheduleIntervalHours: Int = 1
    @AppStorage("excludedTitleFilters") private var excludedTitleFiltersRaw: String = ""
    @AppStorage("excludedOrganizerFilters") private var excludedOrganizerFiltersRaw: String = ""
    @AppStorage("mirrorAcceptedOnly") private var mirrorAcceptedOnly: Bool = false
    var overlapMode: OverlapMode {
        get { OverlapMode(rawValue: overlapModeRaw) ?? .allow }
        nonmutating set { overlapModeRaw = newValue.rawValue }
    }
    @State private var writeEnabled = false            // dry-run unless checked
    @State private var logText = "Ready."
    @State private var isRunning = false
    @State private var isCLIRun = false
    @State private var cliRunErrorCount = 0
    @AppStorage("lastRunAtISO") private var lastRunAtISO: String = ""
    @AppStorage("lastRunOK") private var lastRunOK: Bool = true
    @AppStorage("lastRunSummary") private var lastRunSummary: String = ""
    @State private var confirmCleanup = false
    @State private var mirrorTask: Task<Void, Never>? = nil
    @State private var progressText: String? = nil
    /// Token for the EKEventStoreChanged observer; nil until calendar access is granted.
    @State private var storeObserver: NSObjectProtocol? = nil
    // Run-session guard: prevents the same source event from being mirrored
    // into the same target more than once across multiple routes within a
    // single "Mirror Now" click.
    @AppStorage("titlePrefix") private var titlePrefix: String = "🪞 "   // global title prefix for mirrored placeholders
    @AppStorage("placeholderTitle") private var placeholderTitle: String = "Busy"   // global customizable placeholder title
    @AppStorage("autoDeleteMissing") private var autoDeleteMissing: Bool = true       // delete mirrors whose source instance no longer exists
    
    // Mirrors can run either by manual selection (source + at least one target)
    // or using predefined routes. This derived flag controls the Mirror Now button.
    private var canRunMirrorNow: Bool {
        let hasManualTargets = !targetIDs.isEmpty
        let hasRouteTargets = routes.contains { !$0.targetIDs.isEmpty }
        return hasAccess && !isRunning && !calendars.isEmpty && (hasManualTargets || hasRouteTargets)
    }

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 720
        return f
    }()

    private static let hourFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 24
        return f
    }()

    private static let smallIntFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 24
        return f
    }()

    private var scheduleMode: ScheduleMode {
        get { ScheduleMode(rawValue: scheduleModeRaw) ?? (scheduleWeekdaysOnly ? .weekdays : .daily) }
        nonmutating set { scheduleModeRaw = newValue.rawValue }
    }

    private var launchAgentLabel: String { "com.cqrenet.BusyMirror.saved-routes" }

    private var launchAgentURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("LaunchAgents/\(launchAgentLabel).plist", isDirectory: false)
    }

    private var hasInstalledSchedule: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private var scheduleSummary: String {
        switch scheduleMode {
        case .hourly:
            return "every \(scheduleIntervalHours) hour" + (scheduleIntervalHours == 1 ? "" : "s")
        case .daily:
            return String(format: "%02d:%02d daily", scheduleHour, scheduleMinute)
        case .weekdays:
            return String(format: "%02d:%02d weekdays", scheduleHour, scheduleMinute)
        }
    }

    private func clampScheduleTime() {
        let nextHour = min(max(scheduleHour, 0), 23)
        if nextHour != scheduleHour { scheduleHour = nextHour }
        let nextMinute = min(max(scheduleMinute, 0), 59)
        if nextMinute != scheduleMinute { scheduleMinute = nextMinute }
        let nextInterval = min(max(scheduleIntervalHours, 1), 24)
        if nextInterval != scheduleIntervalHours { scheduleIntervalHours = nextInterval }
    }

    private func launchAgentScheduleProperties() -> [String: Any] {
        switch scheduleMode {
        case .hourly:
            return ["StartInterval": scheduleIntervalHours * 3600]
        case .daily:
            return ["StartCalendarInterval": ["Hour": scheduleHour, "Minute": scheduleMinute]]
        case .weekdays:
            let intervals: [[String: Int]] = (1...5).map { weekday in
                ["Hour": scheduleHour, "Minute": scheduleMinute, "Weekday": weekday]
            }
            return ["StartCalendarInterval": intervals]
        }
    }

    private func launchCtl(_ arguments: [String], allowFailure: Bool = false) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [outText, errText].filter { !$0.isEmpty }.joined(separator: "\n")
        if proc.terminationStatus != 0 && !allowFailure {
            throw NSError(
                domain: "BusyMirrorLaunchCtl",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combined.isEmpty ? "launchctl failed (\(proc.terminationStatus))" : combined]
            )
        }
        return combined
    }

    private func installSchedule() {
        guard !routes.isEmpty else {
            log("Cannot install schedule: no saved routes.")
            return
        }
        clampScheduleTime()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: AppLogStore.logDirectoryURL, withIntermediateDirectories: true)

            let executablePath = Bundle.main.executableURL?.path
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BusyMirror").path
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [executablePath, "--run-saved-routes", "--write", "1", "--exit"],
                "RunAtLoad": false,
                "StandardOutPath": AppLogStore.launchdStdoutURL.path,
                "StandardErrorPath": AppLogStore.launchdStderrURL.path,
                "WorkingDirectory": NSHomeDirectory(),
                "EnvironmentVariables": ["HOME": NSHomeDirectory()]
            ].merging(launchAgentScheduleProperties()) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)

            let domain = "gui/\(getuid())"
            _ = try? launchCtl(["bootout", domain, launchAgentURL.path], allowFailure: true)
            _ = try launchCtl(["bootstrap", domain, launchAgentURL.path])
            log("Installed schedule at \(scheduleSummary). LaunchAgent: \(launchAgentURL.path)")
        } catch {
            log("Failed to install schedule: \(error.localizedDescription)")
        }
    }

    private func removeSchedule() {
        do {
            let domain = "gui/\(getuid())"
            _ = try? launchCtl(["bootout", domain, launchAgentURL.path], allowFailure: true)
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            log("Removed schedule: \(launchAgentURL.path)")
        } catch {
            log("Failed to remove schedule: \(error.localizedDescription)")
        }
    }

    // Deterministic ordering to keep indices stable across runs
    private func sortedCalendars(_ cals: [EKCalendar]) -> [EKCalendar] {
        return cals.sorted { a, b in
            if a.source.title != b.source.title { return a.source.title < b.source.title }
            if a.title != b.title { return a.title < b.title }
            return a.calendarIdentifier < b.calendarIdentifier
        }
    }

    private var excludedTitleFilterList: [String] {
        excludedTitleFiltersRaw
            .split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var excludedTitleFilterTerms: [String] {
        excludedTitleFilterList.map { $0.lowercased() }
    }

    private var excludedOrganizerFilterList: [String] {
        excludedOrganizerFiltersRaw
            .split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var excludedOrganizerFilterTerms: [String] {
        excludedOrganizerFilterList.map { $0.lowercased() }
    }

    private func rebuildSelectionsFromIDs() {
        // Map IDs -> indices in current calendars
        var idToIndex: [String:Int] = [:]
        for (i, c) in calendars.enumerated() { idToIndex[c.calendarIdentifier] = i }
        if calendars.isEmpty {
            sourceIndex = 0
            sourceID = nil
            targetSelections.removeAll()
            targetIDs.removeAll()
            return
        }
        // Drop selections that no longer exist in EventKit
        targetIDs = Set(targetIDs.filter { idToIndex[$0] != nil })
        // Restore source index from sourceID if possible
        if let sid = sourceID, let idx = idToIndex[sid] { sourceIndex = idx }
        else if !calendars.isEmpty { sourceIndex = min(sourceIndex, calendars.count - 1); sourceID = calendars[sourceIndex].calendarIdentifier }
        // Ensure selected source is never a target
        if let sid = sourceID { targetIDs.remove(sid) }
        // Restore targets from IDs
        let restored = targetIDs.compactMap { idToIndex[$0] }
        targetSelections = Set(restored).filter { $0 != sourceIndex }
    }

    private func pruneStaleCalendarReferences() -> (removedTargets: Int, droppedRoutes: Int, trimmedRoutes: Int, removedSource: Bool) {
        let validIDs = Set(calendars.map { $0.calendarIdentifier })

        let originalTargets = targetIDs
        targetIDs = Set(originalTargets.filter { validIDs.contains($0) })
        let removedTargets = originalTargets.count - targetIDs.count

        var removedSource = false
        if let sid = sourceID, !validIDs.contains(sid) {
            sourceID = nil
            removedSource = true
        }

        var droppedRoutes = 0
        var trimmedRoutes = 0
        if !routes.isEmpty {
            var cleaned: [Route] = []
            cleaned.reserveCapacity(routes.count)
            for route in routes {
                guard validIDs.contains(route.sourceID) else {
                    droppedRoutes += 1
                    continue
                }

                var filteredTargets = Set(route.targetIDs.filter { validIDs.contains($0) })
                filteredTargets.remove(route.sourceID)
                guard !filteredTargets.isEmpty else {
                    droppedRoutes += 1
                    continue
                }

                var next = route
                if filteredTargets != route.targetIDs {
                    next.targetIDs = filteredTargets
                    trimmedRoutes += 1
                }
                cleaned.append(next)
            }
            routes = cleaned
        }

        return (removedTargets: removedTargets, droppedRoutes: droppedRoutes, trimmedRoutes: trimmedRoutes, removedSource: removedSource)
    }

    private func indexForCalendar(id: String) -> Int? { calendars.firstIndex(where: { $0.calendarIdentifier == id }) }
    private func labelForCalendar(id: String) -> String { calendars.first(where: { $0.calendarIdentifier == id }).map(calLabel) ?? id }


    // Ensure the currently selected source calendar is not present in targets
    private func enforceNoSourceInTargets() {
        guard sourceIndex < calendars.count else { return }
        let sid = calendars[sourceIndex].calendarIdentifier
        // Remove by index
        if targetSelections.contains(sourceIndex) {
            targetSelections.remove(sourceIndex)
        }
        // Remove by ID (in case indices shifted)
        targetIDs.remove(sid)
    }

    // MARK: - Extracted UI sections to simplify type-checking
    private var selectedSourceName: String {
        guard calendars.indices.contains(sourceIndex) else { return "Not selected" }
        return calLabel(calendars[sourceIndex])
    }

    @ViewBuilder
    private func statusPill(
        _ title: String,
        systemImage: String,
        fill: Color,
        foreground: Color = .white
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .foregroundStyle(foreground)
    }

    @ViewBuilder
    private func panelCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.34), lineWidth: 1.2)
        )
    }

    private func addRouteFromCurrentSelection() {
        guard let sid = sourceID, !targetIDs.isEmpty else { return }
        let r = Route(sourceID: sid,
                      targetIDs: targetIDs,
                      privacy: hideDetails,
                      copyNotes: copyDescription,
                      syncReminders: syncReminders,
                      mergeGapHours: mergeGapHours,
                      overlap: overlapMode,
                      allDay: mirrorAllDay)
        routes.append(r)
    }

    private func runConfiguredRoutes(_ configuredRoutes: [Route], sessionGuard: inout Set<String>) async {
        var ranAnyRoute = false
        var skippedMissingSource = 0
        var skippedNoTargets = 0

        for (idx, r) in configuredRoutes.enumerated() {
            if Task.isCancelled { break }
            guard let sIdx = indexForCalendar(id: r.sourceID) else {
                skippedMissingSource += 1
                continue
            }

            let validTargets = Set(r.targetIDs.filter { tid in
                tid != r.sourceID && indexForCalendar(id: tid) != nil
            })
            guard !validTargets.isEmpty else {
                skippedNoTargets += 1
                continue
            }

            ranAnyRoute = true
            let config = MirrorConfig(
                daysBack: daysBack,
                daysForward: daysForward,
                mergeGapMin: max(0, r.mergeGapHours * 60),
                hideDetails: r.privacy,
                copyDescription: r.copyNotes,
                mirrorAllDay: r.allDay,
                overlapMode: r.overlap,
                titlePrefix: titlePrefix,
                placeholderTitle: placeholderTitle,
                filterByWorkHours: filterByWorkHours,
                workHoursStart: workHoursStart,
                workHoursEnd: workHoursEnd,
                excludedTitleFilterTerms: excludedTitleFilterTerms,
                excludedOrganizerFilterTerms: excludedOrganizerFilterTerms,
                mirrorAcceptedOnly: mirrorAcceptedOnly,
                autoDeleteMissing: autoDeleteMissing,
                writeEnabled: writeEnabled,
                syncReminders: r.syncReminders
            )
            let srcCal = calendars[sIdx]
            let targets = calendars.filter { validTargets.contains($0.calendarIdentifier) && $0.calendarIdentifier != srcCal.calendarIdentifier }
            await MainActor.run {
                sourceIndex = sIdx
                sourceID = r.sourceID
                targetIDs = validTargets
                targetIDs.remove(r.sourceID)
                progressText = "Route \(idx + 1) of \(configuredRoutes.count)"
            }
            let engine = makeEngine()
            await engine.runMirror(store: store, config: config, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: true)
        }

        if skippedMissingSource > 0 {
            log("- SKIP routes with missing source calendar: \(skippedMissingSource)")
        }
        if skippedNoTargets > 0 {
            log("- SKIP routes with no valid targets: \(skippedNoTargets)")
        }
        if !ranAnyRoute {
            log("No valid routes to run. Refresh calendars and update your route selections.")
        }
    }

    private func makeMirrorConfig() -> MirrorConfig {
        MirrorConfig(
            daysBack: daysBack,
            daysForward: daysForward,
            mergeGapMin: mergeGapMin,
            hideDetails: hideDetails,
            copyDescription: copyDescription,
            mirrorAllDay: mirrorAllDay,
            overlapMode: overlapMode,
            titlePrefix: titlePrefix,
            placeholderTitle: placeholderTitle,
            filterByWorkHours: filterByWorkHours,
            workHoursStart: workHoursStart,
            workHoursEnd: workHoursEnd,
            excludedTitleFilterTerms: excludedTitleFilterTerms,
            excludedOrganizerFilterTerms: excludedOrganizerFilterTerms,
            mirrorAcceptedOnly: mirrorAcceptedOnly,
            autoDeleteMissing: autoDeleteMissing,
            writeEnabled: writeEnabled,
            syncReminders: syncReminders
        )
    }

    private func startMirrorNow() {
        guard !appController.isSyncing else { return }
        guard mirrorTask == nil else { return }
        appController.setSyncing(true)
        isRunning = true
        progressText = nil
        mirrorTask = Task {
            defer {
                Task { @MainActor in
                    appController.setSyncing(false)
                    isRunning = false
                    mirrorTask = nil
                    progressText = nil
                }
            }
            var sessionGuard = Set<String>()
            if routes.isEmpty {
                guard calendars.indices.contains(sourceIndex) else {
                    log("Cannot mirror: selected source is invalid.")
                    return
                }
                let config = makeMirrorConfig()
                let srcCal = calendars[sourceIndex]
                await MainActor.run {
                    sourceID = srcCal.calendarIdentifier
                    enforceNoSourceInTargets()
                }
                let targetSet = Set(targetIDs).subtracting([srcCal.calendarIdentifier])
                let targets = calendars.filter { targetSet.contains($0.calendarIdentifier) }
                let engine = makeEngine()
                await engine.runMirror(store: store, config: config, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: false)
            } else {
                await runConfiguredRoutes(routes, sessionGuard: &sessionGuard)
            }
        }
    }

    private func cancelMirror() {
        mirrorTask?.cancel()
        mirrorTask = nil
        appController.setSyncing(false)
        isRunning = false
        log("Cancelled.")
    }

    private func handlePendingMenuBarSyncIfNeeded() {
        guard appController.hasPendingSyncRequest else { return }
        guard !isRunning else { return }
        guard hasAccess else { return }
        guard !calendars.isEmpty else { return }
        guard canRunMirrorNow else {
            appController.clearPendingSyncRequest()
            log("Menu bar sync requested, but no valid manual targets or saved routes are available.")
            return
        }
        appController.clearPendingSyncRequest()
        startMirrorNow()
    }

    @ViewBuilder
    private func optionsSection() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Mirroring defaults, filters, and work hours moved to Preferences.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Text("Open Preferences…")
                }
                Spacer(minLength: 0)
            }

            Divider()

            Toggle("Write to calendars (disable for Dry-Run)", isOn: $writeEnabled)
                .disabled(isRunning)

            HStack(spacing: 10) {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
                Button("Reveal Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogStore.logFileURL])
                }
                Spacer(minLength: 0)
            }

            Divider()

            ScheduleSectionView(
                scheduleMode: Binding(
                    get: { scheduleMode },
                    set: { newValue in
                        scheduleMode = newValue
                        scheduleWeekdaysOnly = (newValue == .weekdays)
                    }
                ),
                scheduleIntervalHours: $scheduleIntervalHours,
                scheduleHour: $scheduleHour,
                scheduleMinute: $scheduleMinute,
                isRunning: isRunning,
                routesEmpty: routes.isEmpty,
                hasInstalledSchedule: hasInstalledSchedule,
                scheduleSummary: scheduleSummary,
                onInstall: installSchedule,
                onRemove: removeSchedule,
                onRevealLaunchAgent: { NSWorkspace.shared.activateFileViewerSelecting([launchAgentURL]) },
                onScheduleTimeChanged: clampScheduleTime
            )

            HStack(spacing: 10) {
                Button("Cleanup Placeholders") {
                    if writeEnabled {
                        // Real delete: ask for confirmation first
                        confirmCleanup = true
                    } else {
                        // Dry-run: run without confirmation
                        Task {
                            if routes.isEmpty {
                                await runCleanupForCurrentSelection()
                            } else {
                                for r in routes {
                                    await runCleanupForRoute(r)
                                }
                            }
                        }
                    }
                }
                .disabled(isRunning)
                .buttonStyle(.bordered)

                Button("Refresh Calendars") {
                    reloadCalendars(forceResetStore: true)
                }
                .disabled(isRunning)
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let compactLayout = proxy.size.width < 1220
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("BusyMirror")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                Text("Mirror availability across calendars")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                if hasAccess {
                                    statusPill("\(calendars.count) calendars", systemImage: "calendar", fill: .black)
                                } else {
                                    statusPill("No access", systemImage: "lock.fill", fill: .red)
                                }
                                Button {
                                    guard !isRunning else { return }
                                    writeEnabled.toggle()
                                    log("Mode: \(writeEnabled ? "WRITE" : "DRY-RUN")")
                                } label: {
                                    statusPill(writeEnabled ? "WRITE" : "DRY RUN", systemImage: writeEnabled ? "pencil" : "eye", fill: writeEnabled ? .red : .black)
                                }
                                .buttonStyle(.plain)
                                .help("Click to toggle write mode.")
                                if isRunning {
                                    statusPill("RUNNING", systemImage: "arrow.triangle.2.circlepath", fill: .orange)
                                }
                                if let progressText {
                                    Text(progressText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if isRunning {
                                    Button("Cancel") {
                                        cancelMirror()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                } else {
                                    Button("Mirror Now") {
                                        startMirrorNow()
                                    }
                                    .disabled(!canRunMirrorNow)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                }
                                Button(hasAccess ? "Recheck Permission" : "Request Calendar Access") {
                                    requestAccess()
                                }
                                .disabled(isRunning)
                                .buttonStyle(.bordered)
                            }
                        }

                        if !hasAccess {
                            panelCard(
                                title: "Calendar Permission Needed",
                                subtitle: "BusyMirror needs access to read and mirror your events.",
                                symbol: "lock.fill"
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Calendar access is not granted yet. Use the button above to continue.")
                                        .foregroundStyle(.secondary)
                                    Button("Request Calendar Access") {
                                        requestAccess()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        } else if compactLayout {
                            panelCard(title: "Calendars", subtitle: "Source: \(selectedSourceName)", symbol: "calendar") {
                                CalendarsSectionView(
                                    calendars: calendars,
                                    sourceIndex: $sourceIndex,
                                    targetSelections: $targetSelections,
                                    targetIDs: $targetIDs,
                                    isRunning: isRunning
                                )
                            }
                            panelCard(title: "Actions & Schedule", subtitle: "Export, cleanup, and manual scheduling", symbol: "slider.horizontal.3") {
                                optionsSection()
                            }
                            panelCard(title: "Routes", subtitle: "\(routes.count) configured", symbol: "arrow.triangle.branch") {
                                RoutesSectionView(
                                    routes: $routes,
                                    calendars: calendars,
                                    isRunning: isRunning,
                                    titlePrefix: titlePrefix,
                                    placeholderTitle: placeholderTitle,
                                    canAddRoute: sourceID != nil && !targetIDs.isEmpty,
                                    onAddRoute: addRouteFromCurrentSelection
                                )
                            }
                            panelCard(title: "Activity Log", subtitle: "Latest events and dry-run output", symbol: "terminal") {
                                LogSectionView(logText: logText)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 12) {
                                    panelCard(title: "Calendars", subtitle: "Source: \(selectedSourceName)", symbol: "calendar") {
                                        CalendarsSectionView(
                                    calendars: calendars,
                                    sourceIndex: $sourceIndex,
                                    targetSelections: $targetSelections,
                                    targetIDs: $targetIDs,
                                    isRunning: isRunning
                                )
                                    }
                                    panelCard(title: "Actions & Schedule", subtitle: "Export, cleanup, and manual scheduling", symbol: "slider.horizontal.3") {
                                        optionsSection()
                                    }
                                }
                                .frame(width: 430, alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true)

                                VStack(spacing: 12) {
                                    panelCard(title: "Routes", subtitle: "\(routes.count) configured", symbol: "arrow.triangle.branch") {
                                        RoutesSectionView(
                                    routes: $routes,
                                    calendars: calendars,
                                    isRunning: isRunning,
                                    titlePrefix: titlePrefix,
                                    placeholderTitle: placeholderTitle,
                                    canAddRoute: sourceID != nil && !targetIDs.isEmpty,
                                    onAddRoute: addRouteFromCurrentSelection
                                )
                                    }
                                    panelCard(title: "Activity Log", subtitle: "Latest events and dry-run output", symbol: "terminal") {
                                        LogSectionView(logText: logText)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: 1480, alignment: .topLeading)
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
        }
        .confirmationDialog(
            "Delete mirrored placeholders?",
            isPresented: $confirmCleanup,
            titleVisibility: .visible
        ) {
            Button("Delete now", role: .destructive) {
                Task {
                    if routes.isEmpty {
                        await runCleanupForCurrentSelection()
                    } else {
                        for r in routes {
                            await runCleanupForRoute(r)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let prefixNote = titlePrefix.isEmpty ? "" : " (title prefix ‘\(titlePrefix)’)"
            Text("This will remove events identified as mirrored by URL prefix\(prefixNote) within the current window (Days back/forward) from the selected target calendars.")
        }
        .onAppear {
            appController.setMainWindowVisible(true)
            AppLogStore.append("=== BusyMirror launch ===")
            log("Log file: \(AppLogStore.logFileURL.path)")
            requestAccess()
            loadSettingsFromDefaults()
            tryRunCLIIfPresent()
            enforceNoSourceInTargets()
            handlePendingMenuBarSyncIfNeeded()
            if !isCLIRun {
                appController.bootstrapBackgroundSync()
            }
        }
        .onDisappear {
            appController.setMainWindowVisible(false)
            unregisterStoreObserver()
        }
        // Persist key settings whenever they change, to ensure restore between runs
        .onChange(of: appController.syncRequestToken) { _ in
            handlePendingMenuBarSyncIfNeeded()
        }
        .onChange(of: daysBack) { _ in saveSettingsToDefaults() }
        .onChange(of: daysForward) { _ in saveSettingsToDefaults() }
        .onChange(of: mergeGapHours) { _ in saveSettingsToDefaults() }
        .onChange(of: hideDetails) { _ in saveSettingsToDefaults() }
        .onChange(of: copyDescription) { _ in saveSettingsToDefaults() }
        .onChange(of: syncReminders) { _ in saveSettingsToDefaults() }
        .onChange(of: mirrorAllDay) { _ in saveSettingsToDefaults() }
        .onChange(of: mirrorAcceptedOnly) { _ in saveSettingsToDefaults() }
        .onChange(of: overlapModeRaw) { _ in saveSettingsToDefaults() }
        .onChange(of: titlePrefix) { _ in saveSettingsToDefaults() }
        .onChange(of: placeholderTitle) { _ in saveSettingsToDefaults() }
        .onChange(of: autoDeleteMissing) { _ in saveSettingsToDefaults() }
        .onChange(of: sourceIndex) { newValue in
            // Track selected source by persistent ID and ensure it is not a target
            if newValue < calendars.count { sourceID = calendars[newValue].calendarIdentifier }
            enforceNoSourceInTargets()
            saveSettingsToDefaults()
        }
        .onChange(of: targetSelections) { _ in
            // If the new source is accidentally included, drop it
            enforceNoSourceInTargets()
            saveSettingsToDefaults()
        }
        .onChange(of: targetIDs) { _ in
            // If IDs contain the source’s ID, drop it
            enforceNoSourceInTargets()
            saveSettingsToDefaults()
            handlePendingMenuBarSyncIfNeeded()
        }
        .onChange(of: routes) { _ in
            saveSettingsToDefaults()
            handlePendingMenuBarSyncIfNeeded()
            appController.armAutoSyncIfPossible()
        }
    }
    
    // MARK: - CLI support
    private static let cliHelpText = """
    BusyMirror — mirror calendar events between EventKit calendars.

    Usage:
      BusyMirror --run-saved-routes [--write 1] [--exit]
      BusyMirror --routes "1->2,3; 4->5" [--write 1] [--exit]
      BusyMirror --list-calendars [--json]
      BusyMirror --status [--json]
      BusyMirror --help

    Run modes:
      --run-saved-routes     Run the routes configured in the app's saved settings.
      --routes SPEC          Run ad-hoc routes by 1-based calendar index, e.g. "1->2,3".
      --list-calendars       Print available calendars (index, id, title, source) and exit.
      --status               Print last-run and schedule diagnostics and exit.
      --help, -h             Print this help and exit.

    Options:
      --json                 Machine-readable JSON output for --list-calendars / --status.
      --write 1              Actually create/update/delete events (default: dry-run).
      --exit                 Quit the app after the run completes.
      --cleanup-only         Only delete stale mirrored placeholders; don't mirror.
      --privacy 1|0          Hide event details behind a placeholder title.
      --copy-notes 1|0       Copy the source event's notes into the mirror.
      --sync-reminders 1|0   Copy source event alarms into the mirror.
      --all-day 1|0          Mirror all-day events.
      --mode allow|skipCovered|fillGaps
      --days-back N / --days-forward N
      --merge-gap-hours N
      --exclude-titles "token1, token2"
      --exclude-organizers "alice@example.com, Example Org"
    """

    private func recordRunResult(ok: Bool, summary: String) {
        lastRunAtISO = ISO8601DateFormatter().string(from: Date())
        lastRunOK = ok
        lastRunSummary = summary
    }

    private struct CLICalendarInfo: Codable {
        let index: Int
        let id: String
        let title: String
        let source: String
        let sourceType: String
        let allowsModify: Bool
    }

    private struct CLIStatusInfo: Codable {
        let lastRunAt: String?
        let lastRunOK: Bool?
        let lastRunSummary: String?
        let scheduleInstalled: Bool
        let scheduleSummary: String?
        let routeCount: Int
        let logFilePath: String
    }

    private func sourceTypeLabel(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    private func printCalendars(json: Bool) {
        let infos = calendars.enumerated().map { idx, cal in
            CLICalendarInfo(
                index: idx + 1,
                id: cal.calendarIdentifier,
                title: cal.title,
                source: cal.source.title,
                sourceType: sourceTypeLabel(cal.source.sourceType),
                allowsModify: cal.allowsContentModifications
            )
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(infos), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        } else {
            for info in infos {
                print("\(info.index): \(info.title) [\(info.source), \(info.sourceType)]\(info.allowsModify ? "" : " (read-only)")  id=\(info.id)")
            }
        }
    }

    private func printStatus(json: Bool) {
        let info = CLIStatusInfo(
            lastRunAt: lastRunAtISO.isEmpty ? nil : lastRunAtISO,
            lastRunOK: lastRunAtISO.isEmpty ? nil : lastRunOK,
            lastRunSummary: lastRunSummary.isEmpty ? nil : lastRunSummary,
            scheduleInstalled: hasInstalledSchedule,
            scheduleSummary: hasInstalledSchedule ? scheduleSummary : nil,
            routeCount: routes.count,
            logFilePath: AppLogStore.logFileURL.path
        )
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(info), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        } else {
            print("Last run: \(info.lastRunAt ?? "never")\(info.lastRunAt != nil ? (info.lastRunOK == true ? " (ok)" : " (error)") : "")")
            if let summary = info.lastRunSummary { print("  \(summary)") }
            print("Schedule: \(info.scheduleInstalled ? (info.scheduleSummary ?? "installed") : "not installed")")
            print("Saved routes: \(info.routeCount)")
            print("Log file: \(info.logFilePath)")
        }
    }

    func tryRunCLIIfPresent() {
        let args = CommandLine.arguments
        let jsonOutput = args.contains("--json")

        if args.contains("--help") || args.contains("-h") {
            isCLIRun = true
            print(Self.cliHelpText)
            NSApp.terminate(nil)
            return
        }

        if args.contains("--status") {
            isCLIRun = true
            printStatus(json: jsonOutput)
            NSApp.terminate(nil)
            return
        }

        if args.contains("--list-calendars") {
            isCLIRun = true
            Task {
                if hasAccess { await MainActor.run { reloadCalendars() } }
                for _ in 0..<50 {
                    if hasAccess && !calendars.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard hasAccess else {
                    FileHandle.standardError.write("No calendar access.\n".data(using: .utf8)!)
                    exit(2)
                }
                await MainActor.run { printCalendars(json: jsonOutput) }
                NSApp.terminate(nil)
            }
            return
        }

        let routesIdx = args.firstIndex(of: "--routes")
        let runSavedRoutes = args.contains("--run-saved-routes")
        guard routesIdx != nil || runSavedRoutes else { return }
        isCLIRun = true
        cliRunErrorCount = 0

        func boolArg(_ name: String, default def: Bool) -> Bool {
            if let i = args.firstIndex(of: name), i+1 < args.count {
                let v = args[i+1].lowercased()
                return v == "1" || v == "true" || v == "yes" || v == "on"
            }
            return def
        }
        func intArg(_ name: String, default def: Int) -> Int {
            if let i = args.firstIndex(of: name), i+1 < args.count, let n = Int(args[i+1]) { return n }
            return def
        }
        func strArg(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i+1 < args.count { return args[i+1] }
            return nil
        }

        // Configure options from CLI flags
        hideDetails = boolArg("--privacy", default: hideDetails)
        copyDescription = boolArg("--copy-notes", default: copyDescription)
        syncReminders = boolArg("--sync-reminders", default: syncReminders)
        writeEnabled = boolArg("--write", default: writeEnabled)
        mirrorAllDay = boolArg("--all-day", default: mirrorAllDay)
        daysForward = intArg("--days-forward", default: daysForward)
        daysBack = intArg("--days-back", default: daysBack)
        mergeGapHours = intArg("--merge-gap-hours", default: mergeGapHours)
        if let modeStr = strArg("--mode")?.lowercased() {
            switch modeStr {
            case "allow": overlapModeRaw = OverlapMode.allow.rawValue
            case "skipcovered", "skip": overlapModeRaw = OverlapMode.skipCovered.rawValue
            case "fillgaps", "gaps": overlapModeRaw = OverlapMode.fillGaps.rawValue
            default: break
            }
        }
        // Optional filters via CLI
        if let tFilters = strArg("--exclude-titles") { excludedTitleFiltersRaw = tFilters }
        if let oFilters = strArg("--exclude-organizers") { excludedOrganizerFiltersRaw = oFilters }

        let routesSpec = {
            guard let routesIdx else { return "" }
            return (routesIdx + 1 < args.count) ? args[routesIdx + 1] : ""
        }()
        let routeParts = routesSpec.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if runSavedRoutes {
            log("CLI: run saved routes")
        } else {
            log("CLI: routes=\(routesSpec)")
        }
        Task {
            // If permission already granted, force a sync calendar reload so
            // the CLI doesn't race the async permission callback.
            if hasAccess {
                await MainActor.run { reloadCalendars() }
            }
            // Wait up to ~10s for calendars to load
            for _ in 0..<50 {
                if hasAccess && !calendars.isEmpty { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard hasAccess, !calendars.isEmpty else {
                log("CLI: no calendar access; aborting")
                recordRunResult(ok: false, summary: "no calendar access")
                exit(2)
            }

            let cliConfig = makeMirrorConfig()
            if runSavedRoutes {
                if routes.isEmpty {
                    log("CLI: no saved routes; aborting")
                    recordRunResult(ok: false, summary: "no saved routes")
                    exit(3)
                } else if boolArg("--cleanup-only", default: false) {
                    for r in routes {
                        log("CLI: cleanup saved route \(r.sourceID)")
                        await runCleanupForRoute(r)
                    }
                    recordRunResult(ok: cliRunErrorCount == 0, summary: "cleaned up \(routes.count) saved route(s)")
                } else {
                    var sessionGuard = Set<String>()
                    await runConfiguredRoutes(routes, sessionGuard: &sessionGuard)
                    recordRunResult(ok: cliRunErrorCount == 0, summary: "ran \(routes.count) saved route(s)")
                }
            } else {
                for part in routeParts where !part.isEmpty {
                    let lr = part.split(separator: "->", maxSplits: 1).map { String($0) }
                    guard lr.count == 2, let s1 = Int(lr[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let srcIdx0 = max(0, s1 - 1)
                    let tgtIdxs0: [Int] = lr[1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces))?.advanced(by: -1) }.filter { $0 >= 0 }
                    if srcIdx0 >= calendars.count { continue }
                    let srcCal = calendars[srcIdx0]
                    let targetSet = Set(tgtIdxs0.compactMap { i in calendars.indices.contains(i) ? calendars[i].calendarIdentifier : nil }).subtracting([srcCal.calendarIdentifier])
                    let targets = calendars.filter { targetSet.contains($0.calendarIdentifier) }
                    await MainActor.run {
                        sourceIndex = srcIdx0
                        sourceID = srcCal.calendarIdentifier
                        targetSelections = Set(tgtIdxs0)
                        targetIDs = targetSet
                    }

                    if boolArg("--cleanup-only", default: false) {
                        log("CLI: cleanup route \(part)")
                        let engine = makeEngine()
                        await engine.runCleanup(store: store, daysBack: daysBack, daysForward: daysForward, sourceCalendar: srcCal, targetCalendars: targets, titlePrefix: titlePrefix, placeholderTitle: placeholderTitle, writeEnabled: writeEnabled)
                    } else {
                        log("CLI: mirror route \(part)")
                        let engine = makeEngine()
                        var sessionGuard = Set<String>()
                        await engine.runMirror(store: store, config: cliConfig, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: false)
                    }
                }
                recordRunResult(ok: cliRunErrorCount == 0, summary: "ran \(routeParts.count) route(s)")
            }
            // Exit only when --exit is explicitly passed.  isCLIRun alone does
            // not force termination so that advanced users can open the UI with
            // --routes to pre-populate a run without auto-quitting.
            if CommandLine.arguments.contains("--exit") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Permissions & Calendars
    @MainActor
    func requestAccess() {
        log("Requesting calendar access…")
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    hasAccess = granted
                    if granted {
                        // Reinitialize the store after permission changes to ensure sources load
                        store = EKEventStore()
                        reloadCalendars()
                    } else {
                        appController.clearPendingSyncRequest()
                    }
                    log(granted ? "Access granted." : "Access denied.")
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    hasAccess = granted
                    if granted {
                        // Reinitialize the store after permission changes to ensure sources load
                        store = EKEventStore()
                        reloadCalendars()
                    } else {
                        appController.clearPendingSyncRequest()
                    }
                    log(granted ? "Access granted." : "Access denied.")
                }
            }
        }
    }
    
    @MainActor
    func reloadCalendars(forceResetStore: Bool = false) {
        if forceResetStore {
            // EventKit can cache stale/inactive calendars; recreate store for a hard refresh.
            // Unregister the existing EKEventStoreChanged observer first — it targets the
            // old store object and would never fire again after the store is replaced.
            unregisterStoreObserver()
            store = EKEventStore()
        }
        let fetched = store.calendars(for: .event)
        calendars = sortedCalendars(fetched)
        let pruned = pruneStaleCalendarReferences()
        // Initialize IDs on first load
        if sourceID == nil, let first = calendars.first { sourceID = first.calendarIdentifier }
        // Rebuild index-based selections from stored IDs
        rebuildSelectionsFromIDs()
        if pruned.removedTargets > 0 || pruned.droppedRoutes > 0 || pruned.trimmedRoutes > 0 || pruned.removedSource {
            log("Pruned stale calendars: source removed=\(pruned.removedSource ? "yes" : "no"), selected targets removed=\(pruned.removedTargets), routes dropped=\(pruned.droppedRoutes), routes trimmed=\(pruned.trimmedRoutes).")
            saveSettingsToDefaults()
        }
        log("Loaded \(calendars.count) calendars.")
        // Register for live calendar-store changes the first time we have access,
        // so the calendar list stays up-to-date without pressing "Refresh".
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [self] _ in
                // Skip silent background refreshes while a sync is running to
                // avoid interfering with an in-progress mirror operation.
                guard !isRunning else { return }
                reloadCalendars()
            }
        }
        handlePendingMenuBarSyncIfNeeded()
    }

    @MainActor
    private func unregisterStoreObserver() {
        if let token = storeObserver {
            NotificationCenter.default.removeObserver(token)
            storeObserver = nil
        }
    }
    
    // MARK: - Export / Import Settings
    struct SettingsPayload: Codable {
        var daysBack: Int
        var daysForward: Int
        var mergeGapHours: Int
        var hideDetails: Bool
        var copyDescription: Bool
        var syncReminders: Bool = false
        var mirrorAllDay: Bool
        var filterByWorkHours: Bool = false
        var workHoursStart: Int = 9
        var workHoursEnd: Int = 17
        var excludedTitleFilters: [String] = []
        var excludedOrganizerFilters: [String] = []
        var mirrorAcceptedOnly: Bool = false
        var overlapMode: String
        var titlePrefix: String
        var placeholderTitle: String
        var autoDeleteMissing: Bool
        var routes: [Route]
        // UI selections (optional for backward compatibility)
        var selectedSourceID: String? = nil
        var selectedTargetIDs: [String]? = nil
        // optional metadata
        var appVersion: String?
        var exportedAt: Date = Date()

        init(daysBack: Int, daysForward: Int, mergeGapHours: Int, hideDetails: Bool, copyDescription: Bool,
             syncReminders: Bool = false, mirrorAllDay: Bool, filterByWorkHours: Bool, workHoursStart: Int,
             workHoursEnd: Int, excludedTitleFilters: [String], excludedOrganizerFilters: [String],
             mirrorAcceptedOnly: Bool, overlapMode: String, titlePrefix: String, placeholderTitle: String,
             autoDeleteMissing: Bool, routes: [Route], selectedSourceID: String? = nil,
             selectedTargetIDs: [String]? = nil, appVersion: String? = nil, exportedAt: Date = Date()) {
            self.daysBack = daysBack
            self.daysForward = daysForward
            self.mergeGapHours = mergeGapHours
            self.hideDetails = hideDetails
            self.copyDescription = copyDescription
            self.syncReminders = syncReminders
            self.mirrorAllDay = mirrorAllDay
            self.filterByWorkHours = filterByWorkHours
            self.workHoursStart = workHoursStart
            self.workHoursEnd = workHoursEnd
            self.excludedTitleFilters = excludedTitleFilters
            self.excludedOrganizerFilters = excludedOrganizerFilters
            self.mirrorAcceptedOnly = mirrorAcceptedOnly
            self.overlapMode = overlapMode
            self.titlePrefix = titlePrefix
            self.placeholderTitle = placeholderTitle
            self.autoDeleteMissing = autoDeleteMissing
            self.routes = routes
            self.selectedSourceID = selectedSourceID
            self.selectedTargetIDs = selectedTargetIDs
            self.appVersion = appVersion
            self.exportedAt = exportedAt
        }

        // Custom decode: every field added after the very first release must be
        // read with decodeIfPresent so that a settings blob written by an older
        // build (missing that key) doesn't fail the whole decode and silently
        // wipe all saved routes/settings (see: settings.v2 losing data across
        // the 1.5.1 -> 1.6.0 upgrade when `syncReminders` was added).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            daysBack = try c.decodeIfPresent(Int.self, forKey: .daysBack) ?? 1
            daysForward = try c.decodeIfPresent(Int.self, forKey: .daysForward) ?? 7
            mergeGapHours = try c.decodeIfPresent(Int.self, forKey: .mergeGapHours) ?? 0
            hideDetails = try c.decodeIfPresent(Bool.self, forKey: .hideDetails) ?? true
            copyDescription = try c.decodeIfPresent(Bool.self, forKey: .copyDescription) ?? false
            syncReminders = try c.decodeIfPresent(Bool.self, forKey: .syncReminders) ?? false
            mirrorAllDay = try c.decodeIfPresent(Bool.self, forKey: .mirrorAllDay) ?? false
            filterByWorkHours = try c.decodeIfPresent(Bool.self, forKey: .filterByWorkHours) ?? false
            workHoursStart = try c.decodeIfPresent(Int.self, forKey: .workHoursStart) ?? 9
            workHoursEnd = try c.decodeIfPresent(Int.self, forKey: .workHoursEnd) ?? 17
            excludedTitleFilters = try c.decodeIfPresent([String].self, forKey: .excludedTitleFilters) ?? []
            excludedOrganizerFilters = try c.decodeIfPresent([String].self, forKey: .excludedOrganizerFilters) ?? []
            mirrorAcceptedOnly = try c.decodeIfPresent(Bool.self, forKey: .mirrorAcceptedOnly) ?? false
            overlapMode = try c.decodeIfPresent(String.self, forKey: .overlapMode) ?? OverlapMode.allow.rawValue
            titlePrefix = try c.decodeIfPresent(String.self, forKey: .titlePrefix) ?? "🪞 "
            placeholderTitle = try c.decodeIfPresent(String.self, forKey: .placeholderTitle) ?? "Busy"
            autoDeleteMissing = try c.decodeIfPresent(Bool.self, forKey: .autoDeleteMissing) ?? true
            routes = try c.decodeIfPresent([Route].self, forKey: .routes) ?? []
            selectedSourceID = try c.decodeIfPresent(String.self, forKey: .selectedSourceID)
            selectedTargetIDs = try c.decodeIfPresent([String].self, forKey: .selectedTargetIDs)
            appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
            exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        }
    }

    private func makeSnapshot() -> SettingsPayload {
        SettingsPayload(
            daysBack: daysBack,
            daysForward: daysForward,
            mergeGapHours: mergeGapHours,
            hideDetails: hideDetails,
            copyDescription: copyDescription,
            mirrorAllDay: mirrorAllDay,
            filterByWorkHours: filterByWorkHours,
            workHoursStart: workHoursStart,
            workHoursEnd: workHoursEnd,
            excludedTitleFilters: excludedTitleFilterList,
            excludedOrganizerFilters: excludedOrganizerFilterList,
            mirrorAcceptedOnly: mirrorAcceptedOnly,
            overlapMode: overlapMode.rawValue,
            titlePrefix: titlePrefix,
            placeholderTitle: placeholderTitle,
            autoDeleteMissing: autoDeleteMissing,
            routes: routes,
            selectedSourceID: sourceID,
            selectedTargetIDs: Array(targetIDs).sorted(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            exportedAt: Date()
        )
    }

    private func applySnapshot(_ s: SettingsPayload) {
        daysBack = s.daysBack
        daysForward = s.daysForward
        mergeGapHours = s.mergeGapHours
        hideDetails = s.hideDetails
        copyDescription = s.copyDescription
        syncReminders = s.syncReminders
        mirrorAllDay = s.mirrorAllDay
        filterByWorkHours = s.filterByWorkHours
        workHoursStart = s.workHoursStart
        workHoursEnd = s.workHoursEnd
        excludedTitleFiltersRaw = s.excludedTitleFilters.joined(separator: "\n")
        excludedOrganizerFiltersRaw = s.excludedOrganizerFilters.joined(separator: "\n")
        mirrorAcceptedOnly = s.mirrorAcceptedOnly
        overlapMode = OverlapMode(rawValue: s.overlapMode) ?? .allow
        titlePrefix = s.titlePrefix
        placeholderTitle = s.placeholderTitle
        autoDeleteMissing = s.autoDeleteMissing
        routes = s.routes
        // Restore UI selections if provided
        if let selSrc = s.selectedSourceID { sourceID = selSrc }
        if let selTgts = s.selectedTargetIDs { targetIDs = Set(selTgts) }
        clampWorkHours()
        // Rebuild indices from IDs after restoring selections
        rebuildSelectionsFromIDs()
    }

    /// Used only at launch (`loadSettingsFromDefaults`) — restores just the
    /// state that has no other persistence (`routes` and the manual
    /// source/target selection are plain `@State`, not `@AppStorage`).
    /// Deliberately does NOT touch the @AppStorage-backed fields even though
    /// they're also present in the decoded snapshot: those already restore
    /// themselves from their own UserDefaults keys before this ever runs, and
    /// since Preferences is now a separate window, a value changed there
    /// wouldn't necessarily have re-triggered `saveSettingsToDefaults()` —
    /// applying the (possibly stale) snapshot copy on top would silently
    /// revert a preference the user just changed. `applySnapshot` (the full
    /// version) stays reserved for Import, where overwriting everything from
    /// the imported file is exactly the point.
    private func restoreLaunchState(from s: SettingsPayload) {
        routes = s.routes
        if let selSrc = s.selectedSourceID { sourceID = selSrc }
        if let selTgts = s.selectedTargetIDs { targetIDs = Set(selTgts) }
        rebuildSelectionsFromIDs()
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "BusyMirror-Settings.json"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(makeSnapshot())
                try data.write(to: url, options: Data.WritingOptions.atomic)
                log("✓ Exported settings to \(url.path)")
            } catch {
                log("✗ Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let snap = try JSONDecoder().decode(SettingsPayload.self, from: data)
                applySnapshot(snap)
                saveSettingsToDefaults()
                log("✓ Imported settings from \(url.lastPathComponent)")
            } catch {
                log("✗ Import failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Settings persistence (UserDefaults)
    private func makeEngine() -> MirrorEngine {
        MirrorEngine(log: log)
    }

    private func runCleanupForCurrentSelection() async {
        guard hasAccess, !calendars.isEmpty else { return }
        guard calendars.indices.contains(sourceIndex) else {
            log("Cannot cleanup: selected source is invalid.")
            return
        }
        let srcCal = calendars[sourceIndex]
        let targetSet = Set(targetIDs).subtracting([srcCal.calendarIdentifier])
        let targets = calendars.filter { targetSet.contains($0.calendarIdentifier) }
        await makeEngine().runCleanup(store: store, daysBack: daysBack, daysForward: daysForward, sourceCalendar: srcCal, targetCalendars: targets, titlePrefix: titlePrefix, placeholderTitle: placeholderTitle, writeEnabled: writeEnabled)
    }

    private func runCleanupForRoute(_ route: Route) async {
        guard let sIdx = indexForCalendar(id: route.sourceID) else { return }
        let srcCal = calendars[sIdx]
        let targetSet = route.targetIDs.subtracting([srcCal.calendarIdentifier])
        let targets = calendars.filter { targetSet.contains($0.calendarIdentifier) }
        // Do NOT mutate sourceIndex / sourceID / targetIDs here: cleanup does
        // not need to reflect route selections in the UI and doing so causes
        // jarring picker jumps when iterating over multiple routes.
        await makeEngine().runCleanup(store: store, daysBack: daysBack, daysForward: daysForward, sourceCalendar: srcCal, targetCalendars: targets, titlePrefix: titlePrefix, placeholderTitle: placeholderTitle, writeEnabled: writeEnabled)
    }

    private let settingsDefaultsKey = "settings.v2"
    private let legacyRoutesDefaultsKey = "routes.v1"

    private func saveSettingsToDefaults() {
        do {
            let data = try JSONEncoder().encode(makeSnapshot())
            UserDefaults.standard.set(data, forKey: settingsDefaultsKey)
        } catch {
            log("✗ Failed to save settings: \(error.localizedDescription)")
        }
    }

    private func loadSettingsFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: settingsDefaultsKey) {
            do {
                let snap = try JSONDecoder().decode(SettingsPayload.self, from: data)
                restoreLaunchState(from: snap)
                // A build affected by an earlier settings.v2 decode failure (fixed
                // in 1.6.0 — a newly added field with no decode fallback threw and
                // wiped routes in memory, which a later autosave then persisted
                // back as empty) can still be running with `routes: []` in
                // settings.v2 while the untouched legacy `routes.v1` key still
                // holds the real routes. Recover them if so.
                if routes.isEmpty, let legacyData = defaults.data(forKey: legacyRoutesDefaultsKey),
                   let recovered = try? JSONDecoder().decode([Route].self, from: legacyData), !recovered.isEmpty {
                    routes = recovered
                    log("Recovered \(recovered.count) route(s) from legacy backup (routes.v1).")
                    saveSettingsToDefaults()
                }
            } catch {
                log("✗ Failed to load settings: \(error.localizedDescription)")
            }
            return
        }

        // Legacy fallback: routes-only payload
        guard let legacyData = defaults.data(forKey: legacyRoutesDefaultsKey) else { return }
        do {
            let decodedRoutes = try JSONDecoder().decode([Route].self, from: legacyData)
            routes = decodedRoutes
            clampWorkHours()
            saveSettingsToDefaults() // upgrade stored format
        } catch {
            log("✗ Failed to load routes: \(error.localizedDescription)")
        }
    }

    // MARK: - Filters

    private func clampWorkHours() {
        let clampedStart = min(max(workHoursStart, 0), 23)
        if clampedStart != workHoursStart { workHoursStart = clampedStart }
        let clampedEnd = min(max(workHoursEnd, 1), 24)
        if clampedEnd != workHoursEnd { workHoursEnd = clampedEnd }
        if workHoursEnd <= workHoursStart {
            let adjustedEnd = min(workHoursStart + 1, 24)
            if workHoursEnd != adjustedEnd { workHoursEnd = adjustedEnd }
        }
    }

    // MARK: - Logging
    func log(_ s: String) {
        AppLogStore.append(s)
        if isCLIRun {
            let lower = s.lowercased()
            if lower.contains("error") || lower.contains("fail") {
                cliRunErrorCount += 1
            }
        }
        DispatchQueue.main.async {
            logText.append("\n" + s)
            let maxLines = 2000
            let lines = logText.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > maxLines {
                logText = lines.suffix(maxLines).joined(separator: "\n")
            }
        }
    }
    
}
