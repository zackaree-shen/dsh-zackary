#!/usr/bin/env bash
# Double-click entry point (macOS Finder / Linux file manager): ensure the DSH
# web server runs, then open the web profile in the default browser.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${DSH_WEB_PORT:-43120}"
# A cold `dsh web` boot loads the whole plugin tree and has been measured at
# 42-250s, so a fixed 90s budget reported a failure while the server was still
# starting. Wait on the condition instead, with prompt feedback and a hard cap.
TIMEOUT="${DSH_WEB_TIMEOUT:-300}"
URL="http://127.0.0.1:${PORT}/"
LOG="$HOME/.local/share/dsh-web/server.log"

port_open() { curl -s -o /dev/null --max-time 3 "$URL" 2>/dev/null; }

# Only lines written after this point are this attempt's business: the previous
# "last 30 lines" dump could surface a crash from days earlier (typically a
# stale EADDRINUSE) and make it look like the cause of this run.
log_lines=0
if [[ -f "$LOG" ]]; then log_lines="$(wc -l <"$LOG" 2>/dev/null || echo 0)"; fi
new_log_lines() { tail -n "+$((log_lines + 1))" "$LOG" 2>/dev/null; }

if ! port_open; then
  echo "Starting DSH web server (profile: web, port ${PORT}) ..."
  nohup "$SCRIPT_DIR/dsh-web-server.sh" >/dev/null 2>&1 &
  waited=0
  while (( waited < TIMEOUT )); do
    port_open && break
    # A supervisor that already gave up will never open the port: stop now and
    # show its reason instead of burning the whole timeout.
    if new_log_lines | grep -q 'gave up after 5 immediate failures'; then
      echo "The server supervisor gave up after repeated immediate failures."
      break
    fi
    if (( waited > 0 && waited % 15 == 0 )); then
      echo "  still starting (${waited}s elapsed; a cold boot can take several minutes) ..."
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
fi

if ! port_open; then
  echo "Port ${PORT} did not come up within ${TIMEOUT}s."
  if [[ -n "$(new_log_lines)" ]]; then
    echo "--- log lines written since this attempt started ($LOG) ---"
    new_log_lines | tail -30
    if new_log_lines | grep -q 'EADDRINUSE'; then
      echo "EADDRINUSE: the port is already held by another process, usually a"
      echo "leftover \"dsh web\" from an earlier start. Close it and retry."
    fi
  else
    echo "--- nothing new in the log; last 30 lines (older events, NOT this attempt) ---"
    tail -30 "$LOG" 2>/dev/null || echo "(no log yet)"
  fi
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
  tokens="$(grep -oE "token=[A-Za-z0-9_-]+" "$LOG" 2>/dev/null \
    | awk '!seen[$0]++{a[++n]=$0} END{for(i=n;i>=1;i--)print a[i]}')"
  for t in $tokens; do
    if token_ok "$t"; then open_url="http://127.0.0.1:${PORT}/?${t}"; break 2; fi
  done
  # A freshly started server may not have flushed its URL line yet.
  [[ $(date +%s) -ge $deadline ]] && break
  sleep 1
done
if [[ -z "$open_url" ]]; then
  echo "No live token found in $LOG; opening ${URL} without one."
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  open "${open_url:-$URL}"
else
  xdg-open "${open_url:-$URL}" >/dev/null 2>&1 &
fi
