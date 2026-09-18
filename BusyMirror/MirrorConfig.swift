import Foundation
import EventKit

enum OverlapMode: String, CaseIterable, Identifiable, Codable {
    case allow, skipCovered, fillGaps
    var id: String { rawValue }
}

struct MirrorConfig {
    let daysBack: Int
    let daysForward: Int
    let mergeGapMin: Int
    let hideDetails: Bool
    let copyDescription: Bool
    let mirrorAllDay: Bool
    let overlapMode: OverlapMode
    let titlePrefix: String
    let placeholderTitle: String
    let filterByWorkHours: Bool
    let workHoursStart: Int
    let workHoursEnd: Int
    let excludedTitleFilterTerms: [String]
    let excludedOrganizerFilterTerms: [String]
    let mirrorAcceptedOnly: Bool
    let autoDeleteMissing: Bool
    let writeEnabled: Bool
    let syncReminders: Bool
}
