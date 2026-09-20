import SwiftUI
import EventKit

private enum RouteSheet: Identifiable {
    case add
    case edit(index: Int, route: Route)
    case preview(Route)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let index, _): return "edit-\(index)"
        case .preview(let route): return "preview-\(route.id)"
        }
    }
}

struct ContentView: View {
    private let routeStore = RouteStore.shared

    @State private var calendars: [EKCalendar] = []
    @State private var routes: [Route] = []
    @State private var accessError: String?
    @State private var sheet: RouteSheet?
    @State private var runningRouteID: Route.ID?
    @State private var logLines: [String] = []
    @State private var lastSyncDate: Date?
    @State private var confirmCleanup = false
    @State private var isCleaningUp = false
    @State private var showingSettings = false
    @State private var isSyncingAll = false
    @State private var calendarsWithMirrors: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if let accessError {
                    Section { Text(accessError).foregroundStyle(.red) }
                }

                Section {
                    if let lastSyncDate {
                        Text("Last synced \(lastSyncDate.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never synced").foregroundStyle(.secondary)
                    }
                }

                Section("Routes") {
                    if routes.isEmpty {
                        Text("No routes yet. Tap + to add one.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                        routeRow(route, index: index)
                            .swipeActions(edge: .leading) {
                                Button("Edit") { sheet = .edit(index: index, route: route) }.tint(.blue)
                            }
                    }
                    .onDelete { indexSet in
                        routes.remove(atOffsets: indexSet)
                        routeStore.saveRoutes(routes)
                    }
                }

                if !logLines.isEmpty {
                    Section("Log") {
                        ForEach(logLines.indices, id: \.self) { i in
                            Text(logLines[i]).font(.caption).monospaced()
                        }
                    }
                }
            }
            .navigationTitle("BusyMirror")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .add } label: { Image(systemName: "plus") }
                        .disabled(calendars.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await syncAll() }
                    } label: {
                        if isSyncingAll {
                            ProgressView()
                        } else {
                            Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(routes.isEmpty || isSyncingAll || runningRouteID != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        confirmCleanup = true
                    } label: {
                        Label("Clean Up Placeholders", systemImage: "trash")
                    }
                    .disabled(routes.isEmpty || isCleaningUp)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet(routeStore: routeStore)
            }
            .confirmationDialog(
                "Delete mirrored placeholders?",
                isPresented: $confirmCleanup,
                titleVisibility: .visible
            ) {
                Button("Delete Now", role: .destructive) { Task { await cleanupAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes events identified as mirrored placeholders (by title prefix) within the sync window from every route's target calendars.")
            }
            .sheet(item: $sheet) { mode in
                switch mode {
                case .add:
                    RouteFormView(calendars: calendars, existing: nil, globalPrefix: routeStore.titlePrefix, calendarsWithMirrors: calendarsWithMirrors, onPreview: preview) { route in
                        routes.append(route)
                        routeStore.saveRoutes(routes)
                    }
                case .edit(let index, let route):
                    RouteFormView(calendars: calendars, existing: route, globalPrefix: routeStore.titlePrefix, calendarsWithMirrors: calendarsWithMirrors, onPreview: preview) { updated in
                        routes[index] = updated
                        routeStore.saveRoutes(routes)
                    }
                case .preview(let route):
                    PlannedChangesSheet(calendars: calendars, load: { await preview(route) })
                }
            }
            .task {
                await requestAccessAndLoadCalendars()
                routes = routeStore.loadRoutes()
                lastSyncDate = routeStore.lastSyncDate
                calendarsWithMirrors = mirroredCalendarIDs(among: calendars, store: routeStore.eventStore)
            }
        }
    }

    private func routeRow(_ route: Route, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(route.titlePrefix ?? routeStore.titlePrefix)
                    if let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) {
                        calChip(source)
                        mirrorBadge(for: source, in: calendarsWithMirrors)
                    } else {
                        Text("Unknown source")
                    }
                }
                .font(.subheadline)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    ForEach(route.targetIDs.sorted(), id: \.self) { id in
                        if let target = calendars.first(where: { $0.calendarIdentifier == id }) {
                            calChip(target)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if runningRouteID == route.id {
                ProgressView()
            } else {
                Button("Run") { Task { await run(route) } }
                    .buttonStyle(.bordered)
                    .disabled(isSyncingAll)
            }
            Menu {
                Button { sheet = .preview(route) } label: {
                    Label("Preview", systemImage: "eye")
                }
                Button { sheet = .edit(index: index, route: route) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    routes.remove(at: index)
                    routeStore.saveRoutes(routes)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func requestAccessAndLoadCalendars() async {
        do {
            let granted = try await routeStore.requestAccess()
            guard granted else {
                accessError = "Calendar access denied. Enable it in Settings > BusyMirror."
                return
            }
            calendars = routeStore.calendars()
        } catch {
            accessError = error.localizedDescription
        }
    }

    private func run(_ route: Route) async {
        runningRouteID = route.id
        defer { runningRouteID = nil }
        logLines = await routeStore.run(route: route, calendars: calendars)
        lastSyncDate = routeStore.lastSyncDate
    }

    private func preview(_ route: Route) async -> [PlannedChange] {
        await routeStore.preview(route: route, calendars: calendars)
    }

    private func syncAll() async {
        isSyncingAll = true
        defer { isSyncingAll = false }
        logLines = await routeStore.runAll()
        lastSyncDate = routeStore.lastSyncDate
    }

    private func cleanupAll() async {
        isCleaningUp = true
        defer { isCleaningUp = false }
        logLines = await routeStore.cleanupAll()
    }
}

private struct SettingsSheet: View {
    let routeStore: RouteStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("🪞 ", text: Binding(
                        get: { routeStore.titlePrefix },
                        set: { routeStore.titlePrefix = $0 }
                    ))
                } header: {
                    Text("Mirror Prefix")
                } footer: {
                    Text("Prepended to mirrored placeholder event titles.")
                }

                Section {
                    TextEditor(text: Binding(
                        get: { routeStore.excludedTitleFiltersRaw },
                        set: { routeStore.excludedTitleFiltersRaw = $0 }
                    ))
                    .frame(minHeight: 80)
                } header: {
                    Text("Skip if title contains")
                } footer: {
                    Text("Comma or newline separated. Source events matching any term are skipped when syncing.")
                }

                Section {
                    TextEditor(text: Binding(
                        get: { routeStore.excludedOrganizerFiltersRaw },
                        set: { routeStore.excludedOrganizerFiltersRaw = $0 }
                    ))
                    .frame(minHeight: 80)
                } header: {
                    Text("Skip if organizer contains")
                } footer: {
                    Text("Comma or newline separated.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RouteFormView: View {
    let calendars: [EKCalendar]
    let existing: Route?
    let globalPrefix: String
    let calendarsWithMirrors: Set<String>
    let onPreview: (Route) async -> [PlannedChange]
    let onSave: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewRoute: Route?
    @State private var sourceID: String?
    @State private var targetIDs: Set<String>
    @State private var privacy: Bool
    @State private var copyNotes: Bool
    @State private var syncReminders: Bool
    @State private var allDay: Bool
    @State private var mergeGapHours: Int
    @State private var overlap: OverlapMode
    @State private var prefixMode: PrefixMode
    @State private var titlePrefixText: String
    @State private var mirrorMirroredEvents: Bool
    @State private var passThroughMirroredTitles: Bool

    init(calendars: [EKCalendar], existing: Route?, globalPrefix: String, calendarsWithMirrors: Set<String>, onPreview: @escaping (Route) async -> [PlannedChange], onSave: @escaping (Route) -> Void) {
        self.calendars = calendars
        self.existing = existing
        self.globalPrefix = globalPrefix
        self.calendarsWithMirrors = calendarsWithMirrors
        self.onPreview = onPreview
        self.onSave = onSave
        _sourceID = State(initialValue: existing?.sourceID)
        _targetIDs = State(initialValue: existing?.targetIDs ?? [])
        _privacy = State(initialValue: existing?.privacy ?? true)
        _copyNotes = State(initialValue: existing?.copyNotes ?? false)
        _syncReminders = State(initialValue: existing?.syncReminders ?? false)
        _allDay = State(initialValue: existing?.allDay ?? false)
        _mergeGapHours = State(initialValue: existing?.mergeGapHours ?? 0)
        _overlap = State(initialValue: existing?.overlap ?? .allow)
        let parsedPrefix = PrefixMode.from(existing?.titlePrefix)
        _prefixMode = State(initialValue: parsedPrefix.mode)
        _titlePrefixText = State(initialValue: parsedPrefix.customText)
        _mirrorMirroredEvents = State(initialValue: existing?.mirrorMirroredEvents ?? false)
        _passThroughMirroredTitles = State(initialValue: existing?.passThroughMirroredTitles ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source calendar", selection: $sourceID) {
                        Text("None").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            HStack {
                                calChip(cal)
                                mirrorBadge(for: cal, in: calendarsWithMirrors)
                            }
                            .tag(Optional(cal.calendarIdentifier))
                        }
                    }
                } header: {
                    Text("Source")
                } footer: {
                    Text("\"has mirrors\" tags a calendar that already contains mirrored events — likely a target of another route or device.")
                }
                Section("Targets") {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        if cal.calendarIdentifier != sourceID {
                            Toggle(isOn: Binding(
                                get: { targetIDs.contains(cal.calendarIdentifier) },
                                set: { isOn in
                                    if isOn { targetIDs.insert(cal.calendarIdentifier) }
                                    else { targetIDs.remove(cal.calendarIdentifier) }
                                }
                            )) {
                                HStack {
                                    calChip(cal)
                                    mirrorBadge(for: cal, in: calendarsWithMirrors)
                                }
                            }
                        }
                    }
                }
                Section {
                    Picker("Prefix", selection: $prefixMode) {
                        ForEach(PrefixMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    if prefixMode == .custom {
                        TextField("e.g. WORK1: ", text: $titlePrefixText)
                    }
                } header: {
                    Text("Prefix")
                } footer: {
                    switch prefixMode {
                    case .global:
                        Text("Uses the global mirror prefix (\(globalPrefix)) set in Settings.")
                    case .custom:
                        Text("Uses a prefix specific to this route.")
                    case .none:
                        Text("No prefix at all for this route's mirrored events.")
                    }
                }
                Section {
                    Toggle("Mirror already-mirrored events", isOn: $mirrorMirroredEvents)
                    if mirrorMirroredEvents {
                        Toggle("Copy chained titles as-is", isOn: $passThroughMirroredTitles)
                    }
                } footer: {
                    Text(mirrorMirroredEvents
                        ? "Off (default): source events that are themselves mirrors are skipped, preventing re-mirroring. \"Copy chained titles as-is\" avoids stacking this route's prefix onto an upstream one (e.g. \"B: A: Meeting\") — with Privacy off, the upstream title is kept verbatim; with Privacy on, this route's own placeholder is used but the upstream prefix is preserved (e.g. \"WORK1: Busy\" instead of this route's own prefix), so different sources stay distinguishable even behind a placeholder. Enabling either on a route that loops back to its own target will duplicate events on every run."
                        : "Off (default): source events that are themselves mirrors (from any route, any device) are skipped, preventing re-mirroring. Turn on only for a deliberate chain (A → B → C) — enabling it on a route that loops back to its own target will duplicate events on every run.")
                }
                Section {
                    Toggle("Private", isOn: $privacy)
                    Toggle("Copy description", isOn: $copyNotes)
                        .disabled(privacy)
                    Toggle("Sync reminders", isOn: $syncReminders)
                    Toggle("Mirror all-day events", isOn: $allDay)
                } footer: {
                    Text("Private mirrors as a placeholder with no details. If off, the source title (and optionally description) is copied.")
                }
                Section {
                    Stepper(value: $mergeGapHours, in: 0...24) {
                        Text("Merge gap: \(mergeGapHours)h")
                    }
                    Picker("Overlap mode", selection: $overlap) {
                        ForEach(OverlapMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } header: {
                    Text("Overlap")
                } footer: {
                    Text("Merge gap: merge adjacent source events separated by ≤ this many hours. Overlap — allow: always place; skipCovered: skip if target already covers the time; fillGaps: only fill uncovered gaps.")
                }
            }
            .navigationTitle(existing == nil ? "New Route" : "Edit Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Preview") { previewRoute = makeRoute() }
                        .disabled(!isComplete)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let route = makeRoute() else { return }
                        onSave(route)
                        dismiss()
                    }
                    .disabled(!isComplete)
                }
            }
            .sheet(item: $previewRoute) { route in
                PlannedChangesSheet(calendars: calendars, load: { await onPreview(route) })
            }
        }
    }

    private var isComplete: Bool { sourceID != nil && !targetIDs.isEmpty }

    // The route exactly as currently configured in the form (saved or not) — Save and
    // Preview both use this, so a preview always matches what saving would run.
    private func makeRoute() -> Route? {
        guard let sourceID else { return nil }
        let resolvedPrefix = prefixMode.resolve(customText: titlePrefixText)
        return Route(
            sourceID: sourceID,
            targetIDs: targetIDs,
            privacy: privacy,
            copyNotes: copyNotes,
            syncReminders: syncReminders,
            mergeGapHours: mergeGapHours,
            overlap: overlap,
            allDay: allDay,
            titlePrefix: resolvedPrefix,
            mirrorMirroredEvents: mirrorMirroredEvents,
            passThroughMirroredTitles: passThroughMirroredTitles
        )
    }
}
