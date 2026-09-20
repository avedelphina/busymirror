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

// ⚠️ next to a calendar that already contains mirrored events (see mirroredCalendarIDs) —
// worth knowing when picking a source, since it's likely a target from another route or device.
@ViewBuilder
func mirrorBadge(for cal: EKCalendar, in calendarsWithMirrors: Set<String>) -> some View {
    if calendarsWithMirrors.contains(cal.calendarIdentifier) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("This calendar already contains mirrored placeholder events")
    }
}
