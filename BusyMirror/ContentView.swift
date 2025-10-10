import SwiftUI
import EventKit
import AppKit
import ObjectiveC

/// Placeholder title is configurable via state (see `placeholderTitle`)
private let SAME_TIME_TOL_MIN: Double = 5
private let SKIP_ALL_DAY_DEFAULT = true

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
private func parseMirrorURL(_ url: URL?) -> (srcEventID: String?, occ: Date?, start: Date?, end: Date?) {
    guard let abs = url?.absoluteString, abs.hasPrefix("mirror://") else { return (nil, nil, nil, nil) }
    let body = abs.dropFirst("mirror://".count)
    let parts = body.split(separator: "|")
    var srcID: String? = nil
    var occDate: Date? = nil
    var sDate: Date? = nil
    var eDate: Date? = nil
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
    return (srcID, occDate, sDate, eDate)
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
        // Enable Mirror Now whenever calendars are available and permission is granted.
        // The action itself chooses between routes or manual selection.
        return hasAccess && !isRunning && !calendars.isEmpty
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

    private func rebuildSelectionsFromIDs() {
        // Map IDs -> indices in current calendars
        var idToIndex: [String:Int] = [:]
        for (i, c) in calendars.enumerated() { idToIndex[c.calendarIdentifier] = i }
        // Restore source index from sourceID if possible
        if let sid = sourceID, let idx = idToIndex[sid] { sourceIndex = idx }
        else if !calendars.isEmpty { sourceIndex = min(sourceIndex, calendars.count - 1); sourceID = calendars[sourceIndex].calendarIdentifier }
        // Restore targets from IDs
        let restored = targetIDs.compactMap { idToIndex[$0] }
        targetSelections = Set(restored).filter { $0 != sourceIndex }
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
    @ViewBuilder
    private func calendarsSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source calendar")
            Picker("Source", selection: $sourceIndex) {
                ForEach(Array(calendars.indices), id: \.self) { i in
                    Text("\(i+1): \(calLabel(calendars[i]))").tag(i)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)
            .disabled(isRunning || calendars.isEmpty)

            Text("Target calendars (check one or more)")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
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
                            HStack { Text("\(i+1):"); calChip(calendars[i]) }
                        }
                        .disabled(isRunning || isSource)
                    }
                }
            }
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func routesSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routes (multi-source)").font(.headline)
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
                Button("Clear") { routes.removeAll() }
                    .disabled(isRunning || routes.isEmpty)
            }
            if routes.isEmpty {
                Text("No routes yet. Pick a Source and Targets above, then click ‘Add from current selection’.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($routes, id: \.id) { routeBinding in
                    routeCard(for: routeBinding)
                }
            }
        }
    }

    @ViewBuilder
    private func routeCard(for routeBinding: Binding<Route>) -> some View {
        let route = routeBinding.wrappedValue
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sourceSummaryView(for: route)
                Text("→ Targets:")
                targetSummaryView(for: route)
                Spacer()
                Toggle("Private", isOn: routeBinding.privacy)
                    .help("If ON, mirror as ‘\(titlePrefix)\(placeholderTitle)’ with no notes. If OFF, mirror source title (and optionally notes).")
                separatorDot()
                mergeGapField(for: routeBinding)
                Toggle("Copy desc", isOn: routeBinding.copyNotes)
                    .disabled(isRunning || route.privacy)
                    .help("If ON and Private is OFF, copy the source event’s notes/description into the placeholder.")
                Toggle("Mark Private", isOn: routeBinding.markPrivate)
                    .disabled(isRunning)
                    .help("If ON, attempt to mark mirrored events as Private on the server (e.g., Exchange). Titles still use your prefix and source title.")
                overlapPicker(for: routeBinding)
                    .disabled(isRunning)
                Toggle("All-day", isOn: routeBinding.allDay)
                    .disabled(isRunning)
                    .help("Mirror all-day events for this source.")
                separatorDot()
                Button(role: .destructive) { removeRoute(id: route.id) } label: { Text("Remove") }
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.1))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func sourceSummaryView(for route: Route) -> some View {
        Text("Source:")
        if let sCal = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) {
            HStack(spacing: 6) {
                Circle().fill(calColor(sCal)).frame(width: 10, height: 10)
                Text(calLabel(sCal)).bold()
            }
        } else {
            Text(labelForCalendar(id: route.sourceID)).bold()
        }
    }

    @ViewBuilder
    private func targetSummaryView(for route: Route) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(route.targetIDs.sorted(by: <), id: \.self) { tid in
                    if let tCal = calendars.first(where: { $0.calendarIdentifier == tid }) {
                        HStack(spacing: 6) {
                            Circle().fill(calColor(tCal)).frame(width: 10, height: 10)
                            Text(calLabel(tCal))
                        }
                    } else {
                        Text(labelForCalendar(id: tid))
                    }
                }
            }
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func mergeGapField(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 6) {
            Text("Merge gap:")
            TextField("0", value: routeBinding.mergeGapHours, formatter: Self.intFormatter)
                .frame(width: 48)
                .disabled(isRunning)
                .help("Merge adjacent source events separated by ≤ this many hours (e.g., flight legs). 0 = no merge.")
            Text("h").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func overlapPicker(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 6) {
            Text("Overlap:")
            Picker("Overlap", selection: routeBinding.overlap) {
                ForEach(OverlapMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 160)
            .help("allow = always place; skipCovered = skip if target already has a block covering the time; fillGaps = only fill uncovered gaps within the source block.")
        }
    }

    @ViewBuilder
    private func separatorDot() -> some View {
        Text("·").foregroundStyle(.secondary)
    }

    private func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
    }

    @ViewBuilder
    private func optionsSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Days back:")
                TextField("1", value: $daysBack, formatter: Self.intFormatter)
                    .frame(width: 60)
                    .disabled(isRunning)
                Text("Days forward:")
                TextField("7", value: $daysForward, formatter: Self.intFormatter)
                    .frame(width: 60)
                    .disabled(isRunning)
            }
            .onChange(of: daysBack) { v in daysBack = max(0, v) }
            .onChange(of: daysForward) { v in daysForward = max(0, v) }
            HStack(spacing: 8) {
                Text("Default merge gap:")
                TextField("0", value: $mergeGapHours, formatter: Self.intFormatter)
                    .frame(width: 60)
                    .disabled(isRunning)
                Text("hours").foregroundStyle(.secondary)
            }
            .onChange(of: mergeGapHours) { newVal in
                mergeGapMin = max(0, newVal * 60)
            }
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

            HStack(spacing: 8) {
                Text("Title prefix:")
                TextField("🪞 ", text: $titlePrefix)
                    .frame(width: 72)
                    .disabled(isRunning)
                Text("(left blank for none)").foregroundStyle(.secondary)
            }
            // Insert placeholder title UI
            HStack(spacing: 8) {
                Text("Placeholder title:")
                TextField("Busy", text: $placeholderTitle)
                    .frame(width: 160)
                    .disabled(isRunning)
            }

            Toggle("Limit mirroring to work hours", isOn: $filterByWorkHours)
                .disabled(isRunning)
                .onChange(of: filterByWorkHours) { _ in saveSettingsToDefaults() }

            if filterByWorkHours {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Start hour:")
                        TextField("9", value: $workHoursStart, formatter: Self.hourFormatter)
                            .frame(width: 48)
                            .disabled(isRunning)
                        Text("End hour:")
                        TextField("17", value: $workHoursEnd, formatter: Self.hourFormatter)
                            .frame(width: 48)
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
                TextEditor(text: $excludedTitleFiltersRaw)
                    .font(.body)
                    .frame(minHeight: 80)
                    .disabled(isRunning)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Matches are case-insensitive and apply before mirroring.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .onChange(of: excludedTitleFiltersRaw) { _ in saveSettingsToDefaults() }

            Toggle("Write to calendars (disable for Dry-Run)", isOn: $writeEnabled)
                .disabled(isRunning)

            // Insert auto-delete toggle after writeEnabled
            Toggle("Auto-delete mirrors if source is removed", isOn: $autoDeleteMissing)
                .disabled(isRunning)
            HStack(spacing: 12) {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
            }
            .padding(.vertical, 4)

            HStack {
                Button(isRunning ? "Running…" : "Mirror Now") {
                    Task {
                        // New click -> reset the guard so we don't re-process
                        sessionGuard.removeAll()
                        if routes.isEmpty {
                            await runMirror()
                        } else {
                            for r in routes {
                                // Resolve source index and target IDs for this route
                                if let sIdx = indexForCalendar(id: r.sourceID) {
                                    // Save globals
                                    let prevPrivacy = hideDetails
                                    let prevCopy = copyDescription
                                    let prevGapH = mergeGapHours
                                    let prevGapM = mergeGapMin
                                    let prevOverlap = overlapMode
                                    let prevAllDay = mirrorAllDay
                                    // Apply per-route state changes on MainActor
                                    await MainActor.run {
                                        sourceIndex = sIdx
                                        sourceID = r.sourceID
                                        targetIDs = r.targetIDs
                                        // Belt-and-suspenders: ensure source is not in targets even if UI state is stale
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
                                        // Restore globals
                                        hideDetails = prevPrivacy
                                        copyDescription = prevCopy
                                        mergeGapHours = prevGapH
                                        mergeGapMin = prevGapM
                                        overlapModeRaw = prevOverlap.rawValue
                                        mirrorAllDay = prevAllDay
                                    }
                                }
                            }
                        }
                    }
                }
                .disabled(!canRunMirrorNow)

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

                Button("Refresh Calendars") {
                    reloadCalendars()
                }
                .disabled(isRunning)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func logSection() -> some View {
        Text("Log")
        TextEditor(text: $logText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BusyMirror").font(.title2).bold()
                Spacer()
                Button(hasAccess ? "Recheck Permission" : "Request Calendar Access") {
                    requestAccess()
                }
                .disabled(isRunning)
            }
            Divider()

            if !hasAccess {
                Text("Calendar access not granted yet. Click “Request Calendar Access”.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    calendarsSection()
                    optionsSection()
                }
                routesSection()
                logSection()
            }
        }
        .padding(16)
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
        guard let routesIdx = args.firstIndex(of: "--routes") else { return }
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

        let routesSpec = (routesIdx+1 < args.count) ? args[routesIdx+1] : ""
        let routeParts = routesSpec.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        log("CLI: routes=\(routesSpec)")
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
    func reloadCalendars() {
        let fetched = store.calendars(for: .event)
        calendars = sortedCalendars(fetched)
        // Initialize IDs on first load
        if sourceID == nil, let first = calendars.first { sourceID = first.calendarIdentifier }
        // Rebuild index-based selections from stored IDs
        rebuildSelectionsFromIDs()
        log("Loaded \(calendars.count) calendars.")
    }
    
    // MARK: - Mirror engine (EventKit)
    func runMirror() async {
        guard hasAccess, !calendars.isEmpty else { return }
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
        let enforceWorkHours = filterByWorkHours && workHoursEnd > workHoursStart
        let allowedStartMinutes = workHoursStart * 60
        let allowedEndMinutes = workHoursEnd * 60
        var skippedWorkHours = 0
        var skippedTitles = 0
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

            // Cross-route loop guard: unique key generator for (source, occurrence/time, target)
            func guardKey(for blk: Block, targetID: String) -> String {
                if trackByID, let sid = blk.srcEventID {
                    let occ = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                    return "\(srcCal.calendarIdentifier)|\(sid)|\(occ)|\(targetID)"
                } else {
                    return "\(srcCal.calendarIdentifier)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)|\(targetID)"
                }
            }

            func createOrUpdateIfNeeded(_ blk: Block) {
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
                    _ = setEventPrivateIfSupported(existingByTime, markPrivate)
                    do {
                        try store.save(existingByTime, span: .thisEvent, commit: true)
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
                        _ = setEventPrivateIfSupported(existing, markPrivate)
                        do {
                            try store.save(existing, span: .thisEvent, commit: true)
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
                _ = setEventPrivateIfSupported(newEv, markPrivate)
                do {
                    try store.save(newEv, span: .thisEvent, commit: true)
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
                    createOrUpdateIfNeeded(b)
                case .skipCovered:
                    if fullyCovered(occupied, block: b, tolMin: SAME_TIME_TOL_MIN) {
                        log("- SKIP covered [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        createOrUpdateIfNeeded(b)
                    }
                case .fillGaps:
                    let gaps = gapsWithin(occupied, in: b)
                    if gaps.isEmpty {
                        log("- SKIP no gaps [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        for g in gaps { createOrUpdateIfNeeded(g) }
                    }
                }
            }
            log("[Summary → \(tgtName)] created=\(created), updated=\(updated), skipped=\(skipped)")
            // Auto-delete placeholders whose source instance no longer exists
            if autoDeleteMissing {
                let validKeys: Set<String> = Set(baseBlocks.compactMap { blk in
                    if (mergeGapMin == 0), let sid = blk.srcEventID {
                        let occTS = blk.occurrence?.timeIntervalSince1970 ?? blk.start.timeIntervalSince1970
                        return "\(sid)|\(occTS)"
                    }
                    return nil
                })
                if !validKeys.isEmpty {
                    var removed = 0
                    for (_, ev) in placeholdersByOccurrenceID {
                        if ev.calendar.calendarIdentifier != tgt.calendarIdentifier { continue }
                        let parsed = parseMirrorURL(ev.url)
                        if let sid = parsed.srcEventID, let occ = parsed.occ {
                            let k = "\(sid)|\(occ.timeIntervalSince1970)"
                            if !validKeys.contains(k) {
                                if !writeEnabled {
                                    log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(ev.startDate ?? windowStart) -> \(ev.endDate ?? windowEnd)")
                                } else {
                                    do { try store.remove(ev, span: .thisEvent, commit: true); removed += 1 }
                                    catch { log("Delete failed: \(error.localizedDescription)") }
                                }
                            }
                        }
                    }
                    if removed > 0 { log("[Cleanup missing for \(tgtName)] deleted=\(removed)") }
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
        logText.append("\n" + s)
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
                do { try store.remove(ev, span: .thisEvent, commit: true); delCount += 1 }
                catch { log("Delete failed: \(error.localizedDescription)") }
            }
        }
        log("[Cleanup \(tgt.title)] deleted=\(delCount)")
    }
}
}
