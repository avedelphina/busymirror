import SwiftUI

/// Manual/fixed-time `launchd` scheduling — extracted from ContentView. Since
/// 1.7.0 this is a fallback/override; the primary reliability mechanism is
/// the event-driven auto-sync in `BusyMirrorAppController`, which arms itself
/// automatically once routes exist and needs no UI.
struct ScheduleSectionView: View {
    @Binding var scheduleMode: ScheduleMode
    @Binding var scheduleIntervalHours: Int
    @Binding var scheduleHour: Int
    @Binding var scheduleMinute: Int
    let isRunning: Bool
    let routesEmpty: Bool
    let hasInstalledSchedule: Bool
    let scheduleSummary: String
    let onInstall: () -> Void
    let onRemove: () -> Void
    let onRevealLaunchAgent: () -> Void
    let onScheduleTimeChanged: () -> Void

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private static let hourFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 0
        f.maximum = 24
        f.maximumFractionDigits = 0
        return f
    }()

    private static let smallIntFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 1
        f.maximumFractionDigits = 0
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduled runs (manual override)")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Picker("Mode", selection: $scheduleMode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)
                Spacer(minLength: 0)
            }
            if scheduleMode == .hourly {
                HStack(spacing: 8) {
                    Text("Every")
                    TextField("1", value: $scheduleIntervalHours, formatter: Self.smallIntFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(isRunning)
                    Text(scheduleIntervalHours == 1 ? "hour" : "hours")
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Time")
                    TextField("8", value: $scheduleHour, formatter: Self.hourFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(isRunning)
                    Text(":")
                    TextField("0", value: $scheduleMinute, formatter: Self.intFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(isRunning)
                    Spacer(minLength: 0)
                }
            }
            Text("Creates a LaunchAgent that runs the installed app with saved routes in write mode.")
                .foregroundStyle(.secondary)
                .font(.footnote)
            Text(hasInstalledSchedule ? "Installed: \(scheduleSummary)" : "Not installed")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Install Schedule", action: onInstall)
                    .disabled(isRunning || routesEmpty)
                Button("Remove Schedule", action: onRemove)
                    .disabled(isRunning || !hasInstalledSchedule)
                Button("Reveal LaunchAgent", action: onRevealLaunchAgent)
                    .disabled(!hasInstalledSchedule)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: scheduleHour) { _ in onScheduleTimeChanged() }
        .onChange(of: scheduleMinute) { _ in onScheduleTimeChanged() }
        .onChange(of: scheduleIntervalHours) { _ in onScheduleTimeChanged() }
    }
}
