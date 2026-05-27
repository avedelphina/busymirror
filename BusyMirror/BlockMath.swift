import Foundation

struct Block: Hashable {
    let start: Date
    let end: Date
    let srcStableID: String?  // stable source item ID for reschedule tracking
    let label: String?        // source title (for dry-run / non-private)
    let notes: String?        // source notes (for optional copy)
    let occurrence: Date?     // occurrenceDate for recurring instances
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
    var cur = Block(start: sorted[0].start, end: sorted[0].end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)
    for b in sorted.dropFirst() {
        let gap = b.start.timeIntervalSince(cur.end) / 60.0
        if gap <= Double(gapMinutes) {
            if b.end > cur.end { cur = Block(start: cur.start, end: b.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil) }
        } else {
            out.append(cur)
            cur = Block(start: b.start, end: b.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)
        }
    }
    out.append(cur)
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
    if mergedSegs.isEmpty { return [Block(start: block.start, end: block.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)] }
    var segs: [Block] = []
    for s in mergedSegs where s.end > block.start && s.start < block.end {
        let ss = max(s.start, block.start)
        let ee = min(s.end, block.end)
        if ee > ss { segs.append(Block(start: ss, end: ee, srcStableID: nil, label: nil, notes: nil, occurrence: nil)) }
    }
    if segs.isEmpty { return [Block(start: block.start, end: block.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)] }
    let merged = coalesce(segs)
    var gaps: [Block] = []
    var prevEnd = block.start
    for s in merged {
        if s.start > prevEnd { gaps.append(Block(start: prevEnd, end: s.start, srcStableID: nil, label: nil, notes: nil, occurrence: nil)) }
        if s.end > prevEnd { prevEnd = s.end }
    }
    if prevEnd < block.end { gaps.append(Block(start: prevEnd, end: block.end, srcStableID: nil, label: nil, notes: nil, occurrence: nil)) }
    return gaps
}
