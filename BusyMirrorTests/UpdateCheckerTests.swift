import XCTest
@testable import BusyMirror

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionComparison() {
        XCTAssertTrue(isNewerVersion("v1.12.0", than: "1.11.0"))
        XCTAssertTrue(isNewerVersion("1.11.1", than: "1.11.0"))
        XCTAssertTrue(isNewerVersion("2.0", than: "1.99.9"))
        XCTAssertTrue(isNewerVersion("1.10.0", than: "1.9.0"))   // numeric, not lexical
        XCTAssertFalse(isNewerVersion("1.11.0", than: "1.11.0"))
        XCTAssertFalse(isNewerVersion("1.11", than: "1.11.0"))    // missing component = 0
        XCTAssertFalse(isNewerVersion("v1.10.9", than: "1.11.0"))
    }
}
