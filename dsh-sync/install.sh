#!/usr/bin/env bash
# Sync shareable DSH configuration/plugins from this repo into the local DSH home.
# Usage: ./install.sh [--skip-install]
set -euo pipefail

SKIP_INSTALL=0
if [[ "${1:-}" == "--skip-install" ]]; then
  SKIP_INSTALL=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DSH="$SCRIPT_DIR/dsh"

if [[ ! -d "$REPO_DSH" ]]; then
  echo "Cannot find dsh sync source: $REPO_DSH" >&2
  exit 1
fi

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
echo "DSH_HOME = $DSH_HOME"
mkdir -p "$DSH_HOME"

copy_into() {
  local src="$1"
  local dest="$2"
  if [[ ! -d "$src" ]]; then
    echo "Skipping missing source: $src" >&2
    return
  fi
  mkdir -p "$dest"
  cp -R "$src"/. "$dest"/
}

cp -f "$REPO_DSH/settings.yaml" "$DSH_HOME/settings.yaml"
copy_into "$REPO_DSH/.agent-presets" "$DSH_HOME/.agent-presets"
copy_into "$REPO_DSH/plugins" "$DSH_HOME/plugins"
copy_into "$REPO_DSH/profiles" "$DSH_HOME/profiles"

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  echo "Skipped pnpm install (--skip-install)."
  echo "Done. Files copied to $DSH_HOME"
  exit 0
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "Warning: pnpm not found; files copied but dependencies were not installed." >&2
  exit 0
fi

for profile in "$DSH_HOME"/profiles/*/; do
  [[ -d "$profile" ]] || continue
  if [[ ! -f "$profile/package.json" ]]; then
    continue
  fi
  name="$(basename "$profile")"
  echo "Installing profile '$name' ..."
  (
    cd "$profile"
    pnpm install --no-frozen-lockfile
  )
done

echo "Done. Restart DSH Desktop if it was running."
