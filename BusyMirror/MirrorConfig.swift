import Foundation
import EventKit

// Default sync window, shared so both apps agree. (Mac lets you change it in Preferences;
// iOS uses these fixed until it gets the same setting.)
let defaultSyncDaysBack = 1
let defaultSyncDaysForward = 14

enum OverlapMode: String, CaseIterable, Identifiable, Codable {
    case allow, skipCovered, fillGaps
    var id: String { rawValue }
}

// Comma/newline-separated filter text -> lowercased terms. Global and per-route filters share this format.
func parseFilterTerms(_ raw: String) -> [String] {
    raw.split { $0 == "\n" || $0 == "," }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
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
    var passThroughMirroredTitles: Bool // if true, copy an already-mirrored source event's title verbatim instead of re-prefixing it (avoids "B: A: Meeting" stacking on chained routes)
    var excludedTitleFilters: String = ""     // title terms skipped by this route (comma/newline separated); added to the global list unless overrideGlobalFilters
    var excludedOrganizerFilters: String = "" // same for organizers
    var overrideGlobalFilters: Bool = false   // true = this route's title/organizer lists replace the global ones (empty = no filtering)
    var filterByWorkHours: Bool?              // per-route work-hours filter; nil = inherit the app's global setting
    var workHoursStart: Int?                  // nil = inherit global hours
    var workHoursEnd: Int?
    var mirrorAcceptedOnly: Bool?             // nil = inherit the app's global setting
    enum CodingKeys: String, CodingKey { case sourceID, targetIDs, privacy, copyNotes, syncReminders, mergeGapHours, overlap, allDay, titlePrefix, mirrorMirroredEvents, passThroughMirroredTitles, excludedTitleFilters, excludedOrganizerFilters, overrideGlobalFilters, filterByWorkHours, workHoursStart, workHoursEnd, mirrorAcceptedOnly }

    init(sourceID: String, targetIDs: Set<String>, privacy: Bool, copyNotes: Bool, syncReminders: Bool, mergeGapHours: Int, overlap: OverlapMode, allDay: Bool, titlePrefix: String? = nil, mirrorMirroredEvents: Bool = false, passThroughMirroredTitles: Bool = false, excludedTitleFilters: String = "", excludedOrganizerFilters: String = "", overrideGlobalFilters: Bool = false, filterByWorkHours: Bool? = nil, workHoursStart: Int? = nil, workHoursEnd: Int? = nil, mirrorAcceptedOnly: Bool? = nil) {
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
        self.passThroughMirroredTitles = passThroughMirroredTitles
        self.excludedTitleFilters = excludedTitleFilters
        self.excludedOrganizerFilters = excludedOrganizerFilters
        self.overrideGlobalFilters = overrideGlobalFilters
        self.filterByWorkHours = filterByWorkHours
        self.workHoursStart = workHoursStart
        self.workHoursEnd = workHoursEnd
        self.mirrorAcceptedOnly = mirrorAcceptedOnly
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
        self.passThroughMirroredTitles = try c.decodeIfPresent(Bool.self, forKey: .passThroughMirroredTitles) ?? false
        self.excludedTitleFilters = try c.decodeIfPresent(String.self, forKey: .excludedTitleFilters) ?? ""
        self.excludedOrganizerFilters = try c.decodeIfPresent(String.self, forKey: .excludedOrganizerFilters) ?? ""
        self.overrideGlobalFilters = try c.decodeIfPresent(Bool.self, forKey: .overrideGlobalFilters) ?? false
        self.filterByWorkHours = try c.decodeIfPresent(Bool.self, forKey: .filterByWorkHours)
        self.workHoursStart = try c.decodeIfPresent(Int.self, forKey: .workHoursStart)
        self.workHoursEnd = try c.decodeIfPresent(Int.self, forKey: .workHoursEnd)
        self.mirrorAcceptedOnly = try c.decodeIfPresent(Bool.self, forKey: .mirrorAcceptedOnly)
    }

    // Effective per-run filter settings: the route's own value where set, else the app's global one.
    // `global` terms must already be lowercased (parseFilterTerms does that for route terms).
    func titleFilterTerms(global: [String]) -> [String] {
        (overrideGlobalFilters ? [] : global) + parseFilterTerms(excludedTitleFilters)
    }
    func organizerFilterTerms(global: [String]) -> [String] {
        (overrideGlobalFilters ? [] : global) + parseFilterTerms(excludedOrganizerFilters)
    }
    func workHours(globalEnabled: Bool, globalStart: Int, globalEnd: Int) -> (enabled: Bool, start: Int, end: Int) {
        (filterByWorkHours ?? globalEnabled, workHoursStart ?? globalStart, workHoursEnd ?? globalEnd)
    }
}

// Inherit / force-on / force-off for an optional per-route Bool (nil / true / false) — the Bool?
// counterpart of PrefixMode, for both apps' route editors.
enum OverrideChoice: String, CaseIterable, Identifiable {
    case global = "Global", on = "On", off = "Off"
    var id: String { rawValue }

    init(_ value: Bool?) {
        switch value {
        case .none: self = .global
        case .some(true): self = .on
        case .some(false): self = .off
        }
    }

    var value: Bool? {
        switch self {
        case .global: return nil
        case .on: return true
        case .off: return false
        }
    }
}

// The three states of Route.titlePrefix as a UI choice, shared by both apps' route editors.
enum PrefixMode: String, CaseIterable, Identifiable {
    case global = "Global"   // titlePrefix == nil: inherit the app's global prefix
    case custom = "Custom"   // non-empty: this route's own prefix
    case none = "None"       // "": no prefix at all

    var id: String { rawValue }

    static func from(_ titlePrefix: String?) -> (mode: PrefixMode, customText: String) {
        switch titlePrefix {
        case .none: return (.global, "")
        case .some(let p) where p.isEmpty: return (.none, "")
        case .some(let p): return (.custom, p)
        }
    }

    // Custom with empty text resolves to "" — an empty custom prefix *is* no prefix, and
    // reads back as None.
    func resolve(customText: String) -> String? {
        switch self {
        case .global: return nil
        case .none: return ""
        case .custom: return customText
        }
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
    let passThroughMirroredTitles: Bool
}
