#!/usr/bin/env bash
# Sync shareable DSH configuration/plugins from this repo into the local DSH home.
# Usage: ./install.sh [--skip-install] [--skip-web-service] [--skip-cli]
set -euo pipefail

SKIP_INSTALL=0
SKIP_WEB_SERVICE=0
SKIP_CLI=0
DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6}"
for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=1 ;;
    --skip-web-service) SKIP_WEB_SERVICE=1 ;;
    --skip-cli) SKIP_CLI=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

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

# 1a2. Install the pre-commit hook so skill edits auto-sync back into the repo
#      on every commit (no need to remember running export for the skill).
HOOK_SRC="$SCRIPT_DIR/hooks/pre-commit"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$HOOK_SRC" ]] && [[ -d "$REPO_ROOT/.git" ]]; then
  mkdir -p "$REPO_ROOT/.git/hooks"
  cp -f "$HOOK_SRC" "$REPO_ROOT/.git/hooks/pre-commit"
  chmod +x "$REPO_ROOT/.git/hooks/pre-commit"
  echo "dsh-sync pre-commit hook installed to $REPO_ROOT/.git/hooks/pre-commit"
else
  echo "Warning: pre-commit hook not installed (source or .git missing): $HOOK_SRC" >&2
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

# 1c. Standalone runtime wiring for `dsh web` (no DSH Desktop needed).
#     1c0. The global CLI must exist.
if [[ "$SKIP_CLI" -eq 0 ]] && ! command -v dsh >/dev/null 2>&1; then
  echo "dsh CLI not found; installing @deepseek-ai/dsh@$DSH_VERSION globally ..."
  npm install -g "@deepseek-ai/dsh@$DSH_VERSION"
fi

#     1c1. The @deepseek-ai SDK must resolve from $DSH_HOME/profiles. DSH Desktop
#     provided it as junctions into its app.asar, which a plain `dsh web` cannot
#     read; point the shared node_modules at the global CLI's own dependency tree
#     instead. Machine-local wiring, deliberately not synced.
ensure_standalone_sdk() {
  local npm_root sdk_target nm probe
  npm_root="$(npm root -g 2>/dev/null || true)"
  if [[ -z "$npm_root" ]]; then
    echo "Warning: 'npm root -g' failed; skipped SDK wiring" >&2
    return 0
  fi
  sdk_target="$npm_root/@deepseek-ai/dsh/node_modules"
  if [[ ! -f "$sdk_target/@deepseek-ai/dsh-base/package.json" ]]; then
    echo "Warning: global dsh dependency tree not found: $sdk_target" >&2
    return 0
  fi
  nm="$DSH_HOME/profiles/node_modules"
  probe="$nm/@deepseek-ai/dsh-base/package.json"
  if [[ -f "$probe" ]]; then
    echo "profiles/node_modules already resolves @deepseek-ai/dsh-base"
    return 0
  fi
  if [[ -L "$nm" ]]; then
    rm -f "$nm"   # dangling symlink: remove the link only
  elif [[ -e "$nm" ]]; then
    mv "$nm" "$nm.bak-$(date +%Y%m%d-%H%M%S)"
    echo "moved unusable profiles/node_modules to a .bak sibling"
  fi
  ln -s "$sdk_target" "$nm"
  echo "profiles/node_modules -> $sdk_target"
}
ensure_standalone_sdk

install_web_service() {
  if [[ "$SKIP_WEB_SERVICE" -eq 1 ]]; then
    echo "Skipped the standalone web server (--skip-web-service)."
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/tools/install-web-service.sh" ]]; then
    bash "$SCRIPT_DIR/tools/install-web-service.sh"
  else
    echo "Warning: tools/install-web-service.sh not found" >&2
  fi
}

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  echo "Skipped pnpm install (--skip-install)."
  echo "Done. Files copied to $DSH_HOME"
  install_web_service
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

# 3. Standalone web profile: autostart agent + double-clickable app entry.
install_web_service
