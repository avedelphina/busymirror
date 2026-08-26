import XCTest
@testable import BusyMirror

final class SettingsPayloadTests: XCTestCase {

    // Only the fields present in the very first schema. Every key added since
    // (syncReminders, filterByWorkHours, workHoursStart/End, excludedTitleFilters,
    // excludedOrganizerFilters, mirrorAcceptedOnly, selectedSourceID/TargetIDs,
    // appVersion, exportedAt) is deliberately missing here, simulating a
    // settings.v2 blob written by an older build.
    private let oldSchemaJSON = """
    {
        "daysBack": 3,
        "daysForward": 10,
        "mergeGapHours": 1,
        "hideDetails": false,
        "copyDescription": true,
        "mirrorAllDay": true,
        "overlapMode": "skipCovered",
        "titlePrefix": "🪞 ",
        "placeholderTitle": "Busy",
        "autoDeleteMissing": true,
        "routes": []
    }
    """

    func testDecodeOldSchemaMissingNewerKeysDoesNotThrow() throws {
        let data = oldSchemaJSON.data(using: .utf8)!
        let payload = try JSONDecoder().decode(ContentView.SettingsPayload.self, from: data)

        // Fields present in the old blob are preserved.
        XCTAssertEqual(payload.daysBack, 3)
        XCTAssertEqual(payload.daysForward, 10)
        XCTAssertEqual(payload.overlapMode, "skipCovered")

        // Fields missing from the old blob fall back to their defaults instead
        // of failing the whole decode.
        XCTAssertEqual(payload.syncReminders, false)
        XCTAssertEqual(payload.filterByWorkHours, false)
        XCTAssertEqual(payload.workHoursStart, 9)
        XCTAssertEqual(payload.workHoursEnd, 17)
        XCTAssertEqual(payload.excludedTitleFilters, [])
        XCTAssertEqual(payload.mirrorAcceptedOnly, false)
        XCTAssertNil(payload.selectedSourceID)
        XCTAssertNil(payload.selectedTargetIDs)
    }

    func testEncodeDecodeRoundTrip() throws {
        let route = Route(sourceID: "a", targetIDs: ["b"], privacy: true, copyNotes: false, syncReminders: true, mergeGapHours: 1, overlap: .allow, allDay: false)
        let original = ContentView.SettingsPayload(
            daysBack: 2, daysForward: 5, mergeGapHours: 0, hideDetails: true, copyDescription: false,
            mirrorAllDay: false, filterByWorkHours: true, workHoursStart: 8, workHoursEnd: 18,
            excludedTitleFilters: ["standup"], excludedOrganizerFilters: [], mirrorAcceptedOnly: true,
            overlapMode: "allow", titlePrefix: "🪞 ", placeholderTitle: "Busy", autoDeleteMissing: true,
            routes: [route]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentView.SettingsPayload.self, from: data)
        XCTAssertEqual(decoded.daysBack, original.daysBack)
        XCTAssertEqual(decoded.excludedTitleFilters, original.excludedTitleFilters)
        XCTAssertEqual(decoded.routes.count, 1)
        XCTAssertEqual(decoded.routes[0].sourceID, "a")
    }
}
