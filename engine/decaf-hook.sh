#!/usr/bin/env bash
# decaf-hook — receives an event from a coding agent's hook config and
# records it to /tmp/decaf.events.$UID so the main decaf process can
# detect per-session activity.
# Line format: TIMESTAMP EVENT SESSION_ID CWD_BASENAME SLUG AGENT

set -u

EVENT="${1:-event}"
AGENT="${2:-}"
DECAF_UID="${UID:-$(id -u)}"
EVENT_FILE="${DECAF_EVENT_FILE:-/tmp/decaf.events.${DECAF_UID}}"
EVENT_DIR="$(dirname "$EVENT_FILE")"

mkdir -p "$EVENT_DIR"

# Extract session_id + cwd + message from hook stdin JSON. Shell regex is
# fine for typical paths/UUIDs/short messages.
cwd=""
session=""
message=""
hook_event=""
if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || true)
  if [[ -n "$input" ]]; then
    input_flat=$(printf '%s' "$input" | tr -d '\n')
    cwd=$(printf '%s' "$input_flat" \
      | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed -E 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    [[ -n "$cwd" ]] && cwd=$(basename "$cwd" 2>/dev/null || echo "$cwd")
    session=$(printf '%s' "$input_flat" \
      | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed -E 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    message=$(printf '%s' "$input_flat" \
      | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed -E 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    hook_event=$(printf '%s' "$input_flat" \
      | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed -E 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  fi
fi

if [[ -z "$AGENT" ]]; then
  if [[ -n "$hook_event" ]]; then
    AGENT="codex"
  else
    AGENT="claude"
  fi
fi
case "$AGENT" in
  codex|claude) ;;
  *) AGENT="claude" ;;
esac

# For Notification events, classify the message so decaf can filter out
# "idle reminders" (which fire even under bypass-permissions and are spammy)
# while still surfacing real permission/attention requests.
slug="-"
if [[ "$EVENT" == "notification" ]]; then
  if [[ "$AGENT" == "codex" || "$hook_event" == "PermissionRequest" ]]; then
    slug="permission"
  else
    msg_lower=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
    case "$msg_lower" in
      *permission*|*approval*|*confirm*) slug="permission" ;;
      *waiting*|*idle*|*"60 second"*|*"still there"*) slug="idle" ;;
      *) slug="other" ;;
    esac
  fi
fi

printf '%s %s %s %s %s %s\n' "$(date +%s)" "$EVENT" "${session:-?}" "${cwd:-?}" "$slug" "$AGENT" >> "$EVENT_FILE"

# Trim if the file has grown unreasonably.
lines=$(wc -l < "$EVENT_FILE" 2>/dev/null | tr -d ' ')
if [[ -n "$lines" && "$lines" -gt 1000 ]]; then
  tail -500 "$EVENT_FILE" > "${EVENT_FILE}.tmp" 2>/dev/null \
    && mv "${EVENT_FILE}.tmp" "$EVENT_FILE"
fi

exit 0
