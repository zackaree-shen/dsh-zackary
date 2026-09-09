#!/usr/bin/env bash
# Double-click entry point (macOS Finder / Linux file manager): ensure the DSH
# web server runs, then open the web profile in an app-style browser window.
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
  echo "Log: $HOME/.local/share/dsh-web/server.log"
  read -r -p "Press Enter to exit"
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -d "/Applications/Microsoft Edge.app" ]]; then
    open -na "Microsoft Edge" --args --app="$URL"
  elif [[ -d "/Applications/Google Chrome.app" ]]; then
    open -na "Google Chrome" --args --app="$URL"
  else
    open "$URL"
  fi
else
  if command -v microsoft-edge >/dev/null 2>&1; then
    microsoft-edge --app="$URL" >/dev/null 2>&1 &
  elif command -v google-chrome >/dev/null 2>&1; then
    google-chrome --app="$URL" >/dev/null 2>&1 &
  else
    xdg-open "$URL" >/dev/null 2>&1 &
  fi
fi
