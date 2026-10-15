export function accountLabel(view, id, empty = 'Choose destination') {
  if (!id) return empty;
  const profile = view.profiles.find(p => p.Id === id);
  const [account, org] = id.split('\\');
  const name = profile?.Email || (profile?.Label && profile.Label !== account ? profile.Label : `Account ${account.slice(0, 8)}`);
  // Organizations can share an email; keep them distinguishable in every picker.
  return `${name} · ${org?.slice(0, 8) || ''}`;
}

function mode(view) {
  if (view.error) return 'Error · auto-sync paused';
  if (view.busy) return 'Working…';
  return view.enabled ? 'Auto · every 30s' : 'Paused';
}

function samePair(view, result) {
  return result && result.source === view.source && result.target === view.target;
}

function time(at, full = false) {
  return full ? new Date(at).toLocaleString() : new Date(at).toLocaleTimeString();
}

function action(Button, controller, key, label, work, needsPair = false) {
  const v = controller.view;
  const ready = !needsPair || Boolean(v.source && v.target && v.source !== v.target);
  return Button({ key, label, dimColor: v.busy || !ready, onPress: async () => {
    await controller.reopen();
    if (!v.busy && (!needsPair || (v.source && v.target && v.source !== v.target))) await work();
  } });
}

function automatic(Button, controller) {
  const v = controller.view;
  return Button({ key: 'auto', label: v.enabled ? 'Pause auto-sync' : 'Start auto-sync',
    dimColor: !v.enabled && (v.busy || !v.source || !v.target || v.source === v.target), onPress: async () => {
      await controller.reopen();
      if (v.enabled) await controller.pause();
      else if (!v.busy && v.source && v.target && v.source !== v.target) await controller.start();
    } });
}

export function launcherVisible(view, site) {
  return view.promptDisplay !== 'hidden' && (view.launcherPlacement === 'all' || view.launcherPlacement === site);
}

export function renderLauncher({ Box, Button }, controller, openSettings, site) {
  const v = controller.view;
  const location = v.launcherPlacement === 'all' ? ` · ${ {band:'Prompt', mode:'Mode', hint:'Hint'}[site] }` : '';
  const status = v.error ? ' · needs attention' : v.enabled ? ' · Auto' : '';
  return Box({ flexDirection: 'row', flexWrap: 'wrap', gap: 1, children: [
    Button({ key: site === 'band' ? 'settings' : `settings-${site}`, label: `History sync${location}${status}`,
      ...(site === 'band' ? {hotkey: 's'} : {}), onPress: openSettings }),
    ...(v.enabled ? [automatic(Button, controller)] : []),
  ] });
}

export function renderBand({ Box, Text, Button }, controller, openSettings) {
  const v = controller.view;
  if (v.promptDisplay === 'hidden') return null;
  if (v.promptDisplay !== 'compact') return renderLauncher({ Box, Button }, controller, openSettings, 'band');
  const direction = `${accountLabel(v, v.source, 'Confirm this account')} → ${accountLabel(v, v.target)}`;
  const last = samePair(v, v.lastResult) ? ` · Last ${time(v.lastResult.at)}` : '';
  return Box({ flexDirection: 'column', children: [
    Box({ flexDirection: 'row', flexWrap: 'wrap', gap: 1, children: [
      Text({ bold: true, children: `History sync · ${mode(v)}` }),
      action(Button, controller, 'sync', 'Sync now', () => controller.sync(), true),
      ...(v.enabled ? [automatic(Button, controller)] : []),
      Button({ key: 'settings', label: 'Sync settings', hotkey: 's', onPress: openSettings }),
      Button({ key: 'details', label: v.expanded ? 'Less' : 'Details', onPress: () => controller.toggleDetails() }),
    ] }),
    Text({ dimColor: true, children: `${direction}${last}` }),
    ...(v.error ? [Text({ color: 'red', children: v.error })] : []),
    ...(v.busy ? [Text({ children: v.status })] : []),
    ...(v.expanded ? [
      Text({ children: samePair(v, v.lastResult) ? v.lastResult.message : v.source && v.target ? 'Ready to preview or sync this direction.' : 'Choose an inactive destination in Sync settings.' }),
      ...(samePair(v, v.lastResult) && v.lastResult.backup ? [Text({ dimColor: true, children: 'Verified backup saved · details in Backups' })] : []),
      Text({ dimColor: true, children: 'Source stays untouched. Pause before switching accounts.' }),
    ] : []),
  ] });
}

export function profilesText(view) {
  return view.profiles.map(p => `${accountLabel(view, p.Id)} | ${p.Id} | ${p.Sessions} sessions`).join('\n');
}

export function filteredPreviewRows(view) {
  const search = view.previewSearch.trim().toLocaleLowerCase();
  return view.previewRows.filter(r =>
    (view.previewFilter === 'all' || (r.After && (view.previewFilter === 'archived' ? r.After.Archived : !r.After.Archived))) &&
    (view.previewChanges === 'all' || (view.previewChanges === 'changes' ? ['Add','Update'].includes(r.Action) : ['Conflict','Skipped'].includes(r.Action))) &&
    (!search || [r.Title,r.Before?.Title,r.After?.Title].some(t => t?.toLocaleLowerCase().includes(search)))
  ).sort((a,b) => a.Title.localeCompare(b.Title) || a.File.localeCompare(b.File));
}

function archiveState(state) { return state ? state.Archived ? 'Archived' : 'Active' : 'Not present'; }

export function previewTableText(rows) {
  const cell = text => String(text ?? '').replace(/[\t\r\n]+/g,' ');
  return [['Session','Change','Before title','Before state','After title','After state','Reason','Session file'],
    ...rows.map(r => [r.Title,r.Action,r.Before?.Title,archiveState(r.Before),r.After?.Title,archiveState(r.After),r.Detail,r.File]),
  ].map(row => row.map(cell).join('\t')).join('\n');
}

export function previewText(view) {
  const p = view.preview;
  if (!p) return '';
  return ['Preview only — no history writes performed.',
    `From: ${accountLabel(view, p.source)} | ${p.source}`,
    `To: ${accountLabel(view, p.target)} | ${p.target}`, time(p.at, true), p.message,
    `Planned operations: ${p.writes}`,
    ...(view.previewRows.length ? [previewTableText(view.previewRows)] : view.report.map(r => `${r.Action}: ${r.File}\n${r.Detail}`)),
    ...(p.reportTruncated ? [`Report limited to ${view.report.length} of ${p.reportTotal} entries.`] : []),
    ...(p.rowsTruncated ? [`Comparison limited to ${view.previewRows.length} of ${p.rowsTotal} sessions.`] : []),
  ].join('\n');
}

export function diagnosticsText(view) {
  return ['History sync diagnostics', `From: ${accountLabel(view, view.source, 'Unconfirmed')} | ${view.source}`,
    `To: ${accountLabel(view, view.target)} | ${view.target}`, mode(view), view.status,
    ...(view.error ? [`Error: ${view.error}`] : []), `Config: ${view.configPath || '(default)'}`,
    profilesText(view), ...(view.preview ? [previewText(view)] : []),
    ...(view.backup ? [`Latest backup: ${view.backup}`] : []),
  ].join('\n');
}

function renderPreviewTable({Box,Text,Button,Select,Input}, controller, copy) {
  const v=controller.view;
  const filtered=filteredPreviewRows(v);
  const pageCount=Math.max(1,Math.ceil(filtered.length/15));
  const page=Math.min(v.previewPage,pageCount-1);
  const pageRows=filtered.slice(page*15,(page+1)*15);
  const selected=v.previewRows.find(r=>r.File===v.selectedPreview);
  const widths=['36%','23%','23%','18%'];
  const cell=(content,index)=>Box({width:widths[index],flexShrink:0,flexDirection:'column',paddingX:1,children:content});
  const stateCell=(state,row)=>[Text({bold:true,children:archiveState(state)}),
    ...(state && state.Title!==row.Title ? [Text({dimColor:true,children:state.Title.slice(0,1000)})] : [])];
  const filters=Box({flexDirection:'row',flexWrap:'wrap',gap:1,children:['all','active','archived'].map(key=>Button({
    key:`filter-${key}`,label:`${v.previewFilter===key?'› ':''}${{all:'All',active:'Active',archived:'Archived'}[key]}`,
    dimColor:v.previewFilter!==key,onPress:()=>controller.filterPreview(key),
  }))});
  const search=Input ? [Input({key:'preview-search',label:'Search titles',placeholder:'Session title…',value:v.previewSearch,
    onInput:value=>controller.searchPreview(value),onSubmit:value=>controller.searchPreview(value)})] : [];
  return [
    Text({bold:true,children:'Destination before → after'}),
    Text({dimColor:true,children:'Active and Archived filter the planned destination state. All also includes sessions left absent. Titles come from the source when available.'}),
    filters,
    Select({key:'preview-changes',label:'Changes',value:v.previewChanges,
      options:[{value:'all',label:'All sessions'},{value:'changes',label:'Additions and updates'},{value:'issues',label:'Conflicts and skipped'}],
      onSelect:value=>controller.filterPreviewChanges(value)}),
    ...search,
    copy('copy-filtered','Copy filtered table',()=>previewTableText(filtered)),
    Text({dimColor:true,children:`${filtered.length} of ${v.previewRows.length} sessions · page ${page+1} of ${pageCount}`}),
    ...(v.preview.rowsTruncated ? [Text({dimColor:true,children:`Comparison contains the first ${v.previewRows.length} of ${v.preview.rowsTotal} sessions.`})] : []),
    Box({flexDirection:'column',borderStyle:'single',children:[
      Box({flexDirection:'row',children:['Session','Before','After','Change'].map((label,i)=>cell([Text({bold:true,children:label})],i))}),
      ...pageRows.map(r=>Box({key:`preview-row-${r.File}`,flexDirection:'row',paddingY:1,children:[
        cell([Text({children:r.Title.slice(0,1000)})],0),cell(stateCell(r.Before,r),1),cell(stateCell(r.After,r),2),
        cell([Text({children:r.Action}),Button({key:`details-${r.File}`,label:'Details',onPress:()=>controller.selectPreview(r.File)})],3),
      ]})),
      ...(!pageRows.length?[Text({dimColor:true,children:'No sessions match these filters.'})]:[]),
    ]}),
    Box({flexDirection:'row',gap:1,children:[
      Button({key:'preview-prev',label:'Previous',dimColor:page===0,onPress:()=>{if(page>0)controller.pagePreview(page-1);}}),
      Button({key:'preview-next',label:'Next',dimColor:page>=pageCount-1,onPress:()=>{if(page<pageCount-1)controller.pagePreview(page+1);}}),
    ]}),
    ...(selected?[
      Text({bold:true,children:selected.Title.slice(0,1000)}),
      Text({children:`${selected.Action}: ${selected.Detail}`}),
      Text({children:`Before: ${selected.Before?.Title||'Not present'} · ${archiveState(selected.Before)}\nAfter: ${selected.After?.Title||'Not present'} · ${archiveState(selected.After)}`}),
      Text({dimColor:true,children:`Changed fields: ${selected.ChangedFields?.join(', ')||'None'}\nSession file: ${selected.File}`}),
    ]:[]),
  ];
}

export function renderPane({ Box, Text, Button, Select, Input }, controller, writer = async () => ({isCopied:false,reason:'no-clipboard'})) {
  const v = controller.view;
  const row = children => Box({ flexDirection: 'row', flexWrap: 'wrap', gap: 1, children });
  const heading = text => Text({ bold: true, children: text });
  const note = text => Text({ dimColor: true, children: text });
  const go = section => controller.showSection(section);
  const copy = (key, label, getText) => Button({key, label, onPress: press => controller.copyText(getText(), writer, press?.surface)});
  const section = v.section || 'accounts';
  let content;
  if (section === 'accounts') {
    const sourceChoices = v.profiles.filter(p => !v.sourceCandidates.length || v.sourceCandidates.includes(p.Id));
    content = [
      heading('Accounts'),
      Text({ children: `From · ${accountLabel(v, v.source, 'Confirm the account open in Claude')}` }),
      ...(v.source ? [note('This session’s account is the source.')] : [
        Text({ children: v.status }),
        Select({ key: 'source-confirmation', label: 'Account open now', value: '',
          options: [{ value: '', label: 'Choose the open account…' }, ...sourceChoices.map(p => ({ value: p.Id, label: accountLabel(v, p.Id) }))],
          onSelect: async value => { await controller.reopen(); if (!v.busy && value) await controller.choose(value, v.target === value ? '' : v.target); } }),
      ]),
      Select({ key: 'target', label: 'To · inactive account', value: v.target,
        options: [{ value: '', label: 'Choose destination…' }, ...v.profiles.filter(p => p.Id !== v.source).map(p => ({
          value: p.Id, label: `${accountLabel(v, p.Id)} · ${p.Sessions} sessions`,
        }))],
        onSelect: async value => { await controller.reopen(); if (!v.busy) await controller.choose(v.source, value); } }),
      note('Copy saved Code history from this account into the destination. Keep the destination account inactive.'),
      copy('copy-profiles', 'Copy profile list', () => profilesText(v)),
      row([action(Button, controller, 'refresh', 'Refresh accounts', () => controller.refresh()),
        action(Button, controller, 'continue', 'Continue to Sync', () => go('sync'), true)]),
      heading('Prompt controls'),
      Select({ key: 'prompt-display', label: 'Show near the prompt', value: v.promptDisplay,
        options: [{ value: 'launcher', label: 'Menu button only' }, { value: 'compact', label: 'Status and quick controls' },
          { value: 'hidden', label: 'Hide — open with /history-sync' }],
        onSelect: value => controller.choosePromptDisplay(value) }),
      Select({ key: 'launcher-placement', label: 'Launcher placement', value: v.launcherPlacement,
        options: [{ value: 'all', label: 'Compare all three locations' }, { value: 'band', label: 'Above the prompt' },
          { value: 'mode', label: 'Session mode area' }, { value: 'hint', label: 'Prompt hint area' }],
        onSelect: value => controller.chooseLauncherPlacement(value) }),
      note('Compare shows Prompt, Mode, and Hint labels. A location appears only if this Desktop build asks the mod to draw it. /history-sync always opens the pane.'),
      note('This launcher appears in the main conversation only. Claude decides where the settings pane opens.'),
    ];
  } else if (section === 'sync') {
    content = [
      heading('Sync'),
      Text({ children: `${accountLabel(v, v.source, 'Confirm this account')} → ${accountLabel(v, v.target)}` }),
      ...(!v.source || !v.target ? [note('Choose accounts before previewing or syncing.'),
        Button({ key: 'choose-accounts', label: 'Choose accounts', onPress: () => go('accounts') })] : []),
      row([action(Button, controller, 'preview', 'Preview', () => controller.preview(), true),
        action(Button, controller, 'sync', 'Sync now', () => controller.sync(), true)]),
      heading('Automatic sync'),
      Text({ children: mode(v) }),
      note('Checks saved history every 30 seconds and shortly after a turn finishes. Starts paused in each session.'),
      row([automatic(Button, controller)]),
      note('Pause before switching accounts. Changing the destination pauses automatic sync.'),
      heading('Results'),
      Text({ children: v.status }),
      ...(samePair(v, v.lastResult) ? [Text({ children: `${v.lastResult.message}\nLast sync: ${time(v.lastResult.at, true)}` })] : [note('No completed sync for this direction yet.')]),
      ...(v.preview ? [Text({ children: v.preview.message }),
        copy('copy-preview', 'Copy preview', () => previewText(v)),
        ...(v.preview.reportTruncated ? [note(`Showing ${v.report.length} of ${v.preview.reportTotal} report entries.`)] : []),
        ...(v.previewRows.length ? renderPreviewTable({Box,Text,Button,Select,Input},controller,copy) :
          v.report.length ? [Text({children:v.report.map(r=>`${r.Action}: ${r.File}\n${r.Detail}`).join('\n').slice(0,9500)})] : [note('No sessions in this preview.')])] : []),
    ];
  } else {
    content = [
      heading('Backups'),
      note('Each modifying sync backs up the destination cards and archive index. Recent backups include their original direction.'),
      ...(v.receipts.length ? v.receipts.flatMap((r, index) => [
        heading(`${index === 0 ? 'Latest backup' : 'Backup'} · ${r.status === 'prepared' ? 'Interrupted — inspect before retrying' : 'Complete'}`),
        Text({ children: `${accountLabel(v, r.source)} → ${accountLabel(v, r.target)}\n${time(r.at, true)}\n${r.message}` }),
        Text({ children: r.backup }),
        copy(`copy-backup-${index}`, 'Copy backup path', () => r.backup),
      ]) : [note('No backup recorded yet. A preview or sync with no changes creates no backup.')]),
      heading('Restore'),
      note('Fully exit Claude before restoring a backup with the standalone Undo command. Review the restore with -WhatIf first.'),
    ];
  }
  return Box({ flexDirection: 'column', gap: 1, padding: 1, children: [
    heading('History sync'),
    copy('copy-diagnostics', 'Copy diagnostics', () => diagnosticsText(v)),
    row(['accounts', 'sync', 'backups'].map((key, i) => Button({ key: `nav-${key}`,
      label: `${section === key ? '› ' : ''}${['Accounts', 'Sync', 'Backups'][i]}`, hotkey: ['a', 's', 'b'][i],
      dimColor: section !== key, onPress: () => go(key) }))),
    ...content,
    ...(v.error ? [Text({ color: 'red', children: v.error })] : []),
    ...(v.notice ? [note(v.notice)] : []),
    ...(v.copyStatus ? [note(v.copyStatus)] : []),
  ] });
}
