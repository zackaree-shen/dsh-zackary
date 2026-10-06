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

# --- skin-center active skin (small, shareable; absent on installs without the skin center) ---
if [[ -f "$DSH_HOME/skin-center-active.json" ]]; then
  cp -f "$DSH_HOME/skin-center-active.json" "$REPO_DSH/skin-center-active.json"
fi

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
# Profiles dsh materializes itself from a shipped template on first use
# (`dsh --profile <name>`). They carry no user configuration, so exporting
# them would only add noise every time one is booted — keep them out of the repo.
EXCLUDED_PROFILES=(headless)
mkdir -p "$REPO_DSH/profiles"
for src in "$DSH_HOME"/profiles/*/; do
  [[ -d "$src" ]] || continue
  name="$(basename "$src")"
  [[ "$name" == "node_modules" ]] && continue
  for ex in "${EXCLUDED_PROFILES[@]}"; do
    [[ "$name" == "$ex" ]] && continue 2
  done
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
# Plugins that must never be exported (uninstalled / deprecated / secrets-adjacent).
EXCLUDED_PLUGINS=(dsh-account-switcher)

# Plugin name -> source path map. macOS ships bash 3.2, which has no
# associative arrays (`declare -A` aborts the whole export), so this is a
# temp directory holding one copy per plugin instead.
PLUGIN_MAP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-export-plugins.XXXXXX")"
trap 'rm -rf "$PLUGIN_MAP"' EXIT

record_plugin() {
  local name="$1" path="$2"
  for ex in "${EXCLUDED_PLUGINS[@]}"; do
    [[ "$name" == "$ex" ]] && return 0
  done
  printf '%s\n' "$path" > "$PLUGIN_MAP/$name"
}

# Portable stand-in for GNU `realpath -m` (macOS/BSD realpath rejects -m and
# no GNU coreutils are assumed). node is already a hard dependency of dsh.
resolve_path() {
  node -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "$1"
}
if ! command -v node >/dev/null 2>&1; then
  echo "Warning: node not found; skipping file:/link: plugin discovery." >&2
fi

for root in "$DSH_HOME/plugins" "$HOME/dsh-plugins"; do
  if [[ -d "$root" ]]; then
    for pdir in "$root"/*/; do
      [[ -d "$pdir" ]] || continue
      record_plugin "$(basename "$pdir")" "$(realpath "$pdir")"
    done
  fi
done

# Also discover plugins referenced as file:/link: deps in local profile manifests.
for src in "$DSH_HOME"/profiles/*/; do
  [[ -d "$src" ]] || continue
  pkg="$src/package.json"
  [[ -f "$pkg" ]] || continue
  command -v node >/dev/null 2>&1 || break
  while IFS= read -r dep_path; do
    [[ -z "$dep_path" ]] && continue
    # Resolve relative to the profile dir; keep only paths that exist.
    if [[ "$dep_path" != /* ]]; then
      dep_path="$(resolve_path "$(dirname "$pkg")/$dep_path")"
    fi
    if [[ -d "$dep_path" ]]; then
      record_plugin "$(basename "$dep_path")" "$dep_path"
    fi
  done < <(perl -ne 'while(/"((?:file|link):[^"]+)"/g){ my $v=$1; $v=~s/^(?:file|link)://; print "$v\n" }' "$pkg")
done

# Copy each plugin's source (never node_modules / .git / caches).
mkdir -p "$REPO_DSH/plugins"
for mapfile in "$PLUGIN_MAP"/*; do
  [[ -f "$mapfile" ]] || continue
  name="$(basename "$mapfile")"
  src="$(cat "$mapfile")"
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
# Done in node: the equivalent perl one-liners need backslashes, `}`, and `"`
# inside character classes, and every shell-quoting combination of those hits a
# perl parse ambiguity. node is already a hard dependency of dsh.
normalize_paths() {
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const names = JSON.parse(process.argv[2]);
    const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    let text = fs.readFileSync(file, "utf8");
    for (const name of [...names].sort((a, b) => b.length - a.length)) {
      const n = esc(name);
      text = text
        .replace(new RegExp(`(?:file|link):C:[\\\\/]Users[\\\\/][^\\r\\n"]*?${n}(?=[\\r\\n"\\s,}:])`, "g"), `link:../../plugins/${name}`)
        .replace(new RegExp(`file:(?:\\.\\./)+${n}(?=[\\r\\n"\\s,}:])`, "g"), `link:../../plugins/${name}`)
        .replace(new RegExp(`link:(?:\\.\\./)*dsh-plugins/${n}(?=[\\r\\n"\\s,}:])`, "g"), `link:../../plugins/${name}`)
        .replace(new RegExp(`directory: (?:\\.\\./)+${n}(?=[\\r\\n,}])`, "g"), `directory: ../../plugins/${name}`);
    }
    fs.writeFileSync(file, text);
  ' "$1" "$2"
}

PLUGIN_NAMES_JSON="$(node -e '
  const fs = require("node:fs");
  const dir = process.argv[1];
  const names = fs.readdirSync(dir).filter((f) => fs.statSync(`${dir}/${f}`).isFile());
  names.sort((a, b) => b.length - a.length);
  process.stdout.write(JSON.stringify(names));
' "$PLUGIN_MAP")"

for pf in "$REPO_DSH"/profiles/*/; do
  for file in package.json pnpm-lock.yaml; do
    f="$pf$file"
    [[ -f "$f" ]] || continue
    normalize_paths "$f" "$PLUGIN_NAMES_JSON"
  done
done

echo "Done. Review git status and commit the changes on the dev branch."
