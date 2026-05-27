import XCTest
@testable import BusyMirror

final class MirrorUtilsTests: XCTestCase {

    // MARK: - stripPrefix

    func testStripPrefixMatching() {
        XCTAssertEqual(stripPrefix("🪞 Meeting", prefix: "🪞 "), "Meeting")
    }

    func testStripPrefixNoMatch() {
        XCTAssertEqual(stripPrefix("Meeting", prefix: "🪞 "), "Meeting")
    }

    func testStripPrefixEmptyPrefix() {
        XCTAssertEqual(stripPrefix("Meeting", prefix: ""), "Meeting")
    }

    func testStripPrefixNilTitle() {
        XCTAssertEqual(stripPrefix(nil, prefix: "🪞 "), "")
    }

    // MARK: - mirrorURL encode/decode round-trip

    func testMirrorURLEncodeDecodeRoundTrip() {
        let raw = "abc|123://"
        let encoded = mirrorURLComponentEncode(raw)
        let decoded = mirrorURLComponentDecode(Substring(encoded))
        XCTAssertEqual(decoded, raw)
    }

    func testMirrorURLAllowedCharactersUnchanged() {
        let raw = "abcABC123-._~"
        XCTAssertEqual(mirrorURLComponentEncode(raw), raw)
    }

    // MARK: - buildMirrorURL / parseMirrorURL

    func testMirrorURLRoundTrip() {
        let calID = "ABC-123"
        let sourceID = "event-456"
        let occ = Date(timeIntervalSince1970: 1000)
        let start = Date(timeIntervalSince1970: 2000)
        let end = Date(timeIntervalSince1970: 3600)

        let url = buildMirrorURL(
            targetCalID: calID,
            sourceCalID: calID,
            sourceStableID: sourceID,
            occurrence: occ,
            start: start,
            end: end
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.hasPrefix("mirror://x/") ?? false)

        let parsed = parseMirrorURL(url)
        XCTAssertEqual(parsed.targetCalID, calID)
        XCTAssertEqual(parsed.sourceCalID, calID)
        XCTAssertEqual(parsed.sourceStableID, sourceID)
        XCTAssertEqual(parsed.occ?.timeIntervalSince1970, 1000)
        XCTAssertEqual(parsed.start?.timeIntervalSince1970, 2000)
        XCTAssertEqual(parsed.end?.timeIntervalSince1970, 3600)
    }

    func testMirrorURLWithSpecialCharacters() {
        let calID = "cal|with/pipe"
        let url = buildMirrorURL(
            targetCalID: calID,
            sourceCalID: "src",
            sourceStableID: nil,
            occurrence: nil,
            start: Date(),
            end: Date()
        )
        XCTAssertNotNil(url)
        let parsed = parseMirrorURL(url)
        XCTAssertEqual(parsed.targetCalID, calID)
    }

    func testParseMirrorURLInvalid() {
        let parsed = parseMirrorURL(URL(string: "https://example.com"))
        XCTAssertNil(parsed.targetCalID)
        XCTAssertNil(parsed.sourceCalID)
    }

    func testParseMirrorURLMissingOptionalFields() {
        let url = URL(string: "mirror://x/tgt;src;;-;;")
        let parsed = parseMirrorURL(url)
        XCTAssertEqual(parsed.targetCalID, "tgt")
        XCTAssertEqual(parsed.sourceCalID, "src")
        XCTAssertNil(parsed.sourceStableID)
        XCTAssertNil(parsed.occ)
        XCTAssertNil(parsed.start)
        XCTAssertNil(parsed.end)
    }

    // MARK: - isMirrorEvent

    func testIsMirrorEventByURL() {
        XCTAssertTrue(isMirrorEvent(title: "Meeting", urlString: "mirror://x", prefix: "🪞 ", placeholder: "Busy"))
    }

    func testIsMirrorEventByPrefix() {
        XCTAssertTrue(isMirrorEvent(title: "🪞 Meeting", urlString: nil, prefix: "🪞 ", placeholder: "Busy"))
    }

    func testIsMirrorEventByPlaceholder() {
        XCTAssertTrue(isMirrorEvent(title: "Busy", urlString: nil, prefix: "", placeholder: "Busy"))
    }

    func testIsMirrorEventByPrefixedPlaceholder() {
        XCTAssertTrue(isMirrorEvent(title: "🪞 Busy", urlString: nil, prefix: "🪞 ", placeholder: "Busy"))
    }

    func testIsMirrorEventNegative() {
        XCTAssertFalse(isMirrorEvent(title: "Regular Meeting", urlString: nil, prefix: "🪞 ", placeholder: "Busy"))
    }

    // MARK: - key generators

    func testSourceOccurrenceKey() {
        let occ = Date(timeIntervalSince1970: 1234)
        let key = sourceOccurrenceKey(sourceCalID: "cal1", sourceStableID: "evt1", occurrence: occ)
        XCTAssertEqual(key, "cal1|evt1|1234.0")
    }

    func testSourceOccurrenceKeyNoOccurrence() {
        let key = sourceOccurrenceKey(sourceCalID: "cal1", sourceStableID: "evt1", occurrence: nil)
        XCTAssertEqual(key, "cal1|evt1|-")
    }

    func testMirrorRecordKey() {
        XCTAssertEqual(mirrorRecordKey(targetCalID: "t", sourceKey: "s"), "t|s")
    }

    func testMirrorTimeKey() {
        let s = Date(timeIntervalSince1970: 100)
        let e = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(mirrorTimeKey(start: s, end: e), "100.0|200.0")
    }
}
