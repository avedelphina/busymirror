import Foundation
import EventKit

private let SAME_TIME_TOL_MIN: Double = 5

private func alarmOffsets(for event: EKEvent) -> [TimeInterval]? {
    guard let alarms = event.alarms, !alarms.isEmpty else { return nil }
    let offsets = alarms.compactMap { alarm -> TimeInterval? in
        if alarm.relativeOffset != 0 {
            return alarm.relativeOffset
        }
        if let absoluteDate = alarm.absoluteDate, let start = event.startDate {
            return absoluteDate.timeIntervalSince(start)
        }
        return nil
    }
    return offsets.isEmpty ? nil : offsets
}

private func alarmsFromOffsets(_ offsets: [TimeInterval]) -> [EKAlarm] {
    offsets.map { EKAlarm(relativeOffset: $0) }
}

struct MirrorRecord: Hashable, Codable {
    var targetCalendarID: String
    var sourceCalendarID: String
    var sourceStableID: String
    var occurrenceTimestamp: TimeInterval?
    var targetEventIdentifier: String?
    var lastKnownStartTimestamp: TimeInterval
    var lastKnownEndTimestamp: TimeInterval
    var updatedAt: Date = Date()

    // updatedAt is intentionally excluded from equality and hashing: it is a
    // bookkeeping timestamp that changes on every write and should not cause
    // the mirror index to be marked dirty when the meaningful fields are equal.
    static func == (lhs: MirrorRecord, rhs: MirrorRecord) -> Bool {
        lhs.targetCalendarID == rhs.targetCalendarID &&
        lhs.sourceCalendarID == rhs.sourceCalendarID &&
        lhs.sourceStableID == rhs.sourceStableID &&
        lhs.occurrenceTimestamp == rhs.occurrenceTimestamp &&
        lhs.targetEventIdentifier == rhs.targetEventIdentifier &&
        lhs.lastKnownStartTimestamp == rhs.lastKnownStartTimestamp &&
        lhs.lastKnownEndTimestamp == rhs.lastKnownEndTimestamp
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(targetCalendarID)
        hasher.combine(sourceCalendarID)
        hasher.combine(sourceStableID)
        hasher.combine(occurrenceTimestamp)
        hasher.combine(targetEventIdentifier)
        hasher.combine(lastKnownStartTimestamp)
        hasher.combine(lastKnownEndTimestamp)
    }

    var sourceKey: String {
        sourceOccurrenceKey(
            sourceCalID: sourceCalendarID,
            sourceStableID: sourceStableID,
            occurrence: occurrenceTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    var timeKey: String {
        "\(lastKnownStartTimestamp)|\(lastKnownEndTimestamp)"
    }
}

@MainActor
final class MirrorEngine {
    private let log: (String) -> Void
    private let mirrorIndexDefaultsKey = "mirror-index.v1"

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    private func loadMirrorIndex() -> [String: MirrorRecord] {
        guard let data = UserDefaults.standard.data(forKey: mirrorIndexDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: MirrorRecord].self, from: data)
        } catch {
            log("✗ Failed to load mirror index: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveMirrorIndex(_ index: [String: MirrorRecord]) {
        do {
            let data = try JSONEncoder().encode(index)
            UserDefaults.standard.set(data, forKey: mirrorIndexDefaultsKey)
        } catch {
            log("✗ Failed to save mirror index: \(error.localizedDescription)")
        }
    }

    func runMirror(
        store: EKEventStore,
        config: MirrorConfig,
        sourceCalendar: EKCalendar,
        targetCalendars: [EKCalendar],
        sessionGuard: inout Set<String>,
        isMultiRouteRun: Bool
    ) async {
        let srcCal = sourceCalendar
        let srcName = calLabel(srcCal)
        let targets = targetCalendars.filter { $0.calendarIdentifier != srcCal.calendarIdentifier }
        if targets.isEmpty {
            log("No target calendars selected. Choose at least one target or add a route with valid targets.")
            return
        }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -config.daysBack, to: todayStart)!
        let windowEnd = cal.date(byAdding: .day, value: config.daysForward, to: todayStart)!
        log("=== BusyMirror ===")
        log("Source: \(srcName)  Targets: \(targets.map { calLabel($0) }.joined(separator: ", "))")
        log("Window: \(windowStart) -> \(windowEnd)")
        log("WRITE: \(config.writeEnabled) \(config.writeEnabled ? "" : "(DRY-RUN)")  mode: \(config.overlapMode.rawValue)  mergeGapMin: \(config.mergeGapMin)  allDay: \(config.mirrorAllDay)")
        log("Route: \(srcName) → {\(targets.map { calLabel($0) }.joined(separator: ", "))}")

        // Source events (recurrences expanded by EventKit)
        let srcPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [srcCal])
        var srcEvents = store.events(matching: srcPred)
        let srcFetched = srcEvents.count
        srcEvents = srcEvents.filter { $0.calendar.calendarIdentifier == srcCal.calendarIdentifier }
        let srcKept = srcEvents.count
        if srcKept != srcFetched {
            log("- WARN: filtered \(srcFetched - srcKept) stray source event(s) not in \(srcName)")
        }
        srcEvents.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        var srcBlocks: [Block] = []
        var skippedMirrors = 0
        let titleFilters = config.excludedTitleFilterTerms
        let organizerFilters = config.excludedOrganizerFilterTerms
        let enforceWorkHours = config.filterByWorkHours && config.workHoursEnd > config.workHoursStart
        let allowedStartMinutes = config.workHoursStart * 60
        let allowedEndMinutes = config.workHoursEnd * 60
        var skippedWorkHours = 0
        var skippedTitles = 0
        var skippedOrganizers = 0
        var skippedStatus = 0
        for ev in srcEvents {
            if Task.isCancelled { break }
            let myStatus = ev.attendees?.first(where: { $0.isCurrentUser })?.participantStatus
            let isTentative = (myStatus == .tentative)
            if config.mirrorAcceptedOnly, ev.hasAttendees {
                if let me = ev.attendees?.first(where: { $0.isCurrentUser }) {
                    // "Maybe" replies still get mirrored, just marked (see displayTitle below)
                    if me.participantStatus != .accepted && me.participantStatus != .tentative {
                        skippedStatus += 1
                        continue
                    }
                } else {
                    skippedStatus += 1
                    continue
                }
            }
            if enforceWorkHours, !ev.isAllDay, let start = ev.startDate,
               isOutsideWorkHours(start, calendar: cal, startMinutes: allowedStartMinutes, endMinutes: allowedEndMinutes) {
                skippedWorkHours += 1
                continue
            }
            if shouldSkip(title: ev.title, filters: titleFilters, titlePrefix: config.titlePrefix) {
                skippedTitles += 1
                continue
            }
            if shouldSkipOrganizer(organizerValues: organizerStrings(for: ev), filters: organizerFilters) {
                skippedOrganizers += 1
                continue
            }
            if !config.mirrorAllDay && ev.isAllDay { continue }
            let evIsMirror = isMirrorEvent(ev, prefix: config.titlePrefix, placeholder: config.placeholderTitle)
            if !config.mirrorMirroredEvents && evIsMirror {
                skippedMirrors += 1
                continue
            }
            guard let s = ev.startDate, let e = ev.endDate, e > s else { continue }
            guard ev.calendar.calendarIdentifier == srcCal.calendarIdentifier else { continue }
            let srcID = stableSourceIdentifier(for: ev)
            srcBlocks.append(Block(start: s, end: e, srcStableID: srcID, label: ev.title, notes: ev.notes, occurrence: ev.occurrenceDate, alarmOffsets: alarmOffsets(for: ev), tentative: isTentative, isMirrorSource: evIsMirror))
        }
        if skippedMirrors > 0 {
            log("- SKIP mirrored-on-source: \(skippedMirrors) instance(s)")
        }
        if skippedWorkHours > 0 {
            log("- SKIP outside work hours: \(skippedWorkHours) event(s)")
        }
        if skippedTitles > 0 {
            log("- SKIP title filter: \(skippedTitles) event(s)")
        }
        if skippedOrganizers > 0 {
            log("- SKIP organizer filter: \(skippedOrganizers) event(s)")
        }
        if skippedStatus > 0 {
            log("- SKIP non-accepted status: \(skippedStatus) event(s)")
        }
        srcBlocks = uniqueBlocks(srcBlocks, trackByID: config.mergeGapMin == 0)

        let baseBlocks = (config.mergeGapMin > 0) ? mergeBlocks(srcBlocks, gapMinutes: config.mergeGapMin) : srcBlocks
        let trackByID = (config.mergeGapMin == 0)
        var mirrorIndex = loadMirrorIndex()
        var mirrorIndexChanged = false

        func sourceKey(for blk: Block) -> String? {
            guard trackByID, let sid = blk.srcStableID else { return nil }
            return sourceOccurrenceKey(sourceCalID: srcCal.calendarIdentifier, sourceStableID: sid, occurrence: blk.occurrence)
        }

        // Cache target events across routes when possible
        var targetEventCache: [String: [EKEvent]] = [:]
        for tgt in targets {
            if Task.isCancelled { break }
            let tgtName = calLabel(tgt)
            log(">>> Target: \(tgtName)")
            if tgt.calendarIdentifier == srcCal.calendarIdentifier {
                log("- SKIP target is same as source: \(tgtName)")
                continue
            }
            let tgtEvents: [EKEvent]
            if let cached = targetEventCache[tgt.calendarIdentifier] {
                tgtEvents = cached
            } else {
                let tgtPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [tgt])
                var evs = store.events(matching: tgtPred)
                let tgtFetched = evs.count
                evs = evs.filter { $0.calendar.calendarIdentifier == tgt.calendarIdentifier }
                if tgtFetched != evs.count {
                    log("- WARN: filtered \(tgtFetched - evs.count) stray target event(s) not in \(tgtName)")
                }
                targetEventCache[tgt.calendarIdentifier] = evs
                tgtEvents = evs
            }

            var placeholderSet = Set<String>()
            var occupied: [Block] = []
            var placeholdersBySourceKey: [String: EKEvent] = [:]
            var placeholdersByTime: [String: EKEvent] = [:]
            var targetEventsByIdentifier: [String: EKEvent] = [:]
            for tv in tgtEvents {
                guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                if let eid = tv.eventIdentifier {
                    targetEventsByIdentifier[eid] = tv
                }
                if let ts = tv.startDate, let te = tv.endDate {
                    let timeKey = mirrorTimeKey(start: ts, end: te)
                    if isMirrorEvent(tv, prefix: config.titlePrefix, placeholder: config.placeholderTitle) {
                        placeholderSet.insert(timeKey)
                        placeholdersByTime[timeKey] = tv
                        let parsed = parseMirrorURL(tv.url)
                        if let sourceCalID = parsed.sourceCalID,
                           let sourceStableID = parsed.sourceStableID,
                           !sourceCalID.isEmpty,
                           !sourceStableID.isEmpty {
                            let key = sourceOccurrenceKey(sourceCalID: sourceCalID, sourceStableID: sourceStableID, occurrence: parsed.occ)
                            placeholdersBySourceKey[key] = tv
                            let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                            let record = MirrorRecord(
                                targetCalendarID: tgt.calendarIdentifier,
                                sourceCalendarID: sourceCalID,
                                sourceStableID: sourceStableID,
                                occurrenceTimestamp: parsed.occ?.timeIntervalSince1970,
                                targetEventIdentifier: tv.eventIdentifier,
                                lastKnownStartTimestamp: ts.timeIntervalSince1970,
                                lastKnownEndTimestamp: te.timeIntervalSince1970
                            )
                            if mirrorIndex[recordKey] != record {
                                mirrorIndex[recordKey] = record
                                mirrorIndexChanged = true
                            }
                        }
                    }
                    occupied.append(Block.span(start: ts, end: te))
                }
            }
            occupied = coalesce(occupied)

            var created = 0
            var skipped = 0
            var updated = 0

            func guardKey(for blk: Block, targetID: String) -> String {
                if let key = sourceKey(for: blk) {
                    return "\(key)|\(targetID)"
                }
                return "\(srcCal.calendarIdentifier)|\(blk.start.timeIntervalSince1970)|\(blk.end.timeIntervalSince1970)|\(targetID)"
            }

            func desiredNotes(for blk: Block) -> String? {
                (!config.hideDetails && config.copyDescription) ? blk.notes : nil
            }

            func upsertMirrorRecord(for blk: Block, event: EKEvent) {
                guard let sid = blk.srcStableID,
                      let key = sourceKey(for: blk),
                      let startDate = event.startDate,
                      let endDate = event.endDate else { return }
                let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                let record = MirrorRecord(
                    targetCalendarID: tgt.calendarIdentifier,
                    sourceCalendarID: srcCal.calendarIdentifier,
                    sourceStableID: sid,
                    occurrenceTimestamp: blk.occurrence?.timeIntervalSince1970,
                    targetEventIdentifier: event.eventIdentifier,
                    lastKnownStartTimestamp: startDate.timeIntervalSince1970,
                    lastKnownEndTimestamp: endDate.timeIntervalSince1970
                )
                if mirrorIndex[recordKey] != record {
                    mirrorIndex[recordKey] = record
                    mirrorIndexChanged = true
                }
            }

            func removeMirrorRecord(for key: String) {
                let recordKey = mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: key)
                if mirrorIndex.removeValue(forKey: recordKey) != nil {
                    mirrorIndexChanged = true
                }
            }

            func resolveMappedEvent(for record: MirrorRecord) -> EKEvent? {
                if let eid = record.targetEventIdentifier,
                   let event = targetEventsByIdentifier[eid],
                   event.calendar.calendarIdentifier == tgt.calendarIdentifier {
                    return event
                }
                return placeholdersByTime[record.timeKey]
            }

            func rememberMirrorEvent(_ event: EKEvent, for blk: Block) {
                if let startDate = event.startDate, let endDate = event.endDate {
                    let timeKey = mirrorTimeKey(start: startDate, end: endDate)
                    placeholderSet.insert(timeKey)
                    placeholdersByTime[timeKey] = event
                }
                if let key = sourceKey(for: blk) {
                    placeholdersBySourceKey[key] = event
                }
                if let eid = event.eventIdentifier {
                    targetEventsByIdentifier[eid] = event
                }
                upsertMirrorRecord(for: blk, event: event)
            }

            func desiredAlarms(for blk: Block) -> [EKAlarm] {
                guard config.syncReminders, let offsets = blk.alarmOffsets else { return [] }
                return alarmsFromOffsets(offsets)
            }

            func alarmsEqual(_ a: [EKAlarm], _ b: [EKAlarm]) -> Bool {
                let offsetsA = a.compactMap { $0.relativeOffset }.sorted()
                let offsetsB = b.compactMap { $0.relativeOffset }.sorted()
                return offsetsA == offsetsB
            }

            func needsUpdate(existing: EKEvent, blk: Block, displayTitle: String, desiredNotes: String?, desiredURL: URL?) -> Bool {
                let curS = existing.startDate ?? blk.start
                let curE = existing.endDate ?? blk.end
                if abs(curS.timeIntervalSince(blk.start)) > SAME_TIME_TOL_MIN * 60 { return true }
                if abs(curE.timeIntervalSince(blk.end)) > SAME_TIME_TOL_MIN * 60 { return true }
                if (existing.title ?? "") != displayTitle { return true }
                if (existing.notes ?? "") != (desiredNotes ?? "") { return true }
                if existing.isAllDay { return true }
                if (existing.url?.absoluteString ?? "") != (desiredURL?.absoluteString ?? "") { return true }
                let newAlarms = desiredAlarms(for: blk)
                let existingAlarms = existing.alarms ?? []
                if !alarmsEqual(newAlarms, existingAlarms) { return true }
                return false
            }

            func createOrUpdateIfNeeded(_ blk: Block) async {
                let gKey = guardKey(for: blk, targetID: tgt.calendarIdentifier)
                if sessionGuard.contains(gKey) {
                    skipped += 1
                    log("- SKIP loop-guard [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    return
                }

                let baseSourceTitle = stripPrefix(blk.label, prefix: config.titlePrefix)
                let effectiveTitle = config.hideDetails ? config.placeholderTitle : (baseSourceTitle.isEmpty ? config.placeholderTitle : baseSourceTitle)
                let titleSuffix = config.hideDetails ? "" : (baseSourceTitle.isEmpty ? "" : " — \(baseSourceTitle)")
                let maybeMark = blk.tentative ? "Maybe: " : ""
                // Chained routes: an already-mirrored source event's title already carries its
                // own upstream prefix, which we don't know how to strip (it isn't ours) — so
                // re-prefixing here would stack ("B: A: Meeting"). Pass it through untouched instead.
                let passThrough = config.mirrorMirroredEvents && config.passThroughMirroredTitles && blk.isMirrorSource
                let displayTitle = passThrough
                    ? (blk.label ?? config.placeholderTitle)
                    : (config.titlePrefix.isEmpty ? "" : config.titlePrefix) + maybeMark + effectiveTitle
                let notes = desiredNotes(for: blk)
                let desiredURL = buildMirrorURL(
                    targetCalID: tgt.calendarIdentifier,
                    sourceCalID: srcCal.calendarIdentifier,
                    sourceStableID: blk.srcStableID,
                    occurrence: blk.occurrence,
                    start: blk.start,
                    end: blk.end
                )
                let exactTimeKey = mirrorTimeKey(start: blk.start, end: blk.end)
                let blkSourceKey = sourceKey(for: blk)

                func updateExisting(_ existing: EKEvent, byTime: Bool) async {
                    let curS = existing.startDate ?? blk.start
                    let curE = existing.endDate ?? blk.end
                    rememberMirrorEvent(existing, for: blk)
                    if !needsUpdate(existing: existing, blk: blk, displayTitle: displayTitle, desiredNotes: notes, desiredURL: desiredURL) {
                        sessionGuard.insert(gKey)
                        skipped += 1
                        return
                    }
                    let byTimeSuffix = byTime ? " (by time)" : ""
                    if !config.writeEnabled {
                        sessionGuard.insert(gKey)
                        log("~ WOULD UPDATE [\(srcName) -> \(tgtName)]\(byTimeSuffix) \(curS) -> \(curE)  TO  \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                        updated += 1
                        return
                    }
                    existing.title = displayTitle
                    existing.availability = blk.tentative ? .tentative : .busy
                    existing.startDate = blk.start
                    existing.endDate = blk.end
                    existing.isAllDay = false
                    existing.notes = notes
                    existing.url = desiredURL
                    existing.alarms = desiredAlarms(for: blk)
                    do {
                        try store.save(existing, span: .thisEvent, commit: true)
                        log("✓ UPDATED [\(srcName) -> \(tgtName)]\(byTimeSuffix) \(blk.start) -> \(blk.end)")
                        rememberMirrorEvent(existing, for: blk)
                        occupied = coalesce(occupied + [Block.span(start: blk.start, end: blk.end)])
                        sessionGuard.insert(gKey)
                        updated += 1
                    } catch {
                        log("Update failed: \(error.localizedDescription)")
                    }
                }

                if let blkSourceKey,
                   let record = mirrorIndex[mirrorRecordKey(targetCalID: tgt.calendarIdentifier, sourceKey: blkSourceKey)],
                   let existing = resolveMappedEvent(for: record) {
                    await updateExisting(existing, byTime: false)
                    return
                }

                if let blkSourceKey, let existing = placeholdersBySourceKey[blkSourceKey] {
                    await updateExisting(existing, byTime: false)
                    return
                }

                if let existingByTime = placeholdersByTime[exactTimeKey] {
                    await updateExisting(existingByTime, byTime: true)
                    return
                }

                if placeholderSet.contains(exactTimeKey) {
                    skipped += 1
                    return
                }
                if !config.writeEnabled {
                    sessionGuard.insert(gKey)
                    log("+ WOULD CREATE [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)\(titleSuffix) [title: \(displayTitle)]")
                    return
                }
                guard tgt.calendarIdentifier != srcCal.calendarIdentifier else {
                    skipped += 1
                    log("- SKIP invariant: target is source [\(srcName)]")
                    return
                }
                let newEv = EKEvent(eventStore: store)
                newEv.calendar = tgt
                newEv.title = displayTitle
                newEv.startDate = blk.start
                newEv.endDate = blk.end
                newEv.isAllDay = false
                newEv.notes = notes
                newEv.url = desiredURL
                newEv.alarms = desiredAlarms(for: blk)
                newEv.availability = blk.tentative ? .tentative : .busy
                do {
                    try store.save(newEv, span: .thisEvent, commit: true)
                    created += 1
                    log("✓ CREATED [\(srcName) -> \(tgtName)] \(blk.start) -> \(blk.end)")
                    rememberMirrorEvent(newEv, for: blk)
                    occupied = coalesce(occupied + [Block.span(start: blk.start, end: blk.end)])
                    sessionGuard.insert(gKey)
                } catch {
                    log("Save failed: \(error.localizedDescription)")
                }
            }

            for b in baseBlocks {
                if Task.isCancelled { break }
                switch config.overlapMode {
                case .allow:
                    await createOrUpdateIfNeeded(b)
                case .skipCovered:
                    if fullyCovered(occupied, block: b, tolMin: SAME_TIME_TOL_MIN) {
                        log("- SKIP covered [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        await createOrUpdateIfNeeded(b)
                    }
                case .fillGaps:
                    let gaps = gapsWithin(occupied, in: b)
                    if gaps.isEmpty {
                        log("- SKIP no gaps [\(srcName) -> \(tgtName)] \(b.start) -> \(b.end)")
                        skipped += 1
                    } else {
                        for g in gaps { await createOrUpdateIfNeeded(g) }
                    }
                }
            }
            log("[Summary → \(tgtName)] created=\(created), updated=\(updated), skipped=\(skipped)")
            if config.autoDeleteMissing {
                let activeSourceKeys = Set(baseBlocks.compactMap { sourceKey(for: $0) })
                let validTimeKeys = Set(baseBlocks.map { mirrorTimeKey(start: $0.start, end: $0.end) })

                var byID: [String: EKEvent] = [:]
                for tv in placeholdersByTime.values {
                    guard tv.calendar.calendarIdentifier == tgt.calendarIdentifier else { continue }
                    if let eid = tv.eventIdentifier { byID[eid] = tv }
                }

                var removed = 0
                var skippedOtherSource = 0
                var skippedLegacyNoURL = 0
                var handledEventIDs = Set<String>()

                let staleMirrorRecords = mirrorIndex.filter {
                    $0.value.targetCalendarID == tgt.calendarIdentifier &&
                    $0.value.sourceCalendarID == srcCal.calendarIdentifier &&
                    !activeSourceKeys.contains($0.value.sourceKey)
                }

                for (recordKey, record) in staleMirrorRecords {
                    if Task.isCancelled { break }
                    let candidate = resolveMappedEvent(for: record)
                    if let candidate {
                        if !config.writeEnabled {
                            log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(candidate.startDate ?? windowStart) -> \(candidate.endDate ?? windowEnd)")
                        } else {
                            do {
                                try store.remove(candidate, span: .thisEvent, commit: true)
                                removed += 1
                            } catch {
                                log("Delete failed: \(error.localizedDescription)")
                            }
                        }
                        if let eid = candidate.eventIdentifier {
                            handledEventIDs.insert(eid)
                        }
                    }
                    if config.writeEnabled || candidate == nil {
                        if mirrorIndex.removeValue(forKey: recordKey) != nil {
                            mirrorIndexChanged = true
                        }
                    }
                }

                for ev in byID.values {
                    if Task.isCancelled { break }
                    if let eid = ev.eventIdentifier, handledEventIDs.contains(eid) {
                        continue
                    }
                    let parsed = parseMirrorURL(ev.url)
                    var shouldDelete = false
                    var parsedSourceKey: String? = nil
                    if let sourceCalID = parsed.sourceCalID, !sourceCalID.isEmpty {
                        if sourceCalID != srcCal.calendarIdentifier {
                            skippedOtherSource += 1
                            continue
                        }
                        if let sourceStableID = parsed.sourceStableID, !sourceStableID.isEmpty {
                            let key = sourceOccurrenceKey(sourceCalID: sourceCalID, sourceStableID: sourceStableID, occurrence: parsed.occ)
                            parsedSourceKey = key
                            if !activeSourceKeys.contains(key) { shouldDelete = true }
                        } else if trackByID,
                                  let s = ev.startDate,
                                  let e = ev.endDate,
                                  !validTimeKeys.contains(mirrorTimeKey(start: s, end: e)) {
                            shouldDelete = true
                        }
                    } else if trackByID && !isMultiRouteRun {
                        if let s = ev.startDate,
                           let e = ev.endDate,
                           !validTimeKeys.contains(mirrorTimeKey(start: s, end: e)) {
                            shouldDelete = true
                        }
                    } else if trackByID && isMultiRouteRun {
                        let hasMapping = mirrorIndex.values.contains {
                            $0.targetCalendarID == tgt.calendarIdentifier &&
                            $0.sourceCalendarID == srcCal.calendarIdentifier &&
                            $0.targetEventIdentifier == ev.eventIdentifier
                        }
                        if !hasMapping {
                            skippedLegacyNoURL += 1
                        }
                        continue
                    }
                    if shouldDelete {
                        if !config.writeEnabled {
                            log("~ WOULD DELETE (missing source) [\(srcName) -> \(tgtName)] \(ev.startDate ?? windowStart) -> \(ev.endDate ?? windowEnd)")
                        } else {
                            do {
                                try store.remove(ev, span: .thisEvent, commit: true)
                                removed += 1
                            } catch {
                                log("Delete failed: \(error.localizedDescription)")
                            }
                        }
                        if let key = parsedSourceKey {
                            removeMirrorRecord(for: key)
                        }
                    }
                }
                if removed > 0 { log("[Cleanup missing for \(tgtName)] deleted=\(removed)") }
                if skippedOtherSource > 0 {
                    log("- INFO cleanup skipped \(skippedOtherSource) placeholders from other source routes on \(tgtName)")
                }
                if skippedLegacyNoURL > 0 {
                    log("- INFO cleanup skipped \(skippedLegacyNoURL) unmanaged legacy placeholders without source metadata on \(tgtName)")
                }
            }
        }
        if mirrorIndexChanged {
            saveMirrorIndex(mirrorIndex)
        }
    }

    func runCleanup(
        store: EKEventStore,
        daysBack: Int,
        daysForward: Int,
        sourceCalendar: EKCalendar,
        targetCalendars: [EKCalendar],
        titlePrefix: String,
        placeholderTitle: String,
        writeEnabled: Bool
    ) async {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -daysBack, to: todayStart)!
        let windowEnd = cal.date(byAdding: .day, value: daysForward, to: todayStart)!
        log("=== Cleanup Busy placeholders in window ===")
        log("(Cleanup is SAFE: mirrored events detected by url prefix or title prefix ‘\(titlePrefix)’)")
        log("Window: \(windowStart) -> \(windowEnd)")

        for tgt in targetCalendars {
            let tgtPred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [tgt])
            let tgtEvents = store.events(matching: tgtPred)
            var delCount = 0
            for ev in tgtEvents {
                guard isMirrorEvent(ev, prefix: titlePrefix, placeholder: placeholderTitle) else { continue }
                if !writeEnabled {
                    log("~ WOULD DELETE [\(tgt.title)] \(ev.startDate ?? todayStart) -> \(ev.endDate ?? todayStart)")
                } else {
                    do {
                        try store.remove(ev, span: .thisEvent, commit: true)
                        delCount += 1
                    } catch {
                        log("Delete failed: \(error.localizedDescription)")
                    }
                }
            }
            log("[Cleanup \(tgt.title)] deleted=\(delCount)")
        }
    }
}
