import { test, expect, mock } from 'claude-code/testing';

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
    on('session.id',()=>({value:'test-owner'}));on('command.register',()=>({value:undefined}));
    on('ui.copy',($,e)=>{copies.push(e.text);return{value:{isCopied:true}};});
    on('ui.render',($,e)=>{const {Text}=$.ui.resolve(e);return Text({children:''});});
    on('session.start',($,e)=>({cwd:e.cwd}));
    on('process.run',($,e)=>{
      const action=e.argv[e.argv.indexOf('-Action')+1];actions.push(action);
      const result=action==='Profiles'?{Ok:true,Profiles:[{Id:a,Email:'source@example.test',Sessions:3},{Id:b,Email:'destination@example.test',Sessions:1}],CurrentProfile:a,SessionProfiles:[a]}:
        action==='Plan'?{Ok:true,Action:'Plan',Additions:1,Updates:1,Rows:[
          {File:'local_add.json',Title:'New active work',Action:'Add',Before:null,After:{Title:'New active work',Archived:false}},
          {File:'local_update.json',Title:'Renamed work',Action:'Update',Before:{Title:'Old name',Archived:false},After:{Title:'Renamed work',Archived:true},ChangedFields:['title','isArchived']},
        ]}:{Ok:true};
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
  });
}
