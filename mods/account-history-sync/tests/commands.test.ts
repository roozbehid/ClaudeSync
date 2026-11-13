import { test, expect, mock } from 'claude-code/testing';

for(const surface of ['terminal','desktop'] as const){
  test(`Codex import selects an independent source, previews a parent and imports once on ${surface}`,async($,on)=>{
    mock.store(on);mock.env(on,{OS:'Windows_NT'});mock.clock(on);
    const a='11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222',b='33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
    const profiles=[{Id:a,Email:'one@example.test',Verified:true},{Id:b,Email:'two@example.test',Verified:true}];
    const sessions=Array.from({length:1002},(_,i)=>({Id:`local_00000000-0000-4000-8000-${i.toString(16).padStart(12,'0')}`,Title:`Session ${i}`,Folder:'C:\\Projects\\Sample'}));
    const snapshots=new Map<string,string>();let imports=0,token=0;
    on('fs.read',($,e)=>({value:snapshots.get(e.path.replaceAll('\\','/'))!}));
    on('session.id',()=>({value:'test-owner'}));on('session.start',($,e)=>({cwd:e.cwd}));on('command.register',()=>({value:undefined}));
    on('process.run',($,e)=>{
      const action=e.argv[e.argv.indexOf('-Action')+1];
      if(!e.argv.some(arg=>arg.includes('ClaudeCodex-Bridge.ps1')))return{value:{exitCode:0,stdout:JSON.stringify({Ok:true,Action:action,Profiles:profiles,CurrentProfile:a,SessionProfiles:[a]}),stderr:'',isStdoutTruncated:false,isStderrTruncated:false}};
      const source=e.argv[e.argv.indexOf('-SourceProfile')+1];
      if(action!=='Profiles')expect(source).toBe(b);
      const selected=e.argv[e.argv.indexOf('-ScopeSession')+1];
      const data:any={action};
      if(action==='Profiles')data.profiles=profiles;
      if(action==='Choices'){data.folders=[{Path:'C:\\Projects\\Sample',Count:1002}];data.sessions=sessions;}
      if(action==='Plan'||action==='Import'||action==='Resume'){
        data.planPath='C:/Private/codex-imports/sample/plans/preview.json';data.codexHome='C:/User/.codex';
        data.rows=[{id:selected,title:'Selected parent',status:action==='Import'?'Imported':'Ready',messages:12,archived:false,cwd:'C:/Projects/Sample',reason:'Synthetic history',warnings:['10 images are linked local files.']}];
      }
      if(action==='Import'){imports++;data.receiptPath='C:/Private/receipt.json';}
      const text=JSON.stringify(data),path=`C:/Private/codex-result-${++token}.json`;snapshots.set(path,text);
      return{value:{exitCode:0,stdout:JSON.stringify({Ok:true,Action:action,ResultPath:path,ResultBytes:text.length}),stderr:'',isStdoutTruncated:false,isStderrTruncated:false}};
    });
    await $.session.start({cwd:'C:/fixture',surface,isInteractive:true});
    const pane=await $.ui.mount({plugin:'account-history-sync',surface,component:'Pane',requestId:'history-sync',props:{title:'History sync',isFocused:true,bodyColumns:100,placement:'dock',scroll:{offset:0,bodyRows:40},view:{}}});
    await pane.press({key:'nav-codex'});await pane.select({key:'codex-source',value:b});await pane.press({key:'codex-choices'});
    if(!await pane.find({type:'Text',text:'Loaded 1 folders and 1002 sessions.'}))throw new Error('Codex choices did not load');
    await pane.select({key:'codex-scope',value:'Session'});await pane.input({key:'codex-choice-search',text:'Session 999',kind:'change'});await pane.select({key:'codex-selection',value:sessions[999].Id});
    await pane.press({key:'codex-import'});expect(imports).toBe(0);
    await pane.press({key:'codex-preview'});if(!await pane.find({type:'Text',text:'Preview ready. Review the sessions before importing.'}))throw new Error('Codex preview did not load');
    await pane.press({key:`codex-detail-${sessions[999].Id}`});expect(await pane.find({type:'Text',text:'10 images are linked local files.'})).toBeDefined();
    await pane.input({key:'codex-destinationFolder',text:'D:\\Mapped',kind:'change'});await pane.press({key:'codex-import'});expect(imports).toBe(0);
    await pane.press({key:'codex-preview'});await pane.press({key:'codex-import'});expect(imports).toBe(1);await pane.press({key:'codex-import'});expect(imports).toBe(1);
    expect(await pane.find({type:'Text',text:'Import results'})).toBeDefined();
    await pane.select({key:'codex-source',value:a});await pane.press({key:'codex-resume'});
    expect(await pane.find({type:'Text',text:'Saved preview loaded. Import will recheck source files and reconcile earlier attempts.'})).toBeDefined();
    expect(await pane.find({key:'codex-selection'})).toBeDefined();expect(imports).toBe(1);
  });
}

for (const surface of ['terminal','desktop'] as const) {
  test(`folder choices keep the pane mounted after loading a large catalog on ${surface}`,async($,on)=>{
    mock.store(on);mock.env(on,{OS:'Windows_NT'});mock.clock(on);
    const a='11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222';
    const b='33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
    const folders=Array.from({length:64},(_,i)=>({Path:`C:\\Projects\\Folder-${i}-${'x'.repeat(90)}`,Count:16}));
    const sessions=Array.from({length:1002},(_,i)=>({Id:`local_00000000-0000-4000-8000-${i.toString(16).padStart(12,'0')}`,Title:`Session ${i}`,Folder:folders[i%folders.length].Path}));
    const snapshot=JSON.stringify({Ok:true,Action:'Choices',Folders:folders,Sessions:sessions});
    on('fs.read',()=>({value:snapshot}));
    on('session.id',()=>({value:'test-owner'}));
    on('session.start',($,e)=>({cwd:e.cwd}));
    on('command.register',()=>({value:undefined}));
    on('process.run',($,e)=>{
      const action=e.argv[e.argv.indexOf('-Action')+1];
      const result=action==='Profiles'?{Ok:true,Action:action,Profiles:[{Id:a,Label:'A',Verified:true},{Id:b,Label:'B',Verified:true}],CurrentProfile:a,SessionProfiles:[a]}:
        action==='Choices'?{Ok:true,Action:action,PreviewPath:'C:/private/choices.json',PreviewBytes:snapshot.length}:{Ok:true,Action:action};
      return{value:{exitCode:0,stdout:JSON.stringify(result),stderr:'',isStdoutTruncated:false,isStderrTruncated:false}};
    });
    await $.session.start({cwd:'C:/fixture',surface,isInteractive:true});
    await $.command.run({command:'history-sync',args:`to ${b}`,origin:{kind:'unclassified'},presentation:{isFullscreen:false,columns:100}});
    const pane=await $.ui.mount({plugin:'account-history-sync',surface,component:'Pane',requestId:'history-sync',props:{title:'History sync',isFocused:true,bodyColumns:100,placement:'dock',scroll:{offset:0,bodyRows:40},view:{}}});
    await pane.press({key:'nav-sync'});
    await pane.select({key:'sync-scope',value:'Folder'});
    await pane.press({key:'load-scope-choices'});
    expect(await pane.find({type:'Text',text:'Loaded 64 folders and 1002 source sessions.'})).toBeDefined();
    expect(await pane.find({key:'scope-folder'})).toBeDefined();
    await pane.select({key:'scope-folder',value:folders[0].Path});
    expect(await pane.find({type:'Text',text:`Selected: Folder: ${folders[0].Path}`})).toBeDefined();
    await pane.input({key:'scope-folder-search',text:'Folder-63-',kind:'change'});
    await pane.select({key:'scope-folder',value:folders[63].Path});
    expect(await pane.find({type:'Text',text:`Selected: Folder: ${folders[63].Path}`})).toBeDefined();
    await pane.input({key:'scope-folder-search',text:'no matching folder',kind:'change'});
    expect(await pane.find({key:'scope-folder'})).toBeDefined();
    await pane.select({key:'sync-scope',value:'Session'});
    expect(await pane.find({type:'Text',text:'1002 matching sessions.'})).toBeDefined();
    await pane.input({key:'scope-search',text:'Session 999',kind:'change'});
    await pane.select({key:'scope-session',value:sessions[999].Id});
    expect(await pane.find({type:'Text',text:'Selected: Session: Session 999 and descendants'})).toBeDefined();
  });
}

test('status command loads without starting sync', async ($, on) => {
  mock.store(on);
  mock.env(on, { OS: 'Windows_NT' });
  mock.clock(on);
  on('session.id', () => ({ value: 'test-owner' }));
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"Ok":true,"Action":"Release"}', stderr: '', isStdoutTruncated:false, isStderrTruncated:false } }));
  on('command.register', () => ({ value: undefined }));
  on('session.start', ($, e) => ({ cwd: e.cwd }));
  await $.session.start({ cwd: 'C:/project', surface: 'terminal', isInteractive: true });
  const result = await $.command.run({ command: 'history-sync', args: 'status', origin: { kind: 'unclassified' }, presentation: { isFullscreen: false, columns: 100 } });
  expect(result.text).toContain('Auto-sync paused');
});

for (const surface of ['terminal', 'desktop'] as const) {
  test(`menu launcher and hidden preference on ${surface}`, async ($, on) => {
    mock.store(on);
    mock.env(on, { OS: 'Windows_NT' });
    mock.clock(on);
    on('session.id', () => ({ value: 'test-owner' }));
    on('process.run', ($, e) => ({ value: { exitCode: e.argv.includes('Profiles') ? 1 : 0,
      stdout: e.argv.includes('Profiles') ? '{"Ok":false,"Error":"Fixture discovery error"}' : '{"Ok":true}', stderr: '', isStdoutTruncated:false, isStderrTruncated:false } }));
    on('command.register', () => ({ value: undefined }));
    on('ui.open', () => ({ value: undefined }));
    const copies: {text:string;surface?:string}[]=[];
    on('ui.copy', ($, e) => {copies.push(e);return{value:{isCopied:true}};});
    on('ui.render', ($, e) => {
      const { Text } = $.ui.resolve(e);
      return Text({ children: e.component === 'SessionMode' ? e.props.modes.join(' & ') : e.component === 'PromptHint' ? e.props.hint : '' });
    });
    on('session.start', ($, e) => ({ cwd: e.cwd }));
    await $.session.start({ cwd: 'C:/fixture', surface, isInteractive: true });
    const band = await $.ui.mount({ plugin: 'account-history-sync', surface, component: 'AbovePrompt',
      props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: {offset: 0, bodyRows: 10}, view: {} } });
    expect(await band.findAll({ type: 'Button' })).toHaveLength(1);
    expect((await band.find({ key: 'settings' }))?.text).toBe('History sync · Prompt · needs attention');
    expect(await band.find({ type: 'Text', text: 'Fixture discovery error' })).toBeUndefined();
    await band.press({ key: 'settings' });
    const pane = await $.ui.mount({ plugin: 'account-history-sync', surface, component: 'Pane', requestId: 'history-sync',
      props: { title: 'History sync', isFocused: true, bodyColumns: 100, placement: 'dock', scroll: {offset: 0, bodyRows: 30}, view: {} } });
    expect(await pane.find({ type: 'Text', text: 'Fixture discovery error' })).toBeDefined();
    await pane.press({key:'copy-diagnostics'});
    expect(copies[0].text).toContain('Fixture discovery error');
    expect(copies[0].surface).toBe(surface);
    expect(await pane.find({type:'Text',text:'Copied to clipboard.'})).toBeDefined();
    const modes = await $.ui.mount({plugin: 'account-history-sync', surface, component:'SessionMode', props:{modes:['Native mode']}});
    const hint = await $.ui.mount({plugin: 'account-history-sync', surface, component:'PromptHint', props:{isDraft:false,isWorking:false,hint:'Native hint'}});
    expect((await modes.find({key:'settings-mode'}))?.text).toBe('History sync · Mode · needs attention');
    expect((await hint.find({key:'settings-hint'}))?.text).toBe('History sync · Hint · needs attention');
    expect(await modes.find({type:'Text',text:'Native mode'})).toBeDefined();
    expect(await hint.find({type:'Text',text:'Native hint'})).toBeDefined();
    await modes.press({key:'settings-mode'});
    await hint.press({key:'settings-hint'});
    await pane.select({key:'launcher-placement',value:'mode'});
    expect(await band.findAll({type:'Button'})).toHaveLength(0);
    expect(await modes.findAll({type:'Button'})).toHaveLength(1);
    expect(await hint.findAll({type:'Button'})).toHaveLength(0);
    await pane.select({key:'launcher-placement',value:'all'});
    await pane.select({ key: 'prompt-display', value: 'hidden' });
    expect(await band.findAll({ type: 'Button' })).toHaveLength(0);
    expect(await modes.findAll({type:'Button'})).toHaveLength(0);
    expect(await hint.findAll({type:'Button'})).toHaveLength(0);
    expect(await modes.find({type:'Text',text:'Native mode'})).toBeDefined();
    const result = await $.command.run({ command: 'history-sync', args: '', origin: {kind: 'unclassified'}, presentation: {isFullscreen: false, columns: 100} });
    expect(result).toMatchObject({});
  });
}

for (const surface of ['terminal','desktop'] as const) {
  test(`before and after table filters titles on ${surface}`,async($,on)=>{
    mock.store(on);mock.env(on,{OS:'Windows_NT'});mock.clock(on);
    const a='11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222';
    const b='33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
    const actions:string[]=[];const copies:string[]=[];
    let previewFile='';const reads:string[]=[];
    on('fs.read',($,e)=>{reads.push(e.path);return{value:previewFile};});
    on('session.id',()=>({value:'test-owner'}));on('command.register',()=>({value:undefined}));
    on('ui.copy',($,e)=>{copies.push(e.text);return{value:{isCopied:true}};});
    on('ui.render',($,e)=>{const {Text}=$.ui.resolve(e);return Text({children:''});});
    on('session.start',($,e)=>({cwd:e.cwd}));
    on('process.run',($,e)=>{
      const action=e.argv[e.argv.indexOf('-Action')+1];actions.push(action);
      const result=action==='Profiles'?{Ok:true,Profiles:[{Id:a,Email:'source@example.test',Sessions:3,Verified:true},{Id:b,Email:'destination@example.test',Sessions:1,Verified:true}],CurrentProfile:a,SessionProfiles:[a]}:
        action==='Plan'?{Ok:true,Action:'Plan',Additions:1,Updates:1,Report:[],Rows:[
          {File:'local_add.json',Title:'New active work',Action:'Add',Before:null,After:{Title:'New active work',Archived:false}},
          {File:'local_update.json',Title:'Renamed work',Action:'Update',Before:{Title:'Old name',Archived:false},After:{Title:'Renamed work',Archived:true},ChangedFields:['title','isArchived']},
        ]}:{Ok:true};
      if(action==='Plan'&&surface==='desktop'){
        expect(e.argv.includes('-PreviewFile')).toBe(true);
        previewFile=JSON.stringify(result);
        return{value:{exitCode:0,stdout:JSON.stringify({Ok:true,Action:'Plan',PreviewPath:'C:/private/preview.json',PreviewBytes:previewFile.length}),stderr:'',isStdoutTruncated:false,isStderrTruncated:false}};
      }
      return{value:{exitCode:0,stdout:JSON.stringify(result),stderr:'',isStdoutTruncated:false,isStderrTruncated:false}};
    });
    await $.session.start({cwd:'C:/fixture',surface,isInteractive:true});
    await $.command.run({command:'history-sync',args:`to ${b}`,origin:{kind:'unclassified'},presentation:{isFullscreen:false,columns:100}});
    await $.command.run({command:'history-sync',args:'preview',origin:{kind:'unclassified'},presentation:{isFullscreen:false,columns:100}});
    const pane=await $.ui.mount({plugin:'account-history-sync',surface,component:'Pane',requestId:'history-sync',props:{title:'History sync',isFocused:true,bodyColumns:100,placement:'dock',scroll:{offset:0,bodyRows:40},view:{}}});
    await pane.press({key:'nav-sync'});
    expect(await pane.find({type:'Text',text:'New active work'})).toBeDefined();
    expect(await pane.find({type:'Text',text:'Old name'})).toBeDefined();
    await pane.press({key:'filter-archived'});
    expect(await pane.find({type:'Text',text:'New active work'})).toBeUndefined();
    expect(await pane.find({type:'Text',text:'Renamed work'})).toBeDefined();
    await pane.input({key:'preview-search',text:'Old name',kind:'change'});
    await pane.press({key:'copy-filtered'});
    expect(copies[0]).toContain('Old name\tActive\tRenamed work\tArchived');
    await pane.press({key:'details-local_update.json'});
    expect(await pane.find({type:'Text',text:'Session file: local_update.json'})).toBeDefined();
    expect(actions.includes('Sync')).toBe(false);expect(actions.includes('Arm')).toBe(false);
    if(surface==='desktop')expect(reads).toHaveLength(1);
  });
}
