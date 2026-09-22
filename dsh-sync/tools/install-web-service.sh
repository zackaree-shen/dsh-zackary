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

# launchd/systemd start the service with a minimal PATH, which hides `dsh`,
# `node`, and everything installed per-user. Bake the invoking shell's PATH
# plus the standard roots into the unit so the supervisor, the `dsh` process,
# and its children all resolve; re-running this installer refreshes it.
# The nodejs.org tarball layout (~/.local/lib/nodejs/node-<ver>/bin, added to
# PATH by ~/.zshrc) is versioned, so its newest entry is prepended explicitly.
nodejs_bin_dir=""
for d in "${HOME}"/.local/lib/nodejs/node-*/bin; do
  [[ -d "$d" ]] && nodejs_bin_dir="$d"
done
BAKED_PATH="${nodejs_bin_dir:+${nodejs_bin_dir}:}${PATH}:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin"

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
    <key>PATH</key>
    <string>__BAKED_PATH__</string>
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
      -e "s|__LOG_DIR__|$LOG_DIR|g" \
      -e "s|__BAKED_PATH__|$BAKED_PATH|g" "$PLIST" > "$PLIST.tmp"
  mv "$PLIST.tmp" "$PLIST"
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST"
  echo "LaunchAgent installed and loaded: $PLIST"

  # ---------- .app bundle (Dock-able, double-clickable) ----------
  # A real bundle, not a bare script: Launchpad and Spotlight only list items
  # that are APPL bundles registered with LaunchServices, and the Dock shows a
  # generic icon unless the bundle carries a .icns of its own.
  APP="$HOME/Applications/DSH Web.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  # The repo ships ONE icon (dsh-web.ico, the Windows artwork) as the single
  # source of truth; macOS needs .icns, so the 256px frame inside the .ico is
  # converted here with the system tools. A conversion failure is non-fatal:
  # the bundle still launches, it just falls back to the generic app icon.
  ICON_LINE=""
  if [[ -f "$SCRIPT_DIR/dsh-web.ico" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    iconset_root="$(mktemp -d)"
    iconset="$iconset_root/AppIcon.iconset"
    mkdir -p "$iconset"
    if sips -s format png "$SCRIPT_DIR/dsh-web.ico" --out "$iconset/base.png" >/dev/null 2>&1; then
      icon_ok=1
      # The base frame is only 256px; larger entries are upscaled so the Dock,
      # Launchpad and Finder previews all have something to read.
      while read -r px name; do
        sips -z "$px" "$px" "$iconset/base.png" --out "$iconset/$name" >/dev/null 2>&1 || icon_ok=0
      done <<'ICON_SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
ICON_SIZES
      rm -f "$iconset/base.png"
      if [[ "$icon_ok" -eq 1 ]] && iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
        ICON_LINE='  <key>CFBundleIconFile</key><string>AppIcon</string>'
        echo "app icon installed: $APP/Contents/Resources/AppIcon.icns"
      else
        echo "Warning: could not build the .icns; the app keeps the generic icon" >&2
      fi
    else
      echo "Warning: could not read $SCRIPT_DIR/dsh-web.ico; the app keeps the generic icon" >&2
    fi
    rm -rf "$iconset_root"
  fi

  cat > "$APP/Contents/Info.plist" <<INFO_EOF
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
${ICON_LINE}
</dict>
</plist>
INFO_EOF
  cat > "$APP/Contents/MacOS/DSHWeb" <<APP_EOF
#!/bin/bash
exec "$TOOLS_DIR/dsh-web-open.command"
APP_EOF
  chmod +x "$APP/Contents/MacOS/DSHWeb"

  # Re-register the bundle so Launchpad/Spotlight pick up a changed icon or a
  # freshly created bundle right away instead of on their next periodic scan.
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 && echo "registered with LaunchServices: $APP"
  fi

  echo "app bundle created: $APP"
  echo "Tip: drag 'DSH Web.app' to the Dock, or search 'DSH Web' in Launchpad/Spotlight."
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
Environment=PATH=__BAKED_PATH__
ExecStart=/bin/bash __TOOLS_DIR__/dsh-web-server.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT_EOF
  sed -e "s|__TOOLS_DIR__|$TOOLS_DIR|g" -e "s|__PORT__|$PORT|g" -e "s|__BAKED_PATH__|$BAKED_PATH|g" "$UNIT" > "$UNIT.tmp"
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
