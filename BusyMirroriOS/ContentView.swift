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
                        routeRow(route)
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

    private func routeRow(_ route: Route) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(calendars.first(where: { $0.calendarIdentifier == route.sourceID })?.title ?? "Unknown")
                    .font(.subheadline)
                Text("→ " + route.targetIDs.compactMap { id in
                    calendars.first(where: { $0.calendarIdentifier == id })?.title
                }.joined(separator: ", "))
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
}

private struct RouteFormView: View {
    let calendars: [EKCalendar]
    let existing: Route?
    let onSave: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String?
    @State private var targetIDs: Set<String>
    @State private var privacy: Bool

    init(calendars: [EKCalendar], existing: Route?, onSave: @escaping (Route) -> Void) {
        self.calendars = calendars
        self.existing = existing
        self.onSave = onSave
        _sourceID = State(initialValue: existing?.sourceID)
        _targetIDs = State(initialValue: existing?.targetIDs ?? [])
        _privacy = State(initialValue: existing?.privacy ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Source calendar", selection: $sourceID) {
                        Text("None").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Text(cal.title).tag(Optional(cal.calendarIdentifier))
                        }
                    }
                }
                Section("Targets") {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        if cal.calendarIdentifier != sourceID {
                            Toggle(cal.title, isOn: Binding(
                                get: { targetIDs.contains(cal.calendarIdentifier) },
                                set: { isOn in
                                    if isOn { targetIDs.insert(cal.calendarIdentifier) }
                                    else { targetIDs.remove(cal.calendarIdentifier) }
                                }
                            ))
                        }
                    }
                }
                Section {
                    Toggle("Hide details (privacy mode)", isOn: $privacy)
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
                            copyNotes: existing?.copyNotes ?? false,
                            syncReminders: existing?.syncReminders ?? false,
                            mergeGapHours: existing?.mergeGapHours ?? 0,
                            overlap: existing?.overlap ?? .allow,
                            allDay: existing?.allDay ?? false
                        ))
                        dismiss()
                    }
                    .disabled(sourceID == nil || targetIDs.isEmpty)
                }
            }
        }
    }
}
