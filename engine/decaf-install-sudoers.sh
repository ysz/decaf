#!/usr/bin/env bash
# decaf-install-sudoers — install a narrow NOPASSWD rule for pmset so the
# menubar app can arm/revert closed-lid mode without re-prompting for the
# admin password on every Start. Designed to be invoked exactly once, via
# `osascript ... with administrator privileges` from the Decaf menubar app.
#
# The rule grants exactly two commands to a single named user:
#   /usr/bin/pmset -b disablesleep 0
#   /usr/bin/pmset -b disablesleep 1
# Nothing else. No wildcards on the binary, no wildcards on the arguments.
# A separate failsafe LaunchAgent also benefits from this rule on next boot.
#
# Safety:
#   - Username is validated to /^[a-z_][a-z0-9_-]*$/ before being embedded.
#   - File is written to a tmpfile, chmod 0440, chown root:wheel, then
#     `visudo -cf` validates it before atomic mv into /etc/sudoers.d/decaf.
#     If validation fails, the tmpfile is removed and the system's sudoers
#     state is untouched.
#
# Removal: `rm -f /etc/sudoers.d/decaf` (handled by v1/uninstall.sh).

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "decaf-install-sudoers: must run as root (invoke via osascript admin)" >&2
  exit 2
fi

USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "usage: decaf-install-sudoers <username>" >&2
  exit 2
fi

# Strict shell-safe username check. Matches macOS shortname rules and
# prevents shell metacharacters from leaking into the sudoers file.
if ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "decaf-install-sudoers: invalid username '$USER_NAME'" >&2
  exit 2
fi

# Confirm the user actually exists locally — guards against typos that would
# install a dangling rule.
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  echo "decaf-install-sudoers: user '$USER_NAME' does not exist" >&2
  exit 2
fi

TARGET="/etc/sudoers.d/decaf"
TMP=$(mktemp /tmp/decaf.sudoers.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat >"$TMP" <<EOF
# Installed by decaf-install-sudoers. Grants $USER_NAME passwordless
# access to exactly the two pmset toggles Decaf needs for closed-lid mode.
# Remove with: sudo rm /etc/sudoers.d/decaf
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -b disablesleep 0, /usr/bin/pmset -b disablesleep 1
EOF

chown root:wheel "$TMP"
chmod 0440 "$TMP"

# Validate BEFORE moving into /etc/sudoers.d — a broken file there would
# break sudo system-wide on next invocation.
if ! /usr/sbin/visudo -cf "$TMP" >/dev/null; then
  echo "decaf-install-sudoers: visudo validation failed; aborting" >&2
  exit 3
fi

mv "$TMP" "$TARGET"
trap - EXIT

echo "decaf-install-sudoers: installed $TARGET for $USER_NAME"
