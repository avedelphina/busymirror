import XCTest
@testable import BusyMirror

final class BlockMathTests: XCTestCase {

    private let d = Date(timeIntervalSince1970: 0)

    private func block(_ startMin: Int, _ endMin: Int, id: String? = nil, alarmOffsets: [TimeInterval]? = nil) -> Block {
        Block(
            start: d.addingTimeInterval(TimeInterval(startMin * 60)),
            end: d.addingTimeInterval(TimeInterval(endMin * 60)),
            srcStableID: id,
            label: nil,
            notes: nil,
            occurrence: nil,
            alarmOffsets: alarmOffsets
        )
    }

    // MARK: - mergeBlocks

    func testMergeBlocksNoGap() {
        let blocks = [block(0, 10), block(10, 20)]
        let merged = mergeBlocks(blocks, gapMinutes: 0)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, blocks[0].start)
        XCTAssertEqual(merged[0].end, blocks[1].end)
    }

    func testMergeBlocksWithGapUnderThreshold() {
        let blocks = [block(0, 10), block(15, 20)]
        let merged = mergeBlocks(blocks, gapMinutes: 10)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, blocks[0].start)
        XCTAssertEqual(merged[0].end, blocks[1].end)
    }

    func testMergeBlocksWithGapOverThreshold() {
        let blocks = [block(0, 10), block(20, 30)]
        let merged = mergeBlocks(blocks, gapMinutes: 5)
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeBlocksEmpty() {
        XCTAssertTrue(mergeBlocks([], gapMinutes: 10).isEmpty)
    }

    func testMergeBlocksPreservesFirstAlarms() {
        let b1 = block(0, 10, alarmOffsets: [-900, -3600])
        let b2 = block(10, 20, alarmOffsets: [-600])
        let merged = mergeBlocks([b1, b2], gapMinutes: 0)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].alarmOffsets, [-900, -3600])
    }

    func testBlockEqualityIgnoresAlarms() {
        let b1 = block(0, 10, alarmOffsets: [-900])
        let b2 = block(0, 10, alarmOffsets: [-1800])
        XCTAssertEqual(b1, b2)
        XCTAssertEqual(Set([b1, b2]).count, 1)
    }

    func testMergeBlocksUnsortedInput() {
        let blocks = [block(30, 40), block(0, 10), block(10, 20)]
        let merged = mergeBlocks(blocks, gapMinutes: 0)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, blocks[1].start)
        XCTAssertEqual(merged[0].end, blocks[2].end)
        XCTAssertEqual(merged[1].start, blocks[0].start)
        XCTAssertEqual(merged[1].end, blocks[0].end)
    }

    // MARK: - coalesce

    func testCoalesceOverlappingBlocks() {
        let blocks = [block(0, 15), block(10, 20), block(25, 30)]
        let result = coalesce(blocks)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].start, blocks[0].start)
        XCTAssertEqual(result[0].end, blocks[1].end)
        XCTAssertEqual(result[1].start, blocks[2].start)
        XCTAssertEqual(result[1].end, blocks[2].end)
    }

    // MARK: - fullyCovered

    func testFullyCoveredExactMatch() {
        let occupied = [block(0, 10)]
        let b = block(0, 10)
        XCTAssertTrue(fullyCovered(occupied, block: b, tolMin: 0))
    }

    func testFullyCoveredPartialOverlap() {
        let occupied = [block(0, 5)]
        let b = block(0, 10)
        XCTAssertFalse(fullyCovered(occupied, block: b, tolMin: 0))
    }

    func testFullyCoveredWithTolerance() {
        let occupied = [block(0, 10)]
        let b = block(2, 8)
        XCTAssertTrue(fullyCovered(occupied, block: b, tolMin: 5))
    }

    func testFullyCoveredMultipleSegments() {
        let occupied = coalesce([block(0, 3), block(3, 10)])
        let b = block(0, 10)
        XCTAssertTrue(fullyCovered(occupied, block: b, tolMin: 0))
    }

    // MARK: - gapsWithin

    func testGapsWithinNoOccupied() {
        let b = block(0, 60)
        let gaps = gapsWithin([], in: b)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, b.start)
        XCTAssertEqual(gaps[0].end, b.end)
    }

    func testGapsWithinSingleGap() {
        let occupied = [block(0, 10), block(20, 30)]
        let b = block(0, 30)
        let gaps = gapsWithin(occupied, in: b)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, occupied[0].end)
        XCTAssertEqual(gaps[0].end, occupied[1].start)
    }

    func testGapsWithinMultipleGaps() {
        let occupied = [block(5, 10), block(15, 20)]
        let b = block(0, 30)
        let gaps = gapsWithin(occupied, in: b)
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0].start, b.start)
        XCTAssertEqual(gaps[0].end, occupied[0].start)
        XCTAssertEqual(gaps[1].start, occupied[0].end)
        XCTAssertEqual(gaps[1].end, occupied[1].start)
        XCTAssertEqual(gaps[2].start, occupied[1].end)
        XCTAssertEqual(gaps[2].end, b.end)
    }

    func testGapsWithinExactFit() {
        let occupied = [block(0, 10)]
        let b = block(0, 10)
        let gaps = gapsWithin(occupied, in: b)
        XCTAssertTrue(gaps.isEmpty)
    }

    // MARK: - uniqueBlocks

    func testUniqueBlocksByTime() {
        let blocks = [block(0, 10), block(0, 10), block(10, 20)]
        let result = uniqueBlocks(blocks, trackByID: false)
        XCTAssertEqual(result.count, 2)
    }

    func testUniqueBlocksByID() {
        let blocks = [
            block(0, 10, id: "a"),
            block(0, 10, id: "a"),
            block(5, 15, id: "b")
        ]
        let result = uniqueBlocks(blocks, trackByID: true)
        XCTAssertEqual(result.count, 2)
    }

    func testTentativeAffectsEqualityAndHash() {
        let base = Block(start: d, end: d.addingTimeInterval(600), srcStableID: "a", label: "x", notes: nil, occurrence: d, alarmOffsets: nil)
        var maybe = base
        maybe.tentative = true
        XCTAssertNotEqual(base, maybe)
        XCTAssertNotEqual(base.hashValue, maybe.hashValue)
    }

    func testUniqueBlocksByIDDifferentOccurrence() {
        let b1 = Block(start: d, end: d.addingTimeInterval(600), srcStableID: "a", label: nil, notes: nil, occurrence: d, alarmOffsets: nil)
        let b2 = Block(start: d, end: d.addingTimeInterval(600), srcStableID: "a", label: nil, notes: nil, occurrence: d.addingTimeInterval(3600), alarmOffsets: nil)
        let result = uniqueBlocks([b1, b2], trackByID: true)
        XCTAssertEqual(result.count, 2)
    }
}
