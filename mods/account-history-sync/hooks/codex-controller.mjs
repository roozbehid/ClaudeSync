const PROFILE = /^[0-9a-f-]{36}\\[0-9a-f-]{36}$/i;
const SESSION = /^local_[0-9a-f-]{36}$/i;
const fields = ['source','scope','folder','session','destinationFolder','codexHome','nodeExecutable','codexExecutable','newRevision'];
const defaults = {source:'',scope:'Folder',folder:'',session:'',destinationFolder:'',codexHome:'',nodeExecutable:'',codexExecutable:'',newRevision:false};
export function createCodexController() {
  const view = {...defaults, profiles:[], folders:[], sessions:[], busy:false, status:'Choose a Claude account to import from.', error:'', preview:null, result:null,
    search:'', profileSearch:'', rowSearch:'', page:0, selected:'', advanced:false, saved:null, attempted:false, retryable:false};
  let api, stopped = false, blocked = () => false, generation = 0, inFlight = 0;
  const redraw = () => { if (!stopped) api?.redraw('ui.render'); };
  const selection = () => Object.fromEntries(fields.map(key => [key, view[key]]));
  const fingerprint = () => JSON.stringify(selection());
  function change(key, value) {
    if (view.busy || !fields.includes(key)) return;
    if (key === 'scope' && !['Folder','Session'].includes(value)) return;
    if (key === 'newRevision' ? typeof value !== 'boolean' : typeof value !== 'string' || value.length > 4096) return;
    if (view[key] === value) return;
    view[key] = value;
    if (key === 'source') Object.assign(view,{folder:'',session:'',folders:[],sessions:[],search:''});
    if (key === 'scope') view.search='';
    Object.assign(view,{preview:null,result:null,error:'',page:0,selected:'',attempted:false,retryable:false,status:'Selection changed. Preview before importing.'}); redraw();
  }
  function validate(needScope = true) {
    if (!PROFILE.test(view.source) || !view.profiles.some(p => p.Id === view.source)) throw new Error('Choose an available Claude source account.');
    if (needScope && (view.scope === 'Folder' ? !view.folder : !SESSION.test(view.session))) throw new Error('Choose a source folder or session, then preview.');
  }
  async function bridge(action, frozen) {
    const adapter=api,current=generation,settings=selection();
    if (!adapter.windows) throw new Error('Claude to Codex imports require Windows.');
    const argv = ['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',`${adapter.root}/scripts/ClaudeCodex-Bridge.ps1`,'-Action',action];
    const config = await adapter.envGet('ACCOUNT_HISTORY_SYNC_CONFIG');
    if(stopped||current!==generation)throw new Error('Session changed before the import helper started.');
    if (config) argv.push('-ConfigPath',config);
    if (action !== 'Profiles') {
      argv.push('-SourceProfile',settings.source,'-Scope',settings.scope);
      if (settings.folder && settings.scope === 'Folder') argv.push('-ScopeFolder',settings.folder);
      if (settings.session && settings.scope === 'Session') argv.push('-ScopeSession',settings.session);
      for (const [key,flag] of [['destinationFolder','DestinationFolder'],['codexHome','CodexHome'],['nodeExecutable','NodeExecutable'],['codexExecutable','CodexExecutable']]) if(settings[key]) argv.push(`-${flag}`,settings[key]);
      if (settings.newRevision) argv.push('-NewRevision');
      if (frozen) argv.push('-PlanPath',frozen.planPath);
    }
    const result = await adapter.processRun(argv,{timeoutMs:600_000});
    if (result.isStdoutTruncated) throw new Error('Helper output was truncated. Keep the saved preview and retry after reloading the plugin.');
    let envelope;
    try { envelope = JSON.parse(result.stdout); } catch { throw new Error(`Import helper returned invalid output. ${result.stderr?.slice(0,300)||''}`); }
    if (result.exitCode !== 0 || !envelope.Ok) throw new Error(envelope.Error || 'Import helper failed.');
    if (envelope.Action !== action || typeof envelope.ResultPath !== 'string' || !/^(?:[a-z]:[\\/]|\\\\)/i.test(envelope.ResultPath) || !Number.isInteger(envelope.ResultBytes) || envelope.ResultBytes < 1 || envelope.ResultBytes > 4194304) throw new Error('Import helper returned invalid result metadata.');
    const text = await adapter.readText(envelope.ResultPath);
    if (typeof text !== 'string' || text.length > 4194304) throw new Error('Import result exceeds the display limit.');
    const data = JSON.parse(text);
    if (data.action !== action) throw new Error('Import result does not match this request.');
    if (['Plan','Resume','Import'].includes(action) && (!Array.isArray(data.rows) || data.rows.some(r => !r || !SESSION.test(r.id) || typeof r.title !== 'string' || typeof r.status !== 'string'))) throw new Error('Import result has invalid session rows.');
    if (data.rows?.some(r=>typeof r.reason!=='string'||!Array.isArray(r.warnings)||r.warnings.some(w=>typeof w!=='string'))) throw new Error('Import result has invalid session details.');
    return data;
  }
  async function run(label, work) {
    if(stopped)return null;
    if(view.busy||inFlight){view.status='A Codex request is still finishing. Wait, then try again.';redraw();return null;}
    if(blocked()){view.status='Claude history sync is busy. Pause it or wait, then try again.';redraw();return null;}
    inFlight++;
    view.busy = true; view.error = ''; view.status = label; redraw();
    const current=generation,active=()=>!stopped&&current===generation;
    return Promise.resolve().then(()=>active()?work(active):null).catch(error=>{if(active()){view.error=error.message;view.status='Check the error, then try again.';}return null;})
      .finally(()=>{inFlight--;if(active()){view.busy=false;redraw();}else if(!stopped&&!inFlight){view.status='The previous request finished. Load the saved preview or refresh accounts.';redraw();}});
  }
  async function save(frozen) {
    view.saved = frozen;
    try { await api.storeSet('codexSavedPreview',frozen); }
    catch { view.error = 'The preview is saved on disk, but its shortcut could not be remembered. Copy the preview path before closing.'; }
  }
  async function refresh() { return run('Finding Claude accounts…',async active=>{
    const data=await bridge('Profiles'); if(!active())return;
    if(!Array.isArray(data.profiles)||data.profiles.some(p=>!PROFILE.test(p.Id)))throw new Error('Import helper returned invalid accounts.');
    view.profiles=data.profiles.map(p=>({Id:p.Id,Email:typeof p.Email==='string'?p.Email:'',Label:typeof p.Label==='string'?p.Label:''}));
    if(view.source&&!view.profiles.some(p=>p.Id===view.source))Object.assign(view,{source:'',folder:'',session:'',folders:[],sessions:[],preview:null,result:null,attempted:false,retryable:false});
    view.status=`Found ${view.profiles.length} Claude accounts. Choose the source account.`;
  }); }
  async function choices() { return run('Loading folders and sessions…',async active=>{
    validate(false);const data=await bridge('Choices');if(!active())return;
    if(!Array.isArray(data.folders)||data.folders.some(f=>!f||typeof f.Path!=='string'||!Number.isInteger(f.Count))||!Array.isArray(data.sessions)||data.sessions.some(s=>!s||!SESSION.test(s.Id)||typeof s.Title!=='string'||typeof s.Folder!=='string'))throw new Error('Import helper returned invalid choices.');
    view.folders=data.folders;view.sessions=data.sessions;view.status=`Loaded ${data.folders.length} folders and ${data.sessions.length} sessions.`;
  }); }
  async function preview() { return run('Preparing a read-only preview…',async active=>{
    validate();view.preview=null;view.result=null;view.attempted=false;view.retryable=false;
    const key=fingerprint(),settings=selection(),data=await bridge('Plan');if(!active())return;
    if(typeof data.planPath!=='string')throw new Error('Preview has no saved plan.');
    view.preview={...data,key};view.page=0;view.selected='';view.status='Preview ready. Review the sessions before importing.';
    await save({settings,planPath:data.planPath});
  }); }
  async function resume() {
    if(view.busy||!view.saved)return;
    const saved=view.saved;
    if(!saved.settings||fields.some(k=>k==='newRevision'?typeof saved.settings[k]!=='boolean':typeof saved.settings[k]!=='string'||saved.settings[k].length>4096))return;
    return run('Loading the saved preview…',async active=>{
      if(saved.settings.source!==view.source||saved.settings.scope!==view.scope)Object.assign(view,{folders:[],sessions:[],search:''});
      for(const key of fields)view[key]=saved.settings[key];
      validate();view.preview=null;view.result=null;
      const data=await bridge('Resume',saved);if(!active())return;
      view.preview={...data,key:fingerprint()};view.attempted=true;view.retryable=true;
      view.status='Saved preview loaded. Import will recheck source files and reconcile earlier attempts.';
    });
  }
  const canImport = () => !view.busy && !inFlight && !stopped && !!view.preview && view.preview.key===fingerprint() && view.preview.rows.some(r=>r.status==='Ready') && (!view.attempted||view.retryable);
  async function importPreview() {
    if(!canImport())return null;
    return run('Importing the saved preview into Codex…',async active=>{
      validate();view.attempted=true;view.retryable=true;
      const data=await bridge('Import',view.preview);if(!active())return;
      view.result=data;view.retryable=data.rows.some(r=>['NotAttempted','NeedsInvestigation'].includes(r.status));
      const count=data.rows.filter(r=>['Imported','Recovered'].includes(r.status)).length;
      view.status=`Import finished: ${count} imported or recovered. Review all results below.`;
    });
  }
  return {view,change,refresh,choices,preview,resume,canImport,importPreview,hasPending:()=>inFlight>0,
    async initialize(adapter,isBlocked=()=>false){generation++;api=adapter;blocked=isBlocked;stopped=false;Object.assign(view,defaults,{busy:false,error:'',profiles:[],folders:[],sessions:[],search:'',preview:null,result:null,attempted:false,retryable:false,status:'Choose a Claude account to import from.'});const saved=await api.storeGet('codexSavedPreview');view.saved=saved&&typeof saved.planPath==='string'?saved:null;},
    async open(){if(!stopped&&!view.profiles.length)await refresh();},stop(){generation++;stopped=true;view.busy=false;},
    search(value){view.search=String(value).slice(0,200);redraw();},searchRows(value){view.rowSearch=String(value).slice(0,200);view.page=0;redraw();},
    searchProfiles(value){view.profileSearch=String(value).slice(0,200);redraw();},
    page(value){if(Number.isInteger(value)&&value>=0)view.page=value;redraw();},select(id){view.selected=view.selected===id?'':id;redraw();},advanced(){view.advanced=!view.advanced;redraw();}};
}
