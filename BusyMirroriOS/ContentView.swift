import SwiftUI
import EventKit

private enum RouteSheet: Identifiable {
    case add
    case edit(index: Int, route: Route)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let index, _): return "edit-\(index)"
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
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        confirmCleanup = true
                    } label: {
                        Label("Clean Up Placeholders", systemImage: "trash")
                    }
                    .disabled(routes.isEmpty || isCleaningUp)
                }
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
                    RouteFormView(calendars: calendars, existing: nil) { route in
                        routes.append(route)
                        routeStore.saveRoutes(routes)
                    }
                case .edit(let index, let route):
                    RouteFormView(calendars: calendars, existing: route) { updated in
                        routes[index] = updated
                        routeStore.saveRoutes(routes)
                    }
                }
            }
            .task {
                await requestAccessAndLoadCalendars()
                routes = routeStore.loadRoutes()
                lastSyncDate = routeStore.lastSyncDate
            }
        }
    }

    private func routeRow(_ route: Route, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) {
                    calChip(source).font(.subheadline)
                } else {
                    Text("Unknown source").font(.subheadline)
                }
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
            }
            Menu {
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

    private func cleanupAll() async {
        isCleaningUp = true
        defer { isCleaningUp = false }
        logLines = await routeStore.cleanupAll()
    }
}

private struct RouteFormView: View {
    let calendars: [EKCalendar]
    let existing: Route?
    let onSave: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String?
    @State private var targetIDs: Set<String>
    @State private var privacy: Bool
    @State private var copyNotes: Bool
    @State private var syncReminders: Bool
    @State private var allDay: Bool
    @State private var mergeGapHours: Int
    @State private var overlap: OverlapMode

    init(calendars: [EKCalendar], existing: Route?, onSave: @escaping (Route) -> Void) {
        self.calendars = calendars
        self.existing = existing
        self.onSave = onSave
        _sourceID = State(initialValue: existing?.sourceID)
        _targetIDs = State(initialValue: existing?.targetIDs ?? [])
        _privacy = State(initialValue: existing?.privacy ?? true)
        _copyNotes = State(initialValue: existing?.copyNotes ?? false)
        _syncReminders = State(initialValue: existing?.syncReminders ?? false)
        _allDay = State(initialValue: existing?.allDay ?? false)
        _mergeGapHours = State(initialValue: existing?.mergeGapHours ?? 0)
        _overlap = State(initialValue: existing?.overlap ?? .allow)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Source calendar", selection: $sourceID) {
                        Text("None").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            calChip(cal).tag(Optional(cal.calendarIdentifier))
                        }
                    }
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
                                calChip(cal)
                            }
                        }
                    }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let sourceID else { return }
                        onSave(Route(
                            sourceID: sourceID,
                            targetIDs: targetIDs,
                            privacy: privacy,
                            copyNotes: copyNotes,
                            syncReminders: syncReminders,
                            mergeGapHours: mergeGapHours,
                            overlap: overlap,
                            allDay: allDay
                        ))
                        dismiss()
                    }
                    .disabled(sourceID == nil || targetIDs.isEmpty)
                }
            }
        }
    }
}
