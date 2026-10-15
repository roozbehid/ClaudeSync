const PROFILE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function describeResult(result) {
  const mode = result.Action === 'Plan' ? 'Preview' : 'Synced';
  return `${mode}: ${result.Additions ?? 0} added, ${result.Updates ?? 0} updated, ${result.Conflicts ?? 0} conflicts, ${result.Skipped ?? 0} skipped.`;
}

export function createController() {
  const view = {
    profiles: [], source: '', sourceCandidates: [], target: '', enabled: false, busy: false,
    status: 'Finding the account for this session…', error: '',
    backup: '', report: [], previewRows: [], previewFilter: 'all', previewChanges: 'all', previewSearch: '', previewPage: 0,
    selectedPreview: '', configPath: '', lastSync: '', copyStatus: '',
    section: 'accounts', expanded: false, promptDisplay: 'launcher', launcherPlacement: 'all', preview: null, lastResult: null, receipts: [], notice: '',
  };
  let api;
  let owner = '';
  let configOverride = '';
  let running = null;
  let ended = false;
  let interval = null;
  let debounce = null;
  let revision = 0;

  function redraw() { api.redraw('ui.render'); }
  async function remember(key, value) {
    try { await api.storeSet(key, value); }
    catch { view.notice = 'Could not remember preferences or recent results. Any backup already created remains on disk.'; redraw(); }
  }
  function showSection(section) {
    if (!['accounts', 'sync', 'backups'].includes(section)) return;
    view.section = section; redraw();
  }
  function filterPreview(value) {
    if (!['all', 'active', 'archived'].includes(value)) return;
    view.previewFilter = value; view.previewPage = 0; redraw();
  }
  function filterPreviewChanges(value) {
    if (!['all', 'changes', 'issues'].includes(value)) return;
    view.previewChanges = value; view.previewPage = 0; redraw();
  }
  function searchPreview(value) { view.previewSearch = String(value).slice(0, 200); view.previewPage = 0; redraw(); }
  function pagePreview(value) { if (Number.isInteger(value) && value >= 0) { view.previewPage = value; redraw(); } }
  function selectPreview(file) { if (view.previewRows.some(r => r.File === file)) { view.selectedPreview = view.selectedPreview === file ? '' : file; redraw(); } }
  function clearPreview() { view.report = []; view.previewRows = []; view.preview = null; view.previewPage = 0; view.selectedPreview = ''; }
  async function copyText(text, writer, surface) {
    try {
      const result = await writer(text, surface);
      view.copyStatus = result?.isCopied ? 'Copied to clipboard.' : `Could not copy to clipboard (${result?.reason || 'unavailable'}).`;
    } catch (error) { view.copyStatus = `Copy failed: ${error.message}`; }
    redraw();
  }
  async function toggleDetails() {
    view.expanded = !view.expanded; redraw();
    await remember('expanded', view.expanded);
  }
  async function choosePromptDisplay(value) {
    if (!['launcher', 'compact', 'hidden'].includes(value)) return;
    view.promptDisplay = value; redraw();
    await remember('promptDisplay', value);
  }
  async function chooseLauncherPlacement(value) {
    if (!['all', 'band', 'mode', 'hint'].includes(value)) return;
    view.launcherPlacement = value; redraw();
    await remember('launcherPlacement', value);
  }
  async function rememberBackup(result, pair) {
    const receipt = { backup: result.Backup, source: pair?.source || '', target: pair?.target || '',
      at: new Date(await api.now()).toISOString(), status: result.Ok ? 'complete' : 'prepared',
      message: result.Ok ? describeResult(result) : result.Error || 'Sync interrupted; inspect this backup before retrying.' };
    view.receipts = [receipt, ...view.receipts.filter(r => r.backup !== receipt.backup)].slice(0, 8);
    await remember('receipts', view.receipts);
  }
  function selectedPair() {
    if (!PROFILE_ID.test(view.source)) throw new Error('Confirm which account is open in Sync settings first.');
    if (!PROFILE_ID.test(view.target)) throw new Error('Choose an inactive destination account first.');
    if (view.source === view.target) throw new Error('Source and destination must be different.');
    if (!view.profiles.some(p => p.Id === view.source) || !view.profiles.some(p => p.Id === view.target)) {
      throw new Error('A selected profile is no longer available. Refresh profiles.');
    }
    return { source: view.source, target: view.target };
  }
  async function bridge(action, pair, keepLease = false) {
    if (api.windows === false) throw new Error('Account history sync runs on native Windows sessions.');
    const argv = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', `${api.root}/scripts/HistorySync-Bridge.ps1`, '-Action', action];
    if (configOverride) argv.push('-ConfigPath', configOverride);
    if (pair) argv.push('-SourceProfile', pair.source, '-TargetProfile', pair.target);
    if (action !== 'Release') argv.push('-SessionId', owner);
    if (['Arm', 'Sync', 'Release'].includes(action)) argv.push('-OwnerSession', owner);
    if (keepLease) argv.push('-KeepLease');
    const processResult = await api.processRun(argv, { timeoutMs: 90_000 });
    let result;
    try { result = JSON.parse(processResult.stdout.trim()); }
    catch { throw new Error(`History helper returned invalid output (exit ${processResult.exitCode}). ${processResult.stderr?.slice(0, 500) || ''}`); }
    if (result.Backup) { view.backup = result.Backup; await rememberBackup({ ...result, Ok: result.Ok && processResult.exitCode === 0 }, pair); }
    if (result.ConfigPath) view.configPath = result.ConfigPath;
    if (processResult.exitCode !== 0 || !result.Ok) throw new Error(result.Error || processResult.stderr || 'History helper failed.');
    return result;
  }
  async function release() {
    if (!owner) return;
    try { await bridge('Release'); }
    catch (error) { view.error = `Paused; controller lease expires within three minutes. ${error.message}`; }
  }
  async function run(label, work) {
    if (ended || running) return null;
    view.busy = true; view.error = ''; view.status = label; redraw();
    // Promise.resolve defers work until running is assigned, including synchronous failures.
    running = Promise.resolve().then(work).catch(async error => {
      view.enabled = false;
      view.error = error.message;
      view.status = 'Sync paused after an error.';
      await release();
      return null;
    }).finally(() => { running = null; view.busy = false; redraw(); });
    return running;
  }
  async function sync(automatic = false) {
    if (automatic && !view.enabled) return null;
    return run('Checking saved history…', async () => {
      const pair = selectedPair();
      const result = await bridge('Sync', pair, view.enabled);
      view.status = describeResult(result);
      const at = new Date(await api.now()).toISOString();
      view.lastSync = new Date(at).toLocaleTimeString();
      view.lastResult = { source: pair.source, target: pair.target, at, message: view.status, backup: result.Backup || '' };
      await remember('lastResult', view.lastResult);
      if (result.Backup) api.log(`History backup: ${result.Backup}`);
      return result;
    });
  }
  async function pause() {
    revision += 1;
    view.enabled = false;
    debounce?.cancel(); debounce = null;
    redraw();
    if (running) await running;
    view.enabled = false;
    await release();
    view.status = 'Auto-sync paused.';
    redraw();
  }
  async function refresh() {
    return run('Finding local profiles…', async () => {
      const result = await bridge('Profiles');
      view.profiles = result.Profiles || [];
      view.sourceCandidates = result.SessionProfiles || [];
      const previousSource = view.source;
      const previousTarget = view.target;
      const wasEnabled = view.enabled;
      if (view.source && !view.profiles.some(p => p.Id === view.source)) view.source = '';
      if (result.CurrentProfile) view.source = result.CurrentProfile;
      else if (view.sourceCandidates.length && !view.sourceCandidates.includes(view.source)) view.source = '';
      if (previousSource !== view.source) {
        revision += 1; view.enabled = false;
        debounce?.cancel(); debounce = null;
        if (previousSource) await release();
      }
      if (view.target && !view.profiles.some(p => p.Id === view.target)) { view.target = ''; view.enabled = false; }
      if (view.target === view.source) view.target = '';
      if (previousSource === view.source && previousTarget !== view.target && wasEnabled) await release();
      if (previousSource !== view.source || previousTarget !== view.target) clearPreview();
      view.status = view.source ? 'This account → inactive destination. Choose a destination and sync.' :
        view.sourceCandidates.length > 1 ? 'This session exists in several accounts. Confirm the open account in Sync settings.' :
        'No account folder identifies this session yet. Confirm the open account in Sync settings, or refresh after a turn.';
      return result;
    });
  }
  async function choose(source, target) {
    if (view.source && source !== view.source) throw new Error('Source is this session’s account. Switch accounts and open a fresh session to reverse the direction.');
    if (source && (!view.profiles.some(p => p.Id === source) || (view.sourceCandidates.length && !view.sourceCandidates.includes(source)))) {
      throw new Error('The chosen source does not contain this session. Refresh profiles.');
    }
    // Confirming an ambiguous source is session-local, never a saved login assumption.
    await pause();
    if (view.source && source !== view.source) throw new Error('The current source changed while waiting. Choose the destination again.');
    view.source = source; view.target = target;
    clearPreview();
    await remember('destination', target);
    view.status = source ? 'This account → selected destination. Destination must be inactive.' : 'Destination selected. Confirm the open account in Sync settings.';
    redraw();
  }
  async function preview() {
    return run('Building a read-only preview…', async () => {
      const result = await bridge('Plan', selectedPair());
      view.report = result.Report || [];
      view.previewRows = Array.isArray(result.Rows) ? result.Rows : [];
      view.previewPage = 0; view.selectedPreview = '';
      view.status = describeResult(result);
      view.preview = { source: view.source, target: view.target, message: view.status,
        writes: result.Writes ?? 0, reportTotal: result.ReportTotal ?? view.report.length,
        reportTruncated: result.ReportTruncated === true, rowsTotal: result.RowsTotal ?? view.previewRows.length,
        rowsTruncated: result.RowsTruncated === true, at: new Date(await api.now()).toISOString() };
      return result;
    });
  }
  async function start() {
    const startingRevision = revision;
    const result = await run('Starting auto-sync…', async () => {
      const pair = selectedPair();
      await bridge('Arm', pair);
      if (ended || startingRevision !== revision) { await release(); return null; }
      view.enabled = true;
      view.status = 'Auto-sync active: source → destination every 30 seconds.';
      return true;
    });
    if (result && view.enabled) await sync(true);
  }
  function stop() {
    revision += 1;
    ended = true; view.enabled = false;
    interval?.cancel(); debounce?.cancel();
  }
  async function initialize(adapter) {
    api = adapter;
    if (api.windows === false) {
      view.error = 'Account history sync runs on native Windows sessions.';
      return;
    }
    owner = await api.sessionId();
    configOverride = (await api.envGet('ACCOUNT_HISTORY_SYNC_CONFIG')) || '';
    view.source = ''; view.sourceCandidates = [];
    const saved = await api.storeGet('destination');
    view.target = typeof saved === 'string' ? saved : '';
    view.expanded = (await api.storeGet('expanded')) === true;
    const promptDisplay = await api.storeGet('promptDisplay');
    view.promptDisplay = ['launcher', 'compact', 'hidden'].includes(promptDisplay) ? promptDisplay : 'launcher';
    const placement = await api.storeGet('launcherPlacement');
    view.launcherPlacement = ['all', 'band', 'mode', 'hint'].includes(placement) ? placement : 'all';
    const receipts = await api.storeGet('receipts');
    view.receipts = Array.isArray(receipts) ? receipts.filter(r => r && typeof r.backup === 'string' && r.backup && typeof r.message === 'string' &&
      PROFILE_ID.test(r.source) && PROFILE_ID.test(r.target) && !Number.isNaN(Date.parse(r.at)) &&
      ['complete', 'prepared'].includes(r.status)).slice(0, 8) : [];
    view.backup = view.receipts[0]?.backup || '';
    const lastResult = await api.storeGet('lastResult');
    view.lastResult = lastResult && PROFILE_ID.test(lastResult.source) && PROFILE_ID.test(lastResult.target) &&
      typeof lastResult.message === 'string' && !Number.isNaN(Date.parse(lastResult.at)) ? lastResult : null;
    view.lastSync = view.lastResult ? new Date(view.lastResult.at).toLocaleTimeString() : '';
    // Never persist auto-enable across sessions, login changes or hot reloads.
    await release();
    await refresh();
    interval = api.every(30_000, async () => { if (ended) return; if (view.enabled) await sync(true); else if (!view.source) await refresh(); });
  }
  function afterTurn() {
    if (ended) return;
    if (!view.enabled && view.source) return;
    debounce?.cancel();
    debounce = api.after(1500, async () => { if (ended) return; if (view.enabled) await sync(true); else if (!view.source) await refresh(); });
  }
  async function reopen() {
    if (!ended) return;
    if (running) await running;
    await release();
    ended = false;
    view.enabled = false; view.error = '';
    interval = null; debounce = null;
    await initialize(api);
    view.status = `Session changed; auto-sync paused. ${view.status}`;
    redraw();
  }
  function resolveSelector(selector) {
    const matches = view.profiles.filter(p => p.Id === selector || p.Email?.toLowerCase() === selector.toLowerCase());
    if (matches.length !== 1) throw new Error('Profile selector is unknown or ambiguous. Use a full profile ID from /history-sync profiles.');
    return matches[0].Id;
  }
  function statusText() {
    return `${view.enabled ? 'Auto-sync active' : 'Auto-sync paused'}; ${view.source || '(confirm open account)'} → ${view.target || '(choose destination)'}. ${view.status}${view.error ? ` ${view.error}` : ''}`;
  }
  return { view, initialize, refresh, choose, preview, start, pause, sync, stop, afterTurn, reopen, resolveSelector, statusText,
    showSection, toggleDetails, choosePromptDisplay, chooseLauncherPlacement, copyText,
    filterPreview, filterPreviewChanges, searchPreview, pagePreview, selectPreview };
}
