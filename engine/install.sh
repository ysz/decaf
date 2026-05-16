#!/usr/bin/env bash
# Standalone CLI installer (the `make cli` path). Copies the bash scripts into
# /usr/local/bin and registers the failsafe LaunchAgent. Use this when you
# want `decaf` on $PATH without the menubar app — e.g. headless/SSH boxes.
# The menubar app embeds its own copy of these scripts inside the .app bundle
# and registers its own LaunchAgent at runtime; it does NOT need this script.

set -euo pipefail

BIN_DIR="/usr/local/bin"
LA_DIR="${HOME}/Library/LaunchAgents"
LA_LABEL="com.decaf.failsafe"
LA_PLIST="${LA_DIR}/${LA_LABEL}.plist"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Installing CLI to $BIN_DIR (sudo)"

SUDO=""
if [[ ! -d "$BIN_DIR" ]]; then
  sudo mkdir -p "$BIN_DIR"
fi
if [[ ! -w "$BIN_DIR" ]]; then
  SUDO="sudo"
fi

$SUDO install -m 0755 "$SRC_DIR/decaf"                      "$BIN_DIR/decaf"
$SUDO install -m 0755 "$SRC_DIR/decaf-failsafe.sh"          "$BIN_DIR/decaf-failsafe"
$SUDO install -m 0755 "$SRC_DIR/decaf-hook.sh"              "$BIN_DIR/decaf-hook"
$SUDO install -m 0755 "$SRC_DIR/decaf-install-sudoers.sh"   "$BIN_DIR/decaf-install-sudoers"

mkdir -p "$LA_DIR"
cat > "$LA_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LA_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/decaf-failsafe</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/decaf-failsafe.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/decaf-failsafe.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$LA_PLIST" 2>/dev/null || true
launchctl load "$LA_PLIST"

echo "✓ Installed decaf, decaf-hook, decaf-failsafe, decaf-install-sudoers + failsafe LaunchAgent"
