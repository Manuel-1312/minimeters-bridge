#!/bin/bash
# minimeters-bridge installer for macOS (bash 3.2 compatible).
#
#   bash install-macos.sh
#
# - finds Python 3.10+ (Homebrew / python.org)
# - copies the bridge to ~/Library/Application Support/MiniMetersBridge and builds a private venv
# - registers a LaunchAgent that starts it at login and keeps it running
# - checks for a loopback device (BlackHole…) and that ws://127.0.0.1:8985 is listening
# Remove everything with: bash uninstall-macos.sh
set -euo pipefail

LABEL="io.github.manuel-1312.minimeters-bridge"
APP="$HOME/Library/Application Support/MiniMetersBridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[33m  %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mX  %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '\033[33m   %s\033[0m\n' "$2"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "This installer is for macOS." "On Linux follow 'Install (macOS / Linux)' in README.md."
[ -f "$SRC/bridge.py" ] || fail "bridge.py not found next to this script." "Run it from the extracted minimeters-bridge folder."

step "Looking for Python 3.10+"
PY=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(sys.version_info<(3,10))' 2>/dev/null; then
        PY="$(command -v "$c")"; break
    fi
done
[ -n "$PY" ] || fail "Python 3.10 or newer is required." "Install it with:  brew install python@3.12   (or from python.org), then run this again."
ok "$("$PY" -V) at $PY"

step "Installing to $APP"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true  # parar la versión anterior antes de tocar sus ficheros
mkdir -p "$APP"
cp "$SRC/bridge.py" "$SRC/requirements.txt" "$SRC/test_client.py" "$APP/"
"$PY" -m venv "$APP/.venv"
"$APP/.venv/bin/python" -m pip install -q --upgrade pip
"$APP/.venv/bin/python" -m pip install -q --only-binary=:all: -r "$APP/requirements.txt" \
    || fail "Could not install the Python packages." "Check your internet connection and run this again."
ok "virtual environment ready"

step "Checking for a loopback audio device"
DEVICES="$("$APP/.venv/bin/python" "$APP/bridge.py" --list-devices 2>/dev/null || true)"
if grep -qiE 'blackhole|loopback|soundflower|background music|vb-cable' <<<"$DEVICES"; then
    ok "found: $(grep -iE 'blackhole|loopback|soundflower|background music|vb-cable' <<<"$DEVICES" | head -1 | sed "s/^ *[0-9]* *//")"
else
    warn "No loopback device found. macOS has no built-in loopback, so the bridge needs one:"
    warn "    brew install --cask blackhole-2ch    (asks for your password)"
    warn "The bridge is installed anyway and picks the device up within a few seconds once it exists."
fi

step "Registering the login item (LaunchAgent)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/.venv/bin/python</string>
        <string>$APP/bridge.py</string>
    </array>
    <key>WorkingDirectory</key><string>$APP</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$APP/stderr.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null || fail "Generated LaunchAgent is invalid: $PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST" || fail "launchctl could not load $PLIST"
ok "starts at every login and restarts if it stops"

step "Waiting for the bridge"
for _ in $(seq 1 30); do
    lsof -nP -iTCP:8985 -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 1
done
lsof -nP -iTCP:8985 -sTCP:LISTEN >/dev/null 2>&1 \
    || fail "The bridge did not start listening on port 8985." "See $APP/bridge.log and $APP/stderr.log"
ok "listening on ws://127.0.0.1:8985 (localhost only)"

cat <<EOF

MiniMeters bridge is running on ws://127.0.0.1:8985

Next:
  1. Audio MIDI Setup -> + -> Create Multi-Output Device, tick your speakers/headphones AND
     BlackHole 2ch, and select it as the system output (details in README.md).
  2. Play music and check:  "$APP/.venv/bin/python" "$APP/test_client.py" 3
     LUFS stuck at -120 = silence: macOS may be blocking audio input for the background
     process. Look for Python in System Settings -> Privacy & Security -> Microphone.
  Log: $APP/bridge.log    Uninstall: bash uninstall-macos.sh
EOF
