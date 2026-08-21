/**
 * dsh-realtime-sync — periodic incremental sync of external agent sessions
 * into DeepSeek Harness.
 *
 * Why this exists: dsh-chat-import already provides full-fidelity, idempotent,
 * incremental importers for 14 agent formats (claude / codex / reasonix /
 * zcode / pi / opencode / ...) plus an auto-sync loop, but that loop only
 * covers claude / codex / grokbuild. This plugin is a thin companion that
 * polls the remaining source roots (reasonix / zcode / pi / opencode by
 * default) on an interval and reuses dsh-chat-import's own machinery
 * (IMPORT_SPECS + importTranscript / importDirectory), so:
 *   - an unchanged source is skipped (already-imported),
 *   - a grown source gets ONLY its new turns appended to the same DSH session,
 *   - a truncated source is detected and reported (not silently rewritten).
 *
 * It must be installed in the same profile as dsh-chat-import (as a bundle),
 * because IMPORT_SPECS is populated when dsh-chat-import's apply registers
 * its tools. The two packages then share one module instance (same resolved
 * file URL), so the imported IMPORT_SPECS Map is the live one.
 */

// dsh-chat-import's package.json exports map does not expose lib/* subpaths,
// so we resolve them as file URLs relative to this module (both packages are
// hoisted side by side under <profile>/node_modules). This module lives at
// <profile>/node_modules/dsh-realtime-sync/lib/index.js, so '../../' is the
// profile's node_modules root.
const profileNodeModules = new URL('../../', import.meta.url)

const name = 'dsh-realtime-sync'
// Same core services dsh-chat-import consumes (fs for path ops, session
// persistence for idempotent decisions).
const inject = ['sessionPersistence', 'fs']

const DEFAULT_FORMATS = ['reasonix', 'zcode', 'pi', 'opencode']
const DEFAULT_INTERVAL_MS = 60_000
const MIN_INTERVAL_MS = 15_000
const MAX_INTERVAL_MS = 3_600_000
const STARTUP_DELAY_MS = 5_000

function clampInterval(value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return DEFAULT_INTERVAL_MS
  return Math.min(Math.max(Math.trunc(n), MIN_INTERVAL_MS), MAX_INTERVAL_MS)
}

function errorText(cause) {
  return String((cause && cause.message) || cause)
}

/**
 * Replicates dsh-chat-import's panel entry `importDiscoveryItem` for one
 * source root: stat the root, then route to the per-format single-file or
 * directory/batch importer registered in IMPORT_SPECS.
 */
async function importRoot(ctx, { IMPORT_SPECS, importTranscript, importDirectory }, format, root) {
  const spec = IMPORT_SPECS.get(format)
  if (!spec) return { mode: 'skipped', status: 'no-spec', format, root }
  // Normalize across dsh-chat-import spec shapes: 0.5.x nests io/derive/registry,
  // 0.4.x keeps flat properties (importFile/deriveArgs/registryDir/...).
  const io = spec.io || {}
  const reg = spec.registry || { dir: spec.registryDir, fingerprintKeys: spec.fingerprintKeys || [] }
  const deriveArgs =
    (spec.derive && spec.derive.args) || spec.deriveArgs || (async () => ({}))
  const collect = (spec.derive && spec.derive.collect) || spec.collect
  const importSingle =
    io.file ||
    spec.importFile ||
    ((c, t, a) =>
      importTranscript(c, t, a, spec.convert, {
        registryDir: reg.dir,
        fingerprintKeys: reg.fingerprintKeys || [],
        readText: spec.readText,
      }))
  const importBatch =
    io.dir ||
    spec.importDir ||
    ((c, d, a) =>
      importDirectory(c, d, a, {
        convert: spec.convert,
        sourceLabel: spec.sourceLabel,
        deriveArgs,
        collect,
        registryDir: reg.dir,
        fingerprintKeys: reg.fingerprintKeys || [],
        readText: spec.readText,
      }))
  const args = { path: root }
  let target
  try {
    target = await ctx.fs.resolve(root)
  } catch (cause) {
    return { mode: 'skipped', status: 'resolve-failed', format, root, error: errorText(cause) }
  }
  let info
  try {
    info = await ctx.fs.stat(target)
  } catch (cause) {
    return { mode: 'skipped', status: 'missing', format, root }
  }
  const fileArgs = { ...args, ...(await deriveArgs(target)) }
  const dirSingle = io.dirSingle || spec.dirSingle
  const alwaysBatch = io.alwaysBatch || spec.alwaysBatch
  const fileBatch = io.fileBatch || spec.fileBatch
  if (info && info.type === 'directory') {
    if (dirSingle && (await dirSingle(ctx, target))) {
      return { mode: 'single', format, ...(await importSingle(ctx, target, fileArgs)) }
    }
    return { mode: 'batch', format, ...(await importBatch(ctx, target, args)) }
  }
  if (alwaysBatch || (fileBatch && (await fileBatch(ctx, target)))) {
    return { mode: 'batch', format, ...(await importBatch(ctx, target, args)) }
  }
  return { mode: 'single', format, ...(await importSingle(ctx, target, fileArgs)) }
}

/** Compact change summary; returns '' when nothing new was imported/appended. */
function summarize(res) {
  if (!res || typeof res !== 'object') return ''
  const changed = Number(res.imported || 0) + Number(res.appended || 0)
  if (changed <= 0) return ''
  const parts = []
  for (const key of ['imported', 'appended', 'alreadyImported', 'skipped', 'failed']) {
    const value = Number(res[key] || 0)
    if (value > 0) parts.push(`${key}=${value}`)
  }
  let text = `${res.mode || '?'} ${parts.join(' ')}`
  if (res.sessionId) text += ` session=${res.sessionId}`
  return text
}

async function apply(ctx, config = {}) {
  const log = (msg) => console.log(`[dsh-realtime-sync] ${msg}`)

  let modules
  try {
    modules = await Promise.all([
      import(new URL('dsh-chat-import/lib/toolkit.mjs', profileNodeModules).href),
      import(new URL('dsh-chat-import/lib/import-core.mjs', profileNodeModules).href),
      import(new URL('dsh-chat-import/lib/discovery.mjs', profileNodeModules).href),
    ])
  } catch (cause) {
    log(`无法加载 dsh-chat-import 模块（请先安装 dsh-chat-import 到同一 profile）：${errorText(cause)}`)
    return
  }
  const [toolkit, importCore, discovery] = modules
  const { IMPORT_SPECS } = toolkit
  const { importTranscript, importDirectory } = importCore
  const { defaultRoots } = discovery

  const enabled = config.enabled !== false
  const formats =
    Array.isArray(config.formats) && config.formats.length > 0 ? config.formats : DEFAULT_FORMATS
  const intervalMs = clampInterval(config.intervalMs)
  const home = typeof config.home === 'string' && config.home ? config.home : undefined

  if (!enabled) {
    log('disabled by config')
    return
  }

  const syncOnce = async () => {
    const roots = defaultRoots(home ? { home } : undefined)
    for (const format of formats) {
      const rootOverride = config.roots && config.roots[format]
      const root = rootOverride || roots[format]
      if (!root) {
        log(`skip ${format}: no default root`)
        continue
      }
      const rootList = Array.isArray(root) ? root : [root]
      for (const singleRoot of rootList) {
        try {
          const res = await importRoot(ctx, { IMPORT_SPECS, importTranscript, importDirectory }, format, singleRoot)
          const summary = summarize(res)
          if (summary) log(`${format}: ${singleRoot} → ${summary}`)
          else if (res && res.status === 'no-spec') log(`${format}: 无 spec（dsh-chat-import 未注册该格式工具？）`)
        } catch (cause) {
          log(`${format}: ${singleRoot} FAILED: ${errorText(cause)}`)
        }
      }
    }
  }

  const bootTimer = setTimeout(() => {
    syncOnce().catch((cause) => log(`initial run failed: ${errorText(cause)}`))
  }, STARTUP_DELAY_MS)
  ctx.effect(() => () => clearTimeout(bootTimer), 'dsh-realtime-sync: boot run')

  const tickTimer = setInterval(() => {
    syncOnce().catch((cause) => log(`tick failed: ${errorText(cause)}`))
  }, intervalMs)
  ctx.effect(() => () => clearInterval(tickTimer), 'dsh-realtime-sync: poll timer')

  log(`started: formats=[${formats.join(', ')}] interval=${intervalMs}ms`)

  // Best-effort status / manual-run command.
  const commands = ctx.get('commands')
  if (commands && typeof commands.register === 'function') {
    try {
      commands.register({
        name: 'realtime-sync',
        description: 'DSH 实时会话同步：查看状态 / 立即同步 / 查看配置（status|run|config）',
        input: { hint: 'status|run|config' },
        handler: async (invocation) => {
          const action = String((invocation && invocation.rawInput) || '')
            .trim()
            .split(/\s+/)[0] || 'status'
          if (action === 'run') {
            try {
              await syncOnce()
              return { kind: 'success', text: '[dsh-realtime-sync] 已触发一轮同步，详见日志' }
            } catch (cause) {
              return { kind: 'error', text: `[dsh-realtime-sync] 同步失败：${errorText(cause)}` }
            }
          }
          if (action === 'config') {
            return {
              kind: 'success',
              text: `[dsh-realtime-sync] formats=[${formats.join(', ')}] interval=${intervalMs}ms enabled=${enabled}`,
            }
          }
          return {
            kind: 'success',
            text: `[dsh-realtime-sync] 运行中：formats=[${formats.join(', ')}] interval=${intervalMs}ms（子命令：run / config）`,
          }
        },
      })
    } catch (cause) {
      log(`命令注册失败（可忽略）：${errorText(cause)}`)
    }
  }
}

export { name, apply, inject }
