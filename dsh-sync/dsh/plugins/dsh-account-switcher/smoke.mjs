// Smoke test for dsh-account-switcher host: create account -> activate -> verify files.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

const root = join(tmpdir(), 'dsh-acct-smoke-' + Date.now())
process.env.DSH_HOME = root
mkdirSync(join(root, 'storages'), { recursive: true })
writeFileSync(join(root, '.credentials.yaml'), 'ZAI_CODING_CN_API_KEY: old-zai\nDEEPSEEK_API_KEY: old-key\n', 'utf8')
writeFileSync(join(root, 'settings.yaml'), [
  'ui-theme:',
  '  preference: system',
  'agent-default-model:',
  '  provider: deepseek-vision',
  '  model: deepseek-v4-flash',
  '  reasoningEffort: high',
  'vision-router:',
  '  onboardingSeen: true',
  'llm-pi-ai:',
  '  providers:',
  '    zai-coding-cn:',
  '      apiKeyEnv: ZAI_CODING_CN_API_KEY',
].join('\n') + '\n', 'utf8')

const mod = await import('file:///' + 'C:/Users/Administrator/dsh-plugins/dsh-account-switcher/index.js')

function makeReq(method, body) {
  const req = { method, destroy() {} }
  req.on = (ev, cb) => { if (ev === 'data' && body !== undefined) cb(JSON.stringify(body)); if (ev === 'end') cb(); return req }
  return req
}
function makeRes() {
  return { statusCode: 0, headers: {}, setHeader(k, v) { this.headers[k] = v }, end(b) { this.body = b } }
}
function call(handler, req) {
  const res = makeRes()
  handler(req, res)
  return new Promise((resolve) => { setTimeout(() => resolve({ status: res.statusCode, json: JSON.parse(res.body || 'null') }), 20) })
}

const handlers = {}
const registeredNamespaces = []
const settingsMock = {
  register: (ns, schema, opts) => { registeredNamespaces.push(String(ns)); return { get: () => ({}), watch: () => () => {}, update: () => {}, replace: () => {} } },
}
const ctx = {
  logger: { warn: (...a) => console.log('[warn]', ...a) },
  get: (key) => (key === 'settings' ? settingsMock : undefined),
  inject: (services, cb) => { if (Array.isArray(services) && services.includes('settings')) cb({ settings: settingsMock }) },
  effect: (fn) => { fn(); return () => {} },
  webServer: { register: ({ path, handler }) => { handlers[path] = handler; return () => {} } },
}
mod.apply(ctx, {})

let failed = 0
function check(label, cond) { console.log((cond ? 'PASS' : 'FAIL') + '  ' + label); if (!cond) failed++ }

// 0. settings namespace registered (needed for the settings card to render)
check('settings namespace registered', registeredNamespaces.includes('dsh-account-switcher'))

// 1. list empty
let r = await call(handlers['/api/account-switcher/accounts'], makeReq('GET'))
check('list initially empty', r.json.ok && r.json.accounts.length === 0 && r.json.activeId === null)

// 2. create account A (official) and B (relay)
r = await call(handlers['/api/account-switcher/accounts'], makeReq('POST', { name: '主号', apiKey: 'sk-A-new', model: 'deepseek-v4-pro', reasoningEffort: 'high' }))
check('create A ok', r.json.ok && r.json.account.hasKey === true && r.json.account.apiKey === undefined)
const idA = r.json.account.id
r = await call(handlers['/api/account-switcher/accounts'], makeReq('POST', { name: '中转B', apiKey: 'sk-B-new', model: 'deepseek-v4-flash', baseURL: 'https://relay.example.com/v1' }))
check('create B ok', r.json.ok)
const idB = r.json.account.id

// 3. list shows both, no key leak
r = await call(handlers['/api/account-switcher/accounts'], makeReq('GET'))
check('list has 2 accounts', r.json.accounts.length === 2)
check('no key leak', r.json.accounts.every((a) => a.apiKey === undefined && a.hasKey === true))

// 4. activate A -> credentials + settings updated
r = await call(handlers['/api/account-switcher/activate'], makeReq('POST', { id: idA }))
check('activate A ok', r.json.ok && r.json.active.name === '主号')
const credsAfter = readFileSync(join(root, '.credentials.yaml'), 'utf8')
check('credentials key updated', credsAfter.includes('DEEPSEEK_API_KEY: sk-A-new'))
check('credentials keeps zai key', credsAfter.includes('ZAI_CODING_CN_API_KEY: old-zai'))
const settingsAfter = readFileSync(join(root, 'settings.yaml'), 'utf8')
check('settings model updated', settingsAfter.includes('model: deepseek-v4-pro'))
check('settings keeps vision-router', settingsAfter.includes('onboardingSeen: true'))
check('settings keeps llm-pi-ai', settingsAfter.includes('zai-coding-cn'))

// 5. activate B -> baseURL written, key swapped
r = await call(handlers['/api/account-switcher/activate'], makeReq('POST', { id: idB }))
check('activate B ok', r.json.ok)
const credsB = readFileSync(join(root, '.credentials.yaml'), 'utf8')
check('credentials key B', credsB.includes('DEEPSEEK_API_KEY: sk-B-new'))
const settingsB = readFileSync(join(root, 'settings.yaml'), 'utf8')
check('settings baseURL B', settingsB.includes('baseURL: https://relay.example.com/v1'))
check('settings model B', settingsB.includes('model: deepseek-v4-flash'))

// 6. update + delete
r = await call(handlers['/api/account-switcher/accounts/update'], makeReq('POST', { id: idA, name: '主号-改' }))
check('update name', r.json.ok && r.json.account.name === '主号-改')
r = await call(handlers['/api/account-switcher/accounts/delete'], makeReq('POST', { id: idA }))
check('delete A', r.json.ok)
r = await call(handlers['/api/account-switcher/accounts'], makeReq('GET'))
check('list has 1 left', r.json.accounts.length === 1)

// 7. backups exist
const fs = await import('node:fs')
const baks = fs.readdirSync(root).filter((f) => f.endsWith('.bak-') || f.includes('.bak-'))
check('backups created', baks.length >= 2)

rmSync(root, { recursive: true, force: true })
console.log(failed === 0 ? '\nALL PASS' : `\n${failed} FAILED`)
process.exit(failed === 0 ? 0 : 1)
