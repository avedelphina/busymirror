import AppKit

// macOS only. Update checking is a plain GitHub Releases lookup — no Sparkle, no auto-install:
// it only tells you a newer version exists and opens its release page. (iOS updates via TestFlight.)

struct UpdateInfo: Equatable {
    let version: String
    let url: URL
}

/// Numeric, component-wise version compare ("v1.12.0" vs "1.11.0"); missing components count as 0.
func isNewerVersion(_ remote: String, than local: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
    }
    let r = parts(remote), l = parts(local)
    for i in 0..<max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0
        let b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
}

private let latestReleaseAPI = URL(string: "https://api.github.com/repos/avedelphina/busymirror/releases/latest")!
private let checkInterval: TimeInterval = 24 * 60 * 60

extension BusyMirrorAppController {
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Launch-time check: skipped if the user turned it off or it already ran in the last day.
    func checkForUpdatesIfDue() async {
        guard UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool ?? true else { return }
        if let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date,
           Date().timeIntervalSince(last) < checkInterval { return }
        await refreshAvailableUpdate()
    }

    /// Latest published release (GitHub's "latest" skips drafts and pre-releases), or nil if the
    /// request failed. Only opens/keeps a github.com https link, whatever the response says.
    private func fetchLatestRelease() async -> UpdateInfo? {
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.html_url.scheme == "https", release.html_url.host == "github.com" else { return nil }
        return UpdateInfo(version: release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), url: release.html_url)
    }

    /// Returns false if GitHub couldn't be reached (a failed check isn't recorded, so it retries next launch).
    @discardableResult
    func refreshAvailableUpdate() async -> Bool {
        guard let latest = await fetchLatestRelease() else { return false }
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        availableUpdate = isNewerVersion(latest.version, than: currentVersion) ? latest : nil
        return true
    }

    /// "Check for Updates…" — always answers with an alert, unlike the silent launch-time check.
    func checkForUpdatesInteractively() async {
        let reached = await refreshAvailableUpdate()
        let alert = NSAlert()
        if !reached {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Check your internet connection and try again."
        } else if let update = availableUpdate {
            alert.messageText = "BusyMirror \(update.version) is available"
            alert.informativeText = "You have \(currentVersion)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText = "BusyMirror \(currentVersion) is the latest version."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let update = availableUpdate {
            NSWorkspace.shared.open(update.url)
        }
    }
}
