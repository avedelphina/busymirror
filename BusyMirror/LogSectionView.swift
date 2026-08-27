import SwiftUI

/// Activity log viewer — extracted from ContentView. Renders `logText`
/// (plain newline-separated lines, no timestamps — those only exist in the
/// persistent file log written by AppLogStore) as readable rows with a
/// status icon per line instead of a raw monospaced dump, plus a search
/// filter. "Clear" only empties this in-memory view; the file log on disk
/// (Reveal Log File, in the toolbar's overflow menu) is untouched.
struct LogSectionView: View {
    @Binding var logText: String
    @State private var searchText = ""

    private enum LineKind {
        case ok, error, warning, info

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .ok: return .green
            case .error: return .red
            case .warning: return .orange
            case .info: return .secondary
            }
        }
    }

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let kind: LineKind
    }

    private var lines: [Line] {
        logText.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { idx, raw in
                let text = String(raw)
                let kind: LineKind
                if text.hasPrefix("✓") { kind = .ok }
                else if text.hasPrefix("✗") { kind = .error }
                else if text.contains("SKIP") || text.contains("WARN") { kind = .warning }
                else { kind = .info }
                return Line(id: idx, text: text, kind: kind)
            }
            .filter { !$0.text.isEmpty }
            .filter { searchText.isEmpty || $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Activity Log")
                    .font(.title2.weight(.bold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search log", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 180)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                Button("Clear") { logText = "" }
                    .buttonStyle(.bordered)
                    .disabled(logText.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: line.kind.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(line.kind.color)
                                .padding(.top, 3)
                            Text(line.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22))
            )
        }
        .padding(20)
    }
}
