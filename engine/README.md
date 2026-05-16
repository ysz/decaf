# decaf

Like `caffeinate -i`, but knows when your agent is done and tells your phone.
Plus closed-lid support without an HDMI dummy plug.

Built for the case where you kick off a coding agent (Claude Code, Codex CLI,
Aider, Cursor agent) that will churn for 30 minutes to a few hours, and you
want to close the lid and walk away.

Targets Apple Silicon Macs running recent macOS. Pure bash — every line is
auditable, no notarization, no `$99/yr` Apple Developer cert, no kext.

## Install

    ./install.sh
    decaf setup     # one-time: wires Claude Code + Codex hooks for instant notifications

`install.sh` copies four scripts into `/usr/local/bin/` (`decaf`,
`decaf-failsafe`, `decaf-hook`, `decaf-install-sudoers`) and registers a LaunchAgent
(`~/Library/LaunchAgents/com.decaf.failsafe.plist`) that reverts
`pmset disablesleep` on next login if decaf ever crashes while it was
holding the system awake.

`decaf setup` merges Decaf hook entries into both
`~/.claude/settings.json` and `~/.codex/hooks.json`, backing up existing
files to `*.decaf.bak`. Claude Code events cover `UserPromptSubmit`,
`Stop`, and `Notification`; Codex events cover `UserPromptSubmit`,
`Stop`, and `PermissionRequest`. Without this step, auto mode has no
agent lifecycle events to consume, so use manual Start/Stop, watch mode,
or wrap mode instead.

Modern Codex CLI enables hooks by default. If Codex asks to review newly
configured hooks, run `/hooks` inside Codex and trust Decaf. Restart any
Codex sessions that were already open before setup so they reload the hook
configuration.

Dependencies: `caffeinate`, `pmset`, `ioreg`, `pgrep`, `osascript`, `curl` —
all baked into macOS. `python3` is used by `decaf setup` only (to merge
JSON). It ships with Xcode Command Line Tools, which Homebrew, git, npm,
rustup, etc. all pull in automatically — so almost every dev has it. If
not: `xcode-select --install`.

Optional: `brew install terminal-notifier` for prettier notification sender
name (otherwise notifications show under "Script Editor").

## Usage

There are three modes — pick whichever matches your workflow:

    # AUTO MODE (default). Listens for Claude Code / Codex hook events.
    # Holds the Mac awake and sleeps it once every tracked session is idle
    # and the lid is closed. Runs until you stop it.
    decaf
    decaf --closed-lid

    # WATCH MODE. Attach to one specific PID.
    decaf --watch 41224

    # WRAP MODE. Spawn a command as a child and watch it; also captures
    # the last 10 lines of stdout into the notification body.
    decaf -- claude --dangerously-skip-permissions

    # POST exit summary to a webhook (ntfy / Pushover / Discord / Slack).
    decaf --notify https://ntfy.sh/my-topic
    decaf --notify https://ntfy.sh/my-topic -- aider

Flags combine: `decaf --closed-lid --notify <url>` is fine in any mode.

### Picking a mode

- **Auto** is the right default for Claude Code and Codex after
  `decaf setup`: start your agent in whatever terminal you normally use,
  then run `decaf` in another terminal or press Start in the menubar.
- **Watch** is what you want when many agent processes exist and you only
  care about one (e.g., Claude Code leaves background workers around —
  `pgrep -lx claude` will show you them, pick the PID of the session you
  actually care about).
- **Wrap** is the simplest — `decaf -- <cmd>` runs `<cmd>` as a child,
  exits when it does, and tails its stdout for the notification body.

On exit, you get a local macOS notification with exit code, duration, and
the last 10 lines of stdout. If `--notify` is set, the same summary is
POSTed to the URL.

## How "done" is detected (auto mode)

Auto mode tracks each Claude Code / Codex session as it works, then tells
you when **everything** is idle so the system can sleep.

After `decaf setup`, Claude Code and Codex call `decaf-hook` on lifecycle
events, which records to `/tmp/decaf.events.$UID`. The `/tmp` location is
intentional: Codex runs hooks inside its sandbox, where writing to
`~/.decaf/` is not allowed.

| Agent       | Hook event           | What it means                 | Session state |
| ----------- | -------------------- | ----------------------------- | ------------- |
| Claude Code | `UserPromptSubmit`   | You sent a message             | working       |
| Claude Code | `Stop`               | Claude finished a response     | done          |
| Claude Code | `Notification`       | Claude needs your attention    | working       |
| Codex       | `UserPromptSubmit`   | You sent a message             | working       |
| Codex       | `Stop`               | Codex finished a turn          | done          |
| Codex       | `PermissionRequest`  | Codex needs approval           | working       |

Two notifications fire from auto mode:

1. **Per-session ping** (quiet Tink) — each time a session goes `done` or
   needs attention. Tells you which `cwd` finished.
2. **System sleep** — when **every** tracked session has been `done` for
   at least 30 seconds and the lid is closed, Decaf waits another 15
   seconds before sleeping. If a new prompt arrives, the state resets and
   sleep can fire later.

Sessions that started **before** decaf started, and never received any
event after decaf started, are not tracked — they're already idle from
our perspective. Wrap mode (`decaf -- <cmd>`) and watch mode
(`decaf --watch <pid>`) don't need hooks — they own the process and
exit when it does.

## Keeping the system awake

| Mode             | Mechanism                                                   |
| ---------------- | ----------------------------------------------------------- |
| Default          | `caffeinate -i` (PreventUserIdleSystemSleep) for our lifetime |
| `--closed-lid`   | + `sudo pmset -b disablesleep 1` + 2 Hz `displaysleepnow` watcher when the lid is closed |

`pmset disablesleep 1` sets a kernel-level flag (the same one macOS uses
during software updates) that overrides clamshell sleep on both AC and
battery. It does **not** require disabling SIP, kexts, or a virtual display.

When decaf exits, it reverts the flag. If it crashes, the failsafe
LaunchAgent reverts the flag on next login. If the machine reboots, the
flag clears automatically.

## Tradeoffs (read before relying on this)

**Thermal.** Closed-lid plus heavy CPU on a fanless Air restricts airflow.
Long agent runs can thermal-throttle or trigger a thermal shutdown. This is
physics, not a bug.

**Battery.** Closed-lid mode keeps the CPU available, so battery drains
faster than sleep. By default decaf refuses to start `--closed-lid`
below 15% on battery; override with `OK_ON_LOW_BATTERY=1`.

**Crash cleanup.** If decaf is `kill -9`'d while `--closed-lid` is
armed, `SleepDisabled` stays on until the failsafe runs at next login or
you reboot. You can also revert manually with `sudo pmset -b disablesleep 0`.

**Notifications.** Without `terminal-notifier`, notifications show under
"Script Editor" — a cosmetic wart of using `osascript`.

**Admin prompt.** Every `--closed-lid` session prompts for a password
unless your sudo timestamp is still cached (5-minute default). A V2 with
an SMAppService helper would eliminate this; not in V1.

**Apple policy.** `pmset disablesleep` is public and documented, but
non-zero risk Apple restricts it in the future. The non-closed-lid mode
keeps working either way.

## Files

    decaf                      main script
    decaf-failsafe.sh          boot-time pmset revert (LaunchAgent runs this)
    decaf-hook.sh              Claude Code / Codex hook receiver → events file
    decaf-install-sudoers.sh   one-shot NOPASSWD rule installer
    install.sh                 installer (writes LaunchAgent plist inline)
    uninstall.sh               full cleanup (binaries, LaunchAgent, sudoers, hooks)
    README.md                  this file
