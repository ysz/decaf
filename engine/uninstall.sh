#!/usr/bin/env bash
# Decaf uninstaller. Removes binaries, LaunchAgent, .app, Claude Code / Codex hooks,
# user data (~/.decaf including Telegram creds), and stops any running watcher.
#
# Idempotent — safe to re-run. Missing items are silently skipped.

set -uo pipefail   # not -e: every step must run even if some have nothing to do

BIN_DIR="/usr/local/bin"
LA_PLIST="${HOME}/Library/LaunchAgents/com.decaf.failsafe.plist"
APP_PATH="/Applications/Decaf.app"
APP_CLI="${APP_PATH}/Contents/Resources/cli/decaf"
DATA_DIR="${HOME}/.decaf"

echo "→ Decaf uninstaller"
echo ""

# 1. Remove Claude Code / Codex hooks via whichever decaf binary is installed. The new
#    install model ships the CLI inside the .app bundle (no /usr/local/bin
#    files unless the user explicitly ran `make cli`). Prefer the bundled copy;
#    fall back to the legacy path for old installs.
DECAF_BIN=""
[[ -x "$APP_CLI" ]] && DECAF_BIN="$APP_CLI"
[[ -z "$DECAF_BIN" && -x "$BIN_DIR/decaf" ]] && DECAF_BIN="$BIN_DIR/decaf"
if [[ -n "$DECAF_BIN" ]]; then
  echo "→ removing Claude Code / Codex hooks (via decaf setup --remove)"
  "$DECAF_BIN" setup --remove 2>&1 | grep -E 'Claude Code|Codex CLI|hook|backup' || true
fi

# 2. Stop ALL running watchers — including orphans from pre-NOPASSWD builds
#    that launched bash decaf via osascript admin (running as root) and got
#    leaked when the menubar app crashed. /tmp/decaf.pid only tracks the
#    most-recent watcher; sudo pkill catches the others. We match on the bare
#    name `decaf` (with leading slash or space, to exclude /Applications/Decaf
#    matches in argv[0]) to catch both bundled and legacy install paths.
echo "→ stopping running watcher(s)"
if [[ -f "/tmp/decaf.pid" ]]; then
  pid=$(awk '{print $1}' /tmp/decaf.pid 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  fi
fi
sudo pkill -f "/decaf --closed-lid" 2>/dev/null || true
pkill -f "/decaf( |$)" 2>/dev/null || true
sleep 1
# Belt-and-suspenders: if any orphan died without running its EXIT trap and
# pmset got left in disablesleep=1, revert it. The failsafe LaunchAgent would
# catch this at next login, but uninstall should leave the system clean now.
if [[ "$(pmset -g 2>/dev/null | awk '/SleepDisabled/ { print $2; exit }')" == "1" ]]; then
  echo "→ reverting orphaned pmset disablesleep=1 (sudo)"
  sudo pmset -b disablesleep 0 2>/dev/null || true
fi

# 3. Stop the menubar app.
echo "→ stopping menubar app"
pkill -f 'Decaf.app/Contents/MacOS' 2>/dev/null || true

# 4. Unload + remove LaunchAgent.
if [[ -f "$LA_PLIST" ]]; then
  echo "→ unloading LaunchAgent"
  launchctl unload "$LA_PLIST" 2>/dev/null || true
  rm -f "$LA_PLIST"
fi

# 5. Remove binaries + sudoers rule (sudo — /usr/local/bin and /etc/sudoers.d
#    are both root-owned). The watcher was killed in step 2 first so its
#    cleanup() had a chance to revert pmset *while the rule was still in
#    place* — removing the rule first could leave the system stuck with
#    SleepDisabled=1 on a non-admin shell.
to_remove=()
for suffix in "" "-hook" "-failsafe" "-install-sudoers"; do
  p="$BIN_DIR/decaf${suffix}"
  [[ -e "$p" ]] && to_remove+=("$p")
done
[[ -e "/etc/sudoers.d/decaf" ]] && to_remove+=("/etc/sudoers.d/decaf")
if (( ${#to_remove[@]} > 0 )); then
  echo "→ removing binaries + sudoers rule (sudo)"
  if sudo rm -f "${to_remove[@]}"; then
    for p in "${to_remove[@]}"; do
      if [[ ! -e "$p" ]]; then
        echo "  removed: $p"
      else
        echo "  FAILED to remove: $p" >&2
      fi
    done
  else
    echo "  FAILED: sudo could not authorize. Remove manually:" >&2
    for p in "${to_remove[@]}"; do echo "    sudo rm -f $p" >&2; done
  fi
fi

# 6. Remove .app from /Applications.
if [[ -d "$APP_PATH" ]]; then
  echo "→ removing $APP_PATH"
  rm -rf "$APP_PATH"
fi

# 7. /tmp state + menubar log. Old builds wrote /tmp/decaf.menubar.log from
#    an osascript-admin context, leaving it root-owned; /tmp's sticky bit
#    means a non-root user can't unlink it. `sudo rm` handles that case; if
#    sudo isn't available here the file just stays around harmlessly.
sudo rm -f /tmp/decaf.pid /tmp/decaf.stop /tmp/decaf.events.* /tmp/decaf.menubar.log /tmp/decaf-failsafe.* 2>/dev/null \
  || rm -f /tmp/decaf.pid /tmp/decaf.stop /tmp/decaf.events.* /tmp/decaf.menubar.log /tmp/decaf-failsafe.* 2>/dev/null || true
rm -f "${HOME}/Library/Logs/decaf-menubar.log" 2>/dev/null || true

# 8. User data — includes Telegram creds. We wipe it because uninstall means
#    uninstall; the user explicitly asked for one-shot removal, not a soft
#    deinstall with state retention.
if [[ -d "$DATA_DIR" ]]; then
  echo "→ removing $DATA_DIR"
  rm -rf "$DATA_DIR"
fi

echo ""
echo "✓ Decaf uninstalled."
