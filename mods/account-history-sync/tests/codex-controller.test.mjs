import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createCodexController} from '../hooks/codex-controller.mjs';
import {renderCodexPane} from '../hooks/codex-ui.mjs';
const A='11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222';
const B='33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
const ID='local_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',CHILD='local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const elements=Object.fromEntries(['Box','Text','Button','Select','Input'].map(type=>[type,props=>({type,props})]));
const flat=tree=>Array.isArray(tree)?tree.flatMap(flat):!tree||typeof tree!=='object'?[]:[tree,...[tree.props?.children||[]].flat().flatMap(flat)];
const control=(tree,key)=>flat(tree).find(e=>e.props.key===key)?.props;
const row=(id=ID,status='Ready')=>({id,title:id===ID?'Release planning':'Child research',status,reason:'Synthetic reason',messages:12,archived:false,cwd:'C:/Sample Project',warnings:['Images are linked local files.']});
function harness(options={}){
 const calls=[],files=new Map(),saved=options.saved||new Map();let counter=0;
 const api={root:'C:/Mods/Sample Plugin',windows:true,redraw(){},storeGet:async key=>saved.get(key),storeSet:async(key,value)=>saved.set(key,value),envGet:async()=>'',readText:async file=>{if(options.readError)throw new Error('Read failed');return files.get(file);},
  async processRun(argv,init){const action=argv[argv.indexOf('-Action')+1];calls.push({action,argv,init});if(options.delay)await options.delay(action);
   if(options.fail?.(action))throw new Error('Native helper interrupted; outcome unknown.');
   let data={action};
   if(action==='Profiles')data.profiles=options.profiles||[{Id:A,Email:'one@example.test'},{Id:B,Email:'two@example.test'}];
   if(action==='Choices')Object.assign(data,{folders:options.folders||[{Path:'C:/Sample Project',Count:2}],sessions:options.sessions||[{Id:ID,Title:'Release planning',Folder:'C:/Sample Project'}]});
   if(['Plan','Resume','Import'].includes(action))Object.assign(data,{planPath:'C:/Private/codex-imports/state/plans/preview.json',codexHome:'C:/User/.codex',rows:action==='Import'?[{...row(),status:options.importStatus||'Imported',target:'synthetic-target'}]:[row(),row(CHILD,'Skipped')],receiptPath:action==='Import'?'C:/Private/receipt.json':undefined});
   if(options.data)data=options.data(action,data);
   const text=JSON.stringify(data),file=`C:/Private/result-${++counter}.json`;files.set(file,text);
   return {exitCode:0,stdout:JSON.stringify({Ok:true,Action:action,ResultPath:file,ResultBytes:text.length}),isStdoutTruncated:!!options.truncated};
  }};return {api,calls,saved};
}
async function ready(options){const h=harness(options),c=createCodexController();await c.initialize(h.api,options?.blocked||(()=>false));await c.open();c.change('source',B);await c.choices();c.change('folder','C:/Sample Project');h.calls.length=0;return {...h,c};}
test('opening and loading independent source choices never previews or imports',async()=>{
 const {c,calls}=await ready();assert.equal(c.view.source,B);assert.equal(c.view.folders.length,1);assert.equal(c.canImport(),false);await c.importPreview();assert.equal(calls.length,0);
});
test('parent selection is explicit and importing requires a saved preview',async()=>{
 const {c,calls}=await ready();c.change('scope','Session');c.change('session',ID);await c.preview();assert.equal(c.canImport(),true);
 assert.ok(calls[0].argv.includes('-ScopeSession'));assert.equal(calls[0].argv[calls[0].argv.indexOf('-Scope')+1],'Session');assert.equal(calls[0].init.timeoutMs,600000);
 await c.importPreview();assert.equal(calls.at(-1).action,'Import');assert.equal(calls.at(-1).argv[calls.at(-1).argv.indexOf('-PlanPath')+1],c.view.preview.planPath);assert.equal(c.canImport(),false);
 await c.importPreview();assert.equal(calls.filter(c=>c.action==='Import').length,1);
});
test('every editable import setting invalidates the preview',async()=>{
 for(const [key,value]of [['source',A],['scope','Session'],['folder','D:/Other'],['session',CHILD],['destinationFolder','D:/Destination'],['codexHome','D:/Codex'],['nodeExecutable','D:/Node/node.exe'],['codexExecutable','D:/Codex/codex.exe'],['newRevision',true]]){
  const {c,calls}=await ready();await c.preview();c.change(key,value);assert.equal(c.canImport(),false,key);await c.importPreview();assert.equal(calls.filter(c=>c.action==='Import').length,0,key);
 }
});
test('empty selection and blocked account operations never call the import helper',async()=>{
 const h=harness(),c=createCodexController();let blocked=false;await c.initialize(h.api,()=>blocked);await c.open();c.change('source',A);await c.preview();assert.match(c.view.error,/Choose a source/);assert.ok(!h.calls.some(c=>c.action==='Plan'));
 c.change('folder','C:/Sample Project');blocked=true;await c.preview();assert.ok(!h.calls.some(c=>c.action==='Plan'));
});
test('rapid repeated import clicks submit once; inputs are frozen while busy',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);const {c,calls}=await ready({delay:action=>action==='Import'?gate:undefined});await c.preview();
 const first=c.importPreview();await Promise.resolve();const old=c.view.source;c.change('source',A);await c.importPreview();assert.equal(c.view.source,old);release();await first;assert.equal(calls.filter(c=>c.action==='Import').length,1);
});
test('an interrupted import retains the same saved preview for explicit recovery',async()=>{
 let fail=true;const {c,calls}=await ready({fail:action=>action==='Import'&&fail});await c.preview();const plan=c.view.preview.planPath;await c.importPreview();assert.equal(c.canImport(),true);assert.match(c.view.error,/outcome unknown/);
 fail=false;await c.importPreview();assert.equal(c.canImport(),false);assert.ok(calls.filter(c=>c.action==='Import').every(c=>c.argv[c.argv.indexOf('-PlanPath')+1]===plan));
});
test('saved preview is restored only on request and never auto-imports after reload',async()=>{
 const {c,saved}=await ready();await c.preview();const h=harness({saved}),reloaded=createCodexController();await reloaded.initialize(h.api);assert.equal(h.calls.length,0);assert.equal(reloaded.canImport(),false);
 await reloaded.open();await reloaded.resume();assert.equal(reloaded.view.source,B);assert.equal(reloaded.canImport(),true);assert.deepEqual(h.calls.map(c=>c.action),['Profiles','Resume']);
});
test('a stale saved preview reports failure and cannot reuse a different previous preview',async()=>{
 const {c}=await ready({fail:action=>action==='Resume'});await c.preview();await c.resume();assert.equal(c.view.preview,null);assert.equal(c.canImport(),false);
});
test('truncated or unreadable file transfer reports error while leaving pane renderable',async()=>{
 for(const options of [{truncated:true},{readError:true},{data:(action,data)=>action==='Choices'?{action,folders:[null],sessions:[]}:data}]){
  const h=harness(options),c=createCodexController();await c.initialize(h.api);await c.open();c.change('source',A);await c.choices();assert.ok(c.view.error);assert.doesNotThrow(()=>renderCodexPane(elements,c));assert.ok(!h.calls.some(c=>c.action==='Import'));
 }
});
test('large catalogs stay bounded and retain a selected session outside search results',async()=>{
 const sessions=Array.from({length:1002},(_,i)=>({Id:`local_00000000-0000-4000-8000-${i.toString(16).padStart(12,'0')}`,Title:`Session ${i}`,Folder:'C:/Sample Project'}));
 const {c}=await ready({sessions});c.change('scope','Session');c.change('session',sessions.at(-1).Id);c.search('Session 0');const picker=control(renderCodexPane(elements,c),'codex-selection');assert.ok(picker.options.some(o=>o.value===sessions.at(-1).Id));assert.ok(picker.options.length<=64);
});
test('UI preview exposes skips, reasons, archive state and attachment warnings before import',async()=>{
 const {c,calls}=await ready();await c.preview();let tree=renderCodexPane(elements,c);assert.equal(control(tree,'codex-import').label,'Import 1 session');await control(tree,`codex-detail-${CHILD}`).onPress();tree=renderCodexPane(elements,c);
 const text=flat(tree).filter(e=>e.type==='Text').map(e=>e.props.children).join('\n');assert.match(text,/Synthetic reason/);assert.match(text,/Images are linked/);assert.match(text,/Skipped/);assert.ok(!calls.some(c=>c.action==='Import'));
});
test('source removal clears a previously enabled preview',async()=>{
 const options={};const {c}=await ready(options);await c.preview();options.profiles=[{Id:A,Email:'one@example.test'}];await c.refresh();assert.equal(c.view.source,'');assert.equal(c.canImport(),false);
});
test('session reload never auto-imports or accepts a late result from the old session',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);const {c,calls,api}=await ready({delay:action=>action==='Import'?gate:undefined});await c.preview();const task=c.importPreview();await Promise.resolve();await Promise.resolve();
 c.stop();await c.initialize(api);await c.open();release();await task;
 assert.equal(c.view.result,null);assert.equal(c.canImport(),false);assert.equal(calls.filter(c=>c.action==='Import').length,1);
});
test('large account catalogs stay within the native picker limit',async()=>{
 const profiles=Array.from({length:100},(_,i)=>({Id:`11111111-1111-4111-8111-111111111111\\00000000-0000-4000-8000-${i.toString(16).padStart(12,'0')}`,Email:`account-${i}@example.test`}));const h=harness({profiles}),c=createCodexController();await c.initialize(h.api);await c.open();c.change('source',profiles.at(-1).Id);c.searchProfiles('account-0');const picker=control(renderCodexPane(elements,c),'codex-source');assert.ok(picker.options.length<=64);assert.ok(picker.options.some(p=>p.value===profiles.at(-1).Id));
});
test('a session ending during configuration lookup cannot start a late import',async()=>{
 const {c,api,calls}=await ready();await c.preview();let release;api.envGet=()=>new Promise(resolve=>release=resolve);const task=c.importPreview();await Promise.resolve();await Promise.resolve();c.stop();release('');await task;assert.ok(!calls.some(c=>c.action==='Import'));
});
test('blocked resume leaves the current selection intact and explains why',async()=>{
 let blocked=false;const {c}=await ready({blocked:()=>blocked});await c.preview();c.change('source',A);blocked=true;await c.resume();assert.equal(c.view.source,A);assert.match(c.view.status,/Claude history sync is busy/);
 blocked=false;await c.resume();assert.equal(c.view.source,B);assert.deepEqual(c.view.folders,[]);const picker=control(renderCodexPane(elements,c),'codex-selection');assert.ok(picker.options.some(o=>o.value===c.view.folder));
});
test('a request surviving session closure remains mutually excluded until it finishes',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);const {c,api}=await ready({delay:action=>action==='Import'?gate:undefined});await c.preview();const task=c.importPreview();await Promise.resolve();await Promise.resolve();c.stop();await c.initialize(api);assert.equal(c.hasPending(),true);await c.refresh();assert.match(c.view.status,/still finishing/);release();await task;assert.equal(c.hasPending(),false);await c.open();assert.equal(c.view.profiles.length,2);
});
