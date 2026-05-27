import Foundation
import EventKit

func isOutsideWorkHours(_ startDate: Date, calendar: Calendar, startMinutes: Int, endMinutes: Int) -> Bool {
    guard endMinutes > startMinutes else { return false }
    let comps = calendar.dateComponents([.hour, .minute], from: startDate)
    guard let hour = comps.hour else { return false }
    let minute = comps.minute ?? 0
    let start = hour * 60 + minute
    return start < startMinutes || start >= endMinutes
}

func shouldSkip(title: String?, filters: [String], titlePrefix: String) -> Bool {
    guard !filters.isEmpty else { return false }
    let rawTitle = (title ?? "").lowercased()
    let strippedTitle = stripPrefix(title, prefix: titlePrefix).lowercased()
    return filters.contains { token in
        rawTitle.contains(token) || strippedTitle.contains(token)
    }
}

func organizerEmail(_ participant: EKParticipant?) -> String? {
    guard let url = participant?.url else { return nil }
    if url.scheme?.lowercased() == "mailto" {
        let abs = url.absoluteString
        if abs.lowercased().hasPrefix("mailto:") {
            return String(abs.dropFirst("mailto:".count))
        }
        return abs
    }
    return url.absoluteString
}

func organizerStrings(for event: EKEvent) -> [String] {
    var out: [String] = []
    if let org = event.organizer {
        if let n = org.name, !n.isEmpty { out.append(n) }
        if let e = organizerEmail(org), !e.isEmpty { out.append(e) }
    }
    // Fallback: some providers may not populate organizer; try chair attendee
    if out.isEmpty, let attendees = event.attendees {
        if let chair = attendees.first(where: { $0.participantRole == .chair }) {
            if let n = chair.name, !n.isEmpty { out.append(n) }
            if let e = organizerEmail(chair), !e.isEmpty { out.append(e) }
        }
    }
    return out
}

func shouldSkipOrganizer(organizerValues: [String], filters: [String]) -> Bool {
    guard !filters.isEmpty else { return false }
    guard !organizerValues.isEmpty else { return false }
    let vals = organizerValues.map { $0.lowercased() }
    for token in filters {
        for v in vals {
            if v.contains(token) { return true }
        }
    }
    return false
}
