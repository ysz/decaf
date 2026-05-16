import Foundation
import AppKit
import Combine

enum AgentState: Equatable {
    case stopped
    case listening
    case error(String)
}

@MainActor
final class Controller: ObservableObject {
    @Published private(set) var state: AgentState = .stopped
    @Published private(set) var binaryPath: String?
    @Published private(set) var hooksInstalled: Bool = false
    @Published private(set) var telegramConfigured: Bool = false
    @Published private(set) var loginItemEnabled: Bool = false
    @Published private(set) var sleepWhenDone: Bool = true
    @Published private(set) var sleepDelayMinutes: Int = 0
    /// Mirrors `sudoersRuleInstalled()`. Drives the "First Start asks for admin
    /// password" caption visibility — once true (after first successful sudoers
    /// install), the caption never reappears unless the rule is removed.
    @Published private(set) var sudoersInstalled: Bool = false
    /// True while a start/stop osascript call is in flight or we're waiting for
    /// the resulting state transition to be visible in /tmp/decaf.pid. Drives
    /// the menubar's Start/Stop button → disabled + spinner during the gap.
    @Published private(set) var isWorking: Bool = false
    /// What state we expect to reach after start/stop. Clears isWorking when
    /// state actually settles there. Safety timeout in refreshState prevents
    /// a stuck spinner if the transition never completes.
    private var pendingTarget: AgentState?
    private var workingStartedAt: Date?
    private static let workingTimeout: TimeInterval = 10

    /// Polls GitHub for new releases. Surfaced to the menu via `availableUpdate`.
    let updater = Updater()
    @Published private(set) var availableUpdate: Updater.ReleaseInfo?

    private var pollTimer: Timer?
    private let pidFile = "/tmp/decaf.pid"
    private let stopRequestFile = "/tmp/decaf.stop"
    private let claudeSettings = "\(NSHomeDirectory())/.claude/settings.json"
    private let codexHooks = "\(NSHomeDirectory())/.codex/hooks.json"
    private let envFile = EnvFile(path: "\(NSHomeDirectory())/.decaf/.env")
    private let loginItemFirstRunKey = "DecafDidAutoEnableLoginItem"
    /// Narrow NOPASSWD rule for `pmset -b disablesleep 0|1`. Written once by
    /// decaf-install-sudoers via an osascript admin call on first Start; lets
    /// every subsequent Start launch decaf as the regular user with no prompt
    /// and survive reboots.
    private let sudoersFile = "/etc/sudoers.d/decaf"

    init() {
        self.binaryPath = Self.locateBinary()
        self.hooksInstalled = Self.checkHooksInstalled(claudeSettings: claudeSettings, codexHooks: codexHooks)
        self.telegramConfigured = Self.checkTelegramConfigured(envFile: envFile)
        let (swd, delay) = Self.readSleepSettings(envFile: envFile)
        self.sleepWhenDone = swd
        self.sleepDelayMinutes = delay
        // First launch: opt user into Login Item so the menubar reflects state
        // after every reboot. Idempotent — only attempted once; user toggle wins after.
        if !UserDefaults.standard.bool(forKey: loginItemFirstRunKey) {
            try? LoginItem.setEnabled(true)
            UserDefaults.standard.set(true, forKey: loginItemFirstRunKey)
        }
        self.loginItemEnabled = LoginItem.isEnabled
        self.sudoersInstalled = FileManager.default.fileExists(atPath: sudoersFile)
        ensureFailsafeAgentRegistered()
        startPolling()
        refreshState()

        // Bridge the Updater's @Published into our own so SwiftUI views
        // observing Controller see updates without subscribing separately.
        // `assign(to: &$prop)` retains its subscription for the lifetime of
        // the receiving @Published — no need to manage cancellables.
        updater.$available.assign(to: &$availableUpdate)
        updater.start()
    }

    /// Path to a CLI script bundled inside Decaf.app/Contents/Resources/cli/,
    /// or nil if the app isn't running from a bundle (e.g. `swift run`).
    /// Files keep their original .sh suffix in the bundle except `decaf` itself.
    static func bundledCLI(_ name: String) -> String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/cli")
            .appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    private static let fallbackBinaryPaths = [
        "/usr/local/bin/decaf",
        "/opt/homebrew/bin/decaf",
        "\(NSHomeDirectory())/.local/bin/decaf",
    ]

    private static func locateBinary() -> String? {
        if let bundled = bundledCLI("decaf") { return bundled }
        for path in fallbackBinaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func checkHooksInstalled(claudeSettings: String, codexHooks: String) -> Bool {
        for path in [claudeSettings, codexHooks] {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
               contents.contains("decaf-hook") {
                return true
            }
        }
        return false
    }

    private static func checkTelegramConfigured(envFile: EnvFile) -> Bool {
        let values = envFile.read()
        return !(values["TELEGRAM_TOKEN"] ?? "").isEmpty && !(values["TELEGRAM_CHAT_ID"] ?? "").isEmpty
    }

    /// Defaults match the bash side: SLEEP_WHEN_DONE=1, SLEEP_DELAY_MIN=0.
    /// Returned bool/Int are the *current* persisted values, falling back to defaults
    /// when the key is absent or unparseable.
    private static func readSleepSettings(envFile: EnvFile) -> (sleepWhenDone: Bool, delay: Int) {
        let v = envFile.read()
        let swd = (v["SLEEP_WHEN_DONE"].flatMap(Int.init) ?? 1) != 0
        let delay = max(0, v["SLEEP_DELAY_MIN"].flatMap(Int.init) ?? 0)
        return (swd, delay)
    }

    func refreshBinary() {
        binaryPath = Self.locateBinary()
    }

    // State source of truth: /tmp/decaf.pid (bash writes it on startup).

    private func startPolling() {
        pollTimer?.invalidate()
        // 0.5s tick: state flip is visible within ~500ms of bash creating or
        // removing /tmp/decaf.pid. Cheap (one file stat + one kill(0) syscall).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    private func refreshState() {
        let newState: AgentState
        if let pid = readPidFile(), pidIsAlive(pid) {
            newState = .listening
        } else if case .error = state {
            newState = state   // sticky error
        } else {
            newState = .stopped
        }
        state = newState

        // Clear the spinner when the transition completes — or after the
        // safety timeout if it never settles. workingStartedAt = nil means
        // we haven't begun the wait yet (Start: still inside the password
        // dialog), so don't treat that as timed-out.
        if isWorking {
            let reached = pendingTarget.map { $0 == newState } ?? false
            let timedOut = workingStartedAt.map { Date().timeIntervalSince($0) > Self.workingTimeout } ?? false
            if reached || timedOut {
                isWorking = false
                pendingTarget = nil
                workingStartedAt = nil
            }
        }
    }

    /// Marks a transition in flight. Pass `immediate: false` when there's a
    /// blocking step before the bash transition actually starts (Start path:
    /// the admin password dialog can sit for arbitrary time). The caller
    /// flips workingStartedAt when the real wait begins.
    private func beginWorking(target: AgentState, immediate: Bool = true) {
        isWorking = true
        pendingTarget = target
        workingStartedAt = immediate ? Date() : nil
    }

    private func readPidFile() -> pid_t? {
        guard let contents = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        let first = contents.split(separator: " ").first ?? contents.split(separator: "\n").first ?? ""
        return pid_t(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` returns 0 if we can signal the process, or -1 with errno:
    ///   ESRCH = no such process (dead)
    ///   EPERM = process exists, we lack permission (root-owned process while we're user)
    /// EPERM still means alive.
    private func pidIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func start() {
        guard let bin = binaryPath else {
            state = .error("decaf binary not found in PATH")
            return
        }
        if case .listening = state { return }
        // immediate: false — don't start the timeout clock until any password
        // dialog is dismissed and bash actually launches.
        beginWorking(target: .listening, immediate: false)

        // First Start ever (or after uninstall of the rule): install the
        // narrow NOPASSWD pmset rule — exactly one password prompt, then this
        // step never happens again, even across reboots. After that, decaf
        // runs as the regular user; `sudo -n pmset` works silently.
        if !sudoersRuleInstalled() {
            installSudoersRule { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.sudoersInstalled = true
                        self.launchDecafAsUser(bin: bin)
                    case .failure(.userCanceled):
                        self.isWorking = false
                        self.pendingTarget = nil
                        self.workingStartedAt = nil
                        self.refreshState()
                    case .failure(.failed(let msg)):
                        self.isWorking = false
                        self.pendingTarget = nil
                        self.workingStartedAt = nil
                        self.state = .error("Sudoers install failed: \(msg)")
                    }
                }
            }
            return
        }

        launchDecafAsUser(bin: bin)
    }

    /// True iff `/etc/sudoers.d/decaf` is present. The directory is
    /// world-traversable on macOS (755 root:wheel) so this works without sudo.
    /// We never read the file's contents — that requires root — only its
    /// existence; bash-side will still probe `sudo -n pmset` and fall back to
    /// an interactive prompt if the rule turns out to be invalid for any
    /// reason.
    private func sudoersRuleInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
    }

    /// Writes ~/Library/LaunchAgents/com.decaf.failsafe.plist pointing at the
    /// bundled decaf-failsafe.sh and loads it via launchctl. Idempotent:
    /// re-writes only when missing or stale (e.g. after the user moves the
    /// .app), and reloads launchctl accordingly. Replaces what v1/install.sh
    /// used to do — lets a drag-and-drop install register the failsafe with
    /// no shell-script install step.
    private func ensureFailsafeAgentRegistered() {
        guard let failsafePath = Self.bundledCLI("decaf-failsafe.sh") else { return }
        let plistDir = "\(NSHomeDirectory())/Library/LaunchAgents"
        let plistPath = "\(plistDir)/com.decaf.failsafe.plist"
        let plistBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.decaf.failsafe</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(failsafePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/decaf-failsafe.out.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/decaf-failsafe.err.log</string>
        </dict>
        </plist>

        """
        let existing = try? String(contentsOfFile: plistPath, encoding: .utf8)
        if existing == plistBody { return }
        try? FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        if existing != nil {
            _ = runSilent("/bin/launchctl", ["unload", plistPath])
        }
        try? plistBody.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = runSilent("/bin/launchctl", ["load", plistPath])
    }

    /// Run a child process, ignore output, return exit code. Used for one-shot
    /// launchctl calls during failsafe registration.
    @discardableResult
    private func runSilent(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Locates the decaf-install-sudoers helper. Prefers the copy embedded in
    /// the .app bundle so a drag-installed Decaf works without a separate
    /// /usr/local/bin install; falls back to legacy install locations.
    private func locateSudoersInstaller() -> String? {
        if let bundled = Self.bundledCLI("decaf-install-sudoers.sh") { return bundled }
        let candidates = [
            "/usr/local/bin/decaf-install-sudoers",
            "/opt/homebrew/bin/decaf-install-sudoers",
            "\(NSHomeDirectory())/.local/bin/decaf-install-sudoers",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One-shot osascript admin call: runs decaf-install-sudoers as root to
    /// drop /etc/sudoers.d/decaf for the current user. This is the *only*
    /// password prompt the user should ever see for Decaf.
    private func installSudoersRule(completion: @escaping (Result<Void, OsascriptError>) -> Void) {
        guard let helper = locateSudoersInstaller() else {
            completion(.failure(.failed("decaf-install-sudoers helper not found (re-run `make install`)")))
            return
        }
        // NSUserName() is the active console user's shortname (macOS shortnames
        // can't contain spaces or shell metacharacters). The helper re-validates
        // it against [a-z_][a-z0-9_-]* and confirms the user exists locally
        // before writing anything, so a tampered value here is rejected by the
        // helper rather than silently embedded. We deliberately do NOT add
        // inner quotes around the username — they would break the outer
        // `do shell script "..."` AppleScript string wrapping.
        let user = NSUserName()
        let safeHelper = helper.replacingOccurrences(of: "\"", with: "\\\"")
        let safeUser = user.replacingOccurrences(of: "\"", with: "\\\"")
        let shellCmd = "\(safeHelper) \(safeUser)"
        let appleScript = "do shell script \"\(shellCmd)\" with administrator privileges"
        runOsascript(appleScript, completion: completion)
    }

    /// Append-mode handle for the menubar's own log of bash decaf output.
    /// Returns nullDevice on any failure — log loss is acceptable, a crash is
    /// not. Path is user-owned so it can't get into the root-owned-in-/tmp
    /// state earlier versions could end up in.
    private func openMenubarLog() -> FileHandle {
        let dir = "\(NSHomeDirectory())/Library/Logs"
        let path = "\(dir)/decaf-menubar.log"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            return FileHandle.nullDevice
        }
        _ = try? fh.seekToEnd()
        return fh
    }

    /// Launch decaf in --closed-lid mode as the regular user. No osascript,
    /// no admin privileges. The bash script uses `sudo -n pmset …` which
    /// works without a prompt thanks to the NOPASSWD rule.
    private func launchDecafAsUser(bin: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--closed-lid"]
        // Log to ~/Library/Logs (user-owned — matches bash decaf's LOG_DIR).
        // Earlier versions used /tmp/decaf.menubar.log, but when decaf ran via
        // osascript admin that file ended up root-owned, and a later
        // user-context launch couldn't append to it (and /tmp's sticky bit
        // blocked us from unlinking it). User-owned path sidesteps that.
        // Falling back to /dev/null on open failure keeps Start working even
        // if logs dir is unwritable for some reason — losing the log is fine,
        // crashing the menubar is not.
        let logHandle = openMenubarLog()
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.standardInput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            isWorking = false
            pendingTarget = nil
            workingStartedAt = nil
            state = .error("Failed to launch decaf: \(error.localizedDescription)")
            return
        }

        // bash is starting; arm the spinner safety timeout from this point.
        workingStartedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Poll for /tmp/decaf.pid every 100ms (up to 3s) so we flip to
            // .listening as soon as bash writes it.
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let pid = self.readPidFile(), self.pidIsAlive(pid) { break }
            }
            self.refreshState()
        }
    }

    /// Quit handler that doesn't leak a running watcher. Without this, Quit
    /// would just close the UI and leave bash decaf running — keeping
    /// pmset disablesleep=1 and a caffeinate assertion alive. Result for the
    /// user: shut the lid expecting sleep, get a hot laptop with music
    /// playing.
    ///
    /// Sequence:
    ///   1. Signal stop via /tmp/decaf.stop (file-based, no sudo). Bash polls
    ///      it every ~1s and exits cleanly, running its EXIT trap that
    ///      reverts pmset.
    ///   2. Wait up to 4s for /tmp/decaf.pid to disappear so the lid-close
    ///      that often follows Quit happens after pmset is reverted.
    ///   3. Terminate the app.
    /// If the watcher was already stopped, this is effectively a no-op pause.
    func quitGracefully() {
        // Fire and forget — bash also clears this file at startup, so it
        // can't get stuck across sessions.
        try? "quit\n".write(toFile: stopRequestFile, atomically: true, encoding: .utf8)

        Task { @MainActor [weak self] in
            guard let self else { NSApplication.shared.terminate(nil); return }
            // Up to 4s (40 × 100ms). Picked over 3s because bash polls
            // /tmp/decaf.stop at 1s granularity and cleanup itself takes a
            // moment (caffeinate kill, pmset revert).
            for _ in 0..<40 {
                if self.readPidFile() == nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func stop() {
        // File-based stop signal so we don't need admin to kill the root bash.
        // Bash watch_auto loop polls /tmp/decaf.stop every 1s and exits cleanly
        // (its EXIT trap reverts pmset). /tmp is world-writable so no sudo here.
        // Catches every running instance at once — handy when zombies are around.
        beginWorking(target: .stopped)
        do {
            try "stop\n".write(toFile: stopRequestFile, atomically: true, encoding: .utf8)
        } catch {
            isWorking = false
            pendingTarget = nil
            workingStartedAt = nil
            state = .error("Failed to signal stop: \(error.localizedDescription)")
            return
        }
        // State will flip to .stopped within ~1-2s via the polling timer once
        // bash exits and removes /tmp/decaf.pid. refreshState clears isWorking.
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            state = .error("Login item: \(error.localizedDescription)")
        }
        loginItemEnabled = LoginItem.isEnabled
    }

    /// Persists SLEEP_WHEN_DONE to ~/.decaf/.env. The bash watcher re-reads
    /// this file every tick, so the toggle takes effect within ~5s without restart.
    func setSleepWhenDone(_ enabled: Bool) {
        sleepWhenDone = enabled
        try? envFile.write(updates: ["SLEEP_WHEN_DONE": enabled ? "1" : "0"])
    }

    /// Minutes are clamped to [0, 240]. 0 = no timer (relevant only when
    /// sleepWhenDone is false; if it's true, the delay is ignored bash-side).
    func setSleepDelayMinutes(_ minutes: Int) {
        let clamped = max(0, min(240, minutes))
        sleepDelayMinutes = clamped
        try? envFile.write(updates: ["SLEEP_DELAY_MIN": String(clamped)])
    }

    func runSetup() {
        guard let bin = binaryPath else {
            state = .error("decaf binary not found in PATH")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["setup"]
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hooksInstalled = Self.checkHooksInstalled(
                    claudeSettings: self.claudeSettings,
                    codexHooks: self.codexHooks
                )
            }
        }
        try? p.run()
    }

    // MARK: - Telegram

    func loadTelegramCreds() -> (token: String, chatID: String) {
        let v = envFile.read()
        return (v["TELEGRAM_TOKEN"] ?? "", v["TELEGRAM_CHAT_ID"] ?? "")
    }

    func saveTelegramCreds(token: String, chatID: String) throws {
        try envFile.write(updates: [
            "TELEGRAM_TOKEN": token,
            "TELEGRAM_CHAT_ID": chatID,
        ])
        telegramConfigured = Self.checkTelegramConfigured(envFile: envFile)
    }

    enum TelegramTestResult {
        case sent
        case failed(String)
    }

    /// Posts a test message to Telegram. Used by Settings "Send test" button.
    func sendTelegramTest(token: String, chatID: String) async -> TelegramTestResult {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            return .failed("invalid token format")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "chat_id=\(chatID)&text=\("Decaf: test notification ✓".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = body.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .sent
            }
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            return .failed(msg)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum OsascriptError: Error {
        case userCanceled
        case failed(String)
    }

    private func runOsascript(_ script: String, completion: @escaping (Result<Void, OsascriptError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "osascript exit \(p.terminationStatus)"
                    if msg.contains("User canceled") || msg.contains("(-128)") {
                        completion(.failure(.userCanceled))
                    } else {
                        completion(.failure(.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))))
                    }
                }
            } catch {
                completion(.failure(.failed(error.localizedDescription)))
            }
        }
    }
}
