#!/usr/bin/env bash
# decaf-failsafe — runs at login via LaunchAgent. If pmset SleepDisabled
# is stuck on with no live decaf process, reverts it. Catches "crashed
# while in --closed-lid mode" scenarios so the system can sleep again.

set -uo pipefail

LOG="${HOME}/Library/Logs/decaf-failsafe.log"
STATE_FILE="/tmp/decaf.pid"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

sleepdisabled=$(pmset -g | awk '/SleepDisabled/ { print $2; exit }')
[[ "$sleepdisabled" != "1" ]] && exit 0

if [[ -f "$STATE_FILE" ]]; then
  pid=$(awk '{print $1}' "$STATE_FILE" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "SleepDisabled=1 and decaf (pid $pid) is alive — no action"
    exit 0
  fi
fi

log "SleepDisabled=1 but no active decaf — reverting"

if sudo -n /usr/bin/pmset -b disablesleep 0 2>/dev/null; then
  log "Reverted via cached sudo"
elif osascript -e 'do shell script "/usr/bin/pmset -b disablesleep 0" with administrator privileges' >/dev/null 2>&1; then
  log "Reverted via admin prompt"
else
  log "FAILED to revert; user must run: sudo pmset -b disablesleep 0"
fi

rm -f "$STATE_FILE"
exit 0
