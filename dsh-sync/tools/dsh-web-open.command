#!/usr/bin/env bash
# Double-click entry point (macOS Finder / Linux file manager): ensure the DSH
# web server runs, then open the web profile in the default browser.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${DSH_WEB_PORT:-43120}"
URL="http://127.0.0.1:${PORT}/"

port_open() { curl -s -o /dev/null --max-time 3 "$URL" 2>/dev/null; }

if ! port_open; then
  echo "Starting DSH web server (profile: web, port ${PORT}) ..."
  nohup "$SCRIPT_DIR/dsh-web-server.sh" >/dev/null 2>&1 &
  for _ in $(seq 1 90); do
    port_open && break
    sleep 1
  done
fi

if ! port_open; then
  echo "Port ${PORT} did not come up within 90s."
  echo "--- last 30 lines of $HOME/.local/share/dsh-web/server.log ---"
  tail -30 "$HOME/.local/share/dsh-web/server.log" 2>/dev/null || echo "(no log yet)"
  read -r -p "Press Enter to exit"
  exit 1
fi

# 0.1.5+ serves the web UI behind a boot-time token; the server prints its
# authenticated URL once per boot and the log is the only place to read it.
log="$HOME/.local/share/dsh-web/server.log"
open_url=$(grep -oE "http://127\.0\.0\.1:${PORT}/\?token=[A-Za-z0-9_-]+" "$log" 2>/dev/null | tail -1)

if [[ "$(uname -s)" == "Darwin" ]]; then
  open "${open_url:-$URL}"
else
  xdg-open "${open_url:-$URL}" >/dev/null 2>&1 &
fi
