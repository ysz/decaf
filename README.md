# Decaf

<p align="center">
  <img src="https://github.com/user-attachments/assets/dcb49ba5-be21-4ec1-8b28-33602a194abd" alt="Decaf" width="480" />
</p>

Close the lid and walk away. Your Mac stays awake so Claude Code or
Codex can keep working. When the agent finishes, the Mac falls fully
asleep on its own; if the agent needs approval, Decaf notifies you.

## What it does

- Close your MacBook lid, your coding agent keeps running. No external
  display, no HDMI dummy plug, no kernel extension.
- The Mac sleeps automatically shortly after Claude Code or Codex
  finishes its task, and notifies you when the agent stops to wait for
  approval.
- Local notification and optional Telegram message with the exit
  summary.
- Open source, every line auditable.

## How it works

- Holds the system awake with `caffeinate -i`, and on Apple Silicon
  flips `pmset disablesleep` so closed-lid does not trigger clamshell
  sleep. That is the same kernel flag macOS itself uses during system
  updates.
- Listens for Claude Code / Codex hook events (`UserPromptSubmit`,
  `Stop`, `Notification` / `PermissionRequest`) to
  catch the exact moment the agent is done or is waiting on you.
  Process-exit alone is a poor proxy: Claude Code keeps background
  workers alive long after the conversation ends.
- When the run is over, runs `pmset sleepnow` after a configurable
  delay so the Mac sleeps fully (no fan, no heat, no battery drain).
- bash engine plus a Swift menubar wrapper. No notarization, no SIP
  disable, no $99/yr Apple Developer cert.

## Compared to alternatives

|                                                       | Decaf | `caffeinate` | Amphetamine | KeepingYouAwake |
|-------------------------------------------------------|:-----:|:------------:|:-----------:|:---------------:|
| Keep awake (lid open)                                 |  ✓   |      ✓       |     ✓       |       ✓        |
| Keep awake (lid closed) on Apple Silicon              |  ✓   |              |  needs HDMI |                |
| Auto-detect when Claude Code / Codex finished         |  ✓   |              |             |                |
| Auto-sleep the Mac when done                          |  ✓   |              |             |                |
| Local notification when done                          |  ✓   |              |             |                |
| Telegram / webhook on done                            |  ✓   |              |             |                |
| No kext, no SIP disable, no external display          |  ✓   |      ✓       |   partial   |       ✓        |
| Open source                                           |  ✓   |    built-in  |             |       ✓        |

Roughly, Decaf does what you would cobble together with
`caffeinate -i -- <agent> && pmset sleepnow`, plus closed-lid support
on Apple Silicon, plus knowing exactly when Claude Code or Codex
considers itself "done" via hooks.

## Install

```sh
git clone https://github.com/ysz/Decaf
cd Decaf
make install
```

**Requires:** macOS 14+ and Xcode Command Line Tools. If you don't
already have the tools: `xcode-select --install`. They ship as a
dependency of Homebrew, git, npm, rustup, so most developers already do.

`make install` builds `Decaf.app` with the bash engine embedded inside
the bundle and copies it to `/Applications/`. No `/usr/local/bin` files,
no sudo at install time.

After install, click the ☕ in your menubar →
**Set up auto-sleep for Claude Code / Codex**. This merges hook entries
into `~/.claude/settings.json` and `~/.codex/hooks.json` (with
backups). Codex may ask you to review newly configured hooks; open
`/hooks` in Codex and trust Decaf if prompted. Restart any Codex sessions
that were already open before setup. Without this setup, Decaf can still
be used manually with Start/Stop, `--watch <pid>`, or `decaf -- <cmd>`,
but auto-sleep events will not fire.

### Why the admin password prompt on first Start?

When you press **Start** for the first time, macOS asks for your admin
password exactly once, then never again. Decaf installs a narrow
sudoers rule that grants passwordless access to **only** these two
commands:

```
/usr/bin/pmset -b disablesleep 1
/usr/bin/pmset -b disablesleep 0
```

`pmset disablesleep` is the kernel-level flag that overrides clamshell
sleep on Apple Silicon, the same mechanism macOS uses during system
updates. It is the only software-only path to "lid closed, agent keeps
running" on modern Macs without external displays or kernel extensions.

After the one-time prompt every subsequent Start works silently.

## Uninstall

```sh
make uninstall
```

Removes everything: the `.app` (with the bundled engine), the failsafe
LaunchAgent, the sudoers rule, Claude Code / Codex hook entries, and
`~/.decaf/` (your Telegram credentials live there, back them up first if
you plan to reinstall).

## Updates

The menubar app polls GitHub Releases once a day. When a newer version
ships, the menu shows **Update available: vX.Y.Z →**. Click it for a
dialog with the upgrade command (`git pull && make install`) and a
Copy button. No silent self-update, you stay in control.

## For terminal-only / headless use

If you don't want the menubar app (e.g. on an SSH-only Mac), the bash
engine is standalone:

```sh
make cli       # puts decaf, decaf-hook, decaf-failsafe, decaf-install-sudoers on /usr/local/bin
```

See [engine/README.md](engine/README.md) for the full feature set:
`--watch <pid>`, `-- <cmd>` wrap mode, custom webhooks, listen-only mode.

## Tradeoffs

- **Thermal.** Closed-lid plus heavy CPU on a fanless MacBook Air
  restricts airflow. Long agent runs can throttle or hit a thermal
  shutdown. Physics, not a bug.
- **Battery.** Closed-lid keeps the CPU available, so battery drains
  faster than sleep. Decaf refuses to start `--closed-lid` below 15%
  on battery by default.
- **Apple policy.** `pmset disablesleep` is public and documented, but
  there is non-zero risk Apple restricts it in the future. The
  lid-open mode keeps working either way.

## Screenshot

<p align="center">
  <img src="https://github.com/user-attachments/assets/6c83c9f9-537d-404b-bd80-fd9bf076185d" alt="Decaf menubar menu" width="480" />
</p>

## License

[MIT](LICENSE).
