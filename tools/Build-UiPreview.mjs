// Review artifact only: embed the production controller/UI with an in-memory fixture adapter.
import { readFile, writeFile } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const controller = await readFile(new URL('mods/account-history-sync/hooks/controller.mjs', root), 'utf8');
const ui = await readFile(new URL('mods/account-history-sync/hooks/ui.mjs', root), 'utf8');
const domLaunchers = await readFile(new URL('experiments/dom-launchers/renderer.js', root), 'utf8');
const runtime = String.raw`
const A = '11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222';
const B = '33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
const profiles = [
  {Id:A, Email:'current@example.test', OrganizationId:A.split('\\')[1], Sessions:12},
  {Id:B, Email:'other@example.test', OrganizationId:B.split('\\')[1], Sessions:4},
];
let c, paneOpen = false, copies = 0, interrupted = false, ambiguous = false;
const saved = new Map([['destination', B]]), log = [];
const noopTimer = () => ({cancel(){}});
const adapter = {
  root:'Fixture only', windows:true, sessionId:async()=> 'preview', envGet:async()=> '',
  now:async()=>Date.now(), storeGet:async key=>saved.get(key), storeSet:async(key,value)=>saved.set(key,value),
  redraw:()=>queueMicrotask(draw), log:()=>{}, every:noopTimer, after:noopTimer,
  processRun:async argv=> {
    const action = argv[argv.indexOf('-Action')+1];
    log.unshift(action); draw();
    await new Promise(resolve=>setTimeout(resolve, 350));
    const result = {Ok:true, Action:action};
    if(action==='Profiles') Object.assign(result,{Profiles:profiles, CurrentProfile:ambiguous?'':A, SessionProfiles:ambiguous?[A,B]:[A]});
    if(action==='Plan') Object.assign(result,{Additions:1, Updates:1, Conflicts:1,Skipped:1,Report:[],Rows:[
      {File:'local_fixture.json',Title:'New project ideas',Action:'Add',Before:null,After:{Title:'New project ideas',Archived:false},Detail:'Saved session card'},
      {File:'local_archive.json',Title:'Release planning',Action:'Update',Before:{Title:'Old release plan',Archived:false},After:{Title:'Release planning',Archived:true},Detail:'Rename and archive',ChangedFields:['title','isArchived']},
      {File:'local_conflict.json',Title:'Account configuration',Action:'Conflict',Before:{Title:'Existing account setup',Archived:false},After:{Title:'Existing account setup',Archived:false},Detail:'CLI identities differ'},
      {File:'local_pending.json',Title:'Unfinished startup',Action:'Skipped',Before:null,After:null,Detail:'CLI session has not started'},
      {File:'local_matching.json',Title:'Documentation review',Action:'Unchanged',Before:{Title:'Documentation review',Archived:true},After:{Title:'Documentation review',Archived:true},Detail:'Already matches'},
    ]});
    if(action==='Sync') {
      copies++;
      Object.assign(result,{Additions:1, Updates:1, Backup:'C:/FixtureBackups/receipt-'+copies});
      if(interrupted) Object.assign(result,{Ok:false, Error:'Simulated destination file change. Automatic sync paused.'});
    }
    return {exitCode:result.Ok?0:1, stderr:'', stdout:JSON.stringify(result)};
  },
};
const element = type=>props=>({type,props});
const constructors = Object.fromEntries(['Box','Text','Button','Select','Input'].map(type=>[type,element(type)]));
function dom(tree) {
  if(tree==null) return document.createTextNode('');
  if(typeof tree!=='object') return document.createTextNode(String(tree));
  const p=tree.props;
  const el=document.createElement(tree.type==='Button'?'button':['Select','Input'].includes(tree.type)?'label':'div');
  if(tree.type==='Box') {
    el.className='box'; el.style.flexDirection=p.flexDirection||'row';
    el.style.flexWrap=p.flexWrap||'nowrap'; el.style.gap=(p.gap||0)*8+'px';
    if(p.padding) el.style.padding=p.padding*8+'px';
    if(p.width)el.style.width=typeof p.width==='number'?p.width*8+'px':p.width;
    if(p.flexShrink!==undefined)el.style.flexShrink=p.flexShrink;
    if(p.paddingX)el.style.paddingInline=p.paddingX*8+'px';
    if(p.paddingY)el.style.paddingBlock=p.paddingY*8+'px';
    if(p.borderStyle)el.style.border='1px solid #d6d3ca';
    for(const child of [p.children||[]].flat()) el.append(dom(child));
  } else if(tree.type==='Text') {
    el.textContent=p.children; el.className='text';
    if(p.bold) el.style.fontWeight='650';
    if(p.dimColor) el.classList.add('muted');
    if(p.color==='red') el.classList.add('error');
  } else if(tree.type==='Button') {
    el.textContent=p.label; if(p.dimColor) el.classList.add('muted');
    el.onclick=async()=>{try{await p.onPress();}catch(error){document.querySelector('#preview-error').textContent=error.message;} draw();};
  } else if(tree.type==='Input') {
    el.textContent=p.label;el.className='picker';
    const input=document.createElement('input');input.value=p.value||'';input.placeholder=p.placeholder||'';input.dataset.key=p.key;
    input.oninput=()=>p.onInput?.(input.value);input.onkeydown=event=>{if(event.key==='Enter')p.onSubmit(input.value);};el.append(input);
  } else {
    el.textContent=p.label; el.className='picker';
    const select=document.createElement('select');
    for(const option of p.options) {const node=document.createElement('option');node.value=option.value;node.textContent=option.label;select.append(node);}
    select.value=p.value; select.onchange=async()=>{await p.onSelect(select.value);draw();}; el.append(select);
  }
  return el;
}
async function openSettings(){if(!c.view.source||!c.view.target)c.showSection('accounts');paneOpen=true;draw();await c.refresh();}
async function copyPreview(text){
  const output=document.querySelector('#copy-output');output.hidden=false;output.value=text;
  if(navigator.clipboard?.writeText){try{await navigator.clipboard.writeText(text);return{isCopied:true};}catch{}}
  return{isCopied:false,reason:'use the selectable text box below'};
}
function draw(){
  if(!c)return;
  const focused=document.activeElement?.dataset?.key;
  const caret=focused?document.activeElement.selectionStart:null;
  document.querySelector('#band').replaceChildren(...(launcherVisible(c.view,'band')?[dom(renderBand(constructors,c,openSettings))]:[]));
  document.querySelector('#mode').replaceChildren(...(launcherVisible(c.view,'mode')?[dom(renderLauncher(constructors,c,openSettings,'mode'))]:[]));
  document.querySelector('#hint').replaceChildren(...(launcherVisible(c.view,'hint')?[dom(renderLauncher(constructors,c,openSettings,'hint'))]:[]));
  document.querySelector('#menu').hidden=!paneOpen;
  if(paneOpen)document.querySelector('#pane').replaceChildren(dom(renderPane(constructors,c,copyPreview)));
  if(focused){const replacement=document.querySelector('#pane input[data-key="'+focused+'"]');if(replacement){replacement.focus();replacement.setSelectionRange(caret,caret);}}
  document.querySelector('#operations').textContent=log.slice(0,8).join(' · ')||'None';
}
document.querySelector('#close').onclick=()=>{paneOpen=false;draw();};
document.addEventListener('keydown',event=>{if(event.key==='Escape'){paneOpen=false;draw();}});
document.querySelector('#failure').onchange=event=>{interrupted=event.target.checked;};
document.querySelector('#ambiguous').onchange=async event=>{ambiguous=event.target.checked;c.stop();await c.reopen();draw();};
document.querySelector('#reload').onclick=async()=>{c.stop();await c.reopen();draw();};
document.querySelector('#remove-dom').onclick=()=>{globalThis.__historySyncDomLaunchers?.dispose();delete globalThis.__historySyncDomLaunchers;};
c=createController(); await c.initialize(adapter); draw();
`;
const html = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>History sync — interactive preview</title>
<style>
:root{color-scheme:light;font:15px/1.5 system-ui,sans-serif;color:#272724;background:#f4f3ee}
*{box-sizing:border-box}body{margin:0 auto;padding:32px 20px;max-width:1000px}h1{font-size:26px;margin:8px 0}p{max-width:750px}.muted{color:#74736d}.error{color:#ad2d20}
.badge{font-size:12px;font-weight:650;letter-spacing:.1em;text-transform:uppercase;color:#7e502e}.box{display:flex;min-width:0}.text{white-space:pre-wrap;overflow-wrap:anywhere}
button,select{font:inherit;border:1px solid #d6d3ca;background:#fcfbf8;border-radius:6px;padding:5px 10px;color:inherit}button{cursor:pointer}button:hover{background:#eeeae0}button:focus-visible,select:focus-visible{outline:2px solid #996044;outline-offset:2px}
.stage{margin-top:24px;border:1px solid #d6d3ca;border-radius:12px;background:#fcfbf8;padding:20px}.conversation{height:160px;display:grid;place-items:center;color:#95938a}.prompt{margin-top:14px;padding:20px;border:1px solid #d6d3ca;border-radius:10px;color:#8b897e}.tools{display:flex;flex-wrap:wrap;align-items:center;gap:18px;margin:24px 0;font-size:13px}.tools label{display:flex;gap:6px;align-items:center}
.picker{display:flex;flex-direction:column;gap:5px}.picker select{width:100%}#menu{margin-top:20px;border:1px solid #d6d3ca;border-radius:10px;background:white;padding:12px}#menu[hidden]{display:none}.menu-top{display:flex;justify-content:space-between;align-items:center;padding:0 8px 8px;border-bottom:1px solid #e6e4dc;margin-bottom:8px;font-size:12px;color:#74736d}code{font-size:12px;overflow-wrap:anywhere}header{display:flex;align-items:center;flex-wrap:wrap;gap:12px}aside{border:1px dashed #c5c0b4;border-radius:8px;padding:10px;margin:16px 0}.footer{display:flex;flex-wrap:wrap;align-items:center;gap:12px;padding-top:8px}
</style>
<header><span class="badge">Version 0.5.0 · UI comparison</span><h1>History sync</h1></header>
<p>Compare three native locations and three DOM launchers. This preview uses the production controller and both UI implementations with fixture accounts. Every operation is simulated; it cannot read or change account files.</p>
<p class="muted">Claude supplies the final styling and pane placement. This is a layout and interaction preview. Automatic timers are disabled here; Start performs one simulated copy.</p>
<aside aria-label="Sidebar">Example Desktop sidebar</aside>
<div class="stage"><div class="conversation">Your Code conversation</div><div id="band"></div><div class="prompt">Write a prompt…</div><div class="footer"><span class="muted">Auto · Mode area</span><div id="mode"></div></div><div class="footer"><span class="muted">Prompt hint area</span><div id="hint"></div></div><section id="menu" hidden aria-label="History sync settings"><div class="menu-top"><span>Settings pane</span><button id="close">Close</button></div><div id="pane"></div></section></div>
<div class="tools"><button id="reload">Simulate session reload</button><button id="remove-dom">Remove DOM launchers</button><label><input id="failure" type="checkbox">Simulate copy failure</label><label><input id="ambiguous" type="checkbox">Session found in both accounts</label></div>
<p class="muted">Simulated helper operations: <code id="operations"></code></p><p id="preview-error" class="error"></p>
<textarea id="copy-output" hidden readonly aria-label="Selectable copy text" style="width:100%;height:160px"></textarea>
<script type="module">${controller.replaceAll('export ', '')}\n${ui.replaceAll('export ', '')}\n${runtime}\n${domLaunchers}</script></html>`;
await writeFile(new URL('docs/history-sync-preview.html', root), html);
console.log('Built docs/history-sync-preview.html with fixture-only operations.');
