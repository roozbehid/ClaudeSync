import test from 'node:test';
import assert from 'node:assert/strict';
import { createController } from '../hooks/controller.mjs';
import { register } from '../hooks/register.mjs';
import { renderBand, renderPane, previewText, filteredPreviewRows } from '../hooks/ui.mjs';

const A = '11111111-1111-4111-8111-111111111111\\22222222-2222-4222-8222-222222222222';
const B = '33333333-3333-4333-8333-333333333333\\44444444-4444-4444-8444-444444444444';
const profiles = [
  { Id: A, Email: 'a@example.test', Label: 'A', OrganizationId: A.split('\\')[1], Sessions: 2 },
  { Id: B, Email: 'b@example.test', Label: 'B', OrganizationId: B.split('\\')[1], Sessions: 1 },
];
const elements = Object.fromEntries(['Box', 'Text', 'Button', 'Select', 'Input'].map(type => [type, props => ({ type, props })]));
const flatten = tree => !tree || typeof tree !== 'object' ? [] : [tree, ...[tree.props?.children || []].flat().flatMap(flatten)];
const control = (tree, key) => flatten(tree).find(e => e.props.key === key).props;
const textContent = tree => flatten(tree).filter(e => e.type === 'Text').map(e => e.props.children).join('\n');

function harness(options = {}) {
  const calls = [], timers = [], logs = [], saved = new Map(Object.entries(options.saved || {}));
  const timer = (ms, fn) => { const t = { ms, fn, cancelled: false, cancel() { this.cancelled = true; } }; timers.push(t); return t; };
  const api = {
    root: 'C:/Mods/History Sync', windows: true,
    redraw() {}, log: text => logs.push(text), now: async () => 1000,
    sessionId: async () => 'test-owner', envGet: async () => options.config || '',
    storeGet: async key => saved.get(key), storeSet: async (key, value) => saved.set(key, value),
    every: timer, after: timer,
    processRun: async (argv, init) => {
      const action = argv[argv.indexOf('-Action') + 1];
      calls.push({ action, argv, init });
      if (options.respond) {
        const result = await options.respond(action, argv);
        if (result) return result;
      }
      return { exitCode: 0, stderr: '', stdout: JSON.stringify({ Ok: true, Action: action,
        Profiles: profiles.map(p => ({ ...p })), CurrentProfile: A, SessionProfiles: [A], Additions: 1, Updates: 0, Conflicts: 0, Skipped: 0, Report: [], Backup: action === 'Sync' ? 'C:/Backups/receipt' : '' }) };
    },
  };
  return { api, calls, timers, logs, saved };
}
async function ready(options) {
  const h = harness(options), c = createController();
  await c.initialize(h.api); await c.refresh(); await c.choose(A, B);
  h.calls.length = 0;
  return { ...h, c };
}

test('startup discovers this account, restores only destination, and never writes history', async () => {
  const h = harness({ saved: { pair: { source: B, target: A }, destination: B } }), c = createController();
  await c.initialize(h.api);
  assert.equal(c.view.enabled, false);
  assert.equal(c.view.source, A);
  assert.equal(c.view.target, B);
  assert.deepEqual(h.calls.map(r => r.action), ['Release', 'Profiles']);
  assert.equal(h.calls[1].argv[h.calls[1].argv.indexOf('-SessionId') + 1], 'test-owner');
  await h.timers[0].fn();
  assert.equal(h.calls.length, 2);
});
test('preview cannot launch a sync', async () => {
  const { c, calls } = await ready();
  await c.preview();
  assert.deepEqual(calls.map(r => r.action), ['Plan']);
});

test('large-history preview and sync get ten minutes while control calls stay bounded', async () => {
  const { c, calls } = await ready();
  await c.preview();
  await c.sync();
  await c.refresh();
  assert.equal(calls.find(call => call.action === 'Plan').init.timeoutMs, 600_000);
  assert.equal(calls.find(call => call.action === 'Sync').init.timeoutMs, 600_000);
  assert.equal(calls.find(call => call.action === 'Profiles').init.timeoutMs, 90_000);
});

test('large previews use a private file instead of truncated process output', async () => {
  const snapshot = { Ok: true, Action: 'Plan', Additions: 1, Rows: Array.from({ length: 700 }, (_, i) => ({ File: `${i}.json`, Title: 'Long title '.repeat(100) })), Report: [], RowsTotal: 700 };
  const text = JSON.stringify(snapshot);
  assert.ok(text.length > 500_000);
  const h = await ready({ respond: async action => action === 'Plan' ? {
    exitCode: 0, stderr: '', stdout: JSON.stringify({ Ok: true, Action: 'Plan', PreviewPath: 'C:/Private/preview.json', PreviewBytes: text.length }),
  } : null });
  const reads = [];
  h.api.readText = async path => { reads.push(path); return text; };
  await h.c.preview();
  assert.equal(h.c.view.error, '');
  assert.equal(h.c.view.previewRows.length, 700);
  assert.deepEqual(reads, ['C:/Private/preview.json']);
  assert.ok(h.calls.find(call => call.action === 'Plan').argv.includes('-PreviewFile'));
  assert.equal(h.calls.some(call => call.action === 'Sync'), false);
});

test('truncated helper output is reported directly without retrying or writing', async () => {
  const h = await ready({ respond: async action => action === 'Plan' ? {
    exitCode: 0, stderr: '', stdout: '{"Ok":true', isStdoutTruncated: true,
  } : null });
  await h.c.preview();
  assert.match(h.c.view.error, /output was truncated/);
  assert.equal(h.c.view.enabled, false);
  assert.deepEqual(h.calls.map(call => call.action), ['Plan', 'Release']);
});

test('failed preview-file reads pause and never start a copy', async () => {
  const h = await ready({ respond: async action => action === 'Plan' ? {
    exitCode: 0, stderr: '', stdout: JSON.stringify({ Ok: true, Action: 'Plan', PreviewPath: 'C:/Private/preview.json', PreviewBytes: 500 }),
  } : null });
  h.api.readText = async () => { throw new Error('Fixture read failure'); };
  await h.c.preview();
  assert.match(h.c.view.error, /Could not read.*Fixture read failure/);
  assert.equal(h.c.view.preview, null);
  assert.equal(h.calls.some(call => call.action === 'Sync'), false);
});
test('manual sync passes explicit pair through an argument vector without a shell', async () => {
  const { c, calls } = await ready({ config: 'C:/Config path/profiles.json' });
  await c.sync();
  const call = calls[0];
  assert.equal(call.action, 'Sync');
  assert.equal(call.argv[call.argv.indexOf('-SourceProfile') + 1], A);
  assert.equal(call.argv[call.argv.indexOf('-TargetProfile') + 1], B);
  assert.equal(call.argv[call.argv.indexOf('-ConfigPath') + 1], 'C:/Config path/profiles.json');
  assert.ok(!call.argv.includes('-KeepLease'));
  assert.equal(c.view.backup, 'C:/Backups/receipt');
});
test('start arms then syncs; manual sync during auto mode retains the lease', async () => {
  const { c, calls, timers } = await ready();
  await c.start();
  assert.deepEqual(calls.map(r => r.action), ['Arm', 'Sync']);
  assert.ok(calls[1].argv.includes('-KeepLease'));
  await c.sync();
  assert.ok(calls[2].argv.includes('-KeepLease'));
  await timers[0].fn();
  assert.equal(calls.at(-1).action, 'Sync');
});
test('pause disables timer and turn-triggered syncing', async () => {
  const { c, calls, timers } = await ready();
  await c.start(); c.afterTurn();
  const pending = timers.at(-1);
  await c.pause();
  assert.equal(c.view.enabled, false); assert.equal(pending.cancelled, true);
  const before = calls.length;
  await timers[0].fn(); await pending.fn();
  assert.equal(calls.length, before);
});
test('destination selection cannot reverse this account into a write target', async () => {
  const { c, calls } = await ready();
  await c.start();
  await assert.rejects(c.choose(B, A), /Source is this session/);
  assert.equal(c.view.source, A); assert.equal(c.view.target, B);
  await c.choose(A, '');
  assert.equal(c.view.enabled, false); assert.equal(calls.at(-1).action, 'Release');
});
test('same-profile pair cannot write or arm', async () => {
  const { c, calls } = await ready(); await c.choose(A, A); calls.length = 0;
  await c.start();
  assert.match(c.view.error, /must be different/);
  assert.ok(!calls.some(r => ['Arm', 'Sync'].includes(r.action)));
});
test('helper errors pause automatic syncing and retain the backup receipt', async () => {
  const { c, calls, timers } = await ready({ respond: async action => action === 'Sync' ? {
    exitCode: 1, stderr: '', stdout: JSON.stringify({ Ok: false, Error: 'A file changed', Backup: 'C:/Prepared/backup' }),
  } : null });
  await c.start();
  assert.equal(c.view.enabled, false); assert.match(c.view.error, /A file changed/);
  assert.equal(c.view.backup, 'C:/Prepared/backup');
  const before = calls.length; await timers[0].fn(); assert.equal(calls.length, before);
});
test('overlapping timer ticks cannot start duplicate processes', async () => {
  let finish;
  const blocked = new Promise(resolve => { finish = resolve; });
  const { c, calls, timers } = await ready({ respond: async action => { if (action === 'Sync') await blocked; return null; } });
  const starting = c.start();
  while (!calls.some(r => r.action === 'Sync')) await Promise.resolve();
  await timers[0].fn();
  assert.equal(calls.filter(r => r.action === 'Sync').length, 1);
  finish(); await starting;
});
test('pause racing with Arm cannot re-enable auto-sync', async () => {
  let finish;
  const blocked = new Promise(resolve => { finish = resolve; });
  const { c, calls } = await ready({ respond: async action => { if (action === 'Arm') await blocked; return null; } });
  const starting = c.start();
  while (!calls.some(r => r.action === 'Arm')) await Promise.resolve();
  const pausing = c.pause(); finish();
  await Promise.all([starting, pausing]);
  assert.equal(c.view.enabled, false);
  assert.ok(!calls.some(r => r.action === 'Sync'));
});
test('session end cancels timers and does not write on logout', async () => {
  const { c, calls, timers } = await ready(); await c.start(); c.afterTurn(); c.stop();
  const before = calls.length;
  for (const t of timers) { assert.equal(t.cancelled, true); await t.fn(); }
  await c.sync(); assert.equal(calls.length, before);
});
test('unsupported environments launch no PowerShell process', async () => {
  const h = harness(), c = createController(); h.api.windows = false;
  await c.initialize(h.api); await c.refresh();
  assert.equal(h.calls.length, 0); assert.match(c.view.error, /native Windows/);
});
test('resume or clear reopens the controller paused until explicitly restarted', async () => {
  const { c, calls } = await ready(); await c.start(); c.stop();
  await c.reopen();
  assert.equal(c.view.enabled, false);
  assert.match(c.view.status, /Session changed/);
  const before = calls.length;
  c.afterTurn(); assert.equal(calls.length, before);
  await c.start(); assert.equal(c.view.enabled, true);
});
test('email ambiguity requires an exact profile ID', async () => {
  const { c } = await ready(); c.view.profiles[1] = { ...c.view.profiles[1], Email: 'a@example.test' };
  assert.throws(() => c.resolveSelector('a@example.test'), /ambiguous/);
  assert.equal(c.resolveSelector(A), A);
});

test('menu launcher supports selection and sync without slash commands on both surfaces', async () => {
  const h = harness(), hooks = [];
  const opened = [];
  register((event, matcher, hook) => { if (typeof matcher === 'function') { hook = matcher; matcher = null; } hooks.push({ event, matcher, hook }); });
  const makeElement = type => props => ({ type, props });
  const host = {
    plugin: { root: h.api.root }, process: { run: h.api.processRun },
    env: { get: async name => name === 'OS' ? 'Windows_NT' : '' },
    session: { id: h.api.sessionId }, store: { get: h.api.storeGet, set: h.api.storeSet },
    clock: { now: h.api.now, every: h.api.every, after: h.api.after },
    command: { register: async () => {} },
    ui: { invalidate() {}, log() {}, open: async options => opened.push(options), resolve: () => Object.fromEntries(['Box','Text','Button','Select'].map(t => [t, makeElement(t)])) },
  };
  await hooks.find(h => h.event === 'session.start').hook(host, {}, async () => ({}));
  const render = hooks.find(h => h.event === 'ui.render' && h.matcher.component === 'Pane').hook;
  assert.equal(await render(host, { requestId: 'other-pane' }, async () => 'original'), 'original');
  const band = hooks.find(h => h.event === 'ui.render' && h.matcher.component === 'AbovePrompt').hook;
  const flatten = tree => !tree || typeof tree !== 'object' ? [] : [tree, ...[tree.props?.children || []].flat().flatMap(flatten)];
  for (const surface of ['terminal', 'desktop']) {
    const tree = await band(host, { surface, props: { hasSurvey: false } }, async () => 'other-mod');
    assert.equal(tree.props.children[0], 'other-mod');
    const elements = flatten(tree);
    assert.equal(elements.filter(e => e.type === 'Select').length, 0);
    const buttons = elements.filter(e => e.type === 'Button');
    assert.deepEqual(buttons.map(e => e.props.label), ['History sync · Prompt']);
    await buttons.find(e => e.props.key === 'settings').props.onPress();
    assert.deepEqual(opened.at(-1), { id: 'history-sync', title: 'History sync', focus: true, closeOnEscape: true });
    let pane = flatten(await render(host, { requestId: 'history-sync', surface }, async () => null));
    const selects = pane.filter(e => e.type === 'Select');
    assert.equal(selects.length, 3); // Destination and appearance; identified source is read-only.
    const target = selects.find(e => e.props.key === 'target');
    assert.ok(!target.props.options.some(p => p.value === A));
    await target.props.onSelect(B);
    await pane.find(e => e.props.key === 'continue').props.onPress();
    pane = flatten(await render(host, { requestId: 'history-sync', surface }, async () => null));
    const before = h.calls.length;
    await pane.find(e => e.props.key === 'preview').props.onPress();
    assert.deepEqual(h.calls.slice(before).map(c => c.action), ['Plan']);
    await pane.find(e => e.props.key === 'sync').props.onPress();
    assert.equal(h.calls.at(-1).action, 'Sync'); // No slash command needed.
    await pane.find(e => e.props.key === 'nav-backups').props.onPress();
    pane = flatten(await render(host, { requestId: 'history-sync', surface }, async () => null));
    assert.ok(pane.some(e => e.type === 'Text' && e.props.children === 'C:/Backups/receipt'));
    await pane.find(e => e.props.key === 'nav-accounts').props.onPress();
  }
  assert.equal(await band(host, { props: { hasSurvey: true } }, async () => 'survey'), 'survey');
  assert.equal(await band(host, { props: { view: { agentId: 'worker' } } }, async () => 'agent-panel'), 'agent-panel');
  const accounts = flatten(await render(host, { requestId: 'history-sync', surface: 'desktop' }, async () => null));
  await accounts.find(e => e.props.key === 'prompt-display').props.onSelect('hidden');
  assert.equal(await band(host, { props: {} }, async () => 'existing'), 'existing');
  // Hiding the launcher does not hide the command entry point.
  const command = hooks.find(h => h.event === 'command.run').hook;
  await command(host, { args: '' });
  assert.equal(opened.at(-1).id, 'history-sync');
});

test('copied session requires session-local account confirmation and never restores a source', async () => {
  const h = harness({ saved: { pair: { source: B, target: A } }, respond: async action => action === 'Profiles' ? {
    exitCode: 0, stdout: JSON.stringify({ Ok: true, Profiles: profiles, CurrentProfile: '', SessionProfiles: [A, B] }), stderr: '',
  } : null }), c = createController();
  await c.initialize(h.api);
  assert.equal(c.view.source, '');
  await c.sync(); assert.ok(!h.calls.some(r => r.action === 'Sync'));
  await c.choose(B, A); await c.sync();
  assert.equal(h.calls.at(-1).argv[h.calls.at(-1).argv.indexOf('-SourceProfile') + 1], B);
  assert.equal(h.saved.get('destination'), A);
  c.stop(); await c.reopen(); assert.equal(c.view.source, '');
});

test('discovery after sync retains a source established in the same session', async () => {
  let duplicated = false;
  const { c } = await ready({ respond: async action => action === 'Profiles' && duplicated ? {
    exitCode: 0, stdout: JSON.stringify({ Ok: true, Profiles: profiles, CurrentProfile: '', SessionProfiles: [A, B] }), stderr: '',
  } : null });
  duplicated = true; await c.refresh(); assert.equal(c.view.source, A);
});

test('changed session profile pauses automation and cannot become its own destination', async () => {
  let changed = false;
  const { c, calls } = await ready({ respond: async action => action === 'Profiles' && changed ? {
    exitCode: 0, stdout: JSON.stringify({ Ok: true, Profiles: profiles, CurrentProfile: B, SessionProfiles: [B] }), stderr: '',
  } : null });
  await c.start(); changed = true; await c.refresh();
  assert.equal(c.view.enabled, false); assert.equal(c.view.source, B); assert.equal(c.view.target, '');
  assert.equal(calls.at(-1).action, 'Release');
});

test('a newly saved session card resolves an initially unknown source without a command', async () => {
  let discovered = false;
  const h = harness({ respond: async action => action === 'Profiles' && !discovered ? {
    exitCode: 0, stdout: JSON.stringify({ Ok: true, Profiles: profiles, CurrentProfile: '', SessionProfiles: [] }), stderr: '',
  } : null }), c = createController();
  await c.initialize(h.api); assert.equal(c.view.source, '');
  discovered = true; c.afterTurn(); await h.timers.at(-1).fn();
  assert.equal(c.view.source, A); assert.ok(!h.calls.some(r => ['Arm', 'Sync'].includes(r.action)));
});

test('settings and detail expansion do not sync, and expansion survives a reload paused', async () => {
  const { c, calls, saved, api } = await ready();
  await c.choosePromptDisplay('compact');
  await control(renderBand(elements, c, () => {}), 'details').onPress();
  await control(renderPane(elements, c), 'nav-backups').onPress();
  assert.equal(calls.length, 0);
  assert.equal(saved.get('expanded'), true);
  const reloaded = createController(); await reloaded.initialize(api);
  assert.equal(reloaded.view.expanded, true);
  assert.equal(reloaded.view.enabled, false);
  assert.ok(!calls.some(r => ['Arm', 'Sync'].includes(r.action)));
});

test('selection clears stale preview but retains receipts with their original direction across reloads', async () => {
  const { c, api, saved } = await ready();
  await c.choosePromptDisplay('compact');
  await c.sync(); await c.preview();
  const completed = c.view.lastResult;
  await c.choose(A, '');
  assert.equal(c.view.preview, null); assert.deepEqual(c.view.report, []);
  assert.deepEqual(c.view.lastResult, completed);
  assert.equal(c.view.receipts[0].target, B);
  assert.ok(!textContent(renderBand(elements, c, () => {})).includes(' · Last '));
  c.showSection('backups');
  assert.match(textContent(renderPane(elements, c)), /a@example.test.*→ b@example.test/);
  const reloaded = createController(); await reloaded.initialize(api);
  assert.deepEqual(reloaded.view.lastResult, saved.get('lastResult'));
  assert.equal(reloaded.view.receipts[0].backup, 'C:/Backups/receipt');
  assert.equal(reloaded.view.enabled, false);
  await reloaded.choose(A, B);
  assert.match(textContent(renderBand(elements, reloaded, () => {})), / · Last /);
});

test('interrupted copy persists its prepared backup without reporting a completed sync', async () => {
  const { c, saved, api } = await ready({ respond: async action => action === 'Sync' ? {
    exitCode: 1, stderr: '', stdout: JSON.stringify({ Ok: false, Error: 'Destination changed', Backup: 'C:/Prepared/backup' }),
  } : null });
  await c.sync();
  assert.equal(c.view.lastResult, null);
  assert.equal(saved.get('receipts')[0].status, 'prepared');
  const reloaded = createController(); await reloaded.initialize(api); reloaded.showSection('backups');
  assert.match(textContent(renderPane(elements, reloaded)), /Interrupted — inspect before retrying/);
  assert.match(textContent(renderPane(elements, reloaded)), /Destination changed/);
});

test('a preference-store failure retains successful results without repeating the copy', async () => {
  const { c, calls, api } = await ready();
  api.storeSet = async () => { throw new Error('store unavailable'); };
  await c.sync();
  assert.deepEqual(calls.map(r => r.action), ['Sync']);
  assert.equal(c.view.lastResult.backup, 'C:/Backups/receipt');
  assert.equal(c.view.receipts.length, 1);
  assert.match(c.view.notice, /remains on disk/);
  assert.equal(c.view.error, '');
});

test('recent backups are bounded, deduplicated, and a no-change sync keeps prior receipts', async () => {
  let count = 0, noChanges = false;
  const { c, saved } = await ready({ respond: async action => action === 'Sync' ? {
    exitCode: 0, stderr: '', stdout: JSON.stringify({ Ok: true, Action: 'Sync', Backup: noChanges ? '' : `C:/Backups/${++count}` }),
  } : null });
  for (let i = 0; i < 10; i++) await c.sync();
  assert.equal(c.view.receipts.length, 8);
  assert.equal(c.view.receipts.at(-1).backup, 'C:/Backups/3');
  count = 9; await c.sync();
  assert.equal(new Set(c.view.receipts.map(r => r.backup)).size, 8);
  noChanges = true; await c.sync();
  assert.equal(c.view.lastResult.backup, '');
  assert.equal(c.view.receipts[0].backup, 'C:/Backups/10');
  assert.equal(saved.get('receipts').length, 8);
});

test('UI callbacks block writes without accounts and expose source confirmation when needed', async () => {
  const { c, calls } = await ready(); await c.choose(A, ''); calls.length = 0;
  await c.choosePromptDisplay('compact');
  await control(renderBand(elements, c, () => {}), 'sync').onPress();
  c.showSection('sync');
  await control(renderPane(elements, c), 'preview').onPress();
  await control(renderPane(elements, c), 'auto').onPress();
  assert.equal(calls.length, 0);
  c.view.source = ''; c.view.sourceCandidates = [A, B]; c.showSection('accounts');
  await control(renderPane(elements, c), 'source-confirmation').onSelect(A);
  assert.equal(c.view.source, A);
  assert.equal(flatten(renderPane(elements, c)).filter(e => e.type === 'Select' && e.props.key === 'source-confirmation').length, 0);
});

test('Pause remains reachable in the compact band while an automatic copy is running', async () => {
  let finish;
  const blocked = new Promise(resolve => { finish = resolve; });
  const { c, calls } = await ready({ respond: async action => { if (action === 'Sync') await blocked; return null; } });
  const starting = c.start();
  while (!calls.some(r => r.action === 'Sync')) await Promise.resolve();
  const pausing = control(renderBand(elements, c, () => {}), 'auto').onPress();
  await Promise.resolve();
  assert.equal(c.view.enabled, false);
  finish(); await Promise.all([starting, pausing]);
  assert.equal(calls.at(-1).action, 'Release');
});

test('disappearing destination pauses and releases automatic control', async () => {
  let removed = false;
  const { c, calls } = await ready({ respond: async action => action === 'Profiles' && removed ? {
    exitCode: 0, stderr: '', stdout: JSON.stringify({ Ok: true, Profiles: [profiles[0]], CurrentProfile: A, SessionProfiles: [A] }),
  } : null });
  await c.start(); removed = true; await c.refresh();
  assert.equal(c.view.enabled, false); assert.equal(c.view.target, '');
  assert.equal(calls.at(-1).action, 'Release');
});

test('launcher keeps setup errors in the pane and changing display never starts sync', async () => {
  const { c, calls, saved, api } = await ready();
  c.view.error = 'Cannot choose a unique Desktop history directory.';
  const launcher = renderBand(elements, c, () => {});
  assert.equal(flatten(launcher).filter(e => e.type === 'Button').length, 1);
  assert.equal(textContent(launcher), '');
  assert.equal(control(launcher, 'settings').label, 'History sync · Prompt · needs attention');
  assert.match(textContent(renderPane(elements, c)), /Cannot choose/);
  await c.choosePromptDisplay('hidden');
  assert.equal(renderBand(elements, c, () => {}), null);
  assert.equal(calls.length, 0);
  assert.equal(saved.get('promptDisplay'), 'hidden');
  const reloaded = createController(); await reloaded.initialize(api);
  assert.equal(reloaded.view.promptDisplay, 'hidden');
  assert.equal(reloaded.view.enabled, false);
  await reloaded.choosePromptDisplay('unsupported');
  assert.equal(reloaded.view.promptDisplay, 'hidden');
});

test('location preferences persist without copying or granting auto-sync permission', async () => {
  const {c,calls,saved,api}=await ready();
  assert.equal(c.view.launcherPlacement,'all');
  await c.chooseLauncherPlacement('mode');
  assert.equal(calls.length,0);assert.equal(saved.get('launcherPlacement'),'mode');
  const restored=createController();await restored.initialize(api);
  assert.equal(restored.view.launcherPlacement,'mode');assert.equal(restored.view.enabled,false);
  await restored.chooseLauncherPlacement('sidebar');assert.equal(restored.view.launcherPlacement,'mode');
});

test('copying diagnostics preserves the full error without launching a helper', async () => {
  const {c,calls}=await ready();
  c.view.error='Cannot safely read profile/local_fixture.json: Invalid session identity.';
  const copies=[];
  await control(renderPane(elements,c,async(text,surface)=>{copies.push({text,surface});return{isCopied:true};}),'copy-diagnostics').onPress({surface:'desktop'});
  assert.equal(calls.length,0);assert.match(copies[0].text,/Invalid session identity/);
  assert.equal(copies[0].surface,'desktop');assert.equal(c.view.copyStatus,'Copied to clipboard.');
});

test('copy preview retains report text beyond the display limit and its original direction', async () => {
  const {c,calls}=await ready();await c.preview();calls.length=0;c.showSection('sync');
  c.view.report=[{Action:'Skipped',File:'local_pending.json',Detail:'Missing CLI session ID'},
    {Action:'Add',File:'local_ready.json',Detail:'x'.repeat(12000)}];
  c.view.preview.reportTotal=2;
  let copied='';
  await control(renderPane(elements,c,async text=>{copied=text;return{isCopied:true};}),'copy-preview').onPress({surface:'desktop'});
  assert.equal(calls.length,0);assert.equal(copied,previewText(c.view));assert.ok(copied.length>12000);
  assert.ok(copied.includes(`From: a@example.test`));assert.ok(copied.includes(`To: b@example.test`));
});

test('copy failures do not pause automation or overwrite history errors', async () => {
  const {c,calls}=await ready();c.view.enabled=true;c.view.error='Existing history diagnostic';
  await c.copyText('fixture',async()=>({isCopied:false,reason:'refused'}),'desktop');
  assert.equal(c.view.enabled,true);assert.equal(c.view.error,'Existing history diagnostic');assert.match(c.view.copyStatus,/refused/);
  await c.copyText('fixture',async()=>{throw new Error('clipboard unavailable');},'desktop');
  assert.match(c.view.copyStatus,/clipboard unavailable/);assert.equal(calls.length,0);
});

const state=(Title,Archived=false)=>({Title,Archived});
const comparisonRows=[
  {File:'local_new.json',Title:'New active work',Action:'Add',Before:null,After:state('New active work'),Detail:'New card'},
  {File:'local_archive.json',Title:'Renamed project',Action:'Update',Before:state('Old project'),After:state('Renamed project',true),Detail:'Rename and archive',ChangedFields:['title','isArchived']},
  {File:'local_conflict.json',Title:'Conflicting source',Action:'Conflict',Before:state('Keep Gmail title'),After:state('Keep Gmail title'),Detail:'Identity differs'},
  {File:'local_pending.json',Title:'Pending startup',Action:'Skipped',Before:null,After:null,Detail:'CLI ID missing'},
  {File:'local_destination.json',Title:'Gmail only',Action:'Skipped',Before:state('Gmail only',true),After:state('Gmail only',true),Detail:'Destination-only'},
  {File:'local_matching.json',Title:'Already matching',Action:'Unchanged',Before:state('Already matching'),After:state('Already matching'),Detail:'Same metadata'},
];
async function compared(){
  const h=await ready({respond:async action=>action==='Plan'?{exitCode:0,stderr:'',stdout:JSON.stringify({Ok:true,Action:'Plan',Additions:1,Updates:1,Rows:comparisonRows,Report:[],RowsTotal:6})}:null});
  await h.c.preview();h.c.showSection('sync');h.calls.length=0;return h;
}
test('active and archived filters use the after state, retaining conflicts in their unchanged state',async()=>{
  const {c,calls}=await compared();
  assert.equal(filteredPreviewRows(c.view).length,6);
  await control(renderPane(elements,c),'filter-archived').onPress();
  assert.deepEqual(filteredPreviewRows(c.view).map(r=>r.Title),['Gmail only','Renamed project']);
  await control(renderPane(elements,c),'filter-active').onPress();
  assert.deepEqual(filteredPreviewRows(c.view).map(r=>r.Title),['Already matching','Conflicting source','New active work']);
  c.filterPreview('all');c.filterPreviewChanges('issues');
  assert.equal(filteredPreviewRows(c.view).length,3);assert.equal(calls.length,0);
});
test('comparison shows real titles and exposes file IDs only in selected details',async()=>{
  const {c,calls}=await compared();
  let tree=renderPane(elements,c);
  assert.match(textContent(tree),/Renamed project/);assert.match(textContent(tree),/Old project/);
  assert.ok(!textContent(tree).includes('local_archive.json'));
  await control(tree,'details-local_archive.json').onPress();
  assert.match(textContent(renderPane(elements,c)),/Session file: local_archive.json/);
  assert.equal(calls.length,0);
});

test('preview details show a repaired parent link and side-session state',async()=>{
  const {c,calls}=await compared();
  const row=c.view.previewRows.find(r=>r.File==='local_archive.json');
  row.After.ParentSessionId='local_parent';row.After.SideSession=true;
  row.ChangedFields.push('spawnedFrom');
  c.selectPreview(row.File);
  const text=textContent(renderPane(elements,c));
  assert.match(text,/Parent before: None\nParent after: local_parent/);
  assert.match(text,/Side session after: Yes/);
  assert.equal(calls.length,0);
});
test('title search matches old names and copying the filtered table follows the current filter',async()=>{
  const {c,calls}=await compared();
  control(renderPane(elements,c),'preview-search').onInput('OLD PROJECT');
  assert.deepEqual(filteredPreviewRows(c.view).map(r=>r.Title),['Renamed project']);
  let copied='';
  await control(renderPane(elements,c,async text=>{copied=text;return{isCopied:true};}),'copy-filtered').onPress({surface:'desktop'});
  assert.match(copied,/Old project\tActive\tRenamed project\tArchived/);
  assert.ok(!copied.includes('New active work'));assert.equal(calls.length,0);
});
test('comparison paginates without losing rows and selection changes clear stale comparison data',async()=>{
  const {c,calls}=await compared();
  c.view.previewRows=Array.from({length:35},(_,i)=>({File:`local_${i}.json`,Title:`Session ${String(i).padStart(2,'0')}`,Action:'Add',After:state('Work'),Before:null}));
  let tree=renderPane(elements,c);
  assert.equal(flatten(tree).filter(e=>e.props.key?.startsWith('preview-row-')).length,15);
  await control(tree,'preview-next').onPress();
  assert.equal(c.view.previewPage,1);c.filterPreview('archived');assert.equal(c.view.previewPage,0);
  c.filterPreview('all');await c.choose(A,'');
  assert.equal(c.view.previewRows.length,0);assert.equal(c.view.preview,null);
  assert.ok(!calls.some(r=>r.action==='Sync'));
});
