import XCTest
@testable import BusyMirror

// Routes are persisted as JSON by both apps; the Mac app has a history of route data-loss
// bugs from decode failures, so the newer fields must be optional on read and lossless on write.
final class RouteCodingTests: XCTestCase {

    private func roundTrip(_ route: Route) throws -> Route {
        try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
    }

    private func makeRoute(titlePrefix: String?, mirrorMirrored: Bool = false, passThrough: Bool = false) -> Route {
        Route(sourceID: "src", targetIDs: ["t1", "t2"], privacy: true, copyNotes: false,
              syncReminders: true, mergeGapHours: 2, overlap: .skipCovered, allDay: true,
              titlePrefix: titlePrefix, mirrorMirroredEvents: mirrorMirrored,
              passThroughMirroredTitles: passThrough)
    }

    func testRoundTripPreservesAllFields() throws {
        let decoded = try roundTrip(makeRoute(titlePrefix: "WORK: ", mirrorMirrored: true, passThrough: true))
        XCTAssertEqual(decoded.sourceID, "src")
        XCTAssertEqual(decoded.targetIDs, ["t1", "t2"])
        XCTAssertEqual(decoded.overlap, .skipCovered)
        XCTAssertEqual(decoded.titlePrefix, "WORK: ")
        XCTAssertTrue(decoded.mirrorMirroredEvents)
        XCTAssertTrue(decoded.passThroughMirroredTitles)
    }

    func testRouteFiltersRoundTripAndParse() throws {
        var route = makeRoute(titlePrefix: nil)
        route.excludedTitleFilters = "Standup, Lunch\n focus "
        route.excludedOrganizerFilters = "boss@x.com"
        let decoded = try roundTrip(route)
        XCTAssertEqual(parseFilterTerms(decoded.excludedTitleFilters), ["standup", "lunch", "focus"])
        XCTAssertEqual(parseFilterTerms(decoded.excludedOrganizerFilters), ["boss@x.com"])
    }

    func testRouteFiltersOverrideAndInherit() throws {
        var route = makeRoute(titlePrefix: nil)
        route.excludedTitleFilters = "Lunch"
        XCTAssertEqual(route.titleFilterTerms(global: ["standup"]), ["standup", "lunch"])
        route.overrideGlobalFilters = true
        XCTAssertEqual(route.titleFilterTerms(global: ["standup"]), ["lunch"])
        route.excludedTitleFilters = ""
        XCTAssertEqual(route.titleFilterTerms(global: ["standup"]), [])
        XCTAssertEqual(route.organizerFilterTerms(global: ["a@x.com"]), [])
        route.overrideGlobalFilters = false
        XCTAssertEqual(route.organizerFilterTerms(global: ["a@x.com"]), ["a@x.com"])
    }

    func testWorkHoursAndAcceptedOnlyInheritThenOverride() throws {
        var route = makeRoute(titlePrefix: nil)
        var h = route.workHours(globalEnabled: true, globalStart: 8, globalEnd: 18)
        XCTAssertEqual([h.enabled ? 1 : 0, h.start, h.end], [1, 8, 18])
        route.filterByWorkHours = false
        route.workHoursStart = 10
        h = route.workHours(globalEnabled: true, globalStart: 8, globalEnd: 18)
        XCTAssertEqual([h.enabled ? 1 : 0, h.start, h.end], [0, 10, 18])
        route.mirrorAcceptedOnly = true
        let decoded = try roundTrip(route)
        XCTAssertEqual(decoded.filterByWorkHours, false)
        XCTAssertEqual(decoded.workHoursStart, 10)
        XCTAssertNil(decoded.workHoursEnd)
        XCTAssertEqual(decoded.mirrorAcceptedOnly, true)
        XCTAssertEqual([OverrideChoice(nil), OverrideChoice(true), OverrideChoice(false)], [.global, .on, .off])
    }

    func testEmptyPrefixStaysDistinctFromNil() throws {
        XCTAssertEqual(try roundTrip(makeRoute(titlePrefix: "")).titlePrefix, "")
        XCTAssertNil(try roundTrip(makeRoute(titlePrefix: nil)).titlePrefix)
    }

    func testLegacyJSONWithoutNewFieldsStillDecodes() throws {
        // A route saved before titlePrefix / mirrorMirroredEvents / passThroughMirroredTitles existed.
        let legacy = """
        {"sourceID":"src","targetIDs":["t1"],"privacy":true,"copyNotes":false,
         "mergeGapHours":0,"overlap":"allow","allDay":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Route.self, from: legacy)
        XCTAssertNil(decoded.titlePrefix)
        XCTAssertFalse(decoded.mirrorMirroredEvents)
        XCTAssertFalse(decoded.passThroughMirroredTitles)
        XCTAssertFalse(decoded.syncReminders)
        XCTAssertEqual(decoded.excludedTitleFilters, "")
        XCTAssertEqual(decoded.excludedOrganizerFilters, "")
        XCTAssertFalse(decoded.overrideGlobalFilters)
        XCTAssertNil(decoded.filterByWorkHours)
        XCTAssertNil(decoded.mirrorAcceptedOnly)
    }
}
