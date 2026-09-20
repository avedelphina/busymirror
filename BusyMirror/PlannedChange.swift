import Foundation

// One change a mirror run would make. MirrorEngine emits these (dry-run only)
// alongside its "WOULD ..." log lines so a UI can show a structured preview
// instead of asking people to read log text.
struct PlannedChange: Identifiable {
    enum Kind {
        case create, update, delete

        fileprivate var sortRank: Int {
            switch self {
            case .create: return 0
            case .update: return 1
            case .delete: return 2
            }
        }
    }

    // Why an existing mirror needs updating.
    enum Reason: Hashable {
        case time, title, marker, notes, allDay, link, reminders
    }

    let id = UUID()
    let kind: Kind
    let targetName: String
    let targetCalendarID: String
    let oldTitle: String?
    let newTitle: String?
    let oldStart: Date?
    let oldEnd: Date?
    let newStart: Date?
    let newEnd: Date?
    let reasons: [Reason]

    init(
        kind: Kind,
        targetName: String,
        targetCalendarID: String,
        oldTitle: String? = nil,
        newTitle: String? = nil,
        oldStart: Date? = nil,
        oldEnd: Date? = nil,
        newStart: Date? = nil,
        newEnd: Date? = nil,
        reasons: [Reason] = []
    ) {
        self.kind = kind
        self.targetName = targetName
        self.targetCalendarID = targetCalendarID
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.oldStart = oldStart
        self.oldEnd = oldEnd
        self.newStart = newStart
        self.newEnd = newEnd
        self.reasons = reasons
    }

    // Where this change lands on the calendar: the new time for create/update,
    // the existing time for delete. Grouping and sort key.
    var effectiveStart: Date? { newStart ?? oldStart }

    // Explanations for update reasons that an old → new title/time doesn't already show.
    var extraNotes: [String] {
        guard kind == .update else { return [] }
        var notes: [String] = []
        if reasons.contains(.marker) { notes.append("Changes an invisible chain marker in the title (no visible change)") }
        if reasons.contains(.notes) { notes.append("Notes changed") }
        if reasons.contains(.reminders) { notes.append("Reminders changed") }
        if reasons.contains(.allDay) { notes.append("Converted from an all-day event") }
        // The tracking link embeds the time, so it changes whenever the time does — only worth
        // mentioning when it's the sole reason.
        if reasons == [.link] { notes.append("Refreshes tracking data (no visible change)") }
        return notes
    }
}

// A title differing only by the invisible chain marker is a real update (the stored
// title changes) but shows as identical old → new text, so it needs its own reason.
func titleChangeReason(existing: String, desired: String) -> PlannedChange.Reason? {
    if existing == desired { return nil }
    let strip = { (s: String) in s.replacingOccurrences(of: mirrorTitleMarker, with: "") }
    return strip(existing) == strip(desired) ? .marker : .title
}

struct PlannedDayGroup: Identifiable {
    let day: Date
    let changes: [PlannedChange]
    var id: Date { day }
}

struct PlannedTargetGroup: Identifiable {
    let targetCalendarID: String
    let targetName: String
    let days: [PlannedDayGroup]
    var id: String { targetCalendarID }
}

// Target calendar (by name) → day → time-ordered changes.
func groupPlannedChanges(_ changes: [PlannedChange], calendar: Calendar = .current) -> [PlannedTargetGroup] {
    Dictionary(grouping: changes, by: { $0.targetCalendarID })
        .map { (targetID, items) -> PlannedTargetGroup in
            let byDay = Dictionary(grouping: items) {
                calendar.startOfDay(for: $0.effectiveStart ?? .distantPast)
            }
            let days = byDay.keys.sorted().map { day in
                PlannedDayGroup(day: day, changes: byDay[day, default: []].sorted(by: plannedChangeOrder))
            }
            return PlannedTargetGroup(targetCalendarID: targetID, targetName: items[0].targetName, days: days)
        }
        .sorted { $0.targetName.localizedCaseInsensitiveCompare($1.targetName) == .orderedAscending }
}

private func plannedChangeOrder(_ a: PlannedChange, _ b: PlannedChange) -> Bool {
    let sa = a.effectiveStart ?? .distantPast
    let sb = b.effectiveStart ?? .distantPast
    if sa != sb { return sa < sb }
    return a.kind.sortRank < b.kind.sortRank
}

func plannedChangeSummary(_ changes: [PlannedChange]) -> String {
    let creates = changes.filter { $0.kind == .create }.count
    let updates = changes.filter { $0.kind == .update }.count
    let deletes = changes.filter { $0.kind == .delete }.count
    var parts: [String] = []
    if creates > 0 { parts.append("\(creates) to create") }
    if updates > 0 { parts.append("\(updates) to update") }
    if deletes > 0 { parts.append("\(deletes) to delete") }
    return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
}
