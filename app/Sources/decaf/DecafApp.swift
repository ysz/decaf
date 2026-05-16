import SwiftUI
import AppKit

@main
struct DecafApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            menubarLabel
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(controller: controller)
        }
    }

    @ViewBuilder
    private var menubarLabel: some View {
        switch controller.state {
        case .listening:
            Image(nsImage: DecafIcon.image(active: true))
        case .stopped:
            Image(nsImage: DecafIcon.image(active: false))
        case .error:
            Image(systemName: "exclamationmark.triangle")
        }
    }
}

struct MenuView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text("Decaf · keeps Mac awake with lid closed")

        Divider()
        statusRow
        startStopButton
        if shouldShowFirstStartCaption {
            Text("First Start asks for admin password.")
                .font(.caption)
        }

        if showOptionalSetup {
            Divider()
            Text("Optional setup")
                .font(.caption)
            setupHooks
            setupTelegram
        }

        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        if let release = controller.availableUpdate {
            Button("Update available: v\(release.displayVersion) →") {
                showUpdateAlert(release: release)
            }
        }
        Button("About Decaf") { showAboutPanel() }
        Button("Quit") { controller.quitGracefully() }
            .keyboardShortcut("q")
    }

    /// "First Start asks for admin password." caption — only when the user is
    /// in a clean Stopped state, the binary is present, and the NOPASSWD rule
    /// hasn't been installed yet. After the first successful Start, sudoers is
    /// in place and this caption disappears forever.
    private var shouldShowFirstStartCaption: Bool {
        if case .listening = controller.state { return false }
        if controller.isWorking { return false }
        if controller.binaryPath == nil { return false }
        return !controller.sudoersInstalled
    }

    private var showOptionalSetup: Bool {
        !controller.hooksInstalled || !controller.telegramConfigured
    }

    /// Status row tells the user what the Mac is doing right now. When On,
    /// the tail also hints how the session ends (manual Stop vs. auto on
    /// hook fire). When Off, the Mac just sleeps as usual regardless of
    /// whether hooks are installed — the hooks state is reflected by the
    /// optional-setup section appearing/disappearing.
    @ViewBuilder
    private var statusRow: some View {
        switch controller.state {
        case .listening:
            let tail = controller.hooksInstalled
                ? " On · sleeps when Claude Code / Codex finish"
                : " On · stays awake until you Stop"
            Text("●").foregroundColor(.green) + Text(tail)
        case .stopped:
            if controller.binaryPath == nil {
                Text("⚠ Can't find the `decaf` CLI — re-run `make install`")
            } else {
                Text("○ Off · Mac will sleep as usual")
            }
        case .error(let msg):
            Text("⚠ \(msg)")
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        switch controller.state {
        case .listening:
            Button(controller.isWorking ? "Stopping…" : "Stop") { controller.stop() }
                .keyboardShortcut("s")
                .disabled(controller.isWorking)
        case .stopped, .error:
            Button(controller.isWorking ? "Starting…" : "Start") { controller.start() }
                .keyboardShortcut("s")
                .disabled(controller.isWorking || controller.binaryPath == nil)
        }
    }

    @ViewBuilder
    private var setupHooks: some View {
        if controller.hooksInstalled {
            Text("✓ Auto-sleep for Claude Code / Codex")
                .font(.caption)
        } else {
            Button("○ Set up auto-sleep for Claude Code / Codex") { controller.runSetup() }
                .disabled(controller.binaryPath == nil)
        }
    }

    @ViewBuilder
    private var setupTelegram: some View {
        if controller.telegramConfigured {
            Text("✓ Telegram notifications")
                .font(.caption)
        } else {
            SettingsLink {
                Text("○ Set up Telegram notifications")
            }
        }
    }

    /// Update flow: detected a new release on GitHub. We don't ship a
    /// self-updater (no $99/yr Developer ID → notarized download flow not
    /// viable), so we just tell the user how to upgrade their build-from-source
    /// install and offer to copy the command.
    private func showUpdateAlert(release: Updater.ReleaseInfo) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let upgradeCommand = "cd ~/path/to/your/decaf && git pull && make install"
        let alert = NSAlert()
        alert.messageText = "Decaf v\(release.displayVersion) is available"
        alert.informativeText = """
            You have v\(current).

            To upgrade, open Terminal and run:

                \(upgradeCommand)
            """
        alert.addButton(withTitle: "Copy command")     // .alertFirstButtonReturn  (primary, rightmost)
        alert.addButton(withTitle: "Release notes")    // .alertSecondButtonReturn
        alert.addButton(withTitle: "Later")            // .alertThirdButtonReturn
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(upgradeCommand, forType: .string)
        case .alertSecondButtonReturn:
            controller.updater.openRelease()
        default:
            break
        }
    }

    /// LSUIElement apps don't activate on their own, so the About panel would
    /// open behind whatever the user was just looking at. Explicit `activate`
    /// pulls it forward. Credits text is shown below the version number in the
    /// standard panel.
    private func showAboutPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let font = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Keeps your Mac awake (lid closed) while Claude Code and Codex work, sleeps it when they finish.\n\n",
            attributes: [.foregroundColor: NSColor.labelColor, .font: font]
        ))
        credits.append(NSAttributedString(
            string: "Made by Grisha\n2026\n",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]
        ))
        credits.append(NSAttributedString(
            string: "github.com/ysz/decaf",
            attributes: [
                .link: URL(string: "https://github.com/ysz/decaf")!,
                .foregroundColor: NSColor.linkColor,
                .font: font,
            ]
        ))
        // Center everything in the About panel — matches Apple's default layout.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: 0, length: credits.length))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }
}
