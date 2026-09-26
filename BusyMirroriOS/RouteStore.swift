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
    private let placeholderTitle = "Busy"
    let eventStore = EKEventStore()

    private init() {}

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? Date
    }

    var titlePrefix: String {
        get { UserDefaults.standard.string(forKey: "titlePrefix") ?? "🪞 " }
        set { UserDefaults.standard.set(newValue, forKey: "titlePrefix") }
    }

    var excludedTitleFiltersRaw: String {
        get { UserDefaults.standard.string(forKey: "excludedTitleFilters") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "excludedTitleFilters") }
    }

    var excludedOrganizerFiltersRaw: String {
        get { UserDefaults.standard.string(forKey: "excludedOrganizerFilters") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "excludedOrganizerFilters") }
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

    // Dry run of a route as configured right now (it needn't be saved): returns every
    // create/update/delete a real run would make, without writing anything or touching
    // "Last synced".
    func preview(route: Route, calendars: [EKCalendar]) async -> [PlannedChange] {
        var changes: [PlannedChange] = []
        await run(route: route, calendars: calendars, writeEnabled: false, onChange: { changes.append($0) })
        return changes
    }

    @discardableResult
    func run(
        route: Route,
        calendars: [EKCalendar],
        writeEnabled: Bool = true,
        onChange: ((PlannedChange) -> Void)? = nil
    ) async -> [String] {
        guard let source = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) else { return [] }
        let targets = calendars.filter { route.targetIDs.contains($0.calendarIdentifier) }
        guard !targets.isEmpty else { return [] }

        var lines: [String] = []
        let engine = MirrorEngine(log: { lines.append($0) })
        engine.onPlannedChange = onChange
        // No global work-hours/accepted-only setting on iOS: those apply only where a route turns them on.
        let hours = route.workHours(globalEnabled: false, globalStart: 9, globalEnd: 17)
        let config = MirrorConfig(
            daysBack: defaultSyncDaysBack,
            daysForward: defaultSyncDaysForward,
            mergeGapMin: route.mergeGapHours * 60,
            hideDetails: route.privacy,
            copyDescription: route.copyNotes,
            mirrorAllDay: route.allDay,
            overlapMode: route.overlap,
            titlePrefix: route.titlePrefix ?? titlePrefix,
            placeholderTitle: placeholderTitle,
            filterByWorkHours: hours.enabled,
            workHoursStart: hours.start,
            workHoursEnd: hours.end,
            excludedTitleFilterTerms: route.titleFilterTerms(global: parseFilterTerms(excludedTitleFiltersRaw)),
            excludedOrganizerFilterTerms: route.organizerFilterTerms(global: parseFilterTerms(excludedOrganizerFiltersRaw)),
            mirrorAcceptedOnly: route.mirrorAcceptedOnly ?? false,
            autoDeleteMissing: true,
            writeEnabled: writeEnabled,
            syncReminders: route.syncReminders,
            mirrorMirroredEvents: route.mirrorMirroredEvents,
            passThroughMirroredTitles: route.passThroughMirroredTitles
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
        if writeEnabled {
            UserDefaults.standard.set(Date(), forKey: lastSyncDefaultsKey)
        }
        return lines
    }

    @discardableResult
    func runAll() async -> [String] {
        let cals = calendars()
        var lines: [String] = []
        for route in loadRoutes() {
            lines += await run(route: route, calendars: cals)
        }
        return lines
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
            daysBack: defaultSyncDaysBack,
            daysForward: defaultSyncDaysForward,
            sourceCalendar: source,
            targetCalendars: targets,
            titlePrefix: route.titlePrefix ?? titlePrefix,
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
