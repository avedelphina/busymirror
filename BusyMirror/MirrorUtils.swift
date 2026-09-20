import Foundation
import EventKit

// Calendar label helper to disambiguate identical names
func calLabel(_ cal: EKCalendar) -> String {
    let src = cal.source.title
    return src.isEmpty ? cal.title : "\(cal.title) — \(src)"
}

// Remove our prefix when building titles so it never doubles up
func stripPrefix(_ title: String?, prefix: String) -> String {
    guard let t = title else { return "" }
    if prefix.isEmpty { return t }
    return t.hasPrefix(prefix) ? String(t.dropFirst(prefix.count)) : t
}

// Invisible boundary marker embedded right after a route's prefix when a
// mirrored title is built (see MirrorEngine's title construction). Lets a
// downstream chained route recover exactly which characters were "the
// upstream prefix" without knowing that route's prefix string in advance —
// unlike stripPrefix, which only strips a prefix you already know.
let mirrorTitleMarker = "\u{2063}"

// Everything before the marker, if present — the upstream route's prefix,
// verbatim, for a chained route to preserve under its own Privacy setting.
func extractMirrorPrefix(from title: String?) -> String? {
    guard let title, let range = title.range(of: mirrorTitleMarker) else { return nil }
    return String(title[title.startIndex..<range.lowerBound])
}

private let mirrorURLAllowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

func mirrorURLComponentEncode(_ raw: String) -> String {
    raw.addingPercentEncoding(withAllowedCharacters: mirrorURLAllowedCharacters) ?? raw
}

func mirrorURLComponentDecode(_ raw: Substring) -> String {
    let value = String(raw)
    return value.removingPercentEncoding ?? value
}

func stableSourceIdentifier(for event: EKEvent) -> String? {
    if let external = event.calendarItemExternalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
       !external.isEmpty {
        return "ext:\(external)"
    }
    let local = event.calendarItemIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !local.isEmpty {
        return "loc:\(local)"
    }
    if let legacy = event.eventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
       !legacy.isEmpty {
        return "evt:\(legacy)"
    }
    return nil
}

func sourceOccurrenceKey(sourceCalID: String, sourceStableID: String, occurrence: Date?) -> String {
    let occPart = occurrence.map { String($0.timeIntervalSince1970) } ?? "-"
    return "\(sourceCalID)|\(sourceStableID)|\(occPart)"
}

func mirrorRecordKey(targetCalID: String, sourceKey: String) -> String {
    "\(targetCalID)|\(sourceKey)"
}

func mirrorTimeKey(start: Date, end: Date) -> String {
    "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
}

func buildMirrorURL(targetCalID: String, sourceCalID: String, sourceStableID: String?, occurrence: Date?, start: Date, end: Date) -> URL? {
    let sourceID = sourceStableID ?? ""
    let occ = occurrence.map { String($0.timeIntervalSince1970) } ?? "-"
    // Percent-encode IDs so that any embedded ";" doesn't corrupt the
    // semicolon-delimited path when the URL is later parsed.
    let parts = [
        mirrorURLComponentEncode(targetCalID),
        mirrorURLComponentEncode(sourceCalID),
        mirrorURLComponentEncode(sourceID),
        occ,
        String(start.timeIntervalSince1970),
        String(end.timeIntervalSince1970)
    ]
    var components = URLComponents()
    components.scheme = "mirror"
    components.host = "x"
    // Use percentEncodedPath so URLComponents does not re-encode the already
    // percent-encoded IDs (double-encoding would break round-trip parsing).
    components.percentEncodedPath = "/" + parts.joined(separator: ";")
    return components.url
}

// Parse mirror URL: mirror://x/<tgtID>;<srcCalID>;<srcStableID>;<occTS>;<startTS>;<endTS>
// Backward-compatible with legacy mirror://<tgtID>|<srcCalID>|... format
func parseMirrorURL(_ url: URL?) -> (targetCalID: String?, sourceCalID: String?, sourceStableID: String?, occ: Date?, start: Date?, end: Date?) {
    guard let abs = url?.absoluteString, abs.hasPrefix("mirror://") else { return (nil, nil, nil, nil, nil, nil) }
    let body = abs.dropFirst("mirror://".count)
    // Strip legacy host placeholder if present
    let strippedBody = body.hasPrefix("x/") ? body.dropFirst("x/".count) : body
    let parts = strippedBody.contains(";")
        ? strippedBody.split(separator: ";", omittingEmptySubsequences: false)
        : strippedBody.split(separator: "|", omittingEmptySubsequences: false)
    var targetCalID: String? = nil
    var sourceCalID: String? = nil
    var srcID: String? = nil
    var occDate: Date? = nil
    var sDate: Date? = nil
    var eDate: Date? = nil
    if parts.count >= 1 { targetCalID = mirrorURLComponentDecode(parts[0]) }
    if parts.count >= 2 { sourceCalID = mirrorURLComponentDecode(parts[1]) }
    if parts.count >= 3 {
        let decoded = mirrorURLComponentDecode(parts[2])
        srcID = decoded.isEmpty ? nil : decoded
    }
    if parts.count >= 4,
       String(parts[3]) != "-",
       let ts = TimeInterval(String(parts[3])) {
        occDate = Date(timeIntervalSince1970: ts)
    }
    if parts.count >= 6,
       let sTS = TimeInterval(String(parts[4])),
       let eTS = TimeInterval(String(parts[5])) {
        sDate = Date(timeIntervalSince1970: sTS)
        eDate = Date(timeIntervalSince1970: eTS)
    }
    return (targetCalID, sourceCalID, srcID, occDate, sDate, eDate)
}

// Pure title/URL-based mirror detection (testable without EKEvent)
func isMirrorEvent(title: String?, urlString: String?, prefix: String, placeholder: String) -> Bool {
    if let urlString = urlString, urlString.hasPrefix("mirror://") { return true }
    let t = title ?? ""
    if !prefix.isEmpty && t.hasPrefix(prefix) { return true }
    if t == placeholder || (!prefix.isEmpty && t == (prefix + placeholder)) { return true }
    return false
}

// EKEvent wrapper
func isMirrorEvent(_ ev: EKEvent, prefix: String, placeholder: String) -> Bool {
    isMirrorEvent(title: ev.title, urlString: ev.url?.absoluteString, prefix: prefix, placeholder: placeholder)
}

// Calendars that already contain mirror-tagged events, whichever app/device/prefix wrote
// them — the mirror:// URL tag is prefix-independent, so this works across the Mac/iOS
// boundary even though the two apps don't share routes. URL-only on purpose: isMirrorEvent's
// title path would match untitled events against an empty placeholder. A hint for pickers,
// so the window is modest, and synchronous (EventKit fetch) — call it on load/refresh, not
// on every store-change notification.
func mirroredCalendarIDs(among calendars: [EKCalendar], store: EKEventStore, daysBack: Int = 60, daysForward: Int = 60) -> Set<String> {
    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    guard let windowStart = cal.date(byAdding: .day, value: -daysBack, to: todayStart),
          let windowEnd = cal.date(byAdding: .day, value: daysForward, to: todayStart) else { return [] }

    var result = Set<String>()
    for c in calendars {
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [c])
        if store.events(matching: predicate).contains(where: { $0.url?.absoluteString.hasPrefix("mirror://") ?? false }) {
            result.insert(c.calendarIdentifier)
        }
    }
    return result
}
