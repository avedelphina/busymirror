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

    private func parseFilterTerms(_ raw: String) -> [String] {
        raw.split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
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
            titlePrefix: route.titlePrefix ?? titlePrefix,
            placeholderTitle: placeholderTitle,
            filterByWorkHours: false,
            workHoursStart: 9,
            workHoursEnd: 17,
            excludedTitleFilterTerms: parseFilterTerms(excludedTitleFiltersRaw),
            excludedOrganizerFilterTerms: parseFilterTerms(excludedOrganizerFiltersRaw),
            mirrorAcceptedOnly: false,
            autoDeleteMissing: true,
            writeEnabled: true,
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
        UserDefaults.standard.set(Date(), forKey: lastSyncDefaultsKey)
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
            daysBack: 1,
            daysForward: 14,
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

    // Detects calendars that already contain mirrored events, regardless of
    // which app/device/prefix wrote them — every mirror event carries a
    // mirror:// URL tag independent of the visible title prefix, so this
    // works across Mac/iOS even though the two use separate route sets.
    func calendarsContainingMirrors(_ calendars: [EKCalendar], daysBack: Int = 365, daysForward: Int = 365) -> Set<String> {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day, value: -daysBack, to: todayStart),
              let windowEnd = cal.date(byAdding: .day, value: daysForward, to: todayStart) else { return [] }

        var result = Set<String>()
        for c in calendars {
            let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [c])
            // URL-only check (not isMirrorEvent's title-prefix path): a "" prefix/placeholder
            // would spuriously match untitled events via isMirrorEvent's placeholder equality check.
            let hasMirror = eventStore.events(matching: predicate).contains {
                $0.url?.absoluteString.hasPrefix("mirror://") ?? false
            }
            if hasMirror { result.insert(c.calendarIdentifier) }
        }
        return result
    }
}
