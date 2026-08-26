import SwiftUI

/// Read-only activity log viewer — extracted from ContentView.
struct LogSectionView: View {
    let logText: String

    var body: some View {
        TextEditor(text: Binding(get: { logText }, set: { _ in }))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22))
            )
    }
}
