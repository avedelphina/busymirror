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
    }
}
