#!/usr/bin/env bash
# macOS / Linux setup for the standalone DSH web profile:
#   1. deploy the launcher/supervisor scripts to ~/.local/share/dsh-web/tools
#   2. install an autostart agent that keeps the server running
#        macOS -> LaunchAgent  ~/Library/LaunchAgents/com.dsh.web-server.plist
#        Linux -> systemd user unit  ~/.config/systemd/user/dsh-web-server.service
#   3. create a double-clickable app entry
#        macOS -> ~/Applications/DSH Web.app  (drag to the Dock)
#        Linux -> ~/.local/share/applications/dsh-web.desktop
#   4. start the server now (idempotent)
#
# Called by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${DSH_WEB_PORT:-43120}"
TOOLS_DIR="${HOME}/.local/share/dsh-web/tools"
LOG_DIR="${HOME}/.local/share/dsh-web"
mkdir -p "$TOOLS_DIR" "$LOG_DIR"

for f in dsh-web-server.sh dsh-web-open.command; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "Missing tool: $SCRIPT_DIR/$f" >&2
    exit 1
  fi
  cp -f "$SCRIPT_DIR/$f" "$TOOLS_DIR/$f"
done
chmod +x "$TOOLS_DIR/dsh-web-server.sh" "$TOOLS_DIR/dsh-web-open.command"
echo "dsh-web tools installed to $TOOLS_DIR"

port_open() { curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null; }

OS="$(uname -s)"

if [[ "$OS" == "Darwin" ]]; then
  # ---------- LaunchAgent ----------
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST="$PLIST_DIR/com.dsh.web-server.plist"
  mkdir -p "$PLIST_DIR"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.dsh.web-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>__TOOLS_DIR__/dsh-web-server.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DSH_WEB_PORT</key>
    <string>__PORT__</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>__LOG_DIR__/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>__LOG_DIR__/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
  # Portable in-place edit (BSD `sed -i ''` and GNU `sed -i` disagree).
  sed -e "s|__TOOLS_DIR__|$TOOLS_DIR|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__LOG_DIR__|$LOG_DIR|g" "$PLIST" > "$PLIST.tmp"
  mv "$PLIST.tmp" "$PLIST"
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST"
  echo "LaunchAgent installed and loaded: $PLIST"

  # ---------- .app bundle (Dock-able, double-clickable) ----------
  APP="$HOME/Applications/DSH Web.app"
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<'INFO_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DSH Web</string>
  <key>CFBundleDisplayName</key><string>DSH Web</string>
  <key>CFBundleIdentifier</key><string>com.dsh.web</string>
  <key>CFBundleExecutable</key><string>DSHWeb</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
INFO_EOF
  cat > "$APP/Contents/MacOS/DSHWeb" <<APP_EOF
#!/bin/bash
exec "$TOOLS_DIR/dsh-web-open.command"
APP_EOF
  chmod +x "$APP/Contents/MacOS/DSHWeb"
  echo "app bundle created: $APP"
  echo "Tip: drag 'DSH Web.app' to the Dock (or copy it to /Applications)."
else
  # ---------- Linux: systemd user unit ----------
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT="$UNIT_DIR/dsh-web-server.service"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=DSH web profile server (http://127.0.0.1:__PORT__/)
After=network.target

[Service]
Type=simple
Environment=DSH_WEB_PORT=__PORT__
ExecStart=/bin/bash __TOOLS_DIR__/dsh-web-server.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT_EOF
  sed -e "s|__TOOLS_DIR__|$TOOLS_DIR|g" -e "s|__PORT__|$PORT|g" "$UNIT" > "$UNIT.tmp"
  mv "$UNIT.tmp" "$UNIT"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable --now dsh-web-server.service || true
    echo "systemd user unit installed: $UNIT"
  else
    echo "systemctl not found; unit written but not enabled: $UNIT" >&2
  fi

  # ---------- .desktop entry ----------
  APPS_DIR="$HOME/.local/share/applications"
  mkdir -p "$APPS_DIR"
  cat > "$APPS_DIR/dsh-web.desktop" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=DSH Web
Comment=Open the DSH web profile
Exec=bash $TOOLS_DIR/dsh-web-open.command
Terminal=false
Categories=Development;
DESKTOP_EOF
  echo "desktop entry created: $APPS_DIR/dsh-web.desktop"
fi

# Preflight: boot the profile once so a broken tree (credentials layout
# mismatch, missing plugin, stale link) is reported HERE instead of showing up
# later as a blank browser page.
verify_web_boot() {
  echo "Verifying the web profile boots ..."
  local out
  if out="$(dsh web --help 2>&1)"; then
    echo "web profile boot check: OK"
    return 0
  fi
  echo "Warning: web profile boot check FAILED; first lines:" >&2
  printf '%s\n' "$out" | head -n 12 >&2
  return 1
}
verify_web_boot || true

# Start now unless something already serves the port.
if port_open; then
  echo "port $PORT already served; left as is"
else
  if [[ "$OS" == "Darwin" ]]; then
    launchctl kickstart -k "gui/$(id -u)/com.dsh.web-server" >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl --user restart dsh-web-server.service >/dev/null 2>&1 || true
  else
    nohup "$TOOLS_DIR/dsh-web-server.sh" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 90); do
    port_open && break
    sleep 1
  done
  if port_open; then
    echo "server is listening on http://127.0.0.1:$PORT/"
  else
    echo "Warning: server did not come up; check $LOG_DIR/server.log" >&2
    echo "--- last 30 lines of $LOG_DIR/server.log ---" >&2
    tail -30 "$LOG_DIR/server.log" 2>/dev/null >&2 || echo "(no log yet)" >&2
  fi
fi
