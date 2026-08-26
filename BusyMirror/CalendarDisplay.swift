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
