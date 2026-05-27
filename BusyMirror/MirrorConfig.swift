import Foundation
import EventKit

struct MirrorConfig {
    let daysBack: Int
    let daysForward: Int
    let mergeGapMin: Int
    let hideDetails: Bool
    let copyDescription: Bool
    let markPrivate: Bool
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
}
