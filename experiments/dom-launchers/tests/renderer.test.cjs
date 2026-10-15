const test = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {JSDOM} = require('jsdom');
const {mountHistorySyncDom} = require('../renderer.js');
function fixture(html = '<aside aria-label="Sidebar"></aside><header></header><main><button id="native">History sync · Prompt</button><textarea>Unsubmitted prompt</textarea></main>') {
  const dom = new JSDOM(html,{url:'https://claude.ai/code/fixture',runScripts:'outside-only'});
  const api = mountHistorySyncDom(dom.window.document);
  const control = (host,key) => dom.window.document.querySelector(`[data-history-sync-dom="${host}"]`).shadowRoot.querySelector(`[data-key="${key}"]`);
  return {dom,api,control,doc:dom.window.document,close(){api.dispose();dom.window.close();}};
}
test('all three DOM locations attach and proxy only the native settings button', () => {
  const f=fixture();let clicks=0;f.doc.querySelector('#native').onclick=()=>clicks++;
  assert.deepEqual(f.api.snapshot(),{placement:'all',ready:true,sidebarAttached:true,headerAttached:true});
  f.control('sidebar','open-sidebar').click();f.control('floating','open-floating').click();
  f.control('header','menu-header').click();f.control('menu','open-menu').click();
  assert.equal(clicks,3);assert.equal(f.doc.querySelector('textarea').value,'Unsubmitted prompt');
  f.close();
});
test('a missing native launcher never submits a prompt or invokes another button', () => {
  const f=fixture('<button id="send">Send</button><textarea>Draft</textarea>');let clicks=0;f.doc.querySelector('#send').onclick=()=>clicks++;
  assert.equal(f.api.open(),false);assert.equal(f.control('sidebar','open-sidebar').disabled,true);
  f.control('floating','open-floating').click();assert.equal(clicks,0);assert.equal(f.doc.querySelector('textarea').value,'Draft');f.close();
});
test('launcher resolves a fresh native button after React replaces the original', async () => {
  const f=fixture();let old=0,fresh=0;f.doc.querySelector('#native').onclick=()=>old++;
  const replacement=f.doc.createElement('button');replacement.textContent='History sync · Mode';replacement.onclick=()=>fresh++;
  f.doc.querySelector('#native').replaceWith(replacement);await Promise.resolve();
  f.control('sidebar','open-sidebar').click();assert.equal(old,0);assert.equal(fresh,1);f.close();
});
test('sidebar and header fall back without moving or deleting app content', () => {
  const f=fixture('<main><button id="native">History sync</button><p>Conversation</p></main>');
  assert.equal(f.api.snapshot().sidebarAttached,false);assert.equal(f.api.snapshot().headerAttached,false);
  assert.equal(f.doc.querySelector('p').textContent,'Conversation');
  assert.match(f.doc.querySelector('[data-history-sync-dom="sidebar"]').style.cssText,/position: fixed/);f.close();
});
test('recreated sidebar reattaches exactly one launcher', async () => {
  const f=fixture();f.doc.querySelector('aside').remove();await new Promise(r=>setImmediate(r));
  const aside=f.doc.createElement('aside');f.doc.body.prepend(aside);await new Promise(r=>setImmediate(r));
  assert.equal(aside.querySelectorAll('[data-history-sync-dom="sidebar"]').length,1);
  assert.equal(f.doc.querySelectorAll('[data-history-sync-dom="sidebar"]').length,1);f.close();
});
test('placement choice persists display only and Alt-click opens its menu without activating sync', () => {
  const f=fixture();let clicks=0;f.doc.querySelector('#native').onclick=()=>clicks++;
  f.api.setPlacement('sidebar');assert.equal(f.doc.querySelector('[data-history-sync-dom="floating"]').hidden,true);
  f.control('sidebar','open-sidebar').dispatchEvent(new f.dom.window.MouseEvent('click',{altKey:true}));
  assert.equal(clicks,0);assert.equal(f.doc.querySelector('[data-history-sync-dom="menu"]').shadowRoot.querySelector('section').hidden,false);
  f.api.dispose();const restored=mountHistorySyncDom(f.doc);assert.equal(restored.snapshot().placement,'sidebar');assert.equal(clicks,0);restored.dispose();f.close();
});
test('dispose removes injected nodes and does not modify native controls', async () => {
  const f=fixture();f.api.dispose();f.doc.querySelector('#native').textContent='History sync · Hint';await new Promise(r=>setImmediate(r));
  assert.equal(f.doc.querySelectorAll('[data-history-sync-dom]').length,0);assert.ok(f.doc.querySelector('#native'));f.close();
});
test('runtime hot reload cleanup cannot dispose its replacement', () => {
  const f=fixture();f.api.dispose();const disposers=[];
  f.dom.window.ctx={onDispose:fn=>disposers.push(fn)};
  const source=readFileSync(require.resolve('../renderer.js'),'utf8');
  f.dom.window.eval(source);const first=f.dom.window.__historySyncDomLaunchers;
  f.dom.window.eval(source);const second=f.dom.window.__historySyncDomLaunchers;
  assert.notEqual(first,second);disposers[0]();assert.equal(f.doc.querySelectorAll('[data-history-sync-dom]').length,4);
  disposers[1]();assert.equal(f.doc.querySelectorAll('[data-history-sync-dom]').length,0);f.close();
});
