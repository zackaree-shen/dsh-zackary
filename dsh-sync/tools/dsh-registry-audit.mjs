#!/usr/bin/env node
/**
 * dsh-registry-audit — find plugin registrations that collide.
 *
 * Static: scans every installed plugin bundle for slot / tab-kind / command /
 * tool / HTTP-route / loader-row registrations and reports the keys claimed by
 * more than one package. Runtime (--runtime): relaunches DSH Desktop with CDP,
 * captures the renderer console ("... already registered", slot crashes) and the
 * `[data-slot-error]` slots, then restarts it normally.
 *
 * Usage: node dsh-registry-audit.mjs [--profile a,b] [--runtime] [--json] [--quiet]
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync, spawn } from 'node:child_process';

const HOME = os.homedir();
const DSH = process.env.DSH_HOME || path.join(HOME, '.dsh');
const PROFILES = path.join(DSH, 'profiles');
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n) => { const i = argv.indexOf(n); return i > -1 ? argv[i + 1] : undefined; };
const JSON_OUT = flag('--json');
const QUIET = flag('--quiet');
const ONLY = opt('--profile')?.split(',').map((s) => s.trim()).filter(Boolean);

const SKIP_DIRS = new Set(['node_modules', '.git', 'src', 'types', 'locale', 'assets', 'preview', 'docs', 'scripts']);
const MAX_FILE = 12_000_000;

const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const exists = (p) => { try { fs.accessSync(p); return true; } catch { return false; } };

/** Every .js/.mjs/.cjs file under dir, plugin's own node_modules excluded. */
function jsFiles(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) jsFiles(p, out); }
    else if (/\.(js|mjs|cjs)$/.test(e.name)) out.push(p);
  }
  return out;
}

/** Object literals passed to `.register(`, brace-matched, with the call's own prefix. */
function registerCalls(text) {
  const out = [];
  let i = 0;
  while ((i = text.indexOf('.register(', i)) !== -1) {
    const before = text.slice(Math.max(0, i - 120), i);
    const start = text.indexOf('{', i);
    if (start === -1 || start - i > 12) { i += 10; continue; }
    let depth = 0, k = start, quote = null;
    for (; k < text.length; k++) {
      const c = text[k];
      if (quote) { if (c === '\\') { k++; continue; } if (c === quote) quote = null; continue; }
      if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
      if ('{(['.includes(c)) depth++;
      else if ('})]'.includes(c)) { depth--; if (!depth) break; }
    }
    out.push({ before, body: text.slice(start, k + 1) });
    i = k + 1;
  }
  return out;
}

const FIELD = {
  id: /(?:^|[{,\s])id\s*:\s*["'`]([\w.:@/-]+)["'`]/,
  name: /(?:^|[{,\s])name\s*:\s*["'`]([\w.:@/-]+)["'`]/,
  kind: /(?:^|[{,\s])kind\s*:\s*([^,\n}]{1,80})/,
  path: /(?:^|[{,\s])path\s*:\s*["'`]([^\w"'`]?[\/][^"'`]{1,80})["'`]/,
};
const field = (body, re) => { const m = re.exec(body); return m ? m[1].trim() : ''; };

/** `kind: SOME_CONST` -> the const's string literal in the same file, when it has one. */
function resolveConst(text, expr) {
  const name = expr.replace(/['"`]/g, '').trim();
  if (!/^[A-Za-z_$][\w$]*$/.test(name)) return null;
  const m = new RegExp(`(?:const|let|var)\\s+${name.replace(/\$/g, '\\$')}\\s*=\\s*["'\`]([\\w.:-]+)["'\`]`).exec(text);
  return m ? m[1] : null;
}

/** plugin packages: profile deps + bundle list + shared runtime tree + ~/.dsh/plugins */
function packages(profilesFilter) {
  const pkgs = new Map();
  const add = (name, dir) => { if (name && dir && !pkgs.has(name)) pkgs.set(name, dir); };
  const resolve = (profileDir, name) =>
    [path.join(profileDir, 'node_modules', name), path.join(PROFILES, 'node_modules', name)]
      .find((d) => exists(path.join(d, 'package.json')));

  const shared = path.join(PROFILES, 'node_modules');
  if (exists(shared)) {
    for (const e of fs.readdirSync(shared, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      if (e.name.startsWith('@')) {
        for (const s of fs.readdirSync(path.join(shared, e.name), { withFileTypes: true })) {
          const dir = path.join(shared, e.name, s.name);
          add(readJson(path.join(dir, 'package.json'))?.name, dir);
        }
      } else {
        const dir = path.join(shared, e.name);
        add(readJson(path.join(dir, 'package.json'))?.name, dir);
      }
    }
  }
  const selfPlugins = path.join(DSH, 'plugins');
  if (exists(selfPlugins)) {
    for (const e of fs.readdirSync(selfPlugins, { withFileTypes: true })) {
      const dir = path.join(selfPlugins, e.name);
      add(readJson(path.join(dir, 'package.json'))?.name, dir);
    }
  }
  const profileBundles = new Map();
  for (const e of fs.readdirSync(PROFILES, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name.startsWith('node_modules')) continue;
    if (profilesFilter && !profilesFilter.includes(e.name)) continue;
    const dir = path.join(PROFILES, e.name);
    const pkg = readJson(path.join(dir, 'package.json'));
    if (!pkg) continue;
    const bundles = ((pkg.dsh || {}).profile || {}).bundles || [];
    profileBundles.set(e.name, new Set(bundles));
    for (const n of new Set([...Object.keys(pkg.dependencies || {}), ...bundles])) add(n, resolve(dir, n));
  }
  return { pkgs, profileBundles };
}

function staticScan(profilesFilter) {
  const { pkgs, profileBundles } = packages(profilesFilter);
  const claims = new Map(); // registry -> Map(key -> Set(pkg))
  const claim = (registry, key, pkg) => {
    if (!key) return;
    if (!claims.has(registry)) claims.set(registry, new Map());
    const m = claims.get(registry);
    if (!m.has(key)) m.set(key, new Set());
    m.get(key).add(pkg);
  };

  for (const [pkg, dir] of pkgs) {
    for (const file of jsFiles(dir)) {
      const text = readText(file);
      if (!text || text.length > MAX_FILE) continue;

      // a registry fed a computed kind (`kind: descriptor.id`) hides its kinds behind
      // a descriptor table; those tables are `{ id, title, ..., component }` objects.
      if (/kind\s*:\s*[\w$]+\s*\.\s*id\b/.test(text)) {
        const re = /\{[\s\S]{0,200}?\bid\s*:\s*["'`]([\w.:-]+)["'`][\s\S]{0,4000}?\bcomponent\s*:/g;
        let m;
        while ((m = re.exec(text))) claim('sidebar tab kind', m[1], pkg);
      }

      for (const { before, body } of registerCalls(text)) {
        const literalKind = field(body, FIELD.kind);
        const bareKind = literalKind && !/[.``]/.test(literalKind);
        const rawKind = literalKind.replace(/^["'`]|["'`]$/g, '');
        const kind = bareKind ? rawKind : resolveConst(text, literalKind);
        const id = field(body, FIELD.id);
        const name = field(body, FIELD.name);
        const route = field(body, FIELD.path);

        if (/tab/i.test(before) && kind && /title\s*:|guide\s*:|patterns\s*:/.test(body)) {
          claim('sidebar tab kind', kind, pkg);
        } else if (/webServer/i.test(before) && route) {
          claim('http route', route, pkg);
        } else if (/slots?/i.test(before) && name.includes('.') && id) {
          // a slot allows many id-less entries; only a shared explicit id can clash
          claim('slot name+id', `${name} | ${id}`, pkg);
        } else if (/commands?\./i.test(before) && name) {
          claim('slash command', name, pkg);
        } else if (/tools?\./i.test(before) && name && !name.includes('.')) {
          claim('tool', name, pkg);
        } else if (/settings/i.test(before) && id && /title\s*:|label\s*:/.test(body)) {
          claim('settings page', id, pkg);
        }
      }
    }
  }

  // loader row ids: a second `- id:` with `disabled:` is the opt-in override, not a clash
  const rows = new Map();
  const patchFiles = [path.join(DSH, 'cordis.patch.yml')];
  for (const [prof, bundles] of profileBundles) {
    const dir = path.join(PROFILES, prof);
    patchFiles.push(path.join(dir, 'cordis.patch.yml'));
    for (const b of bundles) {
      for (const c of [path.join(dir, 'node_modules', b), path.join(PROFILES, 'node_modules', b)]) {
        if (exists(path.join(c, 'cordis.patch.yml'))) patchFiles.push(path.join(c, 'cordis.patch.yml'));
      }
    }
  }
  for (const file of new Set(patchFiles)) {
    const text = readText(file);
    let current = null;
    for (const line of text.split(/\r?\n/)) {
      const m = /^\s*-\s*id:\s*['"]?([\w.@/-]+)['"]?\s*$/.exec(line);
      if (m) { current = m[1]; continue; }
      if (current && /^\s*disabled:\s*true\s*$/.test(line)) { current = null; continue; }
      if (current && /^\s*(?:-\s*)?(?:insert|id):/.test(line)) current = null;
    }
    // plain duplicate `insert` rows inside one document are the only hostile case
    const ids = [...text.matchAll(/-\s*insert:\s*\n\s*-\s*id:\s*['"]?([\w.@/-]+)['"]?/g)].map((m) => m[1]);
    const seen = new Set();
    for (const id of ids) {
      if (seen.has(id)) {
        if (!rows.has('loader row id')) rows.set('loader row id', new Map());
        const m = rows.get('loader row id');
        if (!m.has(id)) m.set(id, new Set());
        m.get(id).add(path.relative(DSH, file));
      }
      seen.add(id);
    }
  }
  if (rows.size) for (const [k, v] of rows) claims.set(k, v);

  const conflicts = [];
  for (const [registry, keys] of claims) {
    for (const [key, who] of keys) {
      if (who.size < 2) continue;
      conflicts.push({ registry, key, packages: [...who].sort() });
    }
  }
  conflicts.sort((a, b) => a.registry.localeCompare(b.registry) || a.key.localeCompare(b.key));
  return { packagesScanned: pkgs.size, keysChecked: [...claims].reduce((n, [, m]) => n + m.size, 0), conflicts };
}

const DESKTOP_EXE = () => path.join(process.env.LOCALAPPDATA || '', 'Programs/DeepSeek Harness/DeepSeek Harness.exe');
const ELECTRON_PROC = 'DeepSeek Harness';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function ps(command) {
  return execFileSync('powershell.exe', ['-NoProfile', '-Command', command], { encoding: 'utf8' });
}

/** Relaunch Desktop with CDP, collect renderer errors + slot-error slots, restart clean. */
async function runtimeScan(waitMs = 45_000) {
  if (process.platform !== 'win32') return { skipped: 'runtime scan is Windows/DSH Desktop only' };
  const exe = DESKTOP_EXE();
  if (!exists(exe)) return { skipped: `DSH Desktop not found at ${exe}` };
  if (typeof WebSocket !== 'function') return { skipped: 'needs Node 22+ (global WebSocket)' };

  ps(`Get-Process -Name '${ELECTRON_PROC}' -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 3; 'ok'`);
  spawn(exe, ['--remote-debugging-port=9333'], { detached: true, stdio: 'ignore', cwd: path.dirname(exe) }).unref();

  const errors = new Map();
  let slots = [];
  let ws;
  try {
    let list = null;
    for (let i = 0; i < 40 && !list; i++) {
      await sleep(1500);
      try { list = await (await fetch('http://127.0.0.1:9333/json/list')).json(); } catch { /* not up yet */ }
    }
    const page = (list || []).find((t) => t.type === 'page' && t.url.startsWith('dsh-app')) || (list || []).find((t) => t.type === 'page');
    if (page) {
      ws = new WebSocket(page.webSocketDebuggerUrl);
      let id = 0;
      const note = (level, text) => {
        const key = `${level}|${text.replace(/\s+/g, ' ').slice(0, 260)}`;
        errors.set(key, (errors.get(key) || 0) + 1);
      };
      ws.addEventListener('open', () => {
        ws.send(JSON.stringify({ id: ++id, method: 'Runtime.enable' }));
        ws.send(JSON.stringify({ id: ++id, method: 'Log.enable' }));
      });
      ws.addEventListener('message', (ev) => {
        const m = JSON.parse(ev.data);
        if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) {
          note(m.params.type, m.params.args.map((a) => a.value ?? a.description ?? a.type).join(' '));
        }
        if (m.method === 'Log.entryAdded' && ['error', 'warning'].includes(m.params.entry.level)) {
          note(m.params.entry.level, m.params.entry.text || '');
        }
      });
      await sleep(waitMs);
      const domId = ++id;
      ws.send(JSON.stringify({
        id: domId, method: 'Runtime.evaluate',
        params: { expression: `JSON.stringify([...document.querySelectorAll('[data-slot-error]')].map(e=>e.getAttribute('data-slot-error')))`, returnByValue: true },
      }));
      const dom = await new Promise((resolve) => {
        const timer = setTimeout(() => resolve('[]'), 8000);
        const handler = (ev) => {
          const m = JSON.parse(ev.data);
          if (m.id === domId) { clearTimeout(timer); ws.removeEventListener('message', handler); resolve(m.result?.result?.value || '[]'); }
        };
        ws.addEventListener('message', handler);
      });
      try { slots = JSON.parse(dom); } catch { slots = []; }
    }
  } finally {
    try { ws?.close(); } catch { /* already closed */ }
    ps(`Get-Process -Name '${ELECTRON_PROC}' -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2; Start-Process -FilePath '${exe}'; 'relaunched'`);
  }
  const noise = [...errors].filter(([k]) => /already registered|slot entry crashed|is incompatible with dsh|did not activate/i.test(k));
  return { errors: [...errors].map(([k, n]) => ({ level: k.split('|')[0], count: n, text: k.split('|').slice(1).join('|') })), conflicts: noise.map(([k]) => k.split('|').slice(1).join('|')), slots };
}

const result = { static: staticScan(ONLY) };
if (flag('--runtime')) result.runtime = await runtimeScan(Number(opt('--wait') || 45_000));

if (JSON_OUT) {
  console.log(JSON.stringify(result, null, 2));
} else if (!QUIET) {
  const { packagesScanned, keysChecked, conflicts } = result.static;
  console.log(`scanned ${packagesScanned} packages / ${keysChecked} registration keys`);
  if (!conflicts.length) console.log('static: no registration key is claimed by more than one package');
  for (const c of conflicts) console.log(`  [${c.registry}] ${c.key}\n     ${c.packages.join('  vs  ')}`);
  if (result.runtime) {
    const r = result.runtime;
    if (r.skipped) console.log(`runtime: skipped (${r.skipped})`);
    else {
      console.log(`runtime: ${r.conflicts.length} conflict-ish messages, slot errors: ${r.slots.length ? r.slots.join(', ') : 'none'}`);
      for (const c of r.conflicts) console.log(`  ${c.slice(0, 200)}`);
      for (const e of r.errors.filter((x) => x.level === 'error' && !/already registered|did not activate/i.test(x.text)).slice(0, 8)) {
        console.log(`  (console) ×${e.count} ${e.text.slice(0, 160)}`);
      }
    }
  }
}
const failed = result.static.conflicts.length > 0 || (result.runtime && !result.runtime.skipped && result.runtime.conflicts.length > 0);
process.exit(failed ? 1 : 0);
