import XCTest
@testable import BusyMirror

final class EventFiltersTests: XCTestCase {

    // MARK: - isOutsideWorkHours

    func testInsideWorkHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
        XCTAssertFalse(isOutsideWorkHours(date, calendar: calendar, startMinutes: 9 * 60, endMinutes: 17 * 60))
    }

    func testOutsideWorkHoursBeforeStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 8, minute: 59))!
        XCTAssertTrue(isOutsideWorkHours(date, calendar: calendar, startMinutes: 9 * 60, endMinutes: 17 * 60))
    }

    func testOutsideWorkHoursAtEndBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 17, minute: 0))!
        XCTAssertTrue(isOutsideWorkHours(date, calendar: calendar, startMinutes: 9 * 60, endMinutes: 17 * 60))
    }

    func testOutsideWorkHoursInvalidRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
        // end <= start means "no enforcement"
        XCTAssertFalse(isOutsideWorkHours(date, calendar: calendar, startMinutes: 17 * 60, endMinutes: 9 * 60))
    }

    // MARK: - shouldSkip

    func testShouldSkipEmptyFilters() {
        XCTAssertFalse(shouldSkip(title: "Meeting", filters: [], titlePrefix: "🪞 "))
    }

    func testShouldSkipMatchingRawTitle() {
        XCTAssertTrue(shouldSkip(title: "Standup", filters: ["standup"], titlePrefix: ""))
    }

    func testShouldSkipMatchingStrippedTitle() {
        XCTAssertTrue(shouldSkip(title: "🪞 Standup", filters: ["standup"], titlePrefix: "🪞 "))
    }

    func testShouldSkipCaseInsensitive() {
        XCTAssertTrue(shouldSkip(title: "STANDUP", filters: ["standup"], titlePrefix: ""))
    }

    func testShouldSkipNoMatch() {
        XCTAssertFalse(shouldSkip(title: "Meeting", filters: ["standup"], titlePrefix: ""))
    }

    func testShouldSkipNilTitle() {
        XCTAssertFalse(shouldSkip(title: nil, filters: ["standup"], titlePrefix: ""))
    }

    func testShouldSkipMultipleFilters() {
        XCTAssertTrue(shouldSkip(title: "Lunch", filters: ["standup", "lunch"], titlePrefix: ""))
    }

    // MARK: - shouldSkipOrganizer

    func testShouldSkipOrganizerEmptyFilters() {
        XCTAssertFalse(shouldSkipOrganizer(organizerValues: ["alice@example.com"], filters: []))
    }

    func testShouldSkipOrganizerEmptyValues() {
        XCTAssertFalse(shouldSkipOrganizer(organizerValues: [], filters: ["alice"]))
    }

    func testShouldSkipOrganizerMatch() {
        XCTAssertTrue(shouldSkipOrganizer(organizerValues: ["Alice Smith", "alice@example.com"], filters: ["alice"]))
    }

    func testShouldSkipOrganizerCaseInsensitive() {
        XCTAssertTrue(shouldSkipOrganizer(organizerValues: ["ALICE@EXAMPLE.COM"], filters: ["alice"]))
    }

    func testShouldSkipOrganizerPartialMatch() {
        XCTAssertTrue(shouldSkipOrganizer(organizerValues: ["bob@corp.com"], filters: ["corp"]))
    }

    func testShouldSkipOrganizerNoMatch() {
        XCTAssertFalse(shouldSkipOrganizer(organizerValues: ["charlie@example.com"], filters: ["alice"]))
    }
}
