import SwiftUI
import EventKit

/// The "Routes (multi-source)" panel — extracted from ContentView so the
/// route list/editor is its own small, native-feeling view instead of one
/// piece of a 2000-line file. Owns no persisted state itself: `routes` is a
/// binding into ContentView's own @State (which still owns saving it to
/// UserDefaults), and everything else here is read-only context passed down.
struct RoutesSectionView: View {
    @Binding var routes: [Route]
    let calendars: [EKCalendar]
    let isRunning: Bool
    let titlePrefix: String
    let placeholderTitle: String
    let canAddRoute: Bool
    let calendarsWithMirrors: Set<String>
    let onAddRoute: () -> Void
    let onPreview: (Route) -> Void
    let onPreviewAll: () -> Void

    @State private var expandedRouteID: UUID?

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private func labelForCalendar(id: String) -> String {
        calendars.first(where: { $0.calendarIdentifier == id }).map(calLabel) ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Routes (multi-source)")
                    .font(.headline)
                Spacer()
                Button("Add from current selection", action: onAddRoute)
                    .disabled(isRunning || !canAddRoute)
                    .buttonStyle(.borderedProminent)
                Button {
                    onPreviewAll()
                } label: {
                    Label("Preview all", systemImage: "eye")
                }
                .disabled(isRunning || routes.isEmpty)
                .buttonStyle(.bordered)
                .help("List exactly what Sync Now would create, update or delete across all routes. Nothing is written.")
                Button("Clear") { routes.removeAll() }
                    .disabled(isRunning || routes.isEmpty)
                    .buttonStyle(.bordered)
            }
            if routes.isEmpty {
                Text("No routes yet. Pick a Source and Targets above, then click ‘Add from current selection’.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach($routes, id: \.id) { routeBinding in
                        routeCard(for: routeBinding)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routeCard(for routeBinding: Binding<Route>) -> some View {
        let route = routeBinding.wrappedValue
        let isExpanded = expandedRouteID == route.id
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expandedRouteID = isExpanded ? nil : route.id
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        sourceSummaryView(for: route)
                        targetSummaryView(for: route)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                Toggle("Private", isOn: routeBinding.privacy)
                    .help("If ON, mirror as ‘\(route.titlePrefix ?? titlePrefix)\(placeholderTitle)’ with no notes. If OFF, mirror source title (and optionally notes).")
                Toggle("Copy description", isOn: routeBinding.copyNotes)
                    .disabled(isRunning || route.privacy)
                    .help("If ON and Private is OFF, copy the source event’s notes/description into the placeholder.")
                Toggle("Sync reminders", isOn: routeBinding.syncReminders)
                    .disabled(isRunning)
                    .help("If ON, copy the source event’s reminders/alarms into the placeholder.")
                Toggle("Mirror all-day events for this route", isOn: routeBinding.allDay)
                    .disabled(isRunning)
                    .help("Mirror all-day events for this source.")

                RoutePrefixEditor(titlePrefix: routeBinding.titlePrefix, globalPrefix: titlePrefix)
                    .disabled(isRunning)

                Toggle("Mirror already-mirrored events", isOn: routeBinding.mirrorMirroredEvents)
                    .disabled(isRunning)
                    .help("Off (default): source events that are themselves mirrors (from any route, any device) are skipped, preventing re-mirroring. Turn on only for a deliberate chain (A → B → C) — enabling it on a route that loops back to its own target duplicates events on every run.")
                if route.mirrorMirroredEvents {
                    Toggle("Copy chained titles as-is", isOn: routeBinding.passThroughMirroredTitles)
                        .disabled(isRunning)
                        .padding(.leading, 18)
                        .help("Avoids this route's prefix stacking onto an upstream one (e.g. “B: A: Meeting”). With Private off, the upstream title is kept verbatim; with Private on, this route's own placeholder is used but the upstream prefix is preserved (e.g. “WORK1: Busy”). Private always wins over the upstream title.")
                }

                HStack(spacing: 16) {
                    mergeGapField(for: routeBinding)
                    overlapPicker(for: routeBinding)
                    Spacer(minLength: 0)
                    Button {
                        onPreview(route)
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(isRunning)
                    .help("List exactly what Sync Now would create, update or delete for this route. Nothing is written.")
                    Button(role: .destructive) {
                        routes.removeAll { $0.id == route.id }
                    } label: { Text("Remove Route") }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.25), lineWidth: 1.1)
        )
    }

    @ViewBuilder
    private func sourceSummaryView(for route: Route) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sCal = calendars.first(where: { $0.calendarIdentifier == route.sourceID }) {
                HStack(spacing: 6) {
                    Circle().fill(calColor(sCal)).frame(width: 10, height: 10)
                    Text(calLabel(sCal))
                        .fontWeight(.semibold)
                    mirrorBadge(for: sCal, in: calendarsWithMirrors)
                }
            } else {
                Text(labelForCalendar(id: route.sourceID))
                    .fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private func targetSummaryView(for route: Route) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Targets")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(route.targetIDs.sorted(by: <), id: \.self) { tid in
                        if let tCal = calendars.first(where: { $0.calendarIdentifier == tid }) {
                            HStack(spacing: 6) {
                                Circle().fill(calColor(tCal)).frame(width: 9, height: 9)
                                Text(calLabel(tCal))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 999, style: .continuous)
                                    .fill(Color.primary.opacity(0.1))
                            )
                        } else {
                            Text(labelForCalendar(id: tid))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                                        .fill(Color.primary.opacity(0.1))
                                )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mergeGapField(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 8) {
            Text("Merge gap")
            TextField("0", value: routeBinding.mergeGapHours, formatter: Self.intFormatter)
                .frame(width: 56)
                .disabled(isRunning)
                .help("Merge adjacent source events separated by ≤ this many hours (e.g., flight legs). 0 = no merge.")
            Text("h").foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func overlapPicker(for routeBinding: Binding<Route>) -> some View {
        HStack(spacing: 8) {
            Text("Overlap")
            Picker("Overlap", selection: routeBinding.overlap) {
                ForEach(OverlapMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 170)
            .help("allow = always place; skipCovered = skip if target already has a block covering the time; fillGaps = only fill uncovered gaps within the source block.")
        }
        .font(.subheadline)
    }
}

/// Global / Custom / None for a route's prefix (Route.titlePrefix: nil / non-empty / "").
/// Keeps the picked mode and custom text as local state — a bare String? can't tell "Custom,
/// still typing" from "None" — and writes the resolved value back on every change.
private struct RoutePrefixEditor: View {
    @Binding var titlePrefix: String?
    let globalPrefix: String

    @State private var mode: PrefixMode
    @State private var customText: String

    init(titlePrefix: Binding<String?>, globalPrefix: String) {
        _titlePrefix = titlePrefix
        self.globalPrefix = globalPrefix
        let parsed = PrefixMode.from(titlePrefix.wrappedValue)
        _mode = State(initialValue: parsed.mode)
        _customText = State(initialValue: parsed.customText)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Prefix")
            Picker("Prefix", selection: $mode) {
                ForEach(PrefixMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            if mode == .custom {
                TextField("e.g. WORK: ", text: $customText)
                    .frame(width: 140)
            }
            if mode == .global {
                Text("(\(globalPrefix))").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .onChange(of: mode) { _, _ in titlePrefix = mode.resolve(customText: customText) }
        .onChange(of: customText) { _, _ in titlePrefix = mode.resolve(customText: customText) }
        .help("Global: use the mirror prefix from Preferences. Custom: a prefix just for this route. None: no prefix at all.")
    }
}
