import SwiftUI
import EventKit
import AppKit
import ObjectiveC

/// Placeholder title is configurable via state (see `placeholderTitle`)
private let SAME_TIME_TOL_MIN: Double = 5
private let SKIP_ALL_DAY_DEFAULT = true

private enum AppLogStore {
    private static let queue = DispatchQueue(label: "BusyMirror.log.store")
    private static let maxLogSizeBytes: UInt64 = 1_000_000

    static let logDirectoryURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("Logs/BusyMirror", isDirectory: true)
    }()

    static let logFileURL = logDirectoryURL.appendingPathComponent("BusyMirror.log", isDirectory: false)
    private static let archivedLogFileURL = logDirectoryURL.appendingPathComponent("BusyMirror.previous.log", isDirectory: false)
    static let launchdStdoutURL = logDirectoryURL.appendingPathComponent("launchd.stdout.log", isDirectory: false)
    static let launchdStderrURL = logDirectoryURL.appendingPathComponent("launchd.stderr.log", isDirectory: false)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func append(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        queue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
                if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
                   let size = attrs[.size] as? NSNumber,
                   size.uint64Value >= maxLogSizeBytes {
                    try? fm.removeItem(at: archivedLogFileURL)
                    try? fm.moveItem(at: logFileURL, to: archivedLogFileURL)
                }
                if !fm.fileExists(atPath: logFileURL.path) {
                    fm.createFile(atPath: logFileURL.path, contents: nil)
                }
                guard let data = line.data(using: .utf8),
                      let handle = FileHandle(forWritingAtPath: logFileURL.path) else { return }
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                // Logging must never break the app's main behavior.
            }
        }
    }
}

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

// Calendar label helper to disambiguate identical names
private func calLabel(_ cal: EKCalendar) -> String {
    let src = cal.source.title
    return src.isEmpty ? cal.title : "\(cal.title) — \(src)"
}

// Calendar color helpers
private func calColor(_ cal: EKCalendar) -> Color {
    #if os(macOS)
    return Color(cal.cgColor ?? NSColor.systemGray.cgColor)
    #else
    return Color(cgColor: cal.cgColor ?? UIColor.systemGray.cgColor)
    #endif
}

@ViewBuilder
private func calChip(_ cal: EKCalendar) -> some View {
    HStack(spacing: 6) {
        Circle().fill(calColor(cal)).frame(width: 10, height: 10)
        Text(calLabel(cal))
    }
}

private struct MirrorRecord: Hashable, Codable {
    var targetCalendarID: String
    var sourceCalendarID: String
    var sourceStableID: String
    var occurrenceTimestamp: TimeInterval?
    var targetEventIdentifier: String?
    var lastKnownStartTimestamp: TimeInterval
    var lastKnownEndTimestamp: TimeInterval
    var updatedAt: Date = Date()

    var sourceKey: String {
        sourceOccurrenceKey(
            sourceCalID: sourceCalendarID,
            sourceStableID: sourceStableID,
            occurrence: occurrenceTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    var timeKey: String {
        "\(lastKnownStartTimestamp)|\(lastKnownEndTimestamp)"
    }
}

struct Route: Identifiable, Hashable, Codable {
    let id = UUID()
    var sourceID: String
    var targetIDs: Set<String>
    var privacy: Bool              // true = hide details for this source
    var copyNotes: Bool            // copy description when privacy is OFF
    var mergeGapHours: Int         // per-route merge gap (hours)
    var overlap: OverlapMode       // per-route overlap behavior
    var allDay: Bool               // per-route mirror all-day
    var markPrivate: Bool = false  // mark mirrored events as Private (if supported by account)

    enum CodingKeys: String, CodingKey { case sourceID, targetIDs, privacy, copyNotes, mergeGapHours, overlap, allDay, markPrivate }

    init(sourceID: String, targetIDs: Set<String>, privacy: Bool, copyNotes: Bool, mergeGapHours: Int, overlap: OverlapMode, allDay: Bool, markPrivate: Bool = false) {
        self.sourceID = sourceID
        self.targetIDs = targetIDs
        self.privacy = privacy
        self.copyNotes = copyNotes
        self.mergeGapHours = mergeGapHours
        self.overlap = overlap
        self.allDay = allDay
        self.markPrivate = markPrivate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try c.decode(String.self, forKey: .sourceID)
        self.targetIDs = try c.decode(Set<String>.self, forKey: .targetIDs)
        self.privacy = try c.decode(Bool.self, forKey: .privacy)
        self.copyNotes = try c.decode(Bool.self, forKey: .copyNotes)
        self.mergeGapHours = try c.decode(Int.self, forKey: .mergeGapHours)
        self.overlap = try c.decode(OverlapMode.self, forKey: .overlap)
        self.allDay = try c.decode(Bool.self, forKey: .allDay)
        self.markPrivate = (try? c.decode(Bool.self, forKey: .markPrivate)) ?? false
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
    @AppStorage("markPrivate") private var markPrivate: Bool = false           // If ON, set event Private (server-side) when mirroring
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
    @State private var confirmCleanup = false
    @State private var mirrorTask: Task<Void, Never>? = nil
    @State private var progressText: String? = nil
    // Run-session guard: prevents the same source event from being mirrored
    // into the same target more than once across multiple routes within a
    // single "Mirror Now" click.
    @AppStorage("titlePrefix") private var titlePrefix: String = "🪞 "   // global title prefix for mirrored placeholders
    @AppStorage("placeholderTitle") private var placeholderTitle: String = "Busy"   // global customizable placeholder title
    @AppStorage("autoDeleteMissing") private var autoDeleteMissing: Bool = true       // delete mirrors whose source instance no longer exists
    private let mirrorIndexDefaultsKey = "mirror-index.v1"
    
    // Mirrors can run either by manual selection (source + at least one target)
    // or using predefined routes. This derived flag controls the Mirror Now button.
    private var canRunMirrorNow: Bool {
        let hasManualTargets = !targetIDs.isEmpty
        let hasRouteTargets = routes.contains { !$0.targetIDs.isEmpty }
        return hasAccess && !isRunning && !calendars.isEmpty && (hasManualTargets || hasRouteTargets)
    }

    private func loadMirrorIndex() -> [String: MirrorRecord] {
        guard let data = UserDefaults.standard.data(forKey: mirrorIndexDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: MirrorRecord].self, from: data)
        } catch {
            log("✗ Failed to load mirror index: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveMirrorIndex(_ index: [String: MirrorRecord]) {
        do {
            let data = try JSONEncoder().encode(index)
            UserDefaults.standard.set(data, forKey: mirrorIndexDefaultsKey)
        } catch {
            log("✗ Failed to save mirror index: \(error.localizedDescription)")
        }
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

    @ViewBuilder
    private func calendarsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source calendar")
                .font(.subheadline.weight(.semibold))
            Picker("Source", selection: $sourceIndex) {
                ForEach(Array(calendars.indices), id: \.self) { i in
                    Text("\(i + 1): \(calLabel(calendars[i]))").tag(i)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isRunning || calendars.isEmpty)

            Divider()

            HStack {
                Text("Target calendars")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(targetIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(calendars.indices), id: \.self) { i in
                        let isSource = (i == sourceIndex)
                        let binding = Binding<Bool>(
                            get: { !isSource && targetSelections.contains(i) },
                            set: { newValue in
                                // Never allow selecting the source as a target
                                if isSource { return }
                                if newValue {
                                    targetSelections.insert(i)
                                    targetIDs.insert(calendars[i].calendarIdentifier)
                                } else {
                                    targetSelections.remove(i)
                                    targetIDs.remove(calendars[i].calendarIdentifier)
                                }
                            }
                        )
                        Toggle(isOn: binding) {
                            HStack(spacing: 8) {
                                Text("\(i + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                calChip(calendars[i])
                            }
                            .padding(.vertical, 3)
                        }
                        .toggleStyle(.switch)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                        )
                        .disabled(isRunning || isSource)
                        .opacity(isSource ? 0.5 : 1)
                    }
                }
            }
            .frame(minHeight: 170, maxHeight: 260)
        }
    }

    @ViewBuilder
    private func routesSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Routes (multi-source)")
                    .font(.headline)
                Spacer()
                Button("Add from current selection") {
                    guard let sid = sourceID, !targetIDs.isEmpty else { return }
                    let r = Route(sourceID: sid,
                                  targetIDs: targetIDs,
                                  privacy: hideDetails,
                                  copyNotes: copyDescription,
                                  mergeGapHours: mergeGapHours,
                                  overlap: overlapMode,
                                  allDay: mirrorAllDay,
                                  markPrivate: markPrivate)
                    routes.append(r)
                }
                .disabled(isRunning || calendars.isEmpty || targetIDs.isEmpty)
                .buttonStyle(.borderedProminent)
                Button("Clear") { routes.removeAll() }
                    .disabled(isRunning || routes.isEmpty)
                    .buttonStyle(.bordered)
            }
            if routes.isEmpty {
                Text("No routes yet. Pick a Source and Targets above, then click ‘Add from current selection’.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach($routes, id: \.id) { routeBinding in
                        routeCard(for: routeBinding)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routeCard(for routeBinding: Binding<Route>) -> some View {
        let route = routeBinding.wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    sourceSummaryView(for: route)
                    targetSummaryView(for: route)
                }
                Spacer(minLength: 12)
                Button(role: .destructive) { removeRoute(id: route.id) } label: { Text("Remove") }
            }

            Divider()

            Toggle("Private", isOn: routeBinding.privacy)
                .help("If ON, mirror as ‘\(titlePrefix)\(placeholderTitle)’ with no notes. If OFF, mirror source title (and optionally notes).")
            Toggle("Copy description", isOn: routeBinding.copyNotes)
                .disabled(isRunning || route.privacy)
                .help("If ON and Private is OFF, copy the source event’s notes/description into the placeholder.")
            Toggle("Mark mirrored events as Private", isOn: routeBinding.markPrivate)
                .disabled(isRunning)
                .help("If ON, attempt to mark mirrored events as Private on the server (e.g., Exchange). Titles still use your prefix and source title.")
            Toggle("Mirror all-day events for this route", isOn: routeBinding.allDay)
                .disabled(isRunning)
                .help("Mirror all-day events for this source.")

            HStack(spacing: 16) {
                mergeGapField(for: routeBinding)
                overlapPicker(for: routeBinding)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.25), lineWidth: 1.1)
        )
    }

    @ViewBuilder
    private func sourceSummaryView(for route: Route) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sCal = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) {
                HStack(spacing: 6) {
                    Circle().fill(calColor(sCal)).frame(width: 10, height: 10)
                    Text(calLabel(sCal))
                        .fontWeight(.semibold)
                }
            } else {
                Text(labelForCalendar(id: route.sourceID))
                    .fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private func targetSummaryView(for route: Route) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Targets")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(route.targetIDs.sorted(by: <), id: \.self) { tid in
                        if let tCal = calendars.first(where: { $0.calendarIdentifier == tid }) {
                            HStack(spacing: 6) {
                                Circle().fill(calColor(tCal)).frame(width: 9, height: 9)
                                Text(calLabel(tCal))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 999, style: .continuous)
                                    .fill(Color.primary.opacity(0.1))
                            )
                        } else {
                            Text(labelForCalendar(id: tid))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                                        .fill(Color.primary.opacity(0.1))
                                )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mergeGapField(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 8) {
            Text("Merge gap")
            TextField("0", value: routeBinding.mergeGapHours, formatter: Self.intFormatter)
                .frame(width: 56)
                .disabled(isRunning)
                .help("Merge adjacent source events separated by ≤ this many hours (e.g., flight legs). 0 = no merge.")
            Text("h").foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func overlapPicker(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 8) {
            Text("Overlap")
            Picker("Overlap", selection: routeBinding.overlap) {
                ForEach(OverlapMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 170)
            .help("allow = always place; skipCovered = skip if target already has a block covering the time; fillGaps = only fill uncovered gaps within the source block.")
        }
        .font(.subheadline)
    }

    private func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
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
                markPrivate: r.markPrivate,
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
                writeEnabled: writeEnabled
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
            await runMirror(config: config, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: true)
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
            markPrivate: markPrivate,
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
            writeEnabled: writeEnabled
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
                await runMirror(config: config, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: false)
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Days back")
                        TextField("1", value: $daysBack, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                    }
                    HStack(spacing: 8) {
                        Text("Days forward")
                        TextField("7", value: $daysForward, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                    }
                    HStack(spacing: 8) {
                        Text("Default merge gap")
                        TextField("0", value: $mergeGapHours, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                        Text("h").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Days back")
                        TextField("1", value: $daysBack, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                    }
                    HStack(spacing: 8) {
                        Text("Days forward")
                        TextField("7", value: $daysForward, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                    }
                    HStack(spacing: 8) {
                        Text("Default merge gap")
                        TextField("0", value: $mergeGapHours, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .disabled(isRunning)
                        Text("h").foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: daysBack) { v in daysBack = max(0, v) }
            .onChange(of: daysForward) { v in daysForward = max(0, v) }
            .onChange(of: mergeGapHours) { _ in saveSettingsToDefaults() }

            Divider()

            Toggle("Hide details (use \"Busy\" title)", isOn: $hideDetails)
                .disabled(isRunning)
            Toggle("Copy description when mirroring", isOn: $copyDescription)
                .disabled(isRunning || hideDetails)
            Toggle("Mark mirrored events as Private (if supported)", isOn: $markPrivate)
                .disabled(isRunning)
            Toggle("Mirror all-day events", isOn: $mirrorAllDay)
                .disabled(isRunning)
            Toggle("Mirror accepted events only", isOn: $mirrorAcceptedOnly)
                .disabled(isRunning)

            Picker("Overlap mode", selection: $overlapModeRaw) {
                ForEach(OverlapMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("Title prefix")
                    TextField("🪞 ", text: $titlePrefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(isRunning)
                    Text("Placeholder title")
                    TextField("Busy", text: $placeholderTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .disabled(isRunning)
                    Text("(prefix may be blank)").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Title prefix")
                        TextField("🪞 ", text: $titlePrefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(isRunning)
                    }
                    HStack(spacing: 8) {
                        Text("Placeholder title")
                        TextField("Busy", text: $placeholderTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                            .disabled(isRunning)
                    }
                }
            }

            Toggle("Limit mirroring to work hours", isOn: $filterByWorkHours)
                .disabled(isRunning)
                .onChange(of: filterByWorkHours) { _ in saveSettingsToDefaults() }

            if filterByWorkHours {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Start hour")
                        TextField("9", value: $workHoursStart, formatter: Self.hourFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .disabled(isRunning)
                        Text("End hour")
                        TextField("17", value: $workHoursEnd, formatter: Self.hourFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .disabled(isRunning)
                        Text("(local time)").foregroundStyle(.secondary)
                    }
                    Text("Events starting outside this range are skipped; end hour is exclusive.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .onChange(of: workHoursStart) { _ in
                    clampWorkHours()
                    saveSettingsToDefaults()
                }
                .onChange(of: workHoursEnd) { _ in
                    clampWorkHours()
                    saveSettingsToDefaults()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Skip source titles (one per line)")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $excludedTitleFiltersRaw)
                    .font(.body)
                    .frame(minHeight: 82)
                    .disabled(isRunning)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.22))
                    )
                Text("Matches are case-insensitive and apply before mirroring.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .onChange(of: excludedTitleFiltersRaw) { _ in saveSettingsToDefaults() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Skip organizers (name or email, one per line)")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $excludedOrganizerFiltersRaw)
                    .font(.body)
                    .frame(minHeight: 82)
                    .disabled(isRunning)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.22))
                    )
                Text("Checks organizer name, email, or URL. Case-insensitive.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .onChange(of: excludedOrganizerFiltersRaw) { _ in saveSettingsToDefaults() }

            Divider()

            Toggle("Write to calendars (disable for Dry-Run)", isOn: $writeEnabled)
                .disabled(isRunning)
            Toggle("Auto-delete mirrors if source is removed", isOn: $autoDeleteMissing)
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduled runs")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Picker("Mode", selection: Binding(
                        get: { scheduleMode },
                        set: { newValue in
                            scheduleMode = newValue
                            scheduleWeekdaysOnly = (newValue == .weekdays)
                        }
                    )) {
                        ForEach(ScheduleMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isRunning)
                    Spacer(minLength: 0)
                }
                if scheduleMode == .hourly {
                    HStack(spacing: 8) {
                        Text("Every")
                        TextField("1", value: $scheduleIntervalHours, formatter: Self.smallIntFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .disabled(isRunning)
                        Text(scheduleIntervalHours == 1 ? "hour" : "hours")
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Time")
                        TextField("8", value: $scheduleHour, formatter: Self.hourFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .disabled(isRunning)
                        Text(":")
                        TextField("0", value: $scheduleMinute, formatter: Self.intFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .disabled(isRunning)
                        Spacer(minLength: 0)
                    }
                }
                Text("Creates a LaunchAgent that runs the installed app with saved routes in write mode.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Text(hasInstalledSchedule ? "Installed: \(scheduleSummary)" : "Not installed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Install Schedule") { installSchedule() }
                        .disabled(isRunning || routes.isEmpty)
                    Button("Remove Schedule") { removeSchedule() }
                        .disabled(isRunning || !hasInstalledSchedule)
                    Button("Reveal LaunchAgent") {
                        NSWorkspace.shared.activateFileViewerSelecting([launchAgentURL])
                    }
                    .disabled(!hasInstalledSchedule)
                    Spacer(minLength: 0)
                }
            }
            .onChange(of: scheduleHour) { _ in clampScheduleTime() }
            .onChange(of: scheduleMinute) { _ in clampScheduleTime() }
            .onChange(of: scheduleIntervalHours) { _ in clampScheduleTime() }

            HStack(spacing: 10) {
                Button("Cleanup Placeholders") {
                    if writeEnabled {
                        // Real delete: ask for confirmation first
                        confirmCleanup = true
                    } else {
                        // Dry-run: run without confirmation
                        Task {
                            if routes.isEmpty {
                                await runCleanup()
                            } else {
                                for r in routes {
                                    if let sIdx = indexForCalendar(id: r.sourceID) {
                                        await MainActor.run {
                                            sourceIndex = sIdx
                                            sourceID = r.sourceID
                                            targetIDs = r.targetIDs
                                        }
                                        await runCleanup()
                                    }
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

    @ViewBuilder
    private func logSection() -> some View {
        TextEditor(text: Binding(get: { logText }, set: { _ in }))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22))
            )
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
                                calendarsSection()
                            }
                            panelCard(title: "General Settings", subtitle: "Mirroring rules, filters, and actions", symbol: "slider.horizontal.3") {
                                optionsSection()
                            }
                            panelCard(title: "Routes", subtitle: "\(routes.count) configured", symbol: "arrow.triangle.branch") {
                                routesSection()
                            }
                            panelCard(title: "Activity Log", subtitle: "Latest events and dry-run output", symbol: "terminal") {
                                logSection()
                            }
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 12) {
                                    panelCard(title: "Calendars", subtitle: "Source: \(selectedSourceName)", symbol: "calendar") {
                                        calendarsSection()
                                    }
                                    panelCard(title: "General Settings", subtitle: "Mirroring rules, filters, and actions", symbol: "slider.horizontal.3") {
                                        optionsSection()
                                    }
                                }
                                .frame(width: 430, alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true)

                                VStack(spacing: 12) {
                                    panelCard(title: "Routes", subtitle: "\(routes.count) configured", symbol: "arrow.triangle.branch") {
                                        routesSection()
                                    }
                                    panelCard(title: "Activity Log", subtitle: "Latest events and dry-run output", symbol: "terminal") {
                                        logSection()
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
                        await runCleanup()
                    } else {
                        for r in routes {
                            if let sIdx = indexForCalendar(id: r.sourceID) {
                                await MainActor.run {
                                    sourceIndex = sIdx
                                    sourceID = r.sourceID
                                    targetIDs = r.targetIDs
                                }
                                await runCleanup()
                            }
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
        }
        .onDisappear {
            appController.setMainWindowVisible(false)
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
        .onChange(of: mirrorAllDay) { _ in saveSettingsToDefaults() }
        .onChange(of: mirrorAcceptedOnly) { _ in saveSettingsToDefaults() }
        .onChange(of: overlapModeRaw) { _ in saveSettingsToDefaults() }
        .onChange(of: titlePrefix) { _ in saveSettingsToDefaults() }
        .onChange(of: placeholderTitle) { _ in saveSettingsToDefaults() }
        .onChange(of: autoDeleteMissing) { _ in saveSettingsToDefaults() }
        .onChange(of: markPrivate) { _ in saveSettingsToDefaults() }
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
        }
    }
    
    // MARK: - CLI support
    func tryRunCLIIfPresent() {
        let args = CommandLine.arguments
        let routesIdx = args.firstIndex(of: "--routes")
        let runSavedRoutes = args.contains("--run-saved-routes")
        guard routesIdx != nil || runSavedRoutes else { return }
        isCLIRun = true

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
                NSApp.terminate(nil)
                return
            }

            let cliConfig = makeMirrorConfig()
            if runSavedRoutes {
                if routes.isEmpty {
                    log("CLI: no saved routes; aborting")
                } else if boolArg("--cleanup-only", default: false) {
                    for r in routes {
                        if let sIdx = indexForCalendar(id: r.sourceID) {
                            await MainActor.run {
                                sourceIndex = sIdx
                                sourceID = r.sourceID
                                targetIDs = r.targetIDs
                            }
                            log("CLI: cleanup saved route \(r.sourceID)")
                            await runCleanup()
                        }
                    }
                } else {
                    var sessionGuard = Set<String>()
                    await runConfiguredRoutes(routes, sessionGuard: &sessionGuard)
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
                        await runCleanup()
                    } else {
                        log("CLI: mirror route \(part)")
                        var sessionGuard = Set<String>()
                        await runMirror(config: cliConfig, sourceCalendar: srcCal, targetCalendars: targets, sessionGuard: &sessionGuard, isMultiRouteRun: false)
                    }
                }
            }
            if CommandLine.arguments.contains("--exit") || isCLIRun {
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
        handlePendingMenuBarSyncIfNeeded()
    }
    
    // MARK: - Mirror engine (EventKit)
    func runMirror(config: MirrorConfig, sourceCalendar: EKCalendar, targetCalendars: [EKCalendar], sessionGuard: inout Set<String>, isMultiRouteRun: Bool) async {
        guard hasAccess else {
            log("Cannot mirror: calendar access is not granted.")
            return
        }
        guard !calendars.isEmpty else {
            log("Cannot mirror: no calendars loaded. Try Refresh Calendars.")
            return
        }
        let srcCal = sourceCalendar
        let srcName = calLabel(srcCal)
        let targets = targetCalendars.filter { $0.calendarIdentifier != srcCal.calendarIdentifier }
        if targets.isEmpty {
            log("No target calendars selected. Choose at least one target or add a route with valid targets.")
            return
        }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -config.daysBack, to: todayStart)!
        let windowEnd = cal.date(byAdding: .day, value: config.daysForward, to: todayStart)!
        log("=== BusyMirror ===")
        log("Source: \(srcName)  Targets: \(targets.map { calLabel($0) }.joined(separator: ", "))")
        log("Window: \(windowStart) -> \(windowEnd)")
        log("WRITE: \(config.writeEnabled) \(config.writeEnabled ? "" : "(DRY-RUN)")  mode: \(config.overlapMode.rawValue)  mergeGapMin: \(config.mergeGapMin)  allDay: \(config.mirrorAllDay)")
        log("Route: \(srcName) → {\(targets.map { calLabel($0) }.joined(separator: ", "))}")

        // Source events (recurrences expanded by EventKit)
        let srcPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [srcCal])
        var srcEvents = store.events(matching: srcPred)
        let srcFetched = srcEvents.count
        srcEvents = srcEvents.filter { $0.calendar.calendarIdentifier == srcCal.calendarIdentifier }
        let srcKept = srcEvents.count
        if srcKept != srcFetched {
            log("- WARN: filtered \(srcFetched - srcKept) stray source event(s) not in \(srcName)")
        }
        srcEvents.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        var srcBlocks: [Block] = []
        var skippedMirrors = 0
        let titleFilters = config.excludedTitleFilterTerms
        let organizerFilters = config.excludedOrganizerFilterTerms
        let enforceWorkHours = config.filterByWorkHours && config.workHoursEnd > config.workHoursStart
        let allowedStartMinutes = config.workHoursStart * 60
        let allowedEndMinutes = config.workHoursEnd * 60
        var skippedWorkHours = 0
        var skippedTitles = 0
        var skippedOrganizers = 0
        var skippedStatus = 0
        for ev in srcEvents {
            if Task.isCancelled { break }
            if config.mirrorAcceptedOnly, ev.hasAttendees {
                let attendees = ev.attendees ?? []
                if let me = attendees.first(where: { $0.isCurrentUser }) {
                    if me.participantStatus != .accepted {
                        skippedStatus += 1
                        continue
                    }
                } else {
                    skippedStatus += 1
                    continue
                }
            }
            if enforceWorkHours, !ev.isAllDay, let start = ev.startDate,
               isOutsideWorkHours(start, calendar: cal, startMinutes: allowedStartMinutes, endMinutes: allowedEndMinutes) {
                skippedWorkHours += 1
                continue
            }
            if shouldSkip(title: ev.title, filters: titleFilters, titlePrefix: config.titlePrefix) {
                skippedTitles += 1
                continue
            }
            if shouldSkipOrganizer(organizerValues: organizerStrings(for: ev), filters: organizerFilters) {
                skippedOrganizers += 1
                continue
            }
            if !config.mirrorAllDay && ev.isAllDay { continue }
            if isMirrorEvent(ev, prefix: config.titlePrefix, placeholder: config.placeholderTitle) {
                skippedMirrors += 1
                continue
            }
            guard let s = ev.startDate, let e = ev.endDate, e > s else { continue }
            guard ev.calendar.calendarIdentifier == srcCal.calendarIdentifier else { continue }
            let srcID = stableSourceIdentifier(for: ev)
            srcBlocks.append(Block(start: s, end: e, srcStableID: srcID, label: ev.title, notes: ev.notes, occurrence: ev.occurrenceDate))
        }
        if skippedMirrors > 0 {
            log("- SKIP mirrored-on-source: \(skippedMirrors) instance(s)")
        }
        if skippedWorkHours > 0 {
            log("- SKIP outside work hours: \(skippedWorkHours) event(s)")
        }
        if skippedTitles > 0 {
            log("- SKIP title filter: \(skippedTitles) event(s)")
        }
        if skippedOrganizers > 0 {
            log("- SKIP organizer filter: \(skippedOrganizers) event(s)")
        }
        if skippedStatus > 0 {
            log("- SKIP non-accepted status: \(skippedStatus) event(s)")
        }
        srcBlocks = uniqueBlocks(srcBlocks, trackByID: config.mergeGapMin == 0)

        let baseBlocks = (config.mergeGapMin > 0) ? mergeBlocks(srcBlocks, gapMinutes: config.mergeGapMin) : srcBlocks
        let trackByID = (config.mergeGapMin == 0)
        var mirrorIndex = loadMirrorIndex()
        var mirrorIndexChanged = false

        func sourceKey(for blk: Block) -> String? {
            guard trackByID, let sid = blk.srcStableID else { return nil }
            return sourceOccurrenceKey(sourceCalID: srcCal.calendarIdentifier, sourceStableID: sid, occurrence: blk.occurrence)
        }

        // Cache target events across routes when possible
        var targetEventCache: [String: [EKEvent]] = [:]
        for tgt in targets {
            if Task.isCancelled { break }
            let tgtName = calLabel(tgt)
            log(">>> Target: \(tgtName)")
            if tgt.calendarIdentifier == srcCal.calendarIdentifier {
                log("- SKIP target is same as source: \(tgtName)")
                continue
            }
            let tgtEvents: [EKEvent]
            if let cached = targetEventCache[tgt.calendarIdentifier] {
                tgtEvents = cached
            } else {
                let tgtPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [tgt])
                var evs = store.events(matching: tgtPred)
                let tgtFetched = evs.count
                evs = evs.filter { $0.calendar.calendarIdentifier == tgt.calendarIdentifier }
                if tgtFetched != evs.count {
                    log("- WARN: filtered \(tgtFetched - evs.count) stray target event(s) not in \(tgtName)")
                }
                targetEventCache[tgt.calendarIdentifier] = evs
                tgtEvents = evs
            }

            var placeholderSet = Set<String>()
            var occupied: [Block] = []
            var placeholdersBySourceKey: [String: EKEvent] = [:]
            var placeholdersByTime: [String: EKEvent] = [:]
            var targetEventsByIdentifier: [String: EKEvent] = [:]
            for tv in tgtEvents {
                guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                if let eid = tv.eventIdentifier {
                    targetEventsByIdentifier[eid] = tv
                }
                if let ts = tv.startDate, let te = tv.endDate {
                    let timeKey = mirrorTimeKey(start: ts, end: te)
                    if isMirrorEvent(tv, prefix: config.titlePrefix, placeholder: config.placeholderTitle) {
                        placeholderSet.insert(timeKey)
                        placeholdersByTime[timeKey] = tv
                        let parsed = parseMirrorURL(tv.url)
                        if let sourceCalID = parsed.sourceCalID,
                           let sourceStableID = parsed.sourceStableID,
                           !sourceCalID.isEmpty,
                           !sourceStableID.isEmpty {
                            let key = sourceOccurrenceKey(sourceCalID: sourceCalID, sourceStableID: sourceStableID, occurrence: parsed.occ)
                            placeholdersBySourceKey[key] = tv
                            let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                            let record = MirrorRecord(
                                targetCalendarID: tgt.calendarIdentifier,
                                sourceCalendarID: sourceCalID,
                                sourceStableID: sourceStableID,
                                occurrenceTimestamp: parsed.occ?.timeIntervalSince1970,
                                targetEventIdentifier: tv.eventIdentifier,
                                lastKnownStartTimestamp: ts.timeIntervalSince1970,
                                lastKnownEndTimestamp: te.timeIntervalSince1970
                            )
                            if mirrorIndex[recordKey] != record {
                                mirrorIndex[recordKey] = record
                                mirrorIndexChanged = true
                            }
                        }
                    }
                    occupied.append(Block(start: ts, end: te, srcStableID: nil, label: nil, notes: nil, occurrence: nil))
                }
            }
            occupied = coalesce(occupied)

            var created = 0
            var skipped = 0
            var updated = 0
            var warnedPrivateUnsupported = false

            func guardKey(for blk: Block, targetID: String) -> String {
                if let key = sourceKey(for: blk) {
                    return "\(key)|\(targetID)"
                }
                return "\(srcCal.calendarIdentifier)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)|\(targetID)"
            }

            func desiredNotes(for blk: Block) -> String? {
                (!config.hideDetails && config.copyDescription) ? blk.notes : nil
            }

            func upsertMirrorRecord(for blk: Block, event: EKEvent) {
                guard let sid = blk.srcStableID,
                      let key = sourceKey(for: blk),
                      let startDate = event.startDate,
                      let endDate = event.endDate else { return }
                let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                let record = MirrorRecord(
                    targetCalendarID: tgt.calendarIdentifier,
                    sourceCalendarID: srcCal.calendarIdentifier,
                    sourceStableID: sid,
                    occurrenceTimestamp: blk.occurrence?.timeIntervalSince1970,
                    targetEventIdentifier: event.eventIdentifier,
                    lastKnownStartTimestamp: startDate.timeIntervalSince1970,
                    lastKnownEndTimestamp: endDate.timeIntervalSince1970
                )
                if mirrorIndex[recordKey] != record {
                    mirrorIndex[recordKey] = record
                    mirrorIndexChanged = true
                }
            }

            func removeMirrorRecord(for key: String) {
                let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                if mirrorIndex.removeValue(forKey: recordKey) != nil {
                    mirrorIndexChanged = true
                }
            }

            func resolveMappedEvent(for record: MirrorRecord) -> EKEvent? {
                if let eid = record.targetEventIdentifier,
                   let event = targetEventsByIdentifier[eid],
                   event.calendar.calendarIdentifier == tgt.calendarIdentifier {
                    return event
                }
                return placeholdersByTime[record.timeKey]
            }

            func rememberMirrorEvent(_ event: EKEvent, for blk: Block) {
                if let startDate = event.startDate, let endDate = event.endDate {
                    let timeKey = mirrorTimeKey(start: startDate, end: endDate)
                    placeholderSet.insert(timeKey)
                    placeholdersByTime[timeKey] = event
                }
                if let key = sourceKey(for: blk) {
                    placeholdersBySourceKey[key] = event
                }
                if let eid = event.eventIdentifier {
                    targetEventsByIdentifier[eid] = event
                }
                upsertMirrorRecord(for: blk, event: event)
            }

            func needsUpdate(existing: EKEvent, blk: Block, displayTitle: String, desiredNotes: String?, desiredURL: URL?) -> Bool {
                let curS = existing.startDate ?? blk.start
                let curE = existing.endDate ?? blk.end
                if abs(curS.timeIntervalSince(blk.start)) > SAME_TIME_TOL_MIN * 60 { return true }
                if abs(curE.timeIntervalSince(blk.end)) > SAME_TIME_TOL_MIN * 60 { return true }
                if (existing.title ?? "") != displayTitle { return true }
                if (existing.notes ?? "") != (desiredNotes ?? "") { return true }
                if existing.isAllDay { return true }
                if (existing.url?.absoluteString ?? "") != (desiredURL?.absoluteString ?? "") { return true }
                return false
            }

            func createOrUpdateIfNeeded(_ blk: Block) async {
                let gKey = guardKey(for: blk, targetID: tgt.calendarIdentifier)
                if sessionGuard.contains(gKey) {
                    skipped += 1
                    log("- SKIP loop-guard [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    return
                }

                let baseSourceTitle = stripPrefix(blk.label, prefix: config.titlePrefix)
                let effectiveTitle = config.hideDetails ? config.placeholderTitle : (baseSourceTitle.isEmpty ? config.placeholderTitle : baseSourceTitle)
                let titleSuffix = config.hideDetails ? "" : (baseSourceTitle.isEmpty ? "" : " — \(baseSourceTitle)")
                let displayTitle = (config.titlePrefix.isEmpty ? "" : config.titlePrefix) + effectiveTitle
                let notes = desiredNotes(for: blk)
                let desiredURL = buildMirrorURL(
                    targetCalID: tgt.calendarIdentifier,
                    sourceCalID: srcCal.calendarIdentifier,
                    sourceStableID: blk.srcStableID,
                    occurrence: blk.occurrence,
                    start: blk.start,
                    end: blk.end
                )
                let exactTimeKey = mirrorTimeKey(start: blk.start, end: blk.end)
                let blkSourceKey = sourceKey(for: blk)

                func updateExisting(_ existing: EKEvent, byTime: Bool) async {
                    let curS = existing.startDate ?? blk.start
                    let curE = existing.endDate ?? blk.end
                    rememberMirrorEvent(existing, for: blk)
                    if !needsUpdate(existing: existing, blk: blk, displayTitle: displayTitle, desiredNotes: notes, desiredURL: desiredURL) {
                        sessionGuard.insert(gKey)
                        skipped += 1
                        return
                    }
                    let byTimeSuffix = byTime ? " (by time)" : ""
                    if !config.writeEnabled {
                        sessionGuard.insert(gKey)
                        log("~ WOULD UPDATE [\(srcName) -> \(tgtName)]\(byTimeSuffix) \(curS) -> \(curE)  TO  \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                        updated += 1
                        return
                    }
                    existing.title = displayTitle
                    existing.startDate = blk.start
                    existing.endDate = blk.end
                    existing.isAllDay = false
                    existing.notes = notes
                    existing.url = desiredURL
                    let ok = setEventPrivateIfSupported(existing, config.markPrivate)
                    if config.markPrivate && !ok && !warnedPrivateUnsupported {
                        log("- INFO: Mark Private not supported for \(tgtName) [source: \(tgt.source.title)]")
                        warnedPrivateUnsupported = true
                    }
                    do {
                        try await MainActor.run {
                            try store.save(existing, span: .thisEvent, commit: true)
                        }
                        log("✓ UPDATED [\(srcName) -> \(tgtName)]\(byTimeSuffix) \(blk.start) -> \(blk.end)")
                        rememberMirrorEvent(existing, for: blk)
                        occupied = coalesce(occupied + [Block(start: blk.start, end: blk.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)])
                        sessionGuard.insert(gKey)
                        updated += 1
                    } catch {
                        log("Update failed: \(error.localizedDescription)")
                    }
                }

                if let blkSourceKey,
                   let record = mirrorIndex[mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: blkSourceKey)],
                   let existing = resolveMappedEvent(for: record) {
                    await updateExisting(existing, byTime: false)
                    return
                }

                if let blkSourceKey, let existing = placeholdersBySourceKey[blkSourceKey] {
                    await updateExisting(existing, byTime: false)
                    return
                }

                if let existingByTime = placeholdersByTime[exactTimeKey] {
                    await updateExisting(existingByTime, byTime: true)
                    return
                }

                if placeholderSet.contains(exactTimeKey) {
                    skipped += 1
                    return
                }
                if !config.writeEnabled {
                    sessionGuard.insert(gKey)
                    log("+ WOULD CREATE [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                    return
                }
                guard tgt.calendarIdentifier != srcCal.calendarIdentifier else {
                    skipped += 1
                    log("- SKIP invariant: target is source [\(srcName)]")
                    return
                }
                let newEv = EKEvent(eventStore: store)
                newEv.calendar = tgt
                newEv.title = displayTitle
                newEv.startDate = blk.start
                newEv.endDate = blk.end
                newEv.isAllDay = false
                newEv.notes = notes
                newEv.url = desiredURL
                newEv.availability = .busy
                let okNew = setEventPrivateIfSupported(newEv, config.markPrivate)
                if config.markPrivate && !okNew && !warnedPrivateUnsupported {
                    log("- INFO: Mark Private not supported for \(tgtName) [source: \(tgt.source.title)]")
                    warnedPrivateUnsupported = true
                }
                do {
                    try await MainActor.run {
                        try store.save(newEv, span: .thisEvent, commit: true)
                    }
                    created += 1
                    log("✓ CREATED [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    rememberMirrorEvent(newEv, for: blk)
                    occupied = coalesce(occupied + [Block(start: blk.start, end: blk.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)])
                    sessionGuard.insert(gKey)
                } catch {
                    log("Save failed: \(error.localizedDescription)")
                }
            }

            for b in baseBlocks {
                if Task.isCancelled { break }
                switch config.overlapMode {
                case .allow:
                    await createOrUpdateIfNeeded(b)
                case .skipCovered:
                    if fullyCovered(occupied, block: b, tolMin: SAME_TIME_TOL_MIN) {
                        log("- SKIP covered [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        await createOrUpdateIfNeeded(b)
                    }
                case .fillGaps:
                    let gaps = gapsWithin(occupied, in: b)
                    if gaps.isEmpty {
                        log("- SKIP no gaps [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        for g in gaps { await createOrUpdateIfNeeded(g) }
                    }
                }
            }
            log("[Summary → \(tgtName)] created=\(created), updated=\(updated), skipped=\(skipped)")
            if config.autoDeleteMissing {
                let activeSourceKeys = Set(baseBlocks.compactMap { sourceKey(for: $0) })
                let validTimeKeys = Set(baseBlocks.map { mirrorTimeKey(start: $0.start, end: $0.end) })

                var byID: [String: EKEvent] = [:]
                for tv in placeholdersByTime.values {
                    guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                    if let eid = tv.eventIdentifier { byID[eid] = tv }
                }

                var removed = 0
                var skippedOtherSource = 0
                var skippedLegacyNoURL = 0
                var handledEventIDs = Set<String>()

                let staleMirrorRecords = mirrorIndex.filter {
                    $0.value.targetCalendarID == tgt.calendarIdentifier &&
                    $0.value.sourceCalendarID == srcCal.calendarIdentifier &&
                    !activeSourceKeys.contains($0.value.sourceKey)
                }

                for (recordKey, record) in staleMirrorRecords {
                    if Task.isCancelled { break }
                    let candidate = resolveMappedEvent(for: record)
                    if let candidate {
                        if !config.writeEnabled {
                            log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(candidate.startDate ?? windowStart) -> \(candidate.endDate ?? windowEnd)")
                        } else {
                            do {
                                try await MainActor.run {
                                    try store.remove(candidate, span: .thisEvent, commit: true)
                                }
                                removed += 1
                            } catch {
                                log("Delete failed: \(error.localizedDescription)")
                            }
                        }
                        if let eid = candidate.eventIdentifier {
                            handledEventIDs.insert(eid)
                        }
                    }
                    if config.writeEnabled || candidate == nil {
                        if mirrorIndex.removeValue(forKey: recordKey) != nil {
                            mirrorIndexChanged = true
                        }
                    }
                }

                for ev in byID.values {
                    if Task.isCancelled { break }
                    if let eid = ev.eventIdentifier, handledEventIDs.contains(eid) {
                        continue
                    }
                    let parsed = parseMirrorURL(ev.url)
                    var shouldDelete = false
                    var parsedSourceKey: String? = nil
                    if let sourceCalID = parsed.sourceCalID, !sourceCalID.isEmpty {
                        if sourceCalID != srcCal.calendarIdentifier {
                            skippedOtherSource += 1
                            continue
                        }
                        if let sourceStableID = parsed.sourceStableID, !sourceStableID.isEmpty {
                            let key = sourceOccurrenceKey(sourceCalID: sourceCalID, sourceStableID: sourceStableID, occurrence: parsed.occ)
                            parsedSourceKey = key
                            if !activeSourceKeys.contains(key) { shouldDelete = true }
                        } else if trackByID,
                                  let s = ev.startDate,
                                  let e = ev.endDate,
                                  !validTimeKeys.contains(mirrorTimeKey(start: s, end: e)) {
                            shouldDelete = true
                        }
                    } else if trackByID && !isMultiRouteRun {
                        if let s = ev.startDate,
                           let e = ev.endDate,
                           !validTimeKeys.contains(mirrorTimeKey(start: s, end: e)) {
                            shouldDelete = true
                        }
                    } else if trackByID && isMultiRouteRun {
                        let hasMapping = mirrorIndex.values.contains {
                            $0.targetCalendarID == tgt.calendarIdentifier &&
                            $0.sourceCalendarID == srcCal.calendarIdentifier &&
                            $0.targetEventIdentifier == ev.eventIdentifier
                        }
                        if !hasMapping {
                            skippedLegacyNoURL += 1
                        }
                        continue
                    }
                    if shouldDelete {
                        if !config.writeEnabled {
                            log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(ev.startDate ?? windowStart) -> \(ev.endDate ?? windowEnd)")
                        } else {
                            do {
                                try await MainActor.run {
                                    try store.remove(ev, span: .thisEvent, commit: true)
                                }
                                removed += 1
                            } catch {
                                log("Delete failed: \(error.localizedDescription)")
                            }
                        }
                        if let key = parsedSourceKey {
                            removeMirrorRecord(for: key)
                        }
                    }
                }
                if removed > 0 { log("[Cleanup missing for \(tgtName)] deleted=\(removed)") }
                if skippedOtherSource > 0 {
                    log("- INFO cleanup skipped \(skippedOtherSource) placeholders from other source routes on \(tgtName)")
                }
                if skippedLegacyNoURL > 0 {
                    log("- INFO cleanup skipped \(skippedLegacyNoURL) unmanaged legacy placeholders without source metadata on \(tgtName)")
                }
            }
        }
        if mirrorIndexChanged {
            saveMirrorIndex(mirrorIndex)
        }
    }
    
// MARK: - Export / Import Settings
private struct SettingsPayload: Codable {
    var daysBack: Int
    var daysForward: Int
    var mergeGapHours: Int
    var hideDetails: Bool
    var copyDescription: Bool
    var markPrivate: Bool
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
}

    private func makeSnapshot() -> SettingsPayload {
        SettingsPayload(
            daysBack: daysBack,
            daysForward: daysForward,
            mergeGapHours: mergeGapHours,
            hideDetails: hideDetails,
            copyDescription: copyDescription,
            markPrivate: markPrivate,
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
        mirrorAllDay = s.mirrorAllDay
        markPrivate = s.markPrivate
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
                applySnapshot(snap)
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

    // Best-effort: mark an event as Private if the account/server supports it.
    // Uses ObjC selector lookup to avoid crashes on unsupported keys.
    private func setEventPrivateIfSupported(_ ev: EKEvent, _ flag: Bool) -> Bool {
        guard flag else { return false }
        let sel = Selector(("setPrivate:"))
        if ev.responds(to: sel) {
            _ = ev.perform(sel, with: NSNumber(value: true))
            return true
        }
        // Some backends may expose privacy level via a numeric setter
        let sel2 = Selector(("setPrivacy:"))
        if ev.responds(to: sel2) {
            // 1 may represent private on some providers; this is best-effort.
            _ = ev.perform(sel2, with: NSNumber(value: 1))
            return true
        }
        // Try common KVC keys seen in some providers (best-effort, may be no-ops)
        let kvPairs: [(String, Any)] = [
            ("private", true),
            ("isPrivate", true),
            ("privacy", 1),
            ("sensitivity", 1), // Exchange often: 1=personal, 2=private; varies
            ("classification", 1) // iCalendar CLASS: 1 might map to PRIVATE
        ]
        for (key, val) in kvPairs {
            ev.setValue(val, forKey: key)
            return true
        }
        // Not supported; no-op
        return false
    }

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
        DispatchQueue.main.async {
            logText.append("\n" + s)
            let maxLines = 2000
            let lines = logText.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > maxLines {
                logText = lines.suffix(maxLines).joined(separator: "\n")
            }
        }
    }
    
// MARK: - Cleanup: delete Busy placeholders in the active window on selected targets
    func runCleanup() async {
    guard hasAccess, !calendars.isEmpty else { return }
    guard calendars.indices.contains(sourceIndex) else {
        log("Cannot cleanup: selected source is invalid.")
        return
    }
    isRunning = true
    defer { isRunning = false }

    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    let windowStart = cal.date(byAdding: .day, value: -daysBack, to: todayStart)!
    let windowEnd = cal.date(byAdding: .day, value: daysForward, to: todayStart)!
    let targetSet = Set(targetIDs)
    let targets = calendars.filter { targetSet.contains($0.calendarIdentifier) && $0.calendarIdentifier != calendars[sourceIndex].calendarIdentifier }
    log("=== Cleanup Busy placeholders in window ===")
    log("(Cleanup is SAFE: mirrored events detected by url prefix or title prefix ‘\(titlePrefix)’)")
    log("Window: \(windowStart) -> \(windowEnd)")

    for tgt in targets {
        let tgtPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [tgt])
        let tgtEvents = store.events(matching: tgtPred)
        var delCount = 0
        for ev in tgtEvents {
            guard isMirrorEvent(ev, prefix: titlePrefix, placeholder: placeholderTitle) else { continue }
            if !writeEnabled {
                log("~ WOULD DELETE [\(tgt.title)] \(ev.startDate ?? todayStart) -> \(ev.endDate ?? todayStart)")
            } else {
                do {
                    try await MainActor.run {
                        try store.remove(ev, span: .thisEvent, commit: true)
                    }
                    delCount += 1
                }
                catch { log("Delete failed: \(error.localizedDescription)") }
            }
        }
        log("[Cleanup \(tgt.title)] deleted=\(delCount)")
    }
}
}
