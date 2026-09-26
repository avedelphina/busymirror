import SwiftUI

/// Real macOS Settings (⌘,) window. Holds only the pure, globally-persisted
/// defaults (all @AppStorage, shared automatically with ContentView's copies
/// of the same keys) — anything tied to live session state (routes, the
/// dry-run toggle, calendar access) stays in the main window since it has no
/// meaning outside that window's lifecycle.
struct PreferencesView: View {
    @EnvironmentObject private var appController: BusyMirrorAppController

    @AppStorage("daysForward") private var daysForward: Int = defaultSyncDaysForward
    @AppStorage("daysBack") private var daysBack: Int = defaultSyncDaysBack
    @AppStorage("mergeGapHours") private var mergeGapHours: Int = 0

    @AppStorage("hideDetails") private var hideDetails: Bool = true
    @AppStorage("copyDescription") private var copyDescription: Bool = false
    @AppStorage("syncReminders") private var syncReminders: Bool = false
    @AppStorage("mirrorAllDay") private var mirrorAllDay: Bool = false
    @AppStorage("overlapMode") private var overlapModeRaw: String = OverlapMode.allow.rawValue
    @AppStorage("filterByWorkHours") private var filterByWorkHours: Bool = false
    @AppStorage("workHoursStart") private var workHoursStart: Int = 9
    @AppStorage("workHoursEnd") private var workHoursEnd: Int = 17
    @AppStorage("mirrorAcceptedOnly") private var mirrorAcceptedOnly: Bool = false
    @AppStorage("excludedTitleFilters") private var excludedTitleFiltersRaw: String = ""
    @AppStorage("excludedOrganizerFilters") private var excludedOrganizerFiltersRaw: String = ""
    @AppStorage("titlePrefix") private var titlePrefix: String = "🪞 "
    @AppStorage("placeholderTitle") private var placeholderTitle: String = "Busy"
    @AppStorage("autoDeleteMissing") private var autoDeleteMissing: Bool = true
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates: Bool = true

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

    private var disabled: Bool { appController.isSyncing }

    private func clampWorkHours() {
        let clampedStart = min(max(workHoursStart, 0), 23)
        if clampedStart != workHoursStart { workHoursStart = clampedStart }
        let clampedEnd = min(max(workHoursEnd, 1), 24)
        if clampedEnd != workHoursEnd { workHoursEnd = clampedEnd }
        if workHoursEnd <= workHoursStart {
            let adjustedEnd = min(workHoursStart + 1, 24)
            if workHoursEnd != adjustedEnd { workHoursEnd = adjustedEnd }
        }
    }

    var body: some View {
        Form {
            Section("Default time window") {
                HStack {
                    Text("Days back")
                    TextField("\(defaultSyncDaysBack)", value: $daysBack, formatter: Self.intFormatter)
                        .frame(width: 64)
                }
                .disabled(disabled)
                HStack {
                    Text("Days forward")
                    TextField("\(defaultSyncDaysForward)", value: $daysForward, formatter: Self.intFormatter)
                        .frame(width: 64)
                }
                .disabled(disabled)
                HStack {
                    Text("Default merge gap (hours)")
                    TextField("0", value: $mergeGapHours, formatter: Self.intFormatter)
                        .frame(width: 64)
                }
                .disabled(disabled)
            }
            .onChange(of: daysBack) { v in daysBack = max(0, v) }
            .onChange(of: daysForward) { v in daysForward = max(0, v) }
            .onChange(of: mergeGapHours) { v in mergeGapHours = max(0, v) }

            Section("Mirroring defaults") {
                Toggle("Hide details (use \"Busy\" title)", isOn: $hideDetails)
                Toggle("Copy description when mirroring", isOn: $copyDescription)
                    .disabled(hideDetails)
                Toggle("Sync reminders when mirroring", isOn: $syncReminders)
                Toggle("Mirror all-day events", isOn: $mirrorAllDay)
                Toggle("Mirror accepted events only", isOn: $mirrorAcceptedOnly)
                Toggle("Auto-delete mirrors if source is removed", isOn: $autoDeleteMissing)

                Picker("Overlap mode", selection: $overlapModeRaw) {
                    ForEach(OverlapMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
            }
            .disabled(disabled)

            Section("Placeholder title") {
                HStack {
                    Text("Title prefix")
                    TextField("🪞 ", text: $titlePrefix)
                        .frame(width: 90)
                }
                HStack {
                    Text("Placeholder title")
                    TextField("Busy", text: $placeholderTitle)
                        .frame(width: 170)
                }
            }
            .disabled(disabled)

            Section("Work hours") {
                Toggle("Limit mirroring to work hours", isOn: $filterByWorkHours)
                if filterByWorkHours {
                    HStack {
                        Text("Start hour")
                        TextField("9", value: $workHoursStart, formatter: Self.hourFormatter)
                            .frame(width: 56)
                        Text("End hour")
                        TextField("17", value: $workHoursEnd, formatter: Self.hourFormatter)
                            .frame(width: 56)
                        Text("(local time, end exclusive)").foregroundStyle(.secondary)
                    }
                    .onChange(of: workHoursStart) { _ in clampWorkHours() }
                    .onChange(of: workHoursEnd) { _ in clampWorkHours() }
                }
            }
            .disabled(disabled)

            Section("Skip filters") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skip source titles (one per line)")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $excludedTitleFiltersRaw)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22))
                        )
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skip organizers (name or email, one per line)")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $excludedOrganizerFiltersRaw)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22))
                        )
                }
                Text("Matches are case-insensitive and apply before mirroring.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .disabled(disabled)

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheckForUpdates)
                HStack {
                    Button("Check Now") { Task { await appController.checkForUpdatesInteractively() } }
                    if let update = appController.availableUpdate {
                        Text("Version \(update.version) is available.").foregroundStyle(.secondary)
                    } else {
                        Text("Version \(appController.currentVersion)").foregroundStyle(.secondary)
                    }
                }
                Text("Asks GitHub for the latest release at launch, at most once a day. Nothing about you or your calendars is sent.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}
