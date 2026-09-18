import Foundation
import EventKit

enum OverlapMode: String, CaseIterable, Identifiable, Codable {
    case allow, skipCovered, fillGaps
    var id: String { rawValue }
}

struct Route: Identifiable, Hashable, Codable {
    let id = UUID()
    var sourceID: String
    var targetIDs: Set<String>
    var privacy: Bool              // true = hide details for this source
    var copyNotes: Bool            // copy description when privacy is OFF
    var syncReminders: Bool        // copy source event alarms into placeholder
    var mergeGapHours: Int         // per-route merge gap (hours)
    var overlap: OverlapMode       // per-route overlap behavior
    var allDay: Bool               // per-route mirror all-day
    var titlePrefix: String?       // per-route prefix override; nil = use the app's global prefix
    var mirrorMirroredEvents: Bool // if true, don't skip source events that are themselves mirrors (chained mirroring)
    enum CodingKeys: String, CodingKey { case sourceID, targetIDs, privacy, copyNotes, syncReminders, mergeGapHours, overlap, allDay, titlePrefix, mirrorMirroredEvents }

    init(sourceID: String, targetIDs: Set<String>, privacy: Bool, copyNotes: Bool, syncReminders: Bool, mergeGapHours: Int, overlap: OverlapMode, allDay: Bool, titlePrefix: String? = nil, mirrorMirroredEvents: Bool = false) {
        self.sourceID = sourceID
        self.targetIDs = targetIDs
        self.privacy = privacy
        self.copyNotes = copyNotes
        self.syncReminders = syncReminders
        self.mergeGapHours = mergeGapHours
        self.overlap = overlap
        self.allDay = allDay
        self.titlePrefix = titlePrefix
        self.mirrorMirroredEvents = mirrorMirroredEvents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try c.decode(String.self, forKey: .sourceID)
        self.targetIDs = try c.decode(Set<String>.self, forKey: .targetIDs)
        self.privacy = try c.decode(Bool.self, forKey: .privacy)
        self.copyNotes = try c.decode(Bool.self, forKey: .copyNotes)
        self.syncReminders = try c.decodeIfPresent(Bool.self, forKey: .syncReminders) ?? false
        self.mergeGapHours = try c.decode(Int.self, forKey: .mergeGapHours)
        self.overlap = try c.decode(OverlapMode.self, forKey: .overlap)
        self.allDay = try c.decode(Bool.self, forKey: .allDay)
        self.titlePrefix = try c.decodeIfPresent(String.self, forKey: .titlePrefix)
        self.mirrorMirroredEvents = try c.decodeIfPresent(Bool.self, forKey: .mirrorMirroredEvents) ?? false
    }
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
    let mirrorMirroredEvents: Bool
}
