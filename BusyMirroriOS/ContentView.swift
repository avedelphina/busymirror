import SwiftUI
import EventKit

struct ContentView: View {
    private let store = EKEventStore()
    private let routesDefaultsKey = "routes.v1"

    @State private var calendars: [EKCalendar] = []
    @State private var routes: [Route] = []
    @State private var accessError: String?
    @State private var showingAddRoute = false
    @State private var runningRouteID: Route.ID?
    @State private var logLines: [String] = []

    var body: some View {
        NavigationStack {
            List {
                if let accessError {
                    Section { Text(accessError).foregroundStyle(.red) }
                }

                Section("Routes") {
                    if routes.isEmpty {
                        Text("No routes yet. Tap + to add one.").foregroundStyle(.secondary)
                    }
                    ForEach(routes) { route in
                        routeRow(route)
                    }
                    .onDelete { indexSet in
                        routes.remove(atOffsets: indexSet)
                        saveRoutes()
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
                    Button { showingAddRoute = true } label: { Image(systemName: "plus") }
                        .disabled(calendars.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddRoute) {
                AddRouteView(calendars: calendars) { route in
                    routes.append(route)
                    saveRoutes()
                }
            }
            .task {
                await requestAccessAndLoadCalendars()
                loadRoutes()
            }
        }
    }

    private func routeRow(_ route: Route) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(calLabel(source: route, in: calendars))
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

    private func calLabel(source route: Route, in calendars: [EKCalendar]) -> String {
        calendars.first(where: { $0.calendarIdentifier == route.sourceID })?.title ?? "Unknown"
    }

    private func requestAccessAndLoadCalendars() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                accessError = "Calendar access denied. Enable it in Settings > BusyMirror."
                return
            }
            calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
        } catch {
            accessError = error.localizedDescription
        }
    }

    private func run(_ route: Route) async {
        guard let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) else { return }
        let targets = calendars.filter { route.targetIDs.contains($0.calendarIdentifier) }
        guard !targets.isEmpty else { return }

        runningRouteID = route.id
        logLines.removeAll()
        defer { runningRouteID = nil }

        let engine = MirrorEngine(log: { line in
            Task { @MainActor in logLines.append(line) }
        })
        let config = MirrorConfig(
            daysBack: 1,
            daysForward: 14,
            mergeGapMin: route.mergeGapHours * 60,
            hideDetails: route.privacy,
            copyDescription: route.copyNotes,
            mirrorAllDay: route.allDay,
            overlapMode: route.overlap,
            titlePrefix: "🪞 ",
            placeholderTitle: "Busy",
            filterByWorkHours: false,
            workHoursStart: 9,
            workHoursEnd: 17,
            excludedTitleFilterTerms: [],
            excludedOrganizerFilterTerms: [],
            mirrorAcceptedOnly: false,
            autoDeleteMissing: true,
            writeEnabled: true,
            syncReminders: route.syncReminders
        )
        var sessionGuard = Set<String>()
        await engine.runMirror(
            store: store,
            config: config,
            sourceCalendar: source,
            targetCalendars: targets,
            sessionGuard: &sessionGuard,
            isMultiRouteRun: false
        )
    }

    private func saveRoutes() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: routesDefaultsKey)
    }

    private func loadRoutes() {
        guard let data = UserDefaults.standard.data(forKey: routesDefaultsKey),
              let decoded = try? JSONDecoder().decode([Route].self, from: data) else { return }
        routes = decoded
    }
}

private struct AddRouteView: View {
    let calendars: [EKCalendar]
    let onSave: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String?
    @State private var targetIDs = Set<String>()
    @State private var privacy = true

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
            .navigationTitle("New Route")
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
                            copyNotes: false,
                            syncReminders: false,
                            mergeGapHours: 0,
                            overlap: .allow,
                            allDay: false
                        ))
                        dismiss()
                    }
                    .disabled(sourceID == nil || targetIDs.isEmpty)
                }
            }
        }
    }
}
