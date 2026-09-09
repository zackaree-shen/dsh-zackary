#!/usr/bin/env bash
# Start the standalone DSH web server for the `web` profile, and keep it alive.
#
# No DSH Desktop required: this boots the profile with the globally installed
# `dsh` CLI. Deployed by install-web-service.sh to ~/.local/share/dsh-web/tools.
#
# - Idempotent: exits 0 immediately when the port already answers, without
#   touching the log, so a second instance (LaunchAgent + double-click) cannot
#   fail just because the first one is running.
# - Supervises: restarts the server when it exits, but gives up after 5 immediate
#   failures and leaves the cause in the log.
set -uo pipefail

PORT="${DSH_WEB_PORT:-43120}"
LOG_DIR="${HOME}/.local/share/dsh-web"
LOG="${LOG_DIR}/server.log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }

port_open() {
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null
}

# Fast path first, deliberately before any log write (see header).
if port_open; then exit 0; fi

DSH_BIN="$(command -v dsh || true)"
if [[ -z "$DSH_BIN" ]]; then
  log "dsh not found on PATH; install it with: npm i -g @deepseek-ai/dsh"
  exit 1
fi

log "supervisor start (dsh: $DSH_BIN, port: $PORT)"

fails=0
while :; do
  start="$(date +%s)"
  log "starting: $DSH_BIN web --port $PORT"
  "$DSH_BIN" web --port "$PORT" >>"$LOG" 2>&1
  code=$?
  alive=$(( $(date +%s) - start ))
  log "server exited with code $code after ${alive}s"

  if (( alive < 15 )); then
    fails=$((fails + 1))
    if (( fails >= 5 )); then
      log "gave up after 5 immediate failures; see the log above for the cause"
      exit 1
    fi
  else
    fails=0
  fi

  sleep 10
  log "restarting"
done
