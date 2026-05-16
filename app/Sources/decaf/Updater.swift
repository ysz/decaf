import Foundation

/// Lightweight update notifier. Polls the GitHub Releases API for the
/// `ysz/decaf` repo, compares the latest tag against the bundled
/// `CFBundleShortVersionString`, and publishes a `ReleaseInfo` when there's
/// a newer release. The menubar shows "Update vX.Y.Z →" — clicking opens the
/// release page; the user runs `git pull && make install` (or grabs the
/// artifact). We do NOT auto-download or auto-install: the app is ad-hoc
/// signed and shipped via `make install`, so any "press button to update"
/// flow would need Sparkle + a notarized release pipeline. Out of scope.
///
/// Polling cadence: one check on launch (after a small delay so we don't
/// race with menubar startup), then once a day while the app runs. GitHub
/// allows 60 unauthenticated requests/hour per IP, so this is nowhere near
/// the limit even with multiple Decaf installs on the same network.
@MainActor
final class Updater: ObservableObject {
    struct ReleaseInfo: Equatable {
        let tag: String           // "v1.5.0" or "1.5.0" — as published
        let displayVersion: String // normalized for UI: "1.5.0"
        let url: URL              // html_url, the GitHub release page
    }

    @Published private(set) var available: ReleaseInfo?

    /// Pinned at struct level — releases are published against this slug, so
    /// repo renames need a code change anyway. Trailing slash matters: the
    /// URL is built by concatenating "releases/latest".
    private let apiBase = "https://api.github.com/repos/ysz/decaf"

    /// `Bundle.main` is the running .app, so this reflects the build the
    /// user is actually using — not whatever VERSION the bash script claims.
    private let currentVersion: String

    private var timer: Timer?
    private static let checkInterval: TimeInterval = 24 * 60 * 60   // 24h

    init() {
        self.currentVersion =
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Call once from the app entry point. Schedules an initial check ~10s
    /// after launch (off the critical UI path) and a recurring timer after.
    func start() {
        // Already running — don't double-schedule on a hot reload / re-init.
        guard timer == nil else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.checkOnce()
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkOnce() }
        }
    }

    /// One-shot check — also called by the user via "Check for updates…".
    /// Silently swallows network and parse errors: an updater that surfaces
    /// transient network failures in the menubar would be noisier than the
    /// signal it provides.
    func checkOnce() async {
        guard let url = URL(string: "\(apiBase)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API requires a User-Agent on every request. They reject
        // requests without it with 403.
        req.setValue("Decaf-Updater/1 (+https://github.com/ysz/decaf)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return
        }
        // 404 means the repo exists but has zero releases yet — treat as "no
        // update", not an error.
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return
        }

        guard let release = parseRelease(data) else { return }

        if isNewer(release.displayVersion, than: currentVersion) {
            self.available = release
        } else {
            self.available = nil
        }
    }

    /// Open the release page in the default browser. Used by the menu item.
    /// Shells out to /usr/bin/open instead of NSWorkspace.shared.open so the
    /// Updater itself stays free of AppKit — keeps the file UI-agnostic.
    func openRelease() {
        guard let release = available else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [release.url.absoluteString]
        try? p.run()
    }

    // MARK: - parsing

    private func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let urlString = json["html_url"] as? String,
            let url = URL(string: urlString)
        else { return nil }
        let display = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(tag: tag, displayVersion: display, url: url)
    }

    /// Component-wise integer compare. Tolerates "1.5", "1.5.0", "1.5.0.1".
    /// Anything non-numeric (e.g. "1.5.0-beta") is dropped from that
    /// component, which means we treat "1.5.0-beta" == "1.5.0" — good enough
    /// for "should we ping the user"; the user sees the exact tag in the UI
    /// and decides.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { intPrefix(String($0)) }
        let b = current.split(separator: ".").map { intPrefix(String($0)) }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    private func intPrefix(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if let d = ch.wholeNumberValue, ch.isASCII { n = n * 10 + d } else { break }
        }
        return n
    }
}
