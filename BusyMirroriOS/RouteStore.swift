import Foundation
import EventKit

// Owns route persistence, calendar access, and running a route — shared by
// ContentView (UI) and the App Intents (Shortcuts) so both call the same
// logic instead of duplicating it.
@MainActor
final class RouteStore {
    static let shared = RouteStore()

    private let routesDefaultsKey = "routes.v1"
    let eventStore = EKEventStore()

    private init() {}

    func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).sorted { $0.title < $1.title }
    }

    func loadRoutes() -> [Route] {
        guard let data = UserDefaults.standard.data(forKey: routesDefaultsKey),
              let decoded = try? JSONDecoder().decode([Route].self, from: data) else { return [] }
        return decoded
    }

    func saveRoutes(_ routes: [Route]) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: routesDefaultsKey)
    }

    @discardableResult
    func run(route: Route, calendars: [EKCalendar]) async -> [String] {
        guard let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) else { return [] }
        let targets = calendars.filter { route.targetIDs.contains($0.calendarIdentifier) }
        guard !targets.isEmpty else { return [] }

        var lines: [String] = []
        let engine = MirrorEngine(log: { lines.append($0) })
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
            store: eventStore,
            config: config,
            sourceCalendar: source,
            targetCalendars: targets,
            sessionGuard: &sessionGuard,
            isMultiRouteRun: false
        )
        return lines
    }
}
