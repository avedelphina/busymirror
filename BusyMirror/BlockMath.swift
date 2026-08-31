import Foundation

struct Block: Hashable {
    let start: Date
    let end: Date
    let srcStableID: String?  // stable source item ID for reschedule tracking
    let label: String?        // source title (for dry-run / non-private)
    let notes: String?        // source notes (for optional copy)
    let occurrence: Date?     // occurrenceDate for recurring instances
    let alarmOffsets: [TimeInterval]?  // relative alarm offsets copied from source event
    var tentative: Bool = false        // source "Maybe" RSVP; mirrored with a marker
    // ponytail: lost on the merge path (mergeGapMin > 0) along with the title; only tracked in per-event mode

    /// Convenience factory for time-only blocks (used internally for occupancy tracking).
    static func span(start: Date, end: Date) -> Block {
        Block(start: start, end: end, srcStableID: nil, label: nil, notes: nil, occurrence: nil, alarmOffsets: nil)
    }

    // Alarms are carried along for mirroring but do not affect time-based
    // deduplication, merging, or overlap calculations.
    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.start == rhs.start &&
        lhs.end == rhs.end &&
        lhs.srcStableID == rhs.srcStableID &&
        lhs.label == rhs.label &&
        lhs.notes == rhs.notes &&
        lhs.occurrence == rhs.occurrence &&
        lhs.tentative == rhs.tentative
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(start)
        hasher.combine(end)
        hasher.combine(srcStableID)
        hasher.combine(label)
        hasher.combine(notes)
        hasher.combine(occurrence)
        hasher.combine(tentative)
    }
}

// De-dup blocks by occurrence (preferred) or by time range
func uniqueBlocks(_ blocks: [Block], trackByID: Bool) -> [Block] {
    var seen = Set<String>()
    var out: [Block] = []
    for b in blocks {
        let key: String
        if trackByID, let sid = b.srcStableID {
            let occ = b.occurrence.map { String($0.timeIntervalSince1970) } ?? "-"
            key = "id|\(sid)|\(occ)"
        } else {
            key = "t|\(b.start.timeIntervalSince1970)|\(b.end.timeIntervalSince1970)"
        }
        if seen.insert(key).inserted { out.append(b) }
    }
    return out
}

func mergeBlocks(_ blocks: [Block], gapMinutes: Int) -> [Block] {
    guard !blocks.isEmpty else { return [] }
    let sorted = blocks.sorted { $0.start < $1.start }
    var out: [Block] = []
    var cur = Block.span(start: sorted[0].start, end: sorted[0].end)
    var curAlarms = sorted[0].alarmOffsets
    for b in sorted.dropFirst() {
        let gap = b.start.timeIntervalSince(cur.end) / 60.0
        if gap <= Double(gapMinutes) {
            if b.end > cur.end { cur = Block.span(start: cur.start, end: b.end) }
        } else {
            out.append(Block(start: cur.start, end: cur.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil, alarmOffsets: curAlarms))
            cur = Block.span(start: b.start, end: b.end)
            curAlarms = b.alarmOffsets
        }
    }
    out.append(Block(start: cur.start, end: cur.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil, alarmOffsets: curAlarms))
    return out
}

func coalesce(_ segs: [Block]) -> [Block] { mergeBlocks(segs, gapMinutes: 0) }

func fullyCovered(_ mergedSegs: [Block], block: Block, tolMin: Double) -> Bool {
    for s in mergedSegs {
        if s.start <= block.start.addingTimeInterval(tolMin * 60),
           s.end >= block.end.addingTimeInterval(-tolMin * 60) { return true }
    }
    return false
}

func gapsWithin(_ mergedSegs: [Block], in block: Block) -> [Block] {
    if mergedSegs.isEmpty { return [Block.span(start: block.start, end: block.end)] }
    var segs: [Block] = []
    for s in mergedSegs where s.end > block.start && s.start < block.end {
        let ss = max(s.start, block.start)
        let ee = min(s.end, block.end)
        if ee > ss { segs.append(Block.span(start: ss, end: ee)) }
    }
    if segs.isEmpty { return [Block.span(start: block.start, end: block.end)] }
    let merged = coalesce(segs)
    var gaps: [Block] = []
    var prevEnd = block.start
    for s in merged {
        if s.start > prevEnd { gaps.append(Block.span(start: prevEnd, end: s.start)) }
        if s.end > prevEnd { prevEnd = s.end }
    }
    if prevEnd < block.end { gaps.append(Block.span(start: prevEnd, end: block.end)) }
    return gaps
}
