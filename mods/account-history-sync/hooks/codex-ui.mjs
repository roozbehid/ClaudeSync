export function codexDiagnosticsText(v) {
  const data=v.result||v.preview;
  return ['Claude to Codex import',`Source: ${v.profiles.find(p=>p.Id===v.source)?.Email||v.source}`,`Selection: ${v.scope} · ${v.scope==='Folder'?v.folder:v.session}`,v.status,v.error,
    ...(data?[`Codex directory: ${data.codexHome}`,`Preview: ${data.planPath}`,`Receipt: ${data.receiptPath||'Not imported'}`,
      ...data.rows.map(r=>`${r.title} | ${r.status} | ${r.archived?'Archived':'Active'} | ${r.messages||0} messages\n${r.reason}\n${(r.warnings||[]).join('\n')}`)]:[])].filter(Boolean).join('\n');
}
export function renderCodexPane({Box,Text,Button,Select,Input},c,copy=()=>null) {
  const v=c.view,heading=children=>Text({bold:true,children}),note=children=>Text({dimColor:true,children});
  const button=(key,label,fn,enabled=true)=>Button({key,label,dimColor:v.busy||!enabled,onPress:()=>{if(!v.busy&&enabled)return fn();}});
  const input=(key,label,placeholder)=>Input?Input({key:`codex-${key}`,label,placeholder,value:v[key],onInput:value=>c.change(key,value),onSubmit:value=>c.change(key,value)}):note(`${label}: ${v[key]||'Default'}`);
  const row=children=>Box({flexDirection:'row',flexWrap:'wrap',gap:1,children});
  const query=v.search.toLocaleLowerCase(),selected=v.scope==='Folder'?v.folder:v.session;
  const accounts=v.profiles.map(p=>({value:p.Id,label:`${(p.Email||p.Label||'Claude account').slice(0,200)} · ${p.Id.split('\\')[1].slice(0,8)}`})).filter(p=>p.value===v.source||p.label.toLocaleLowerCase().includes(v.profileSearch.toLocaleLowerCase()));
  const accountOptions=accounts.slice(0,62);if(v.source&&!accountOptions.some(p=>p.value===v.source)){const keep=accounts.find(p=>p.value===v.source);if(keep)accountOptions.push(keep);}
  const choices=v.scope==='Folder'?v.folders.map(f=>({value:f.Path,label:`${f.Path.slice(0,360)} · ${f.Count} sessions`})):
    v.sessions.map(s=>({value:s.Id,label:`${(s.Title||'Untitled session').slice(0,160)} · ${s.Folder.slice(0,240)}`}));
  const filtered=choices.filter(o=>o.value===selected||o.label.toLocaleLowerCase().includes(query));
  // Keep large catalogs bounded without removing the selected option.
  const visible=filtered.slice(0,62);if(selected&&!visible.some(o=>o.value===selected)){const keep=choices.find(o=>o.value===selected);if(keep)visible.push(keep);}
  if(selected&&!visible.some(o=>o.value===selected))visible.push({value:selected,label:v.scope==='Session'?(v.preview?.rows.find(r=>r.id===selected)?.title||'Saved session'):selected.slice(0,360)});
  const data=v.result||v.preview,rows=data?.rows||[],matches=rows.filter(r=>r.title.toLocaleLowerCase().includes(v.rowSearch.toLocaleLowerCase()));
  const pages=Math.max(1,Math.ceil(matches.length/15)),page=Math.min(v.page,pages-1),details=rows.find(r=>r.id===v.selected);
  const counts=Object.entries(rows.reduce((all,r)=>(all[r.status]=(all[r.status]||0)+1,all),{})).map(([status,n])=>`${n} ${status}`).join(' · ');
  const ready=v.preview?.rows.filter(r=>r.status==='Ready').length||0;
  return [heading('Claude → Codex'),note('Copy a folder or a session and its descendants as new Codex conversations.'),
    ...(v.profiles.length>62&&Input?[Input({key:'codex-account-search',label:'Find an account',value:v.profileSearch,onInput:value=>c.searchProfiles(value),onSubmit:value=>c.searchProfiles(value)})]:[]),
    Select({key:'codex-source',label:'Claude source account',value:v.source,options:[{value:'',label:'Choose an account…'},...accountOptions],onSelect:value=>c.change('source',value)}),
    row([button('codex-accounts','Refresh accounts',()=>c.refresh()),button('codex-choices','Load folders and sessions',()=>c.choices(),!!v.source)]),
    Select({key:'codex-scope',label:'What to import',value:v.scope,options:[{value:'Folder',label:'Project folder and descendants'},{value:'Session',label:'Session and descendants'}],onSelect:value=>c.change('scope',value)}),
    ...(Input?[Input({key:'codex-choice-search',label:v.scope==='Folder'?'Find a folder':'Find a session',placeholder:'Search…',value:v.search,onInput:value=>c.search(value),onSubmit:value=>c.search(value)})]:[]),
    Select({key:'codex-selection',label:v.scope==='Folder'?'Source folder':'Source session',value:selected,options:[{value:'',label:'Choose a source…'},...visible],onSelect:value=>c.change(v.scope==='Folder'?'folder':'session',value)}),
    note(`${filtered.length} matching choices${filtered.length>62?' · Showing up to 62; refine the search.':''}`),
    note('Parent sessions include their children. Codex displays the conversations as separate threads.'),
    input('destinationFolder','Project folder in Codex (optional)','Keep source folders, or enter an existing local folder'),
    note('Choose an existing project folder when source worktrees are unavailable. Project files are not copied.'),
    Select({key:'codex-revision',label:'Previously imported conversations',value:v.newRevision?'new':'keep',options:[{value:'keep',label:'Keep existing imports'},{value:'new',label:'Create separate snapshots for changed conversations'}],onSelect:value=>c.change('newRevision',value==='new')}),
    button('codex-advanced','Runtime and destination settings',()=>c.advanced()),
    ...(v.advanced?[input('codexHome','Codex data directory (optional)','Use CODEX_HOME or the current Windows profile'),input('nodeExecutable','Node executable (optional)','Use node.exe on PATH'),input('codexExecutable','Codex executable (optional)','Use Codex on PATH')]:[]),
    row([button('codex-preview','Preview changes',()=>c.preview(),!!v.source&&!!selected),button('codex-import',v.result&&!v.retryable?'Import completed':v.attempted?'Retry saved import':`Import ${ready} ${ready===1?'session':'sessions'}`,()=>c.importPreview(),c.canImport())]),
    ...(v.saved?[row([button('codex-resume','Load saved preview',()=>c.resume(),!!v.profiles.length),copy('codex-copy-plan','Copy saved preview path',()=>v.saved.planPath)])]:[]),
    Text({color:v.busy?'yellow':undefined,children:v.status}),...(v.error?[Text({color:'red',children:v.error.slice(0,4000)})]:[]),
    ...(data?[heading(v.result?'Import results':'Preview'),Text({children:`Codex directory: ${data.codexHome}\n${counts}`}),
      note('Only Ready sessions are imported. Archived conversations keep their archive state. Existing Codex conversations are kept.'),
      note('Images and PDFs are linked local files. Provider thinking is omitted; encrypted advisor text is represented by placeholders.'),
      ...(Input?[Input({key:'codex-row-search',label:'Search preview titles',value:v.rowSearch,placeholder:'Session title…',onInput:value=>c.searchRows(value),onSubmit:value=>c.searchRows(value)})]:[]),
      note(`${matches.length} sessions · page ${page+1} of ${pages}`),
      ...matches.slice(page*15,(page+1)*15).map(r=>Box({key:`codex-row-${r.id}`,flexDirection:'column',children:[heading((r.title||'Untitled session').slice(0,1000)),Text({children:`${r.status} · ${r.archived?'Archived':'Active'} · ${r.messages||0} messages`}),button(`codex-detail-${r.id}`,'Details',()=>c.select(r.id))]})),
      row([button('codex-prev','Previous',()=>c.page(page-1),page>0),button('codex-next','Next',()=>c.page(page+1),page+1<pages)]),
      ...(details?[heading(details.title.slice(0,1000)),Text({children:details.reason.slice(0,4000)}),Text({children:`Project folder: ${details.cwd||'Unavailable'}`}),...(details.warnings||[]).map(w=>Text({children:w.slice(0,2000)})),...(details.target?[Text({children:`Codex thread: ${details.target}`})]:[])]:[]),
      ...(data.receiptPath?[Text({children:`Receipt: ${data.receiptPath}`}),copy('codex-copy-receipt','Copy import receipt path',()=>data.receiptPath)]:[])]:[])];
}
