#!/usr/bin/env bash
# Export the current machine's shareable DSH config/plugins back into dsh-sync/dsh.
# Mirrors install.sh in reverse; never copies secrets/sessions/caches.
# Detects every custom plugin on this machine and normalizes absolute paths.
# Usage: ./export.sh
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DSH="$SCRIPT_DIR/dsh"

if [[ ! -d "$DSH_HOME" ]]; then
  echo "Local DSH home not found: $DSH_HOME" >&2
  exit 1
fi

echo "Exporting from $DSH_HOME to $REPO_DSH"

# --- settings.yaml ---
cp -f "$DSH_HOME/settings.yaml" "$REPO_DSH/settings.yaml"

# --- Agent presets ---
if [[ -d "$DSH_HOME/.agent-presets" ]]; then
  rm -rf "$REPO_DSH/.agent-presets"
  cp -R "$DSH_HOME/.agent-presets" "$REPO_DSH/.agent-presets"
fi

# --- dsh-sync skill: pick up local edits back into the repo ---
SKILL_SRC="$HOME/.agents/skills/dsh-sync"
SKILL_DEST="$(cd "$SCRIPT_DIR/.." && pwd)/.agents/skills/dsh-sync"
if [[ -f "$SKILL_SRC/SKILL.md" ]]; then
  mkdir -p "$SKILL_DEST"
  cp -f "$SKILL_SRC/SKILL.md" "$SKILL_DEST/SKILL.md"
  echo "dsh-sync skill exported"
fi

# --- Profiles: update local ones, keep repo-only ones ---
PROFILE_FILES=(package.json pnpm-workspace.yaml cordis.yml cordis.patch.yml pnpm-lock.yaml)
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
  echo "Profile updated: $name"
done

# --- Custom plugin discovery ---
declare -A PLUGINS
for root in "$DSH_HOME/plugins" "$HOME/dsh-plugins"; do
  if [[ -d "$root" ]]; then
    for pdir in "$root"/*/; do
      [[ -d "$pdir" ]] || continue
      PLUGINS["$(basename "$pdir")"]="$(realpath "$pdir")"
    done
  fi
done

# Also discover plugins referenced as file:/link: deps in local profile manifests.
for src in "$DSH_HOME"/profiles/*/; do
  [[ -d "$src" ]] || continue
  pkg="$src/package.json"
  [[ -f "$pkg" ]] || continue
  while IFS= read -r dep_path; do
    [[ -z "$dep_path" ]] && continue
    # Resolve relative to the profile dir; keep only paths that exist.
    if [[ "$dep_path" != /* ]]; then
      dep_path="$(realpath -m "$(dirname "$pkg")/$dep_path")"
    fi
    if [[ -d "$dep_path" ]]; then
      PLUGINS["$(basename "$dep_path")"]="$dep_path"
    fi
  done < <(perl -ne 'while(/"((?:file|link):[^"]+)"/g){ my $v=$1; $v=~s/^(?:file|link)://; print "$v\n" }' "$pkg")
done

# Copy each plugin's source (never node_modules / .git / caches).
mkdir -p "$REPO_DSH/plugins"
for name in "${!PLUGINS[@]}"; do
  src="${PLUGINS[$name]}"
  dest="$REPO_DSH/plugins/$name"
  rm -rf "$dest"
  mkdir -p "$dest"
  for item in "$src"/*; do
    base="$(basename "$item")"
    case "$base" in
      node_modules|.git|.pnpm-store|cache|logs) continue ;;
    esac
    cp -R "$item" "$dest/"
  done
  echo "Plugin exported: $name  <-  $src"
done

# --- Normalize machine-specific absolute paths to the portable relative layout ---
for pf in "$REPO_DSH"/profiles/*/; do
  for file in package.json pnpm-lock.yaml; do
    f="$pf$file"
    [[ -f "$f" ]] || continue
    # Sort plugin names longest-first so a name that is a prefix of another
    # is handled correctly.
    names="$(for n in "${!PLUGINS[@]}"; do echo "$n"; done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      esc="$(printf '%s' "$name" | sed 's/[.[\*^$()+?{|}]/\\&/g')"
      perl -pi -e "
        s{(?:file|link):C:[\\\\/]Users[\\\\/][^\r\n\"]*?$esc(?=[\r\n\"\s,}:])}{link:../../plugins/$name}g;
        s{file:(?:\.\./)+$esc(?=[\r\n\"\s,}:])}{link:../../plugins/$name}g;
        s{link:(?:\.\./)*dsh-plugins/$esc(?=[\r\n\"\s,}:])}{link:../../plugins/$name}g;
        s{directory: (?:\.\./)+$esc(?=[\r\n,}])}{directory: ../../plugins/$name}g;
      " "$f"
    done <<< "$names"
  done
done

echo "Done. Review git status and commit the changes on the dev branch."
