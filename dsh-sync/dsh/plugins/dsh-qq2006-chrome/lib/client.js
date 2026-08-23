// dsh-qq2006-chrome browser half.
//
// Injects the classic QQ2006 window chrome (title bar with penguin + window
// buttons, status bar with online dot) ONLY while the skin-center v2 skin
// "qq2006" is active on <html data-dsh-skin>. Any other skin (or no skin)
// removes the chrome. The chrome class names match the qq2006 user skin's
// skin.css (aCxTRG_qq*), which the skin-center serves scoped under
// html[data-dsh-skin="qq2006"].
//
// The skin-center user-skin contract forbids hooks.mjs for non-builtin skins,
// so the chrome lives here as a standalone client plugin instead.
window.__ModuleLoader__.load({
  id: 'dsh-qq2006-chrome',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    /** The skin id this plugin decorates. */
    const SKIN_ID = 'qq2006'
    const SKIN_TITLE = 'QQ2006 · DeepSeek 在线'

    const PENGUIN_SVG = [
      '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 48 48" aria-hidden="true">',
      '<ellipse cx="24" cy="27" rx="15" ry="18" fill="#20252b"/>',
      '<ellipse cx="24" cy="31" rx="9.5" ry="12.5" fill="#f7f7f7"/>',
      '<ellipse cx="24" cy="13" rx="11.5" ry="10" fill="#20252b"/>',
      '<ellipse cx="24" cy="14.5" rx="7.5" ry="5.8" fill="#f7f7f7"/>',
      '<circle cx="20" cy="12.5" r="2" fill="#fff"/><circle cx="20" cy="12.5" r="1" fill="#101010"/>',
      '<circle cx="28" cy="12.5" r="2" fill="#fff"/><circle cx="28" cy="12.5" r="1" fill="#101010"/>',
      '<polygon points="24,15 21.5,17.3 24,18.7 26.5,17.3" fill="#ff9a16"/>',
      '<rect x="13" y="20" width="22" height="5" rx="2" fill="#e93222"/>',
      '<path d="M14 24 q-3 5 -1 9 q2 -1 3 -7z" fill="#e93222"/>',
      '<ellipse cx="19" cy="45" rx="5" ry="2.5" fill="#ff9a16"/>',
      '<ellipse cx="29" cy="45" rx="5" ry="2.5" fill="#ff9a16"/>',
      '</svg>',
    ].join('')

    /** The class names shared with the qq2006 skin.css. */
    const CLS = {
      titlebar: 'aCxTRG_qqTitlebar',
      icon: 'aCxTRG_qqIcon',
      title: 'aCxTRG_qqTitle',
      windowButton: 'aCxTRG_qqWindowButton',
      statusbar: 'aCxTRG_qqStatusbar',
      online: 'aCxTRG_qqOnline',
    }

    /** True while the chrome is mounted. */
    let mounted = false

    function buildTitlebar() {
      const bar = document.createElement('div')
      bar.className = CLS.titlebar
      bar.dataset.skinChrome = 'titlebar'
      const icon = document.createElement('span')
      icon.className = CLS.icon
      icon.innerHTML = PENGUIN_SVG
      const title = document.createElement('span')
      title.className = CLS.title
      title.textContent = SKIN_TITLE
      bar.append(icon, title)
      for (const glyph of ['_', '□', '×']) {
        const btn = document.createElement('span')
        btn.className = CLS.windowButton
        btn.setAttribute('aria-hidden', 'true')
        btn.textContent = glyph
        bar.append(btn)
      }
      return bar
    }

    function buildStatusbar() {
      const bar = document.createElement('div')
      bar.className = CLS.statusbar
      bar.dataset.skinChrome = 'statusbar'
      const online = document.createElement('span')
      online.className = CLS.online
      online.textContent = '在线'
      const ready = document.createElement('span')
      ready.textContent = 'QQ2006 · Ready'
      bar.append(online, ready)
      return bar
    }

    function mount() {
      if (mounted || typeof document === 'undefined' || !document.body) return
      const titlebar = buildTitlebar()
      const statusbar = buildStatusbar()
      document.body.append(titlebar, statusbar)
      mounted = true
    }

    function unmount() {
      if (!mounted) return
      document.querySelectorAll('[data-skin-chrome="titlebar"],[data-skin-chrome="statusbar"]').forEach((el) => {
        if (el.classList.contains(CLS.titlebar) || el.classList.contains(CLS.statusbar)) el.remove()
      })
      mounted = false
    }

    /** Reconcile the chrome with the active skin attribute. */
    function reconcile() {
      const active = document.documentElement?.getAttribute('data-dsh-skin') || null
      if (active === SKIN_ID) mount()
      else unmount()
    }

    /** @returns {() => void} disposer */
    function apply() {
      if (typeof document === 'undefined') return () => {}
      reconcile()
      const observer = new MutationObserver(reconcile)
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['data-dsh-skin'],
      })
      return () => {
        observer.disconnect()
        unmount()
      }
    }

    exports.apply = apply
    return module.exports
  },
})
