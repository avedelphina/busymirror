import Foundation
import EventKit

// Owns route persistence, calendar access, and running a route — shared by
// ContentView (UI) and the App Intents (Shortcuts) so both call the same
// logic instead of duplicating it.
@MainActor
final class RouteStore {
    static let shared = RouteStore()

    private let routesDefaultsKey = "routes.v1"
    private let lastSyncDefaultsKey = "lastSyncDate.v1"
    private let titlePrefix = "🪞 "
    private let placeholderTitle = "Busy"
    let eventStore = EKEventStore()

    private init() {}

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? Date
    }

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
            titlePrefix: titlePrefix,
            placeholderTitle: placeholderTitle,
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
        UserDefaults.standard.set(Date(), forKey: lastSyncDefaultsKey)
        return lines
    }

    func runAll() async {
        let cals = calendars()
        for route in loadRoutes() {
            await run(route: route, calendars: cals)
        }
    }

    @discardableResult
    func cleanupPlaceholders(route: Route, calendars: [EKCalendar]) async -> [String] {
        guard let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) else { return [] }
        let targets = calendars.filter { route.targetIDs.contains($0.calendarIdentifier) }
        guard !targets.isEmpty else { return [] }

        var lines: [String] = []
        let engine = MirrorEngine(log: { lines.append($0) })
        await engine.runCleanup(
            store: eventStore,
            daysBack: 1,
            daysForward: 14,
            sourceCalendar: source,
            targetCalendars: targets,
            titlePrefix: titlePrefix,
            placeholderTitle: placeholderTitle,
            writeEnabled: true
        )
        return lines
    }

    @discardableResult
    func cleanupAll() async -> [String] {
        let cals = calendars()
        var lines: [String] = []
        for route in loadRoutes() {
            lines += await cleanupPlaceholders(route: route, calendars: cals)
        }
        return lines
    }
}
