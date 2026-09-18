import Foundation

enum AppLogStore {
    private static let queue = DispatchQueue(label: "BusyMirror.log.store")
    private static let maxLogSizeBytes: UInt64 = 1_000_000

    static let logDirectoryURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/BusyMirror", isDirectory: true)
    }()

    static let logFileURL = logDirectoryURL.appendingPathComponent("BusyMirror.log", isDirectory: false)
    private static let archivedLogFileURL = logDirectoryURL.appendingPathComponent("BusyMirror.previous.log", isDirectory: false)
    static let launchdStdoutURL = logDirectoryURL.appendingPathComponent("launchd.stdout.log", isDirectory: false)
    static let launchdStderrURL = logDirectoryURL.appendingPathComponent("launchd.stderr.log", isDirectory: false)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func append(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        queue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
                if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
                   let size = attrs[.size] as? NSNumber,
                   size.uint64Value >= maxLogSizeBytes {
                    try? fm.removeItem(at: archivedLogFileURL)
                    try? fm.moveItem(at: logFileURL, to: archivedLogFileURL)
                }
                if !fm.fileExists(atPath: logFileURL.path) {
                    fm.createFile(atPath: logFileURL.path, contents: nil)
                }
                guard let data = line.data(using: .utf8) else { return }
                // Use the throwing initialiser so we don't silently swallow
                // an inaccessible file — the outer catch handles it.
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never break the app's main behavior.
            }
        }
    }
}
