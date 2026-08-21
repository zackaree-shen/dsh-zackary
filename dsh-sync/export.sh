#!/usr/bin/env bash
# Export the current machine's shareable DSH config/plugins back into dsh-sync/dsh.
# This mirrors install.sh in reverse and never copies secrets/sessions/caches.
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DSH="$SCRIPT_DIR/dsh"

if [[ ! -d "$DSH_HOME" ]]; then
  echo "Local DSH home not found: $DSH_HOME" >&2
  exit 1
fi

echo "Exporting from $DSH_HOME to $REPO_DSH"

cp -f "$DSH_HOME/settings.yaml" "$REPO_DSH/settings.yaml"

# Agent presets
if [[ -d "$DSH_HOME/.agent-presets" ]]; then
  rm -rf "$REPO_DSH/.agent-presets"
  cp -R "$DSH_HOME/.agent-presets" "$REPO_DSH/.agent-presets"
fi

# Profile manifests (never node_modules)
PROFILE_FILES=(package.json pnpm-workspace.yaml cordis.yml cordis.patch.yml pnpm-lock.yaml)
rm -rf "$REPO_DSH/profiles"
mkdir -p "$REPO_DSH/profiles"
for src in "$DSH_HOME"/profiles/*/; do
  [[ -d "$src" ]] || continue
  name="$(basename "$src")"
  [[ "$name" == "node_modules" ]] && continue
  dest="$REPO_DSH/profiles/$name"
  mkdir -p "$dest"
  for file in "${PROFILE_FILES[@]}"; do
    if [[ -f "$src/$file" ]]; then
      cp -f "$src/$file" "$dest/$file"
    fi
  done
done

# Custom plugin source
PLUGIN_SRC=""
if [[ -d "$DSH_HOME/plugins/dsh-account-switcher" ]]; then
  PLUGIN_SRC="$DSH_HOME/plugins/dsh-account-switcher"
elif [[ -d "$HOME/dsh-plugins/dsh-account-switcher" ]]; then
  PLUGIN_SRC="$HOME/dsh-plugins/dsh-account-switcher"
fi
PLUGIN_DEST="$REPO_DSH/plugins/dsh-account-switcher"
PLUGIN_FILES=(package.json index.js lib/client.js cordis.patch.yml README.md smoke.mjs pnpm-lock.yaml)
if [[ -n "$PLUGIN_SRC" ]]; then
  rm -rf "$PLUGIN_DEST"
  mkdir -p "$PLUGIN_DEST/lib"
  for file in "${PLUGIN_FILES[@]}"; do
    if [[ -f "$PLUGIN_SRC/$file" ]]; then
      mkdir -p "$(dirname "$PLUGIN_DEST/$file")"
      cp -f "$PLUGIN_SRC/$file" "$PLUGIN_DEST/$file"
    fi
  done
else
  echo "Warning: custom plugin not found locally: $PLUGIN_SRC" >&2
fi

# Normalize the local absolute link to the portable relative layout.
for file in "$REPO_DSH/profiles/desktop/package.json" "$REPO_DSH/profiles/desktop/pnpm-lock.yaml"; do
  if [[ -f "$file" ]]; then
    sed -i \
      -e 's#link:C:\\Users\\Administrator\\dsh-plugins\\dsh-account-switcher#link:../../plugins/dsh-account-switcher#g' \
      -e 's#link:C:/Users/Administrator/dsh-plugins/dsh-account-switcher#link:../../plugins/dsh-account-switcher#g' \
      -e 's#link:../../../dsh-plugins/dsh-account-switcher#link:../../plugins/dsh-account-switcher#g' \
      "$file"
  fi
done

echo "Done. Review git status and commit the changes on the dev branch."
