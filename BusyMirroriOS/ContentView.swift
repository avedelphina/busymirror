import SwiftUI
import EventKit

struct ContentView: View {
    private let routeStore = RouteStore.shared

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
                    Button { showingAddRoute = true } label: { Image(systemName: "plus") }
                        .disabled(calendars.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddRoute) {
                AddRouteView(calendars: calendars) { route in
                    routes.append(route)
                    routeStore.saveRoutes(routes)
                }
            }
            .task {
                await requestAccessAndLoadCalendars()
                routes = routeStore.loadRoutes()
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
