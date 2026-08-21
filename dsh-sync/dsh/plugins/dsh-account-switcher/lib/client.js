// dsh-account-switcher browser half: the 设置 > 插件 > 插件配置 card that
// manages DeepSeek accounts and switches between them with one click.
// Self-contained by hand (no bundler): the client module system wraps this in
// a CJS factory and the kernel adopts { apply, inject } as a client plugin.
window.__ModuleLoader__.load({
  id: 'dsh-account-switcher',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')
    const { useState, useEffect, useCallback, useRef } = React

    const inject = ['slots']

    const API = {
      accounts: '/api/account-switcher/accounts',
      update: '/api/account-switcher/accounts/update',
      remove: '/api/account-switcher/accounts/delete',
      activate: '/api/account-switcher/activate',
      status: '/api/account-switcher/status',
    }

    // ---- tiny helpers -----------------------------------------------------
    function fetchJson(url, options) {
      const opts = options || {}
      opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers)
      return fetch(url, opts).then((r) => r.json())
    }
    function h(type, props) {
      const args = [type, props || null]
      for (let i = 2; i < arguments.length; i++) args.push(arguments[i])
      return React.createElement.apply(React, args)
    }
    function maskKey(key) {
      if (!key) return ''
      if (key.length <= 8) return '••••••••'
      return key.slice(0, 4) + '••••••••' + key.slice(-4)
    }

    // ---- styles (inline, theme-agnostic) -----------------------------------
    const s = {
      card: { border: '1px solid var(--dsw-border-color, rgba(128,128,128,.3))', borderRadius: '10px', padding: '14px 16px' },
      title: { margin: '0 0 4px', fontSize: '15px', fontWeight: 600 },
      desc: { margin: '0 0 12px', fontSize: '12px', opacity: 0.75 },
      row: { display: 'flex', alignItems: 'center', gap: '10px', padding: '9px 10px', borderRadius: '8px', border: '1px solid var(--dsw-border-color, rgba(128,128,128,.22))', marginBottom: '8px', flexWrap: 'wrap' },
      rowActive: { borderColor: 'var(--dsw-accent-color, #4b6fff)', background: 'rgba(75,111,255,.08)' },
      name: { fontWeight: 600, fontSize: '13px', minWidth: '120px' },
      meta: { fontSize: '12px', opacity: 0.7, flex: 1, minWidth: '120px' },
      badge: { fontSize: '11px', padding: '2px 8px', borderRadius: '999px', background: 'rgba(75,111,255,.15)', color: 'var(--dsw-accent-color, #4b6fff)' },
      badgeKey: { fontSize: '11px', padding: '2px 8px', borderRadius: '999px', background: 'rgba(128,128,128,.15)', opacity: 0.85 },
      btn: { fontSize: '12px', padding: '4px 12px', borderRadius: '6px', border: '1px solid var(--dsw-border-color, rgba(128,128,128,.4))', background: 'transparent', color: 'inherit', cursor: 'pointer' },
      btnPrimary: { background: 'var(--dsw-accent-color, #4b6fff)', color: '#fff', borderColor: 'transparent' },
      btnDanger: { color: '#e5484d', borderColor: 'rgba(229,72,77,.4)' },
      form: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px', marginTop: '12px', paddingTop: '12px', borderTop: '1px dashed var(--dsw-border-color, rgba(128,128,128,.25))' },
      field: { display: 'flex', flexDirection: 'column', gap: '3px' },
      label: { fontSize: '11px', opacity: 0.7 },
      input: { fontSize: '13px', padding: '6px 8px', borderRadius: '6px', border: '1px solid var(--dsw-border-color, rgba(128,128,128,.4))', background: 'var(--dsw-input-background, transparent)', color: 'inherit' },
      full: { gridColumn: '1 / -1' },
      actions: { display: 'flex', gap: '8px', alignItems: 'center', marginTop: '10px' },
      msg: { fontSize: '12px', marginTop: '10px', padding: '8px 10px', borderRadius: '6px' },
      msgOk: { background: 'rgba(46,160,67,.12)', color: '#2ea043' },
      msgErr: { background: 'rgba(229,72,77,.12)', color: '#e5484d' },
      empty: { fontSize: '12px', opacity: 0.65, padding: '10px 0' },
      hint: { fontSize: '11px', opacity: 0.6, marginTop: '10px', lineHeight: 1.6 },
      fieldset: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' },
    }

    // ---- main card ----------------------------------------------------------
    function AccountSwitcherCard() {
      const [accounts, setAccounts] = useState([])
      const [activeId, setActiveId] = useState(null)
      const [keyRef, setKeyRef] = useState('DEEPSEEK_API_KEY')
      const [defaultModels, setDefaultModels] = useState(['deepseek-v4-flash', 'deepseek-v4-pro'])
      const [reasoningLevels, setReasoningLevels] = useState(['off', 'low', 'high', 'max'])
      const [loading, setLoading] = useState(true)
      const [busy, setBusy] = useState(false)
      const [error, setError] = useState(null)
      const [message, setMessage] = useState(null)

      // form state
      const [editingId, setEditingId] = useState(null)
      const [name, setName] = useState('')
      const [apiKey, setApiKey] = useState('')
      const [model, setModel] = useState('deepseek-v4-flash')
      const [baseURL, setBaseURL] = useState('')
      const [reasoningEffort, setReasoningEffort] = useState('high')

      const load = useCallback(async () => {
        try {
          const [list, status] = await Promise.all([
            fetchJson(API.accounts),
            fetchJson(API.status),
          ])
          if (list.ok) {
            setAccounts(list.accounts)
            setActiveId(list.activeId)
            if (list.keyRef) setKeyRef(list.keyRef)
          } else if (list.error) setError(list.error)
          if (status.ok) {
            if (Array.isArray(status.defaultModels) && status.defaultModels.length) setDefaultModels(status.defaultModels)
            if (Array.isArray(status.reasoningLevels) && status.reasoningLevels.length) setReasoningLevels(status.reasoningLevels)
          }
        } catch (e) {
          setError(String(e && e.message ? e.message : e))
        } finally {
          setLoading(false)
        }
      }, [])

      useEffect(() => { load() }, [load])

      function showMessage(text, isError) {
        setMessage(text)
        setError(isError ? text : null)
        if (!isError) setError(null)
      }

      function resetForm() {
        setEditingId(null)
        setName('')
        setApiKey('')
        setModel(defaultModels[0] || 'deepseek-v4-flash')
        setBaseURL('')
        setReasoningEffort('high')
      }

      function startEdit(account) {
        setEditingId(account.id)
        setName(account.name)
        setApiKey('')
        setModel(account.model || defaultModels[0] || 'deepseek-v4-flash')
        setBaseURL(account.baseURL || '')
        setReasoningEffort(account.reasoningEffort || 'high')
        window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' })
      }

      async function submit(e) {
        e.preventDefault()
        if (!name.trim()) return showMessage('名称不能为空', true)
        setBusy(true)
        try {
          const body = { name: name.trim(), model, baseURL: baseURL.trim() || null, reasoningEffort }
          if (editingId) {
            body.id = editingId
            if (apiKey.trim()) body.apiKey = apiKey.trim()
            const r = await fetchJson(API.update, { method: 'POST', body: JSON.stringify(body) })
            if (!r.ok) return showMessage(r.error || '更新失败', true)
            showMessage('已更新：' + body.name)
          } else {
            if (!apiKey.trim()) return showMessage('新账号必须填写 API Key', true)
            body.apiKey = apiKey.trim()
            const r = await fetchJson(API.accounts, { method: 'POST', body: JSON.stringify(body) })
            if (!r.ok) return showMessage(r.error || '创建失败', true)
            showMessage('已添加：' + body.name + '（点「切换到此账号」启用）')
          }
          resetForm()
          await load()
        } catch (err) {
          showMessage(String(err && err.message ? err.message : err), true)
        } finally {
          setBusy(false)
        }
      }

      async function activate(account) {
        setBusy(true)
        try {
          const r = await fetchJson(API.activate, { method: 'POST', body: JSON.stringify({ id: account.id }) })
          if (!r.ok) return showMessage(r.error || '切换失败', true)
          setActiveId(account.id)
          showMessage('已切换到「' + account.name + '」(' + (account.model || '默认模型') + ')。新会话生效，当前会话保留原路由。')
        } catch (err) {
          showMessage(String(err && err.message ? err.message : err), true)
        } finally {
          setBusy(false)
        }
      }

      async function remove(account) {
        if (!window.confirm('删除账号「' + account.name + '」？不会改动 DSH 已写入的凭据。')) return
        setBusy(true)
        try {
          const r = await fetchJson(API.remove, { method: 'POST', body: JSON.stringify({ id: account.id }) })
          if (!r.ok) return showMessage(r.error || '删除失败', true)
          if (activeId === account.id) setActiveId(null)
          showMessage('已删除：' + account.name)
          if (editingId === account.id) resetForm()
          await load()
        } catch (err) {
          showMessage(String(err && err.message ? err.message : err), true)
        } finally {
          setBusy(false)
        }
      }

      const title = editingId ? '编辑账号' : '添加账号'

      return h('div', { style: s.card },
        h('h3', { style: s.title }, '账号管理 · Account Switcher'),
        h('p', { style: s.desc },
          '管理多个 DeepSeek API Key / 模型档案，一键切换（热加载免重启）。切换写入 DSH 原生凭据 ' + keyRef + ' 与默认模型，对新会话生效。'),
        h('div', { style: s.fieldset },
          h('span', { style: s.badge }, '当前 key: ' + keyRef),
          accounts.length > 0
            ? h('span', { style: s.badgeKey }, '账号 ' + accounts.length + ' 个')
            : null,
        ),

        loading
          ? h('p', { style: s.empty }, '加载中…')
          : accounts.length === 0
            ? h('p', { style: s.empty }, '还没有账号。在下方添加第一个 DeepSeek API Key。')
            : h('div', { style: { marginTop: '10px' } },
                accounts.map((account) => h('div', {
                  key: account.id,
                  style: Object.assign({}, s.row, activeId === account.id ? s.rowActive : null),
                },
                  h('span', { style: s.name }, account.name),
                  h('span', { style: s.meta },
                    account.model || '默认模型',
                    account.reasoningEffort ? ' · ' + account.reasoningEffort : '',
                    account.baseURL ? ' · 中转' : ' · 官方',
                  ),
                  account.hasKey
                    ? h('span', { style: s.badgeKey }, '✓ key')
                    : h('span', { style: s.badgeKey }, '无 key'),
                  activeId === account.id ? h('span', { style: s.badge }, '使用中') : null,
                  h('button', { type: 'button', style: Object.assign({}, s.btn, s.btnPrimary), onClick: () => activate(account), disabled: busy || activeId === account.id }, '切换'),
                  h('button', { type: 'button', style: s.btn, onClick: () => startEdit(account), disabled: busy }, '编辑'),
                  h('button', { type: 'button', style: Object.assign({}, s.btn, s.btnDanger), onClick: () => remove(account), disabled: busy }, '删除'),
                )),
              ),

        error ? h('div', { style: Object.assign({}, s.msg, s.msgErr) }, '⚠ ' + error) : null,
        message ? h('div', { style: Object.assign({}, s.msg, s.msgOk) }, '✓ ' + message) : null,

        h('form', { style: s.form, onSubmit: submit },
          h('div', { style: s.field },
            h('label', { style: s.label }, '名称 *'),
            h('input', { style: s.input, value: name, onChange: (e) => setName(e.target.value), placeholder: '如：主号 / 备用号 / 中转A' }),
          ),
          h('div', { style: s.field },
            h('label', { style: s.label }, editingId ? 'API Key（留空不改）' : 'API Key *'),
            h('input', { style: s.input, type: 'password', value: apiKey, onChange: (e) => setApiKey(e.target.value), placeholder: 'sk-…', autoComplete: 'off' }),
          ),
          h('div', { style: s.field },
            h('label', { style: s.label }, '默认模型'),
            h('select', { style: s.input, value: model, onChange: (e) => setModel(e.target.value) },
              defaultModels.map((m) => h('option', { key: m, value: m }, m)),
              h('option', { value: model }, model),
            ),
          ),
          h('div', { style: s.field },
            h('label', { style: s.label }, '推理档位'),
            h('select', { style: s.input, value: reasoningEffort, onChange: (e) => setReasoningEffort(e.target.value) },
              reasoningLevels.map((m) => h('option', { key: m, value: m }, m)),
            ),
          ),
          h('div', { style: Object.assign({}, s.field, s.full) },
            h('label', { style: s.label }, 'baseURL（中转/网关时填，官方留空）'),
            h('input', { style: s.input, value: baseURL, onChange: (e) => setBaseURL(e.target.value), placeholder: 'https://api.deepseek.com' }),
          ),
          h('div', { style: Object.assign({}, s.actions, s.full) },
            h('button', { type: 'submit', style: Object.assign({}, s.btn, s.btnPrimary), disabled: busy }, editingId ? '保存修改' : '添加账号'),
            editingId ? h('button', { type: 'button', style: s.btn, onClick: resetForm, disabled: busy }, '取消') : null,
          ),
        ),

        h('p', { style: s.hint },
          '提示：切换后对「新会话」即时生效（DSH 每请求解析凭据、settings 热加载）；当前会话保留原路由。' +
          '想手改 key？直接编辑 ' + keyRef + ' 所在的 ' + (keyRef ? '~/.dsh/.credentials.yaml' : '') + '（插件每次激活都会先备份）。'
        ),
      )
    }

    // ---- plugin wiring ------------------------------------------------------
    function apply(ctx) {
      ctx.effect(
        () =>
          ctx.slots.inject('settings.plugin.item', function* () {
            yield ctx.slots.register(
              {
                name: 'settings.plugin.item',
                key: 'dsh-account-switcher',
                id: 'dsh-account-switcher',
                order: 40,
                label: () => '账号管理',
                inject: () => ({}),
              },
              AccountSwitcherCard,
            )
          }),
        'dsh-account-switcher: settings card',
      )
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
