import XCTest
@testable import BusyMirror

final class PlannedChangeTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func change(
        _ kind: PlannedChange.Kind,
        target: String = "t1",
        name: String = "Target",
        start: String,
        end: String,
        title: String = "Busy",
        reasons: [PlannedChange.Reason] = []
    ) -> PlannedChange {
        switch kind {
        case .create:
            return PlannedChange(kind: .create, targetName: name, targetCalendarID: target,
                                 newTitle: title, newStart: date(start), newEnd: date(end))
        case .update:
            return PlannedChange(kind: .update, targetName: name, targetCalendarID: target,
                                 oldTitle: title, newTitle: title,
                                 oldStart: date(start), oldEnd: date(end),
                                 newStart: date(start), newEnd: date(end), reasons: reasons)
        case .delete:
            return PlannedChange(kind: .delete, targetName: name, targetCalendarID: target,
                                 oldTitle: title, oldStart: date(start), oldEnd: date(end))
        }
    }

    // MARK: - titleChangeReason

    func testTitleChangeReasonIdentical() {
        XCTAssertNil(titleChangeReason(existing: "🪞 Busy", desired: "🪞 Busy"))
    }

    func testTitleChangeReasonMarkerOnlyAdded() {
        XCTAssertEqual(titleChangeReason(existing: "🪞 Busy", desired: "🪞 " + mirrorTitleMarker + "Busy"), .marker)
    }

    func testTitleChangeReasonMarkerOnlyRemoved() {
        XCTAssertEqual(titleChangeReason(existing: "🪞 " + mirrorTitleMarker + "Busy", desired: "🪞 Busy"), .marker)
    }

    func testTitleChangeReasonRealChange() {
        XCTAssertEqual(titleChangeReason(existing: "🪞 Busy", desired: "WORK: Busy"), .title)
    }

    // MARK: - plannedChangeSummary

    func testSummaryEmpty() {
        XCTAssertEqual(plannedChangeSummary([]), "No changes")
    }

    func testSummaryOmitsZeroKinds() {
        let changes = [
            change(.create, start: "2026-09-19T09:00:00Z", end: "2026-09-19T10:00:00Z"),
            change(.create, start: "2026-09-19T11:00:00Z", end: "2026-09-19T12:00:00Z"),
            change(.delete, start: "2026-09-19T13:00:00Z", end: "2026-09-19T14:00:00Z"),
        ]
        XCTAssertEqual(plannedChangeSummary(changes), "2 to create · 1 to delete")
    }

    // MARK: - groupPlannedChanges

    func testGroupingOrdersTargetsByNameThenDaysThenTime() {
        let changes = [
            change(.create, target: "b", name: "Beta", start: "2026-09-20T09:00:00Z", end: "2026-09-20T10:00:00Z"),
            change(.create, target: "a", name: "alpha", start: "2026-09-20T15:00:00Z", end: "2026-09-20T16:00:00Z"),
            change(.create, target: "a", name: "alpha", start: "2026-09-19T15:00:00Z", end: "2026-09-19T16:00:00Z"),
            change(.create, target: "a", name: "alpha", start: "2026-09-20T08:00:00Z", end: "2026-09-20T09:00:00Z"),
        ]
        let groups = groupPlannedChanges(changes, calendar: utc)

        XCTAssertEqual(groups.map(\.targetName), ["alpha", "Beta"])
        XCTAssertEqual(groups[0].days.count, 2)
        XCTAssertEqual(groups[0].days[0].day, date("2026-09-19T00:00:00Z"))
        XCTAssertEqual(groups[0].days[1].day, date("2026-09-20T00:00:00Z"))
        XCTAssertEqual(groups[0].days[1].changes.compactMap(\.newStart),
                       [date("2026-09-20T08:00:00Z"), date("2026-09-20T15:00:00Z")])
        XCTAssertEqual(groups[1].days.count, 1)
    }

    func testGroupingPlacesDeleteOnItsExistingDay() {
        let changes = [
            change(.delete, start: "2026-09-21T09:00:00Z", end: "2026-09-21T10:00:00Z"),
        ]
        let groups = groupPlannedChanges(changes, calendar: utc)
        XCTAssertEqual(groups[0].days[0].day, date("2026-09-21T00:00:00Z"))
    }

    func testGroupingSameStartOrdersCreateBeforeUpdateBeforeDelete() {
        let s = "2026-09-19T09:00:00Z", e = "2026-09-19T10:00:00Z"
        let changes = [
            change(.delete, start: s, end: e),
            change(.update, start: s, end: e, reasons: [.title]),
            change(.create, start: s, end: e),
        ]
        let kinds = groupPlannedChanges(changes, calendar: utc)[0].days[0].changes.map(\.kind)
        XCTAssertEqual(kinds, [.create, .update, .delete])
    }

    // MARK: - extraNotes

    func testExtraNotesMarkerOnly() {
        let c = change(.update, start: "2026-09-19T09:00:00Z", end: "2026-09-19T10:00:00Z", reasons: [.marker])
        XCTAssertEqual(c.extraNotes.count, 1)
        XCTAssertTrue(c.extraNotes[0].contains("marker"))
    }

    func testExtraNotesLinkAloneIsExplained() {
        let c = change(.update, start: "2026-09-19T09:00:00Z", end: "2026-09-19T10:00:00Z", reasons: [.link])
        XCTAssertEqual(c.extraNotes, ["Refreshes tracking data (no visible change)"])
    }

    func testExtraNotesLinkSuppressedWhenTimeAlsoChanged() {
        let c = change(.update, start: "2026-09-19T09:00:00Z", end: "2026-09-19T10:00:00Z", reasons: [.time, .link])
        XCTAssertTrue(c.extraNotes.isEmpty)
    }

    func testExtraNotesOnlyForUpdates() {
        let c = change(.create, start: "2026-09-19T09:00:00Z", end: "2026-09-19T10:00:00Z", reasons: [.marker])
        XCTAssertTrue(c.extraNotes.isEmpty)
    }

    // MARK: - PrefixMode (Route.titlePrefix as a Global / Custom / None choice)

    func testPrefixModeFromStoredValue() {
        XCTAssertTrue(PrefixMode.from(nil) == (.global, ""))
        XCTAssertTrue(PrefixMode.from("") == (.none, ""))
        XCTAssertTrue(PrefixMode.from("WORK: ") == (.custom, "WORK: "))
    }

    func testPrefixModeResolve() {
        XCTAssertNil(PrefixMode.global.resolve(customText: "ignored"))
        XCTAssertEqual(PrefixMode.none.resolve(customText: "ignored"), "")
        XCTAssertEqual(PrefixMode.custom.resolve(customText: "WORK: "), "WORK: ")
    }

    func testPrefixModeRoundTrips() {
        for stored in [nil, "", "WORK: ", "🪞 "] as [String?] {
            let parsed = PrefixMode.from(stored)
            XCTAssertEqual(parsed.mode.resolve(customText: parsed.customText), stored)
        }
    }

    func testEmptyCustomPrefixReadsBackAsNone() {
        // "Custom" with nothing typed is stored as "" — an empty prefix *is* no prefix.
        let stored = PrefixMode.custom.resolve(customText: "")
        XCTAssertEqual(stored, "")
        XCTAssertEqual(PrefixMode.from(stored).mode, .none)
    }
}
