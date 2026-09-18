import AppIntents
import EventKit

struct RouteEntity: AppEntity {
    let id: UUID
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "BusyMirror Route"
    static var defaultQuery = RouteEntityQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct RouteEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [RouteEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [RouteEntity] {
        allEntities()
    }

    @MainActor
    private func allEntities() -> [RouteEntity] {
        let store = RouteStore.shared
        let cals = store.calendars()
        return store.loadRoutes().map { route in
            let sourceTitle = cals.first(where: { $0.calendarIdentifier == route.sourceID })?.title ?? "Unknown"
            let targetTitles = route.targetIDs.compactMap { id in cals.first(where: { $0.calendarIdentifier == id })?.title }
            return RouteEntity(id: route.id, title: "\(sourceTitle) → \(targetTitles.joined(separator: ", "))")
        }
    }
}

struct RunRouteIntent: AppIntent {
    static var title: LocalizedStringResource = "Run BusyMirror Route"

    @Parameter(title: "Route")
    var route: RouteEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = RouteStore.shared
        guard try await store.requestAccess() else {
            return .result(dialog: "Calendar access denied.")
        }
        let cals = store.calendars()
        guard let match = store.loadRoutes().first(where: { $0.id == route.id }) else {
            return .result(dialog: "Route no longer exists.")
        }
        let lines = await store.run(route: match, calendars: cals)
        return .result(dialog: "\(lines.last ?? "Synced.")")
    }
}

struct RunAllRoutesIntent: AppIntent {
    static var title: LocalizedStringResource = "Run All BusyMirror Routes"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = RouteStore.shared
        guard try await store.requestAccess() else {
            return .result(dialog: "Calendar access denied.")
        }
        let cals = store.calendars()
        let routes = store.loadRoutes()
        for route in routes {
            await store.run(route: route, calendars: cals)
        }
        return .result(dialog: "Ran \(routes.count) route(s).")
    }
}

struct BusyMirrorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAllRoutesIntent(),
            phrases: ["Sync \(.applicationName)", "Run all \(.applicationName) routes"],
            shortTitle: "Sync All Routes",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: RunRouteIntent(),
            phrases: ["Run a \(.applicationName) route"],
            shortTitle: "Run Route",
            systemImageName: "arrow.right.circle"
        )
    }
}
