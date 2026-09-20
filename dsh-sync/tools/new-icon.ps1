# Generate dsh-web.ico — the icon the "DSH Web" desktop shortcut uses.
#
# The committed .ico sits next to this script, so a new machine only needs the
# deployed copy (install-web-service.ps1 does that); you re-run this only when
# the artwork below changes.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\new-icon.ps1
#
# Artwork source: the harness's own favicon (the DeepSeek whale). It is read
# straight out of the installed dsh CLI, so the launcher icon always matches the
# product instead of borrowing a generic shell32 glyph. Frames cover the sizes
# Windows Explorer, the taskbar and Alt-Tab actually request; a rounded
# brand-blue tile keeps the white mark legible on light AND dark taskbars.
#
# Requires Node.js plus the `sharp` module. sharp is not installed for this repo
# on purpose: the CLI that reads this icon already ships it, so the script
# resolves it out of that tree instead of adding a dependency to dsh-sync.

[CmdletBinding()]
param(
    [string]$OutputIco
)

$ErrorActionPreference = 'Stop'

# Resolved here, not as a param() default: on Windows PowerShell 5.1
# $PSScriptRoot is still empty while parameter defaults are evaluated.
if (-not $OutputIco) { $OutputIco = Join-Path $PSScriptRoot 'dsh-web.ico' }

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    $fallback = Join-Path $env:ProgramFiles 'nodejs\node.exe'
    if (Test-Path -LiteralPath $fallback) { $node = $fallback }
}
if (-not $node) { throw 'Node.js is required to rasterize the icon artwork.' }

# The dsh CLI install: it carries both the favicon and a resolvable `sharp`.
$dshModules = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh'
if (-not (Test-Path -LiteralPath $dshModules)) { throw "dsh CLI not found at $dshModules; install it first (npm i -g @deepseek-ai/dsh)" }

$favicon = Join-Path $dshModules 'node_modules\@deepseek-ai\dsh-web-frontend\dist\favicon.svg'
if (-not (Test-Path -LiteralPath $favicon)) { throw "Missing artwork: $favicon" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-icon-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    # ASCII-only content: a UTF-8 BOM or smart punctuation would break the Node
    # run if an editor re-saves this with a different guessed encoding.
    $generator = @'
/* Render dsh-web.ico: the DeepSeek whale in white on the brand-blue tile. */
import { mkdirSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const [, , dshModules, faviconPath, outIco, workDir] = process.argv;
const require = createRequire(import.meta.url);

// Resolve sharp out of the dsh CLI tree: sharp is not a dependency of dsh-sync.
const sharp = require(require.resolve('sharp', { paths: [dshModules] }));

const BRAND_BLUE = '#4D6BFE';
const SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256];

const source = await readFile(faviconPath, 'utf8');
const pathMatch = /<path[^>]*\sd="([^"]+)"/u.exec(source);
if (!pathMatch) throw new Error('the favicon has no path geometry to reuse');
const pathData = pathMatch[1];

/**
 * Per-size geometry. Small frames use a fuller-bleed mark and a larger corner
 * radius: at 16px the default tile plus margin would spend most of the square
 * on background and the whale would read as an indistinct blob.
 */
function geometry(size) {
  if (size <= 20) return { markRatio: 0.72, radiusRatio: 0.3 };
  if (size <= 32) return { markRatio: 0.68, radiusRatio: 0.26 };
  return { markRatio: 0.62, radiusRatio: 0.22 };
}

/** One white whale centered on a rounded brand-blue tile at `size`. */
async function renderPng(size) {
  const { markRatio, radiusRatio } = geometry(size);
  const radius = Math.round(size * radiusRatio);
  const inner = Math.max(2, Math.round(size * markRatio));

  const mark = await sharp(
    Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50" width="50" height="50">` +
        `<path fill="#FFFFFF" d="${pathData}"/></svg>`,
    ),
    { density: 900 },
  )
    .resize(inner, inner, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();

  const tile = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<rect width="${size}" height="${size}" rx="${radius}" ry="${radius}" fill="${BRAND_BLUE}"/></svg>`,
  );

  return sharp(tile).composite([{ input: mark, gravity: 'centre' }]).png({ compressionLevel: 9 }).toBuffer();
}

/** ICONDIR + one ICONDIRENTRY per PNG frame. */
function buildIco(frames) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // type 1 = icon
  header.writeUInt16LE(frames.length, 4);

  const directory = Buffer.alloc(16 * frames.length);
  let offset = header.length + directory.length;

  frames.forEach((frame, index) => {
    const entry = index * 16;
    // 256px is stored as 0 in the single-byte width/height fields.
    directory.writeUInt8(frame.size >= 256 ? 0 : frame.size, entry);
    directory.writeUInt8(frame.size >= 256 ? 0 : frame.size, entry + 1);
    directory.writeUInt8(0, entry + 2); // palette colours
    directory.writeUInt8(0, entry + 3); // reserved
    directory.writeUInt16LE(1, entry + 4); // colour planes
    directory.writeUInt16LE(32, entry + 6); // bits per pixel
    directory.writeUInt32LE(frame.png.length, entry + 8);
    directory.writeUInt32LE(offset, entry + 12);
    offset += frame.png.length;
  });

  return Buffer.concat([header, directory, ...frames.map((frame) => frame.png)]);
}

mkdirSync(workDir, { recursive: true });

const frames = [];
for (const size of SIZES) {
  const png = await renderPng(size);
  frames.push({ size, png });
  // Kept out of the repo: only the .ico is shared.
  writeFileSync(`${workDir}/preview-${size}.png`, png);
}

writeFileSync(outIco, buildIco(frames));
console.log(`wrote ${outIco} (frames: ${SIZES.join(', ')}px)`);
'@

    $generatorPath = Join-Path $work 'build-icon.mjs'
    Set-Content -Path $generatorPath -Value $generator -Encoding UTF8

    & $node $generatorPath $dshModules $favicon $OutputIco $work
    if ($LASTEXITCODE -ne 0) { throw "icon generation failed with exit code $LASTEXITCODE" }
    Write-Host "Icon written: $OutputIco" -ForegroundColor Green
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
