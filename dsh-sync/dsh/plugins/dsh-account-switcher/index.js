/**
 * dsh-account-switcher — host half.
 *
 * cc-switch 风格的多账号管理器。账号档案（名称 / API Key / 默认模型 / 可选
 * baseURL / 推理档位）持久化在 `$DSH_HOME/storages/account-switcher.json`。
 *
 * 「激活」一个账号会做两件事，全部落到 DSH 原生文件上：
 *   1. 把该账号的 key 写入 `$DSH_HOME/.credentials.yaml` 的 DEEPSEEK_API_KEY
 *      （DSH 的 llm-deepseek 适配器按「每次请求」解析凭据，改完即生效）；
 *   2. 更新 `$DSH_HOME/settings.yaml` 的 agent-default-model（默认模型/推理
 *      档位）与可选的 llm-deepseek.baseURL —— DSH settings 是热加载的，免重启。
 *
 * 因此切换账号对「新会话」即时生效；已存在的会话保留其选中的路由（DSH
 * 原生语义），与 harness-switch / cc-switch 的体验一致。
 *
 * 安全：列表接口绝不回传已存 key，只返回 hasKey 布尔；key 仅在新增/更新时
 * 由客户端传入。
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import YAML from 'yaml'
import z from '@deepseek-ai/schemastery'

export const name = 'dsh-account-switcher'
export const inject = ['webServer']

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), '.dsh')
const STORE_PATH = join(DSH_HOME, 'storages', 'account-switcher.json')
const CREDENTIALS_PATH = join(DSH_HOME, '.credentials.yaml')
const SETTINGS_PATH = join(DSH_HOME, 'settings.yaml')
const KEY_REF = 'DEEPSEEK_API_KEY'
const STORE_VERSION = 1

// Settings namespace: registering it makes the plugin appear in the Host's
// served-namespace list, which is what lets the "插件配置" tab render our card.
const NS = 'dsh-account-switcher'
const NS_CONFIG = z.object({
  note: z.string().default('managed by dsh-account-switcher'),
})

const DEFAULT_MODELS = ['deepseek-v4-flash', 'deepseek-v4-pro']
const REASONING_LEVELS = ['off', 'low', 'high', 'max']
const MAX_BODY_BYTES = 1_000_000

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------
function timestamp() {
  const d = new Date()
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

function json(res, status, body) {
  res.statusCode = status
  res.setHeader('Content-Type', 'application/json; charset=utf-8')
  res.end(JSON.stringify(body))
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = ''
    req.on('data', (chunk) => {
      raw += chunk
      if (raw.length > MAX_BODY_BYTES) req.destroy()
    })
    req.on('end', () => {
      if (raw.length === 0) return resolve(null)
      try { resolve(JSON.parse(raw)) } catch { resolve(null) }
    })
    req.on('error', () => resolve(null))
  })
}

function newId() {
  return 'acc-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8)
}

function cleanAccountInput(body, partial) {
  const out = {}
  if (!partial || body.name !== undefined) {
    if (typeof body.name !== 'string' || body.name.trim().length === 0 || body.name.length > 64) return null
    out.name = body.name.trim()
  }
  if (body.apiKey !== undefined) {
    if (typeof body.apiKey !== 'string' || body.apiKey.trim().length === 0 || body.apiKey.length > 512) return null
    out.apiKey = body.apiKey.trim()
  }
  if (body.model !== undefined) {
    if (typeof body.model !== 'string' || body.model.trim().length === 0 || body.model.length > 128) return null
    out.model = body.model.trim()
  }
  if (body.baseURL !== undefined) {
    if (body.baseURL === '' || body.baseURL === null) out.baseURL = null
    else if (typeof body.baseURL !== 'string' || body.baseURL.length > 512) return null
    else out.baseURL = body.baseURL.trim()
  }
  if (body.reasoningEffort !== undefined) {
    if (body.reasoningEffort === '' || body.reasoningEffort === null) out.reasoningEffort = null
    else if (!REASONING_LEVELS.includes(body.reasoningEffort)) return null
    else out.reasoningEffort = body.reasoningEffort
  }
  return out
}

// ---------------------------------------------------------------------------
// durable store
// ---------------------------------------------------------------------------
let store = loadStore()

function loadStore() {
  try {
    const parsed = JSON.parse(readFileSync(STORE_PATH, 'utf8'))
    if (parsed && parsed.version === STORE_VERSION && Array.isArray(parsed.accounts)) return parsed
  } catch { /* first run or corrupt store */ }
  return { version: STORE_VERSION, accounts: [], activeId: null }
}

function saveStore(logger) {
  try {
    mkdirSync(dirname(STORE_PATH), { recursive: true })
    const tmp = STORE_PATH + '.tmp'
    writeFileSync(tmp, JSON.stringify(store, null, 2), 'utf8')
    renameSync(tmp, STORE_PATH)
  } catch (e) {
    if (logger && typeof logger.warn === 'function') logger.warn(`dsh-account-switcher: store save failed: ${String(e)}`)
  }
}

// ---------------------------------------------------------------------------
// yaml file IO (with a single rolling .bak per target)
// ---------------------------------------------------------------------------
function readYaml(path) {
  try {
    const parsed = YAML.parse(readFileSync(path, 'utf8'))
    return parsed !== null && typeof parsed === 'object' ? parsed : {}
  } catch { return null }
}

function writeYaml(path, obj, logger) {
  try {
    const text = YAML.stringify(obj)
    if (existsSync(path)) {
      try { renameSync(path, `${path}.bak-${timestamp()}`) } catch { /* backup is best-effort */ }
    }
    const tmp = `${path}.tmp-${process.pid}`
    writeFileSync(tmp, text, 'utf8')
    renameSync(tmp, path)
    return true
  } catch (e) {
    if (logger && typeof logger.warn === 'function') logger.warn(`dsh-account-switcher: write ${path} failed: ${String(e)}`)
    return false
  }
}

// ---------------------------------------------------------------------------
// activation: credentials + settings
// ---------------------------------------------------------------------------
function activateAccount(id, logger) {
  const account = store.accounts.find((a) => a.id === id)
  if (!account) return { ok: false, status: 404, error: 'unknown account' }
  if (!account.apiKey) return { ok: false, status: 400, error: `account "${account.name}" has no API key stored` }

  // 1) write the key into DSH's native credentials document
  const creds = readYaml(CREDENTIALS_PATH)
  if (creds === null) return { ok: false, status: 500, error: `cannot read ${CREDENTIALS_PATH}` }
  creds[KEY_REF] = account.apiKey
  if (!writeYaml(CREDENTIALS_PATH, creds, logger)) {
    return { ok: false, status: 500, error: `cannot write ${CREDENTIALS_PATH}` }
  }

  // 2) update settings.yaml: agent-default-model (+ optional llm-deepseek.baseURL)
  const settings = readYaml(SETTINGS_PATH)
  if (settings === null) return { ok: false, status: 500, error: `cannot read ${SETTINGS_PATH}` }
  const currentDefault = settings['agent-default-model'] ?? {}
  settings['agent-default-model'] = {
    ...currentDefault,
    provider: account.provider ?? currentDefault.provider ?? 'deepseek-official',
    model: account.model ?? currentDefault.model ?? 'deepseek-v4-flash',
  }
  if (account.reasoningEffort) settings['agent-default-model'].reasoningEffort = account.reasoningEffort
  else if (currentDefault.reasoningEffort === undefined) settings['agent-default-model'].reasoningEffort = 'high'
  if (account.baseURL) {
    settings['llm-deepseek'] = { ...(settings['llm-deepseek'] ?? {}), baseURL: account.baseURL }
  }
  if (!writeYaml(SETTINGS_PATH, settings, logger)) {
    return { ok: false, status: 500, error: `cannot write ${SETTINGS_PATH}` }
  }

  store.activeId = id
  saveStore(logger)
  return {
    ok: true,
    active: { id: account.id, name: account.name, model: account.model, provider: settings['agent-default-model'].provider },
  }
}

function publicAccounts() {
  return store.accounts.map((a) => ({
    id: a.id,
    name: a.name,
    model: a.model ?? null,
    baseURL: a.baseURL ?? null,
    reasoningEffort: a.reasoningEffort ?? null,
    hasKey: Boolean(a.apiKey),
  }))
}

// ---------------------------------------------------------------------------
// routes
// ---------------------------------------------------------------------------
export function apply(ctx, config) {
  // Register a settings namespace so the plugin shows up in the served
  // namespaces of settings.describe() — the "插件配置" tab only renders cards
  // whose key is in that list. ctx.inject waits for the settings service to be
  // ready (the namespace registration is a fiber-level effect, auto-disposed).
  ctx.inject(['settings'], (sctx) => {
    try {
      sctx.settings.register(NS, NS_CONFIG, { base: config })
    } catch (e) {
      if (ctx.logger && typeof ctx.logger.warn === 'function') {
        ctx.logger.warn(`dsh-account-switcher: settings namespace registration failed: ${String(e)}`)
      }
    }
  })

  ctx.effect(() => {
    const disposers = []

    // GET /api/account-switcher/accounts  → list
    // POST /api/account-switcher/accounts → create
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: '/api/account-switcher/accounts',
      handler: async (req, res) => {
        if (req.method === 'GET') {
          return json(res, 200, { ok: true, accounts: publicAccounts(), activeId: store.activeId, keyRef: KEY_REF })
        }
        if (req.method === 'POST') {
          const body = await readBody(req)
          const input = body !== null && typeof body === 'object' ? cleanAccountInput(body, false) : null
          if (input === null) return json(res, 400, { ok: false, error: 'invalid account: name/apiKey/model required' })
          const account = { id: newId(), ...input }
          store.accounts.push(account)
          saveStore(ctx.logger)
          return json(res, 200, { ok: true, account: publicAccounts().find((a) => a.id === account.id) })
        }
        return json(res, 405, { ok: false, error: 'method-not-allowed' })
      },
    }))

    // POST /api/account-switcher/accounts/update → { id, ...fields }
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: '/api/account-switcher/accounts/update',
      handler: async (req, res) => {
        if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'method-not-allowed' })
        const body = await readBody(req)
        if (body === null || typeof body.id !== 'string') return json(res, 400, { ok: false, error: 'id required' })
        const account = store.accounts.find((a) => a.id === body.id)
        if (!account) return json(res, 404, { ok: false, error: 'unknown account' })
        const patch = cleanAccountInput(body, true)
        if (patch === null) return json(res, 400, { ok: false, error: 'invalid fields' })
        Object.assign(account, patch)
        saveStore(ctx.logger)
        return json(res, 200, { ok: true, account: publicAccounts().find((a) => a.id === account.id) })
      },
    }))

    // POST /api/account-switcher/accounts/delete → { id }
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: '/api/account-switcher/accounts/delete',
      handler: async (req, res) => {
        if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'method-not-allowed' })
        const body = await readBody(req)
        if (body === null || typeof body.id !== 'string') return json(res, 400, { ok: false, error: 'id required' })
        const index = store.accounts.findIndex((a) => a.id === body.id)
        if (index === -1) return json(res, 404, { ok: false, error: 'unknown account' })
        store.accounts.splice(index, 1)
        if (store.activeId === body.id) store.activeId = null
        saveStore(ctx.logger)
        return json(res, 200, { ok: true })
      },
    }))

    // POST /api/account-switcher/activate → { id }
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: '/api/account-switcher/activate',
      handler: async (req, res) => {
        if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'method-not-allowed' })
        const body = await readBody(req)
        if (body === null || typeof body.id !== 'string') return json(res, 400, { ok: false, error: 'id required' })
        const result = activateAccount(body.id, ctx.logger)
        return json(res, result.status ?? 200, result.ok ? result : { ok: false, error: result.error })
      },
    }))

    // GET /api/account-switcher/status → active summary
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: '/api/account-switcher/status',
      handler: (req, res) => {
        if (req.method !== 'GET') return json(res, 405, { ok: false, error: 'method-not-allowed' })
        const active = store.accounts.find((a) => a.id === store.activeId) ?? null
        return json(res, 200, {
          ok: true,
          activeId: store.activeId,
          keyRef: KEY_REF,
          defaultModels: DEFAULT_MODELS,
          reasoningLevels: REASONING_LEVELS,
          active: active ? { id: active.id, name: active.name, model: active.model, hasKey: Boolean(active.apiKey) } : null,
        })
      },
    }))

    return () => { for (const dispose of disposers) dispose() }
  }, 'dsh-account-switcher: routes')
}
