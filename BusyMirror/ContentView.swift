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

// Remove our prefix when building titles so it never doubles up
func stripPrefix(_ title: String?, prefix: String) -> String {
    guard let t = title else { return "" }
    if prefix.isEmpty { return t }
    return t.hasPrefix(prefix) ? String(t.dropFirst(prefix.count)) : t
}

// De-dup blocks by occurrence (preferred) or by time range
func uniqueBlocks(_ blocks: [Block], trackByID: Bool) -> [Block] {
    var seen = Set<String>()
    var out: [Block] = []
    for b in blocks {
        let key: String
        if trackByID, let sid = b.srcEventID {
            let occ = b.occurrence?.timeIntervalSince1970 ?? b.start.timeIntervalSince1970
            key = "id|\(sid)|\(occ)"
        } else {
            key = "t|\(b.start.timeIntervalSince1970)|\(b.end.timeIntervalSince1970)"
        }
        if seen.insert(key).inserted { out.append(b) }
    }
    return out
}

// Parse mirror URL: mirror://<tgtID>|<srcCalID>|<srcEventID>|<occTS>|<startTS>|<endTS>
private func parseMirrorURL(_ url: URL?) -> (targetCalID: String?, sourceCalID: String?, srcEventID: String?, occ: Date?, start: Date?, end: Date?) {
    guard let abs = url?.absoluteString, abs.hasPrefix("mirror://") else { return (nil, nil, nil, nil, nil, nil) }
    let body = abs.dropFirst("mirror://".count)
    let parts = body.split(separator: "|")
    var targetCalID: String? = nil
    var sourceCalID: String? = nil
    var srcID: String? = nil
    var occDate: Date? = nil
    var sDate: Date? = nil
    var eDate: Date? = nil
    if parts.count >= 1 { targetCalID = String(parts[0]) }
    if parts.count >= 2 { sourceCalID = String(parts[1]) }
    if parts.count >= 3 { srcID = String(parts[2]) }
    if parts.count >= 4,
       let ts = TimeInterval(String(parts[3])) {
        occDate = Date(timeIntervalSince1970: ts)
    }
    if parts.count >= 6,
       let sTS = TimeInterval(String(parts[4])),
       let eTS = TimeInterval(String(parts[5])) {
        sDate = Date(timeIntervalSince1970: sTS)
        eDate = Date(timeIntervalSince1970: eTS)
    }
    return (targetCalID, sourceCalID, srcID, occDate, sDate, eDate)
}

// Recognize a mirrored placeholder even if URL is missing
private func isMirrorEvent(_ ev: EKEvent, prefix: String, placeholder: String) -> Bool {
    if ev.url?.absoluteString.hasPrefix("mirror://") ?? false { return true }
    let t = ev.title ?? ""
    if !prefix.isEmpty && t.hasPrefix(prefix) { return true }
    if t == placeholder || (!prefix.isEmpty && t == (prefix + placeholder)) { return true }
    return false
}

struct Block: Hashable {
    let start: Date
    let end: Date
    let srcEventID: String?   // for reschedule tracking
    let label: String?        // source title (for dry-run / non-private)
    let notes: String?        // source notes (for optional copy)
    let occurrence: Date?     // occurrenceDate for recurring instances
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
    @State private var mergeGapMin: Int = 0
    @AppStorage("mergeGapHours") private var mergeGapHours: Int = 0
    @AppStorage("hideDetails") private var hideDetails: Bool = true        // Privacy ON by default -> use "Busy"
    @AppStorage("copyDescription") private var copyDescription: Bool = false   // Only applies when hideDetails == false
    @AppStorage("markPrivate") private var markPrivate: Bool = false           // If ON, set event Private (server-side) when mirroring
    @AppStorage("mirrorAllDay") private var mirrorAllDay: Bool = false
    @AppStorage("overlapMode") private var overlapModeRaw: String = OverlapMode.allow.rawValue
    @AppStorage("filterByWorkHours") private var filterByWorkHours: Bool = false
    @AppStorage("workHoursStart") private var workHoursStart: Int = 9
    @AppStorage("workHoursEnd") private var workHoursEnd: Int = 17
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
    // Run-session guard: prevents the same source event from being mirrored
    // into the same target more than once across multiple routes within a
    // single "Mirror Now" click.
    @State private var sessionGuard = Set<String>()
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

    private func runConfiguredRoutes(_ configuredRoutes: [Route]) async {
        var ranAnyRoute = false
        var skippedMissingSource = 0
        var skippedNoTargets = 0

        for r in configuredRoutes {
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
            let prevPrivacy = hideDetails
            let prevCopy = copyDescription
            let prevGapH = mergeGapHours
            let prevGapM = mergeGapMin
            let prevOverlap = overlapMode
            let prevAllDay = mirrorAllDay
            let prevMarkPrivate = markPrivate

            await MainActor.run {
                sourceIndex = sIdx
                sourceID = r.sourceID
                targetIDs = validTargets
                targetIDs.remove(r.sourceID)
                hideDetails = r.privacy
                copyDescription = r.copyNotes
                mergeGapHours = max(0, r.mergeGapHours)
                mergeGapMin = mergeGapHours * 60
                overlapModeRaw = r.overlap.rawValue
                mirrorAllDay = r.allDay
                markPrivate = r.markPrivate
            }
            await runMirror()
            await MainActor.run {
                hideDetails = prevPrivacy
                copyDescription = prevCopy
                mergeGapHours = prevGapH
                mergeGapMin = prevGapM
                overlapModeRaw = prevOverlap.rawValue
                mirrorAllDay = prevAllDay
                markPrivate = prevMarkPrivate
            }
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

    private func startMirrorNow() {
        Task {
            // New click -> reset the guard so we don't re-process
            sessionGuard.removeAll()
            if routes.isEmpty {
                await runMirror()
            } else {
                await runConfiguredRoutes(routes)
            }
        }
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
            .onChange(of: mergeGapHours) { newVal in
                mergeGapMin = max(0, newVal * 60)
            }

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
        TextEditor(text: $logText)
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
                                Button(isRunning ? "Running…" : "Mirror Now") {
                                    startMirrorNow()
                                }
                                .disabled(!canRunMirrorNow)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
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
            Text("This will remove events identified as mirrored (by URL prefix or title prefix ‘\(titlePrefix)’) within the current window (Days back/forward) from the selected target calendars.")
        }
        .onAppear {
            AppLogStore.append("=== BusyMirror launch ===")
            log("Log file: \(AppLogStore.logFileURL.path)")
            requestAccess()
            loadSettingsFromDefaults()
            mergeGapMin = max(0, mergeGapHours * 60)
            tryRunCLIIfPresent()
            enforceNoSourceInTargets()
        }
        // Persist key settings whenever they change, to ensure restore between runs
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
        }
        .onChange(of: routes) { _ in
            saveSettingsToDefaults()
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
        mergeGapMin = max(0, mergeGapHours * 60)
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
                    await runConfiguredRoutes(routes)
                }
            } else {
                for part in routeParts where !part.isEmpty {
                    // Format: "S->T1,T2,T3" (indices are 1-based as shown in UI)
                    let lr = part.split(separator: "->", maxSplits: 1).map { String($0) }
                    guard lr.count == 2, let s1 = Int(lr[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let srcIdx0 = max(0, s1 - 1)
                    let tgtIdxs0: [Int] = lr[1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces))?.advanced(by: -1) }.filter { $0 >= 0 }
                    if srcIdx0 >= calendars.count { continue }
                    await MainActor.run {
                        sourceIndex = srcIdx0
                        sourceID = calendars[srcIdx0].calendarIdentifier
                        targetSelections = Set(tgtIdxs0)
                        targetIDs = Set(tgtIdxs0.compactMap { i in calendars.indices.contains(i) ? calendars[i].calendarIdentifier : nil })
                    }

                    if boolArg("--cleanup-only", default: false) {
                        log("CLI: cleanup route \(part)")
                        await runCleanup()
                    } else {
                        log("CLI: mirror route \(part)")
                        await runMirror()
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
    }
    
    // MARK: - Mirror engine (EventKit)
    func runMirror() async {
        guard hasAccess else {
            log("Cannot mirror: calendar access is not granted.")
            return
        }
        guard !calendars.isEmpty else {
            log("Cannot mirror: no calendars loaded. Try Refresh Calendars.")
            return
        }
        guard calendars.indices.contains(sourceIndex) else {
            log("Cannot mirror: selected source is invalid.")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let srcCal = calendars[sourceIndex]
        // Ensure sourceID is set when we start
        sourceID = srcCal.calendarIdentifier
        // Extra safety: drop source from targets before computing them
        enforceNoSourceInTargets()
        let srcName = calLabel(srcCal)
        // Build targets by identifier to be robust against index/order changes
        let targetSet = Set(targetIDs)
        // Additional guard: log and strip if source sneaks into targets
        if targetSet.contains(srcCal.calendarIdentifier) { log("- WARN: source is present in targets, removing: \(srcName)") }
        let targetSetNoSrc = targetSet.subtracting([srcCal.calendarIdentifier])
        let targets = calendars.filter { targetSetNoSrc.contains($0.calendarIdentifier) }
        if targets.isEmpty {
            log("No target calendars selected. Choose at least one target or add a route with valid targets.")
            return
        }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -daysBack, to: todayStart)!
        let windowEnd = cal.date(byAdding: .day, value: daysForward, to: todayStart)!
        log("=== BusyMirror ===")
        log("Source: \(srcName)  Targets: \(targets.map { calLabel($0) }.joined(separator: ", "))")
        log("Window: \(windowStart) -> \(windowEnd)")
        log("WRITE: \(writeEnabled) \(writeEnabled ? "" : "(DRY-RUN)")  mode: \(overlapMode.rawValue)  mergeGapMin: \(mergeGapMin)  allDay: \(mirrorAllDay)")
        log("Route: \(srcName) → {\(targets.map { calLabel($0) }.joined(separator: ", "))}")

        // Source events (recurrences expanded by EventKit)
        let srcPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [srcCal])
        var srcEvents = store.events(matching: srcPred)
        let srcFetched = srcEvents.count
        // HARD FILTER: even if EventKit returns events from other calendars, keep only exact source calendar
        srcEvents = srcEvents.filter { $0.calendar.calendarIdentifier == srcCal.calendarIdentifier }
        let srcKept = srcEvents.count
        if srcKept != srcFetched {
            log("- WARN: filtered \(srcFetched - srcKept) stray source event(s) not in \(srcName)")
        }
        srcEvents.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        var srcBlocks: [Block] = []
        var skippedMirrors = 0
        let titleFilters = excludedTitleFilterTerms
        let organizerFilters = excludedOrganizerFilterTerms
        let enforceWorkHours = filterByWorkHours && workHoursEnd > workHoursStart
        let allowedStartMinutes = workHoursStart * 60
        let allowedEndMinutes = workHoursEnd * 60
        var skippedWorkHours = 0
        var skippedTitles = 0
        var skippedOrganizers = 0
        var skippedStatus = 0
        for ev in srcEvents {
            if mirrorAcceptedOnly, ev.hasAttendees {
                // Only include events where the current user's attendee status is Accepted
                let attendees = ev.attendees ?? []
                if let me = attendees.first(where: { $0.isCurrentUser }) {
                    if me.participantStatus != .accepted {
                        skippedStatus += 1
                        continue
                    }
                } else {
                    // If we cannot determine a self attendee, treat as not accepted
                    skippedStatus += 1
                    continue
                }
            }
            if enforceWorkHours, !ev.isAllDay, let start = ev.startDate,
               isOutsideWorkHours(start, calendar: cal, startMinutes: allowedStartMinutes, endMinutes: allowedEndMinutes) {
                skippedWorkHours += 1
                continue
            }
            if shouldSkip(event: ev, filters: titleFilters) {
                skippedTitles += 1
                continue
            }
            if shouldSkipOrganizer(event: ev, filters: organizerFilters) {
                skippedOrganizers += 1
                continue
            }
            if SKIP_ALL_DAY_DEFAULT == true && mirrorAllDay == false && ev.isAllDay { continue }
            if isMirrorEvent(ev, prefix: titlePrefix, placeholder: placeholderTitle) {
                // Aggregate skip count for mirrored-on-source
                skippedMirrors += 1
                continue
            }
            guard let s = ev.startDate, let e = ev.endDate, e > s else { continue }
            // Defensive: never treat events from another calendar as source
            guard ev.calendar.calendarIdentifier == srcCal.calendarIdentifier else { continue }
            let srcID = ev.eventIdentifier // stable across launches unless event is deleted
            srcBlocks.append(Block(start: s, end: e, srcEventID: srcID, label: ev.title, notes: ev.notes, occurrence: ev.occurrenceDate))
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
        // Deduplicate source blocks to avoid duplicates from EventKit (recurrences / sync races)
        srcBlocks = uniqueBlocks(srcBlocks, trackByID: mergeGapMin == 0)

        // Merge for Flights or similar
        let baseBlocks = (mergeGapMin > 0) ? mergeBlocks(srcBlocks, gapMinutes: mergeGapMin) : srcBlocks
        let trackByID = (mergeGapMin == 0)

        for tgt in targets {
            let tgtName = calLabel(tgt)
            log(">>> Target: \(tgtName)")
            if tgt.calendarIdentifier == srcCal.calendarIdentifier {
                log("- SKIP target is same as source: \(tgtName)")
                continue
            }
            // Prefetch target window
            let tgtPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [tgt])
            var tgtEvents = store.events(matching: tgtPred)
            let tgtFetched = tgtEvents.count
            // HARD FILTER: ensure we only consider events truly on the target calendar
            tgtEvents = tgtEvents.filter { $0.calendar.calendarIdentifier == tgt.calendarIdentifier }
            if tgtFetched != tgtEvents.count {
                log("- WARN: filtered \(tgtFetched - tgtEvents.count) stray target event(s) not in \(tgtName)")
            }

            var placeholderSet = Set<String>()
            var occupied: [Block] = []
            var placeholdersByOccurrenceID: [String: EKEvent] = [:]
            var placeholdersByTime: [String: EKEvent] = [:]
            for tv in tgtEvents {
                // Defensive: should already be filtered, but double-check target identity
                guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                if let ts = tv.startDate, let te = tv.endDate {
                    let timeKey = "\(ts.timeIntervalSince1970)|\(te.timeIntervalSince1970)"
                    if isMirrorEvent(tv, prefix: titlePrefix, placeholder: placeholderTitle) {
                        placeholderSet.insert(timeKey)
                        placeholdersByTime[timeKey] = tv
                        let parsed = parseMirrorURL(tv.url)
                        if let sid = parsed.srcEventID, let occ = parsed.occ {
                            let key = "\(sid)|\(occ.timeIntervalSince1970)"
                            placeholdersByOccurrenceID[key] = tv
                        }
                    }
                    occupied.append(Block(start: ts, end: te, srcEventID: nil, label: nil, notes: nil, occurrence: nil))
                }
            }
            occupied = coalesce(occupied)

            var created = 0
            var skipped = 0
            var updated = 0
            var warnedPrivateUnsupported = false

            // Cross-route loop guard: unique key generator for (source, occurrence/time, target)
            func guardKey(for blk: Block, targetID: String) -> String {
                if trackByID, let sid = blk.srcEventID {
                    let occ = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                    return "\(srcCal.calendarIdentifier)|\(sid)|\(occ)|\(targetID)"
                } else {
                    return "\(srcCal.calendarIdentifier)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)|\(targetID)"
                }
            }

            func createOrUpdateIfNeeded(_ blk: Block) async {
                // Cross-route loop guard: skip if this (source occurrence -> target) was handled earlier this click
                let gKey = guardKey(for: blk, targetID: tgt.calendarIdentifier)
                if sessionGuard.contains(gKey) {
                    skipped += 1
                    log("- SKIP loop-guard [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    return
                }
                // Privacy-aware title/notes (strip our prefix so it never doubles up)
                let baseSourceTitle = stripPrefix(blk.label, prefix: titlePrefix)
                let effectiveTitle = hideDetails ? placeholderTitle : (baseSourceTitle.isEmpty ? placeholderTitle : baseSourceTitle)
                let titleSuffix = hideDetails ? "" : (baseSourceTitle.isEmpty ? "" : " — \(baseSourceTitle)")
                let displayTitle = (titlePrefix.isEmpty ? "" : titlePrefix) + effectiveTitle

                // Fallback 0: if an existing mirrored event has the exact same time, update it
                let exactTimeKey = "\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)"
                if let existingByTime = placeholdersByTime[exactTimeKey] {
                    if !writeEnabled {
                        sessionGuard.insert(gKey)
                        log("~ WOULD UPDATE [\(srcName) -> \(tgtName)] (by time) \(blk.start) -> \(blk.end) [title: \(displayTitle)]")
                        updated += 1
                        return
                    }
                    existingByTime.title = displayTitle
                    existingByTime.startDate = blk.start
                    existingByTime.endDate = blk.end
                    existingByTime.isAllDay = false
                    if !hideDetails && copyDescription {
                        existingByTime.notes = blk.notes
                    } else {
                        existingByTime.notes = nil
                    }
                    let sid0 = blk.srcEventID ?? ""
                    let occ0 = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                    existingByTime.url = URL(string: "mirror://\(tgt.calendarIdentifier)|\(srcCal.calendarIdentifier)|\(sid0)|\(occ0)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)")
                    let okTime = setEventPrivateIfSupported(existingByTime, markPrivate)
                    if markPrivate && !okTime && !warnedPrivateUnsupported {
                        log("- INFO: Mark Private not supported for \(tgtName) [source: \(tgt.source.title)]")
                        warnedPrivateUnsupported = true
                    }
                    do {
                        try await MainActor.run {
                            try store.save(existingByTime, span: .thisEvent, commit: true)
                        }
                        log("✓ UPDATED [\(srcName) -> \(tgtName)] (by time) \(blk.start) -> \(blk.end)")
                        placeholderSet.insert(exactTimeKey)
                        placeholdersByTime[exactTimeKey] = existingByTime
                        occupied = coalesce(occupied + [Block(start: blk.start, end: blk.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)])
                        sessionGuard.insert(gKey)
                        updated += 1
                    } catch {
                        log("Update failed: \(error.localizedDescription)")
                    }
                    return
                }

                // If we can track by source event ID and we have one, prefer updating the existing placeholder
                if trackByID, let sid = blk.srcEventID {
                    let occTS = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                    let lookupKey = "\(sid)|\(occTS)"
                    if let existing = placeholdersByOccurrenceID[lookupKey] {
                        let curS = existing.startDate ?? blk.start
                        let curE = existing.endDate ?? blk.end
                        let needsUpdate = abs(curS.timeIntervalSince(blk.start)) > SAME_TIME_TOL_MIN*60 || abs(curE.timeIntervalSince(blk.end)) > SAME_TIME_TOL_MIN*60
                        if !needsUpdate {
                            skipped += 1
                            return
                        }
                        if !writeEnabled {
                            sessionGuard.insert(gKey)
                            log("~ WOULD UPDATE [\(srcName) -> \(tgtName)] \(curS) -> \(curE)  TO  \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                            updated += 1
                            return
                        }
                        existing.startDate = blk.start
                        existing.endDate = blk.end
                        existing.title = displayTitle
                        existing.isAllDay = false
                        if !hideDetails && copyDescription {
                            existing.notes = blk.notes
                        } else {
                            existing.notes = nil
                        }
                        existing.url = URL(string: "mirror://\(tgt.calendarIdentifier)|\(srcCal.calendarIdentifier)|\(sid)|\(occTS)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)")
                        let okOcc = setEventPrivateIfSupported(existing, markPrivate)
                        if markPrivate && !okOcc && !warnedPrivateUnsupported {
                            log("- INFO: Mark Private not supported for \(tgtName) [source: \(tgt.source.title)]")
                            warnedPrivateUnsupported = true
                        }
                        do {
                            try await MainActor.run {
                                try store.save(existing, span: .thisEvent, commit: true)
                            }
                            log("✓ UPDATED [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                            placeholderSet.insert("\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)")
                            let timeKey = "\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)"
                            placeholdersByTime[timeKey] = existing
                            occupied = coalesce(occupied + [Block(start: blk.start, end: blk.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)])
                            placeholdersByOccurrenceID[lookupKey] = existing
                            sessionGuard.insert(gKey)
                            updated += 1
                        } catch {
                            log("Update failed: \(error.localizedDescription)")
                        }
                        return
                    }
                }

                // No existing placeholder for this block; dedupe by exact times
                let k = "\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)"
                if placeholderSet.contains(k) { skipped += 1; return }
                if !writeEnabled {
                    sessionGuard.insert(gKey)
                    log("+ WOULD CREATE [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                    return
                }
                // Invariant: never write to the source calendar by mistake
                guard tgt.calendarIdentifier != srcCal.calendarIdentifier else { skipped += 1; log("- SKIP invariant: target is source [\(srcName)]"); return }
                let newEv = EKEvent(eventStore: store)
                newEv.calendar = tgt
                newEv.title = displayTitle
                newEv.startDate = blk.start
                newEv.endDate = blk.end
                newEv.isAllDay = false
                if !hideDetails && copyDescription {
                    newEv.notes = blk.notes
                }
                let sid = blk.srcEventID ?? ""
                let occTS = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                newEv.url = URL(string: "mirror://\(tgt.calendarIdentifier)|\(srcCal.calendarIdentifier)|\(sid)|\(occTS)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)")
                newEv.availability = .busy
                let okNew = setEventPrivateIfSupported(newEv, markPrivate)
                if markPrivate && !okNew && !warnedPrivateUnsupported {
                    log("- INFO: Mark Private not supported for \(tgtName) [source: \(tgt.source.title)]")
                    warnedPrivateUnsupported = true
                }
                do {
                    try await MainActor.run {
                        try store.save(newEv, span: .thisEvent, commit: true)
                    }
                    created += 1
                    log("✓ CREATED [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    placeholderSet.insert(k)
                    occupied = coalesce(occupied + [Block(start: blk.start, end: blk.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)])
                    if !sid.isEmpty {
                        let key = "\(sid)|\(occTS)"
                        placeholdersByOccurrenceID[key] = newEv
                    }
                    let timeKey = k
                    placeholdersByTime[timeKey] = newEv
                    sessionGuard.insert(gKey)
                } catch {
                    log("Save failed: \(error.localizedDescription)")
                }
            }

            for b in baseBlocks {
                switch overlapMode {
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
            // Auto-delete placeholders whose source instance no longer exists.
            // Works even when no source events remain in the window, and
            // also cleans up legacy mirrors that lack a mirror URL (by time).
            if autoDeleteMissing {
                let trackByID = (mergeGapMin == 0)
                let isMultiRouteRun = !routes.isEmpty
                // Build valid occurrence keys from current source blocks (when trackByID)
                let validOccKeys: Set<String> = Set(baseBlocks.compactMap { blk in
                    guard trackByID, let sid = blk.srcEventID else { return nil }
                    let occTS = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                    return "\(sid)|\(occTS)"
                })
                // Also build valid time keys for legacy/fallback cleanup
                let validTimeKeys: Set<String> = Set(baseBlocks.map { blk in
                    "\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)"
                })

                // Consider all known placeholders on target (URL or title-identified)
                // Deduplicate by eventIdentifier to avoid double-processing updated items
                var byID: [String: EKEvent] = [:]
                for tv in placeholdersByTime.values {
                    guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                    if let eid = tv.eventIdentifier { byID[eid] = tv }
                }

                var removed = 0
                var skippedOtherSource = 0
                var skippedLegacyNoURL = 0
                for ev in byID.values {
                    let parsed = parseMirrorURL(ev.url)
                    var shouldDelete = false
                    if let sourceCalID = parsed.sourceCalID, !sourceCalID.isEmpty {
                        // Only clean up placeholders that belong to this route's source calendar.
                        if sourceCalID != srcCal.calendarIdentifier {
                            skippedOtherSource += 1
                            continue
                        }
                        if let sid = parsed.srcEventID, let occ = parsed.occ {
                            let k = "\(sid)|\(occ.timeIntervalSince1970)"
                            // If key not present among current source instances, delete
                            if !validOccKeys.contains(k) { shouldDelete = true }
                        } else if trackByID {
                            // Legacy-ish URL payload for this source: compare exact time window membership.
                            if let s = ev.startDate, let e = ev.endDate {
                                let tk = "\(s.timeIntervalSince1970)|\(e.timeIntervalSince1970)"
                                if !validTimeKeys.contains(tk) { shouldDelete = true }
                            }
                        }
                    } else if trackByID && !isMultiRouteRun {
                        // Legacy fallback without URL source only in single-source runs.
                        if let s = ev.startDate, let e = ev.endDate {
                            let tk = "\(s.timeIntervalSince1970)|\(e.timeIntervalSince1970)"
                            if !validTimeKeys.contains(tk) { shouldDelete = true }
                        }
                    } else if trackByID && isMultiRouteRun {
                        // In multi-route runs, avoid deleting URL-less placeholders that may belong to another source.
                        skippedLegacyNoURL += 1
                        continue
                    }
                    if shouldDelete {
                        if !writeEnabled {
                            log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(ev.startDate ?? windowStart) -> \(ev.endDate ?? windowEnd)")
                        } else {
                            do {
                                try await MainActor.run {
                                    try store.remove(ev, span: .thisEvent, commit: true)
                                }
                                removed += 1
                            }
                            catch { log("Delete failed: \(error.localizedDescription)") }
                        }
                    }
                }
                if removed > 0 { log("[Cleanup missing for \(tgtName)] deleted=\(removed)") }
                if skippedOtherSource > 0 {
                    log("- INFO cleanup skipped \(skippedOtherSource) placeholders from other source routes on \(tgtName)")
                }
                if skippedLegacyNoURL > 0 {
                    log("- INFO cleanup skipped \(skippedLegacyNoURL) legacy placeholders without source URL on \(tgtName)")
                }
            }
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
    var excludedOrganizerFilters: [String]? = nil
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
        mergeGapMin = max(0, s.mergeGapHours * 60)
        hideDetails = s.hideDetails
        copyDescription = s.copyDescription
        mirrorAllDay = s.mirrorAllDay
        markPrivate = s.markPrivate
        filterByWorkHours = s.filterByWorkHours
        workHoursStart = s.workHoursStart
        workHoursEnd = s.workHoursEnd
        excludedTitleFiltersRaw = s.excludedTitleFilters.joined(separator: "\n")
        if let orgs = s.excludedOrganizerFilters {
            excludedOrganizerFiltersRaw = orgs.joined(separator: "\n")
        }
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

    private func isOutsideWorkHours(_ startDate: Date, calendar: Calendar, startMinutes: Int, endMinutes: Int) -> Bool {
        guard endMinutes > startMinutes else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: startDate)
        guard let hour = comps.hour else { return false }
        let minute = comps.minute ?? 0
        let start = hour * 60 + minute
        return start < startMinutes || start >= endMinutes
    }

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
            do {
                ev.setValue(val, forKey: key)
                return true
            } catch {
                // ignore and try next
            }
        }
        // Not supported; no-op
        return false
    }

    private func shouldSkip(event: EKEvent, filters: [String]) -> Bool {
        guard !filters.isEmpty else { return false }
        let rawTitle = (event.title ?? "").lowercased()
        let strippedTitle = stripPrefix(event.title, prefix: titlePrefix).lowercased()
        return filters.contains { token in
            rawTitle.contains(token) || strippedTitle.contains(token)
        }
    }

    // Organizer filters
    private func organizerEmail(_ participant: EKParticipant?) -> String? {
        guard let url = participant?.url else { return nil }
        if url.scheme?.lowercased() == "mailto" {
            let abs = url.absoluteString
            if abs.lowercased().hasPrefix("mailto:") {
                return String(abs.dropFirst("mailto:".count))
            }
            return abs
        }
        return url.absoluteString
    }

    private func organizerStrings(for event: EKEvent) -> [String] {
        var out: [String] = []
        if let org = event.organizer {
            if let n = org.name, !n.isEmpty { out.append(n) }
            if let e = organizerEmail(org), !e.isEmpty { out.append(e) }
        }
        // Fallback: some providers may not populate organizer; try chair attendee
        if out.isEmpty, let attendees = event.attendees {
            if let chair = attendees.first(where: { $0.participantRole == .chair }) {
                if let n = chair.name, !n.isEmpty { out.append(n) }
                if let e = organizerEmail(chair), !e.isEmpty { out.append(e) }
            }
        }
        return out
    }

    private func shouldSkipOrganizer(event: EKEvent, filters: [String]) -> Bool {
        guard !filters.isEmpty else { return false }
        let vals = organizerStrings(for: event).map { $0.lowercased() }
        guard !vals.isEmpty else { return false }
        for token in filters {
            for v in vals {
                if v.contains(token) { return true }
            }
        }
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
        }
    }
    
    // MARK: - Block helpers
    func key(_ b: Block) -> String {
        "\(b.start.timeIntervalSince1970)|\(b.end.timeIntervalSince1970)"
    }
    func mergeBlocks(_ blocks: [Block], gapMinutes: Int) -> [Block] {
        guard !blocks.isEmpty else { return [] }
        let sorted = blocks.sorted { $0.start < $1.start }
        var out: [Block] = []
        var cur = Block(start: sorted[0].start, end: sorted[0].end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)
        for b in sorted.dropFirst() {
            let gap = b.start.timeIntervalSince(cur.end) / 60.0
            if gap <= Double(gapMinutes) {
                if b.end > cur.end { cur = Block(start: cur.start, end: b.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil) }
            } else {
                out.append(cur)
                cur = Block(start: b.start, end: b.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)
            }
        }
        out.append(cur)
        return out
    }
    func coalesce(_ segs: [Block]) -> [Block] { mergeBlocks(segs, gapMinutes: 0) }
    func fullyCovered(_ mergedSegs: [Block], block: Block, tolMin: Double) -> Bool {
        for s in mergedSegs {
            if s.start <= block.start.addingTimeInterval(tolMin*60),
               s.end   >= block.end.addingTimeInterval(-tolMin*60) { return true }
        }
        return false
    }
    func gapsWithin(_ mergedSegs: [Block], in block: Block) -> [Block] {
        if mergedSegs.isEmpty { return [Block(start: block.start, end: block.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)] }
        var segs: [Block] = []
        for s in mergedSegs where s.end > block.start && s.start < block.end {
            let ss = max(s.start, block.start)
            let ee = min(s.end, block.end)
            if ee > ss { segs.append(Block(start: ss, end: ee, srcEventID: nil, label: nil, notes: nil, occurrence: nil)) }
        }
        if segs.isEmpty { return [Block(start: block.start, end: block.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)] }
        let merged = coalesce(segs)
        var gaps: [Block] = []
        var prevEnd = block.start
        for s in merged {
            if s.start > prevEnd { gaps.append(Block(start: prevEnd, end: s.start, srcEventID: nil, label: nil, notes: nil, occurrence: nil)) }
            if s.end > prevEnd { prevEnd = s.end }
        }
        if prevEnd < block.end { gaps.append(Block(start: prevEnd, end: block.end, srcEventID: nil, label: nil, notes: nil, occurrence: nil)) }
        return gaps
    }

// MARK: - Cleanup: delete Busy placeholders in the active window on selected targets
    func runCleanup() async {
    guard hasAccess, !calendars.isEmpty else { return }
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
