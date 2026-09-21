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
# The newest logged token can still be stale — a restarting server prints its
# URL only after binding, while an older instance may still answer the port —
# so candidates are verified against the live server, newest first. Tokens
# are reusable and the probe keeps no cookie, so it cannot consume the
# browser's redemption.
log="$HOME/.local/share/dsh-web/server.log"
token_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    "http://127.0.0.1:${PORT}/?${1}" 2>/dev/null || echo 000)"
  [[ "$code" != "401" && "$code" != "000" ]]
}

open_url=""
deadline=$(( $(date +%s) + 30 ))
while :; do
  # Unique tokens, newest first (portable reverse: no tail -r on GNU).
  tokens="$(grep -oE "token=[A-Za-z0-9_-]+" "$log" 2>/dev/null \
    | awk '!seen[$0]++{a[++n]=$0} END{for(i=n;i>=1;i--)print a[i]}')"
  for t in $tokens; do
    if token_ok "$t"; then open_url="http://127.0.0.1:${PORT}/?${t}"; break 2; fi
  done
  # A freshly started server may not have flushed its URL line yet.
  [[ $(date +%s) -ge $deadline ]] && break
  sleep 1
done
if [[ -z "$open_url" ]]; then
  echo "No live token found in $log; opening ${URL} without one."
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  open "${open_url:-$URL}"
else
  xdg-open "${open_url:-$URL}" >/dev/null 2>&1 &
fi
