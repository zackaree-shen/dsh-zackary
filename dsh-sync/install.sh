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
if [[ -f "$REPO_DSH/skin-center-active.json" ]]; then
  cp -f "$REPO_DSH/skin-center-active.json" "$DSH_HOME/skin-center-active.json"
fi
copy_into "$REPO_DSH/.agent-presets" "$DSH_HOME/.agent-presets"
copy_into "$REPO_DSH/plugins" "$DSH_HOME/plugins"
copy_into "$REPO_DSH/profiles" "$DSH_HOME/profiles"

# 1a. Install the dsh-sync skill into the user-level skill catalog
#     (~/.agents/skills) so every machine/endpoint can load it.
SKILL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)/.agents/skills"
SKILL_DEST="$HOME/.agents/skills"
if [[ -f "$SKILL_REPO/dsh-sync/SKILL.md" ]]; then
  mkdir -p "$SKILL_DEST"
  copy_into "$SKILL_REPO/dsh-sync" "$SKILL_DEST/dsh-sync"
  echo "dsh-sync skill installed to $SKILL_DEST/dsh-sync"
else
  echo "Warning: dsh-sync skill source not found: $SKILL_REPO/dsh-sync" >&2
fi

# 1b. Clear the recovery-page "disable" state (stored in the app's userData, not
#     ~/.dsh) so previously disabled bundles can never keep all plugins off
#     after a sync. Only touches profiles present in this DSH home.
clear_disabled_bundles() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found; cannot clear disabled bundles in $state_file" >&2
    return 0
  fi
  local local_profiles
  local_profiles="$(for p in "$DSH_HOME"/profiles/*/; do [[ -d "$p" ]] && basename "$p"; done | grep -v '^node_modules$')"
  # For each profile in the state file that exists locally, reset disabledBundles to [].
  local tmp="${state_file}.tmp"
  jq --arg profiles "$local_profiles" '
    .profiles |= map(
      if (($profiles | split("\n")) | index(.profileName)) then .disabledBundles = [] else . end
    )' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  echo "Cleared disabled-bundle state in $state_file"
}

if [[ -n "${APPDATA:-}" ]]; then
  clear_disabled_bundles "$APPDATA/DSH Desktop/plugin-management/state.json"
else
  clear_disabled_bundles "$HOME/Library/Application Support/DSH Desktop/plugin-management/state.json"
  clear_disabled_bundles "${XDG_CONFIG_HOME:-$HOME/.config}/DSH Desktop/plugin-management/state.json"
fi

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  echo "Skipped pnpm install (--skip-install)."
  echo "Done. Files copied to $DSH_HOME"
  exit 0
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "Warning: pnpm not found; files copied but dependencies were not installed." >&2
  exit 0
fi

# 1. Install each custom plugin's own dependencies. DSH loads plugin entries by
#    real path, so third-party deps must live inside the plugin directory.
if [[ -d "$DSH_HOME/plugins" ]]; then
  for plugin in "$DSH_HOME"/plugins/*/; do
    [[ -d "$plugin" ]] || continue
    [[ -f "$plugin/package.json" ]] || continue
    name="$(basename "$plugin")"
    echo "Installing plugin '$name' dependencies ..."
    (
      cd "$plugin"
      pnpm install --no-frozen-lockfile
    )
  done
fi

# 2. Install each profile's dependencies.
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
