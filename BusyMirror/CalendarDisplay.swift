import SwiftUI
import EventKit

// Small calendar display helpers shared by ContentView, RoutesSectionView,
// and CalendarsSectionView.

func calColor(_ cal: EKCalendar) -> Color {
    #if os(macOS)
    return Color(cal.cgColor ?? NSColor.systemGray.cgColor)
    #else
    return Color(cgColor: cal.cgColor ?? UIColor.systemGray.cgColor)
    #endif
}

@ViewBuilder
func calChip(_ cal: EKCalendar) -> some View {
    HStack(spacing: 6) {
        Circle().fill(calColor(cal)).frame(width: 10, height: 10)
        Text(calLabel(cal))
    }
}

// A small "has mirrors" tag next to a calendar that already contains mirrored events (see
// mirroredCalendarIDs) — worth knowing when picking a source, since it's likely a target of
// another route or device. Deliberately neutral text rather than a warning icon: a triangle
// read as "something is wrong with this calendar", which it isn't.
@ViewBuilder
func mirrorBadge(for cal: EKCalendar, in calendarsWithMirrors: Set<String>) -> some View {
    if calendarsWithMirrors.contains(cal.calendarIdentifier) {
        Text("has mirrors")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .help("This calendar already contains events mirrored by BusyMirror — from another route or device.")
    }
}
