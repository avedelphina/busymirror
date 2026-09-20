import SwiftUI
import EventKit

// What a route would change right now, change by change — the readable answer to scrolling
// dry-run log lines. Shared by both apps. Opens immediately with a spinner and fills in
// when `load` finishes.
struct PlannedChangesSheet: View {
    let calendars: [EKCalendar]
    let load: () async -> [PlannedChange]

    @Environment(\.dismiss) private var dismiss
    @State private var changes: [PlannedChange]?

    var body: some View {
        NavigationStack {
            Group {
                if let changes {
                    if changes.isEmpty {
                        ContentUnavailableView(
                            "Nothing to change",
                            systemImage: "checkmark.circle",
                            description: Text("The target calendars are already up to date.")
                        )
                    } else {
                        changeList(changes)
                    }
                } else {
                    ProgressView("Checking calendars…")
                }
            }
            .navigationTitle("Preview")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { changes = await load() }
        }
        #if os(macOS)
        // A macOS sheet has no intrinsic size; without this it collapses to a sliver.
        .frame(minWidth: 520, idealWidth: 580, minHeight: 440, idealHeight: 600)
        #endif
    }

    private func changeList(_ changes: [PlannedChange]) -> some View {
        List {
            Section {
                Text(plannedChangeSummary(changes)).font(.headline)
            } footer: {
                Text("This is what would change right now. Nothing has been written.")
            }
            ForEach(groupPlannedChanges(changes)) { target in
                Section {
                    ForEach(target.days) { day in
                        Text(dayLabel(day.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(day.changes) { change in
                            PlannedChangeRow(change: change)
                        }
                    }
                } header: {
                    targetHeader(target).textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func targetHeader(_ group: PlannedTargetGroup) -> some View {
        if let cal = calendars.first(where: { $0.calendarIdentifier == group.targetCalendarID }) {
            calChip(cal)
        } else {
            Text(group.targetName)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct PlannedChangeRow: View {
    let change: PlannedChange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
                .accessibilityLabel(kindName)
            VStack(alignment: .leading, spacing: 3) {
                titleLines
                timeLine
                ForEach(change.extraNotes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var kindName: String {
        switch change.kind {
        case .create: return "Create"
        case .update: return "Update"
        case .delete: return "Delete"
        }
    }

    private var symbol: String {
        switch change.kind {
        case .create: return "plus.circle.fill"
        case .update: return "pencil.circle.fill"
        case .delete: return "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .create: return .green
        case .update: return .orange
        case .delete: return .red
        }
    }

    // Old → new, verbatim: a changed title shows the old one struck through above the new one.
    @ViewBuilder
    private var titleLines: some View {
        switch change.kind {
        case .create:
            Text(display(change.newTitle))
        case .delete:
            Text(display(change.oldTitle)).strikethrough().foregroundStyle(.secondary)
        case .update:
            if change.reasons.contains(.title) {
                Text(display(change.oldTitle)).strikethrough().foregroundStyle(.secondary)
            }
            Text(display(change.newTitle))
        }
    }

    @ViewBuilder
    private var timeLine: some View {
        switch change.kind {
        case .create:
            Text(range(change.newStart, change.newEnd, withDate: false)).font(.subheadline).foregroundStyle(.secondary)
        case .delete:
            Text(range(change.oldStart, change.oldEnd, withDate: false)).font(.subheadline).foregroundStyle(.secondary)
        case .update:
            if change.reasons.contains(.time) {
                let cal = Calendar.current
                let movedDay: Bool = {
                    guard let old = change.oldStart, let new = change.newStart else { return false }
                    return !cal.isDate(old, inSameDayAs: new)
                }()
                Text("\(range(change.oldStart, change.oldEnd, withDate: movedDay)) → \(range(change.newStart, change.newEnd, withDate: movedDay))")
                    .font(.subheadline)
            } else {
                Text(range(change.newStart, change.newEnd, withDate: false)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // The invisible chain marker isn't worth rendering (and an untitled event needs a label).
    private func display(_ title: String?) -> String {
        let text = (title ?? "").replacingOccurrences(of: mirrorTitleMarker, with: "")
        return text.isEmpty ? "(no title)" : text
    }

    private func range(_ start: Date?, _ end: Date?, withDate: Bool) -> String {
        guard let start, let end else { return "—" }
        let cal = Calendar.current
        if end > start, cal.startOfDay(for: start) == start, cal.startOfDay(for: end) == end {
            let days = cal.dateComponents([.day], from: start, to: end).day ?? 1
            let label = days <= 1 ? "All day" : "\(days) days"
            return withDate ? "\(start.formatted(date: .abbreviated, time: .omitted)), \(label)" : label
        }
        let startStyle: Date.FormatStyle = withDate ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()
        let endStyle: Date.FormatStyle = cal.isDate(start, inSameDayAs: end) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
        return "\(start.formatted(startStyle)) – \(end.formatted(endStyle))"
    }
}
