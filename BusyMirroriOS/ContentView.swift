import SwiftUI
import EventKit

// Scaffold: proves the shared MirrorEngine runs standalone on iOS.
// Routes UI, routing persistence, and background sync land in later slices.
struct ContentView: View {
    private let store = EKEventStore()

    @State private var calendars: [EKCalendar] = []
    @State private var sourceID: String?
    @State private var targetID: String?
    @State private var logLines: [String] = []
    @State private var accessError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let accessError {
                    Section {
                        Text(accessError).foregroundStyle(.red)
                    }
                }

                Section("Source") {
                    Picker("Source calendar", selection: $sourceID) {
                        Text("None").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Text(cal.title).tag(Optional(cal.calendarIdentifier))
                        }
                    }
                }

                Section("Target") {
                    Picker("Target calendar", selection: $targetID) {
                        Text("None").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Text(cal.title).tag(Optional(cal.calendarIdentifier))
                        }
                    }
                }

                Section {
                    Button("Sync Now") { Task { await syncNow() } }
                        .disabled(sourceID == nil || targetID == nil || sourceID == targetID)
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
            .task { await requestAccessAndLoadCalendars() }
        }
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

    private func syncNow() async {
        guard let sourceID, let targetID,
              let source = calendars.first(where: { $0.calendarIdentifier == sourceID }),
              let target = calendars.first(where: { $0.calendarIdentifier == targetID }) else { return }

        logLines.removeAll()
        let engine = MirrorEngine(log: { line in
            Task { @MainActor in logLines.append(line) }
        })
        let config = MirrorConfig(
            daysBack: 1,
            daysForward: 14,
            mergeGapMin: 0,
            hideDetails: true,
            copyDescription: false,
            mirrorAllDay: false,
            overlapMode: .allow,
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
            syncReminders: false
        )
        var sessionGuard = Set<String>()
        await engine.runMirror(
            store: store,
            config: config,
            sourceCalendar: source,
            targetCalendars: [target],
            sessionGuard: &sessionGuard,
            isMultiRouteRun: false
        )
    }
}
