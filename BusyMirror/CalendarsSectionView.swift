import SwiftUI
import EventKit

/// The manual source/target calendar picker — extracted from ContentView.
/// Bindings mutate ContentView's own @State directly.
struct CalendarsSectionView: View {
    let calendars: [EKCalendar]
    @Binding var sourceIndex: Int
    @Binding var targetSelections: Set<Int>
    @Binding var targetIDs: Set<String>
    let isRunning: Bool
    let calendarsWithMirrors: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source calendar")
                .font(.subheadline.weight(.semibold))
            Picker("Source", selection: $sourceIndex) {
                ForEach(Array(calendars.indices), id: \.self) { i in
                    // A menu picker can only show text, so the "has mirrors" tag is spelled out here.
                    Text("\(i + 1): \(calLabel(calendars[i]))\(calendarsWithMirrors.contains(calendars[i].calendarIdentifier) ? " (has mirrors)" : "")").tag(i)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isRunning || calendars.isEmpty)

            Divider()

            HStack {
                Text("Target calendars")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(targetIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(calendars.indices), id: \.self) { i in
                        let isSource = (i == sourceIndex)
                        let binding = Binding<Bool>(
                            get: { !isSource && targetSelections.contains(i) },
                            set: { newValue in
                                // Never allow selecting the source as a target
                                if isSource { return }
                                if newValue {
                                    targetSelections.insert(i)
                                    targetIDs.insert(calendars[i].calendarIdentifier)
                                } else {
                                    targetSelections.remove(i)
                                    targetIDs.remove(calendars[i].calendarIdentifier)
                                }
                            }
                        )
                        Toggle(isOn: binding) {
                            HStack(spacing: 8) {
                                Text("\(i + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                calChip(calendars[i])
                                mirrorBadge(for: calendars[i], in: calendarsWithMirrors)
                            }
                            .padding(.vertical, 3)
                        }
                        .toggleStyle(.switch)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                        )
                        .disabled(isRunning || isSource)
                        .opacity(isSource ? 0.5 : 1)
                    }
                }
            }
            .frame(minHeight: 170, maxHeight: 260)
        }
    }
}
