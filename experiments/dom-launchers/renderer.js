/* Standalone DOM launcher experiment; also follows claude-ui-mod's renderer contract.
 * Only activates an existing official History sync button. No credentials, IPC,
 * account files, prompt edits, or second sync controller are involved.
 */
(function () {
  'use strict';
  function mountHistorySyncDom(doc, options = {}) {
    const win = doc.defaultView;
    const storage = options.storage || win.localStorage;
    const preferenceKey = 'claude-history-sync:dom-placement:v1';
    const placements = ['all', 'sidebar', 'header', 'floating'];
    let placement = 'all', disposed = false, queued = false, menuOpen = false;
    try { const saved = storage.getItem(preferenceKey); if (placements.includes(saved)) placement = saved; } catch {}
    const hosts = new Map();
    const cleanup = [];
    const css = `
      :host {color-scheme:light dark;font:13px/1.45 system-ui,sans-serif;color:var(--text-100,#ecece8)}
      * {box-sizing:border-box} button,select {font:inherit;color:inherit;border:1px solid var(--border-300,#666);
        border-radius:7px;background:var(--bg-100,#272727);padding:6px 10px;cursor:pointer}
      button:hover {background:var(--bg-200,#383838)} button:focus-visible,select:focus-visible {outline:2px solid #d99b77;outline-offset:2px}
      button:disabled {opacity:.55;cursor:default} .row {display:flex;gap:6px;align-items:center}
      .menu {width:260px;padding:14px;background:var(--bg-100,#272727);border:1px solid var(--border-300,#666);
        border-radius:10px;box-shadow:0 8px 28px #0004;display:flex;flex-direction:column;gap:12px}
      .menu[hidden]{display:none} .muted {opacity:.75;font-size:12px} label{display:flex;flex-direction:column;gap:5px}
      .title {font-weight:650} .sidebar {width:100%;text-align:left} .floating {box-shadow:0 4px 16px #0004}
    `;
    function host(name) {
      const node = doc.createElement('div');
      node.dataset.historySyncDom = name;
      const root = node.attachShadow({mode:'open'});
      const style = doc.createElement('style'); style.textContent = css; root.append(style);
      hosts.set(name, {node, root}); return hosts.get(name);
    }
    function button(root, key, label, handler, className = '') {
      const node = doc.createElement('button'); node.type = 'button'; node.dataset.key = key;
      node.textContent = label; node.className = className;
      node.addEventListener('click', handler); root.append(node); return node;
    }
    function nativeButton() {
      // querySelectorAll does not cross our shadow roots, and explicit exclusion
      // protects against recursion if the host's DOM representation changes.
      return [...doc.querySelectorAll('button,[role="button"]')].find(node =>
        !node.closest('[data-history-sync-dom]') && /^History sync(?:$|\s*·)/.test(node.textContent.trim()) &&
        !node.disabled && node.getAttribute('aria-disabled') !== 'true');
    }
    function open() {
      const target = nativeButton();
      if (!target) { status.textContent = 'Open a Code session with an official History sync launcher enabled.'; showMenu(true); return false; }
      showMenu(false); target.click(); return true;
    }
    const sidebar = host('sidebar');
    const sidebarButton = button(sidebar.root, 'open-sidebar', 'History sync · Sidebar', event => event.altKey ? showMenu(true) : open(), 'sidebar');
    const header = host('header');
    const headerButton = button(header.root, 'menu-header', 'History sync · Menu', () => showMenu(!menuOpen));
    headerButton.setAttribute('aria-expanded', 'false');
    const floating = host('floating');
    const floatingRow = doc.createElement('div'); floatingRow.className = 'row'; floating.root.append(floatingRow);
    const floatingButton = button(floatingRow, 'open-floating', 'History sync · Floating', open, 'floating');
    const optionsButton = button(floatingRow, 'options', '⋯', () => showMenu(!menuOpen));
    optionsButton.setAttribute('aria-label', 'Choose history sync DOM launcher placement');
    const menu = host('menu');
    const panel = doc.createElement('section'); panel.className = 'menu'; panel.hidden = true;
    panel.setAttribute('aria-label', 'History sync launcher menu'); menu.root.append(panel);
    const title = doc.createElement('div'); title.className = 'title'; title.textContent = 'History sync · DOM launchers'; panel.append(title);
    const status = doc.createElement('div'); status.className = 'muted'; panel.append(status);
    const openButton = button(panel, 'open-menu', 'Open sync settings', open);
    const label = doc.createElement('label'); label.textContent = 'Show launchers'; panel.append(label);
    const select = doc.createElement('select'); select.dataset.key = 'placement';
    for (const [value, text] of [['all','Compare all three'],['sidebar','Sidebar entry'],['header','Header menu'],['floating','Floating button']]) {
      const option = doc.createElement('option'); option.value = value; option.textContent = text; select.append(option);
    }
    select.value = placement; label.append(select);
    select.addEventListener('change', () => { placement = select.value; try {storage.setItem(preferenceKey,placement);} catch {} refresh(); });
    const evidence = doc.createElement('div'); evidence.className = 'muted'; panel.append(evidence);
    button(panel, 'close', 'Close menu', () => showMenu(false));
    function showMenu(value) {
      menuOpen = value; panel.hidden = !value; headerButton.setAttribute('aria-expanded', String(value));
      if (value) select.focus();
    }
    function refresh() {
      if (disposed || !doc.body) return;
      const sidebarAnchor = doc.querySelector('[data-testid="sidebar"],aside,[role="navigation"][aria-label*="Sidebar" i],nav[aria-label*="Sidebar" i]');
      const headerAnchor = doc.querySelector('header,[role="banner"]');
      const sidebarParent = sidebarAnchor || doc.body;
      const headerParent = headerAnchor || doc.body;
      if (sidebar.node.parentNode !== sidebarParent) sidebarParent.append(sidebar.node);
      if (header.node.parentNode !== headerParent) headerParent.append(header.node);
      if (!floating.node.isConnected) doc.body.append(floating.node);
      if (!menu.node.isConnected) doc.body.append(menu.node);
      sidebar.node.style.cssText = sidebarAnchor ? 'display:block;margin:8px;' : 'position:fixed;left:12px;top:40%;z-index:2147483000;';
      header.node.style.cssText = headerAnchor ? 'display:inline-block;margin:4px 8px;' : 'position:fixed;right:20px;top:64px;z-index:2147483000;';
      floating.node.style.cssText = 'position:fixed;right:20px;bottom:24px;z-index:2147483000;';
      menu.node.style.cssText = 'position:fixed;right:20px;top:108px;z-index:2147483001;';
      for (const [name, entry] of hosts) if (name !== 'menu') entry.node.hidden = placement !== 'all' && placement !== name;
      const ready = Boolean(nativeButton());
      for (const item of [sidebarButton, floatingButton, openButton]) item.disabled = !ready;
      status.textContent = ready ? 'Opens the existing official sync pane. Copies still require its controls.' : 'Waiting for a Code session with a visible official History sync launcher.';
      evidence.textContent = `Sidebar: ${sidebarAnchor ? 'attached to app sidebar' : 'left-edge fallback'}. Menu: ${headerAnchor ? 'attached to app header' : 'top-edge fallback'}. Alt-click Sidebar to choose placement.`;
    }
    function schedule() {
      if (queued || disposed) return; queued = true;
      win.queueMicrotask(() => { queued = false; refresh(); });
    }
    const observer = new win.MutationObserver(schedule);
    observer.observe(doc.documentElement, {subtree:true, childList:true, characterData:true});
    cleanup.push(() => observer.disconnect());
    const onKey = event => { if (event.key === 'Escape' && menuOpen) {showMenu(false);headerButton.focus();} };
    doc.addEventListener('keydown', onKey); cleanup.push(() => doc.removeEventListener('keydown',onKey));
    refresh();
    const api = {
      refresh, open,
      setPlacement(value) { if (!placements.includes(value)) return; placement=value;select.value=value;try{storage.setItem(preferenceKey,value);}catch{}refresh(); },
      snapshot() {return {placement,ready:Boolean(nativeButton()),sidebarAttached:sidebar.node.parentNode !== doc.body,headerAttached:header.node.parentNode !== doc.body};},
      dispose() { if(disposed)return;disposed=true;for(const fn of cleanup)fn();for(const item of hosts.values())item.node.remove(); },
    };
    return api;
  }
  if (typeof module === 'object' && module.exports) module.exports = {mountHistorySyncDom};
  else {
    globalThis.__historySyncDomLaunchers?.dispose();
    const mounted = mountHistorySyncDom(document);
    globalThis.__historySyncDomLaunchers = mounted;
    if (typeof ctx === 'object' && typeof ctx.onDispose === 'function') ctx.onDispose(() => {
      mounted.dispose();
      if (globalThis.__historySyncDomLaunchers === mounted) delete globalThis.__historySyncDomLaunchers;
    });
  }
})();
