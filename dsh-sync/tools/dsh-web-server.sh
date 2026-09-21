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
# - Never opens a browser: `dsh web --no-open` keeps the server silent at login;
#   the double-click entry (dsh-web-open.command) owns every browser open.
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

# launchd (macOS) and systemd (Linux) start this script with a minimal PATH
# (/usr/bin:/bin:/usr/sbin:/sbin) that excludes every per-user install root,
# so `dsh` and `node` are resolved explicitly instead of via PATH lookup.
resolve_executable() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

DSH_BIN="$(resolve_executable "$(command -v dsh 2>/dev/null || true)" \
  "${HOME}/.local/bin/dsh" /opt/homebrew/bin/dsh /usr/local/bin/dsh || true)"
if [[ -z "$DSH_BIN" ]]; then
  log "dsh not found on PATH, in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin; install it with: npm i -g @deepseek-ai/dsh"
  exit 1
fi

NODE_BIN="$(resolve_executable "$(command -v node 2>/dev/null || true)" \
  /opt/homebrew/bin/node /usr/local/bin/node "${HOME}/.local/bin/node" \
  "${HOME}"/.local/lib/nodejs/node-*/bin/node || true)"
if [[ -z "$NODE_BIN" ]]; then
  log "node not found on PATH, in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, or ~/.local/lib/nodejs/node-*/bin; install Node.js"
  exit 1
fi
# Keep both resolved executables reachable for the server and its children;
# `dsh` itself is started as `node <bin>` below, so its shebang is bypassed.
export PATH="$(dirname "$NODE_BIN"):$(dirname "$DSH_BIN"):${PATH}"

log "supervisor start (dsh: $DSH_BIN, node: $NODE_BIN, port: $PORT)"

fails=0
while :; do
  start="$(date +%s)"
  log "starting: $NODE_BIN $DSH_BIN web --port $PORT --no-open"
  "$NODE_BIN" "$DSH_BIN" web --port "$PORT" --no-open >>"$LOG" 2>&1
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
