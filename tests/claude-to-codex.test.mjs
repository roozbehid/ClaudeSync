import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {createImportPlan, applyImportPlan, stitchTranscripts, hash} from '../lib/claude-to-codex.mjs';
import {CodexAppServer, resolveCodexLaunch} from '../lib/codex-app-server.mjs';

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(tmpdir(), 'claude-codex-tests-'));
  t.after(async () => {
    assert.equal(path.dirname(path.resolve(root)), path.resolve(tmpdir()));
    assert.ok(path.basename(root).startsWith('claude-codex-tests-'));
    await fs.rm(root, {recursive: true, force: true, maxRetries: 20, retryDelay: 100});
  });
  const stateRoot = path.join(root, 'state'), codexHome = path.join(root, 'codex');
  const profileRoot = path.join(root, 'profile'), projectsRoot = path.join(root, 'projects'), cwd = path.join(root, 'SampleProject');
  for (const dir of [stateRoot, codexHome, profileRoot, projectsRoot, cwd]) await fs.mkdir(dir);
  const id = 'local_' + randomUUID(), sid = randomUUID(), first = randomUUID(), second = randomUUID();
  const transcript = path.join(projectsRoot, sid + '.jsonl'), cardPath = path.join(profileRoot, id + '.json');
  const messages = [
    {type: 'user', uuid: first, parentUuid: null, sessionId: sid, cwd, timestamp: new Date().toISOString(), message: {role: 'user', content: 'Explain the sample.'}},
    {type: 'assistant', uuid: second, parentUuid: first, sessionId: sid, cwd, timestamp: new Date().toISOString(), message: {role: 'assistant', content: [{type: 'text', text: 'The synthetic sample is ready.'}]}},
  ];
  await fs.writeFile(transcript, messages.map(JSON.stringify).join('\n') + '\n');
  await fs.writeFile(cardPath, JSON.stringify({sessionId: id, cliSessionId: sid, cwd, title: 'Release planning'}));
  const record = {id, title: 'Release planning', cwd, parent: '', archived: false, cardPath, cardHash: hash(await fs.readFile(cardPath)), transcripts: [{id: sid, path: transcript}]};
  const request = {action: 'Plan', stateRoot, codexHome, source: {profileId: 'synthetic-profile', profileRoot, projectsRoot}, scope: {mode: 'Session', session: id}, records: [record]};
  return {root, request, record, messages, transcript, async saveMessages(rows = messages) { await fs.writeFile(transcript, rows.map(JSON.stringify).join('\n') + '\n'); }};
}

function mockServer(f, options = {}) {
  const calls = [], target = randomUUID();
  let sessions;
  const server = {
    calls, target,
    async initialize() { return {codexHome: f.request.codexHome}; }, async close() {},
    async request(method, params) {
      calls.push({method, params});
      if (method === 'externalAgentConfig/import/readHistories') return {data: options.histories ?? []};
      if (method === 'externalAgentConfig/detect') {
        if (options.detectError) throw new Error('Synthetic detection failed before submission');
        const staged = await fs.readdir(path.join(f.request.stateRoot, 'source-home/.claude/projects'), {recursive: true});
        return {items: [{itemType: 'CONFIG', description: 'Must never import configuration'}, {itemType: 'SESSIONS', details: {sessions: staged.filter(name => name.endsWith('.jsonl')).map(name => ({path: path.join(f.request.stateRoot, 'source-home/.claude/projects', name), cwd: f.record.cwd}))}}]};
      }
      if (method === 'externalAgentConfig/import') {
        if (options.deadBeforeSend) { server.failure = new Error('Synthetic dead transport'); throw Object.assign(server.failure, {notSubmitted: true, method}); }
        sessions = params.migrationItems[0].details.sessions; return {importId: 'synthetic-import'};
      }
      if (method === 'thread/read') return {thread: {id: params.threadId, cwd: f.record.cwd, name: null}};
      if (method === 'thread/name/set' && options.failNaming) throw new Error('Synthetic interruption after creation');
      if (['thread/name/set', 'thread/archive'].includes(method)) return {};
      throw new Error('Unexpected method ' + method);
    },
    async waitFor() {
      if (options.timeout) { if (options.terminal) server.failure = new Error('Synthetic terminal timeout'); throw new Error('Synthetic completion timeout; outcome unknown.'); }
      if (options.failed) return {itemTypeResults: [{successes: [], failures: [{message: 'Synthetic native failure', source: sessions[0].path}]}]};
      return {itemTypeResults: [{successes: [{itemType: 'SESSIONS', source: sessions[0].path, target}], failures: []}]};
    },
  };
  return server;
}

async function memoryCompactionFixture(t) {
  const f = await fixture(t), [start, head] = f.messages;
  const firstResult = {...start, uuid: randomUUID(), parentUuid: head.uuid, message: {role: 'user', content: [{type: 'tool_result', tool_use_id: 'sample_first', content: 'First preserved result'}]}};
  const call = {...head, uuid: randomUUID(), parentUuid: firstResult.uuid, message: {role: 'assistant', content: [{type: 'tool_use', id: 'sample_second', name: 'SampleRead', input: {value: 'second'}}]}};
  const tail = {...start, uuid: randomUUID(), parentUuid: call.uuid, message: {role: 'user', content: [{type: 'tool_result', tool_use_id: 'sample_second', content: 'Final preserved result'}]}};
  const memory = randomUUID(), middleMemory = randomUUID();
  const boundary = {type: 'system', subtype: 'compact_boundary', uuid: randomUUID(), parentUuid: null, logicalParentUuid: memory};
  const attachment = {type: 'attachment', uuid: randomUUID(), parentUuid: boundary.uuid};
  const summary = {...start, uuid: randomUUID(), parentUuid: attachment.uuid, isCompactSummary: true, message: {role: 'user', content: 'Generated recap to omit'}};
  boundary.compactMetadata = {preservedSegment: {headUuid: head.uuid, tailUuid: tail.uuid, anchorUuid: summary.uuid}, preservedMessages: {anchorUuid: summary.uuid, uuids: [head.uuid, call.uuid, firstResult.uuid, tail.uuid], allUuids: [head.uuid, call.uuid, middleMemory, firstResult.uuid, tail.uuid, memory]}};
  const abandoned = {...head, uuid: randomUUID(), parentUuid: head.uuid, message: {role: 'assistant', content: 'Abandoned branch to omit'}};
  const question = {...start, uuid: randomUUID(), parentUuid: summary.uuid, message: {role: 'user', content: 'Continue after verified compaction'}};
  const records = [start, head, firstResult, call, tail, abandoned, boundary, attachment, summary, question];
  await f.saveMessages(records);
  return {...f, records, boundary, attachment, summary, head, tail, firstResult, question};
}

test('plan freezes readable messages without touching destination or originals', async t => {
  const f = await fixture(t), before = await fs.readFile(f.transcript);
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].status, 'Ready'); assert.equal(plan.rows[0].stats.messages, 2);
  assert.deepEqual(await fs.readdir(f.request.codexHome), []);
  assert.deepEqual(await fs.readFile(f.transcript), before);
  const staged = (await fs.readFile(plan.rows[0].snapshotPath, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(staged[0].sessionId, plan.rows[0].snapshotId); assert.notEqual(staged[0].sessionId, f.record.transcripts[0].id);
});

test('stitches continuation copies once, follows active ancestry, excludes sidechains', async t => {
  const f = await fixture(t), continuation = path.join(f.request.source.projectsRoot, randomUUID() + '.jsonl');
  const branch = {...f.messages[1], uuid: randomUUID(), message: {role: 'assistant', content: 'Abandoned branch'}};
  const next = {...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: 'Continue the example'}};
  const side = {...next, uuid: randomUUID(), isSidechain: true};
  await fs.writeFile(continuation, [...f.messages, branch, next, side].map(JSON.stringify).join('\n') + '\n');
  f.record.transcripts.push({path: continuation});
  const result = await stitchTranscripts(f.record.transcripts, f.request.source.projectsRoot);
  assert.equal(result.messages.length, 3); assert.equal(result.messages.at(-1).content[0].text, 'Continue the example');
});

test('rejects partial records, conflicting IDs, missing ancestry and cycles', async t => {
  const f = await fixture(t);
  await fs.writeFile(f.transcript, JSON.stringify(f.messages[0]));
  assert.match((await createImportPlan(f.request)).rows[0].reason, /incomplete JSONL/);
  await f.saveMessages([...f.messages, {...f.messages[1], message: {role: 'assistant', content: 'Different content'}}]);
  assert.match((await createImportPlan(f.request)).rows[0].reason, /Conflicting repeated/);
  await f.saveMessages([{...f.messages[0], parentUuid: randomUUID()}]);
  assert.match((await createImportPlan(f.request)).rows[0].reason, /missing message/);
  await f.saveMessages([{...f.messages[0], parentUuid: f.messages[0].uuid}]);
  assert.match((await createImportPlan(f.request)).rows[0].reason, /Cyclic/);
});

test('a later continuation branch replaces the abandoned earlier tail', async t => {
  const f = await fixture(t), continuation = path.join(f.request.source.projectsRoot, randomUUID() + '.jsonl');
  const replacement = {...f.messages[1], uuid: randomUUID(), parentUuid: f.messages[0].uuid, message: {role: 'assistant', content: 'Replacement answer'}};
  await fs.writeFile(continuation, [...f.messages, replacement].map(JSON.stringify).join('\n') + '\n');
  const result = await stitchTranscripts([...f.record.transcripts, {path: continuation}], f.request.source.projectsRoot);
  assert.equal(result.messages.length, 2);
  assert.equal(result.messages[1].content[0].text, 'Replacement answer');
});

test('tool records stay readable, reasoning omitted, unknown attachments block session', async t => {
  const f = await fixture(t);
  f.messages[1].message.content.push({type: 'thinking', thinking: 'Provider-specific thought', signature: 'not-portable'}, {type: 'tool_use', id: 'tool_sample', name: 'Read', input: {file_path: 'sample.txt'}});
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: [{type: 'tool_result', tool_use_id: 'tool_sample', content: 'Synthetic result'}]}});
  await f.saveMessages();
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].stats.toolCalls, 1); assert.equal(plan.rows[0].stats.toolResults, 1); assert.equal(plan.rows[0].stats.omittedReasoningBlocks, 1);
  assert.ok(!(await fs.readFile(plan.rows[0].snapshotPath, 'utf8')).includes('not-portable'));
  f.messages[1].message.content.push({type: 'image', source: {type: 'base64', data: 'synthetic'}}); await f.saveMessages();
  assert.match((await createImportPlan(f.request)).rows[0].reason, /Unsupported image source/);
});

test('server tools, references, definitions and advisor results become inert readable records', async t => {
  const f = await fixture(t);
  f.messages[1].message.content.push(
    {type: 'tool_reference', tool_name: 'SampleRead'},
    {type: 'tool_addition', tool: {name: 'SampleRead', description: 'Synthetic tool', input_schema: {type: 'object'}}},
    {type: 'tool_removal', tool: 'SampleRead'},
    {type: 'server_tool_use', id: 'srvtool_sample', name: 'advisor', input: {}},
    {type: 'advisor_tool_result', tool_use_id: 'srvtool_sample', content: {type: 'advisor_redacted_result', encrypted_content: 'opaque-provider-sample'}},
    {type: 'advisor_tool_result', tool_use_id: 'srvtool_other', content: {type: 'advisor_result', text: 'Readable synthetic advice'}},
    {type: 'advisor_tool_result', tool_use_id: 'srvtool_failed', content: {type: 'advisor_tool_result_error', error_code: 'overloaded'}});
  await f.saveMessages();
  const plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready'); assert.equal(row.stats.toolReferences, 1); assert.equal(row.stats.serverToolCalls, 1);
  assert.equal(row.stats.toolDefinitionChanges, 2); assert.equal(row.stats.omittedEncryptedAdvisorResults, 1);
  const staged = await fs.readFile(row.snapshotPath, 'utf8');
  assert.match(staged, /Readable synthetic advice/); assert.match(staged, /encrypted provider-only response/);
  assert.equal(row.stats.advisorErrors, 1); assert.match(staged, /Claude advisor error for srvtool_failed/); assert.match(staged, /overloaded/);
  assert.ok(!staged.includes('opaque-provider-sample')); assert.equal(row.warnings.length, 1);
});

test('tool records retain full inputs/results and native role mapping', async t => {
  const f = await fixture(t), inputTail = 'Input tail Ω😀', outputTail = 'Output tail Ω😀';
  f.messages[1].message.content.push({type: 'tool_use', id: 'tool_long', name: 'Read', input: {file_path: 'sample.txt', offset: 49, custom: 'x'.repeat(6000) + inputTail}});
  const result = {type: 'tool_result', tool_use_id: 'tool_long', is_error: true, content: 'y'.repeat(12000) + outputTail};
  const only = {...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: [{type: 'text', text: ''}, {type: 'thinking', thinking: 'Omit'}, result]}};
  const mixed = {...only, uuid: randomUUID(), parentUuid: only.uuid, message: {role: 'user', content: [{type: 'text', text: 'Actual user follow-up'}, result]}};
  await f.saveMessages([...f.messages, only, mixed]);
  const plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready');
  const staged = (await fs.readFile(row.snapshotPath, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(staged.map(r => r.type), ['user', 'assistant', 'assistant', 'user']);
  assert.equal(row.stats.userMessages, 2); assert.equal(row.stats.assistantMessages, 2);
  assert.ok(staged.every(r => r.message.content.every(b => b.type === 'text')));
  const call = staged[1].message.content.map(b => b.text).join('\n'), output = staged[2].message.content.map(b => b.text).join('\n');
  assert.ok(call.includes(inputTail)); assert.ok(call.includes('"offset": 49'));
  assert.ok(output.includes(outputTail)); assert.ok(output.includes('"is_error": true')); assert.ok(output.includes('tool_long'));
});

test('usage-only repeats are deduplicated; divergent source copies remain blocked', async t => {
  const f = await fixture(t);
  await f.saveMessages([...f.messages, {...f.messages[1], message: {...f.messages[1].message, usage: {output_tokens: 9}}}]);
  assert.equal((await createImportPlan(f.request)).rows[0].stats.messages, 2);
  await f.saveMessages();
  const copy = path.join(f.request.source.projectsRoot, 'copy.jsonl');
  const extra = {...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: 'Later append'}};
  await fs.writeFile(copy, [...f.messages, extra].map(JSON.stringify).join('\n') + '\n');
  f.record.transcripts[0].copies = [f.transcript, copy];
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].stats.messages, 3); assert.equal(plan.rows[0].sources.length, 2);
  await fs.writeFile(copy, JSON.stringify({...f.messages[0], message: {role: 'user', content: 'Divergent history'}}) + '\n');
  assert.match((await createImportPlan(f.request)).rows[0].reason, /diverging history/);
});

const samplePNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVf0AAAAASUVORK5CYII=';
const samplePDF = Buffer.from('%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n');

test('embedded PDFs retain exact bytes, position and metadata; unavailable document sources block', async t => {
  const f = await fixture(t);
  const document = {type: 'document', source: {type: 'base64', media_type: 'application/pdf', data: samplePDF.toString('base64')}, title: 'Synthetic attachment', context: 'Sample context', citations: {enabled: true}};
  f.messages[0].message.content = [{type: 'text', text: 'Before PDF'}, {type: 'tool_result', tool_use_id: 'sample', content: [document]}, {type: 'text', text: 'After PDF'}];
  await f.saveMessages();
  const plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready'); assert.equal(row.stats.documents, 1); assert.equal(row.assets[0].mediaType, 'application/pdf');
  assert.deepEqual(await fs.readFile(row.assets[0].path), samplePDF);
  const staged = await fs.readFile(row.snapshotPath, 'utf8');
  assert.ok(staged.indexOf('Before PDF') < staged.indexOf('Open original document')); assert.ok(staged.indexOf('Open original document') < staged.indexOf('After PDF'));
  assert.match(staged, /Sample context/); assert.match(staged, /Synthetic attachment/); assert.match(row.warnings[0], /PDF documents/);
  assert.ok(!staged.includes(document.source.data));
  document.source = {type: 'url', url: 'https://example.com/sample.pdf'}; await f.saveMessages();
  assert.match((await createImportPlan(f.request)).rows[0].reason, /Unsupported document source/);
  document.source = {type: 'base64', media_type: 'application/pdf', data: Buffer.from('Not PDF bytes').toString('base64')}; await f.saveMessages();
  assert.match((await createImportPlan(f.request)).rows[0].reason, /do not match/);
});
test('images are preserved byte-for-byte with positioned links and checked before import', async t => {
  const f = await fixture(t);
  f.messages[0].message.content = [{type: 'text', text: 'Synthetic screenshot'}, {type: 'image', source: {type: 'base64', media_type: 'image/png', data: samplePNG}}];
  await f.saveMessages();
  const plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready'); assert.equal(row.stats.images, 1); assert.equal(row.assets.length, 1);
  assert.deepEqual(await fs.readFile(row.assets[0].path), Buffer.from(samplePNG, 'base64'));
  const staged = await fs.readFile(row.snapshotPath, 'utf8');
  assert.match(staged, /Open original image/); assert.ok(!staged.includes(samplePNG));
  if (process.platform === 'win32') {
    const repeated = await createImportPlan({...f.request, stateRoot: f.request.stateRoot.toUpperCase()});
    assert.equal(repeated.rows[0].status, 'Ready');
    assert.equal(repeated.rows[0].snapshotHash, row.snapshotHash);
    assert.equal(repeated.rows[0].assets[0].path, row.assets[0].path);
  }
  await fs.writeFile(row.assets[0].path, 'Changed asset');
  await assert.rejects(applyImportPlan({...f.request, planPath: plan.planPath}, () => { throw new Error('Must not connect'); }), /Linked attachment changed/);
});

test('image plans import when the state root uses an extended Windows path', {skip: process.platform !== 'win32'}, async t => {
  const f = await fixture(t);
  f.messages[0].message.content = [{type: 'image', source: {type: 'base64', media_type: 'image/png', data: samplePNG}}];
  await f.saveMessages();
  const request = {...f.request, stateRoot: path.toNamespacedPath(f.request.stateRoot)};
  const plan = await createImportPlan(request);
  assert.equal(plan.rows[0].status, 'Ready');
  const imported = await applyImportPlan({...request, planPath: plan.planPath}, () => mockServer(f));
  assert.equal(imported.rows[0].status, 'Imported');
});

test('stale source or snapshot fails before connecting to Codex', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const forbidden = () => { throw new Error('Must not connect'); };
  await fs.appendFile(f.transcript, '\n');
  await assert.rejects(applyImportPlan({...f.request, planPath: plan.planPath}, forbidden), /transcript changed after preview/);
  await f.saveMessages(); await fs.appendFile(plan.rows[0].snapshotPath, '\n');
  await assert.rejects(applyImportPlan({...f.request, planPath: plan.planPath}, forbidden), /Staged transcript changed/);
});

test('outdated conversion plans cannot import lossy snapshots', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const saved = JSON.parse(await fs.readFile(plan.planPath, 'utf8')); saved.stitcherVersion--;
  await fs.writeFile(plan.planPath, JSON.stringify(saved));
  await assert.rejects(applyImportPlan({...f.request, planPath: plan.planPath}, () => {throw new Error('Must not connect');}), /outdated content conversion/);
});

test('imports sessions only, preserves title/archive, deduplicates repeat', async t => {
  const f = await fixture(t); f.record.archived = true;
  const plan = await createImportPlan(f.request), server = mockServer(f);
  const result = await applyImportPlan({...f.request, planPath: plan.planPath}, () => server);
  assert.equal(result.rows[0].status, 'Imported');
  assert.deepEqual(server.calls.find(c => c.method === 'externalAgentConfig/import').params.migrationItems.map(item => item.itemType), ['SESSIONS']);
  assert.ok(server.calls.some(c => c.method === 'thread/archive'));
  assert.equal(server.calls.find(c => c.method === 'thread/name/set').params.name, 'Release planning');
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Unchanged');
  const again = await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f));
  assert.equal(again.rows[0].status, 'Unchanged');
});

test('changed content needs explicit new revision with a distinct embedded identity', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const original = await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f));
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: 'Next step'}}); await f.saveMessages();
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Changed');
  const revision = await createImportPlan({...f.request, newRevision: true});
  assert.equal(revision.rows[0].status, 'Ready'); assert.notEqual(revision.rows[0].snapshotId, plan.rows[0].snapshotId);
  const server = mockServer(f);
  await applyImportPlan({...f.request, planPath: revision.planPath}, () => server);
  assert.ok(!server.calls.some(c => c.params?.threadId === original.rows[0].target));
});

test('completion timeout is journaled, unknown outcome is not blindly resubmitted', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const timedOut = await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f, {timeout: true}));
  assert.equal(timedOut.rows[0].status, 'NeedsInvestigation');
  const retry = mockServer(f);
  const retried = await applyImportPlan({...f.request, planPath: plan.planPath}, () => retry);
  assert.match(retried.rows[0].reason, /no automatic resubmission/);
  assert.ok(!retry.calls.some(c => c.method === 'externalAgentConfig/import'));
  const recovered = mockServer(f, {histories: [{importId: 'recovered', successes: [{itemType: 'SESSIONS', source: plan.rows[0].snapshotPath, target: randomUUID()}]}]});
  assert.equal((await applyImportPlan({...f.request, planPath: plan.planPath}, () => recovered)).rows[0].status, 'Recovered');
  assert.ok(!recovered.calls.some(c => c.method === 'externalAgentConfig/import'));
  assert.ok(!recovered.calls.some(c => ['thread/name/set', 'thread/archive'].includes(c.method)));
});

test('compaction follows logical ancestry and omits generated recap, not original turns', async t => {
  const f = await fixture(t), boundary = {type: 'system', subtype: 'compact_boundary', uuid: randomUUID(), parentUuid: null, logicalParentUuid: f.messages[1].uuid};
  const summary = {...f.messages[0], uuid: randomUUID(), parentUuid: boundary.uuid, isCompactSummary: true, message: {role: 'user', content: 'Internal recap'}};
  const question = {...f.messages[0], uuid: randomUUID(), parentUuid: summary.uuid, message: {role: 'user', content: 'Question after compaction'}};
  await f.saveMessages([...f.messages, boundary, summary, question]);
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].stats.messages, 3);
  const text = await fs.readFile(plan.rows[0].snapshotPath, 'utf8');
  assert.match(text, /Explain the sample/); assert.match(text, /Question after compaction/); assert.ok(!text.includes('Internal recap'));
  delete boundary.logicalParentUuid; await f.saveMessages([...f.messages, boundary, summary, question]);
  assert.match((await createImportPlan(f.request)).rows[0].reason, /no link to earlier history/);
});

test('memory-only compaction IDs reconnect through verified persisted ancestry', async t => {
  const f = await memoryCompactionFixture(t), plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready'); assert.equal(row.compactionRecoveries.length, 1);
  const staged = (await fs.readFile(row.snapshotPath, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(staged.map(r => r.uuid), [f.records[0], f.head, f.firstResult, f.records[3], f.tail, f.question].map(r => r.uuid));
  const text = JSON.stringify(staged);
  assert.match(text, /Explain the sample/); assert.match(text, /Final preserved result/); assert.match(text, /Continue after verified compaction/);
  assert.ok(!text.includes('Generated recap')); assert.ok(!text.includes('Abandoned branch')); assert.match(row.warnings[0], /verified persisted-message metadata/);
});

test('compaction recovery rejects missing persisted records and ambiguous metadata', async t => {
  const f = await memoryCompactionFixture(t);
  const cases = [
    rows => rows.filter(r => r.uuid !== f.firstResult.uuid),
    rows => { rows.find(r => r.uuid === f.records[0].uuid).parentUuid = randomUUID(); return rows; },
    rows => { rows.find(r => r.uuid === f.records[0].uuid).parentUuid = false; return rows; },
    rows => { rows.find(r => r.uuid === f.records[0].uuid).parentUuid = f.tail.uuid; return rows; },
    rows => { rows.find(r => r.uuid === f.firstResult.uuid).isSidechain = true; return rows; },
    rows => { rows.push({...rows.find(r => r.uuid === f.summary.uuid), uuid: randomUUID()}); return rows; },
    rows => { const a = rows.find(r => r.uuid === f.attachment.uuid); a.type = 'system'; a.subtype = 'compact_boundary'; return rows; },
    rows => { const b = rows.find(r => r.uuid === f.boundary.uuid); b.compactMetadata.preservedMessages.uuids.splice(1, 0, f.records[0].uuid); b.compactMetadata.preservedMessages.allUuids.splice(1, 0, f.records[0].uuid); return rows; },
    rows => { rows.push({...rows.find(r => r.uuid === f.boundary.uuid), logicalParentUuid: randomUUID()}); return rows; },
    rows => { const p = rows.find(r => r.uuid === f.boundary.uuid).compactMetadata.preservedMessages; p.uuids = p.uuids.filter(id => id !== f.firstResult.uuid); p.allUuids = p.allUuids.filter(id => id !== f.firstResult.uuid); return rows; },
  ];
  for (const change of cases) {
    await f.saveMessages(change(structuredClone(f.records)));
    const row = (await createImportPlan(f.request)).rows[0];
    assert.equal(row.status, 'Skipped'); assert.match(row.reason, /cannot verify/);
  }
});

test('a continuation replacing a recovered branch removes its recovery audit', async t => {
  const f = await memoryCompactionFixture(t), sid = randomUUID(), file = path.join(f.request.source.projectsRoot, sid + '.jsonl');
  const replacement = {...f.messages[1], uuid: randomUUID(), parentUuid: f.records[0].uuid, message: {role: 'assistant', content: 'Replacement before compaction'}};
  await fs.writeFile(file, [f.records[0], replacement].map(JSON.stringify).join('\n') + '\n');
  f.record.transcripts.push({id: sid, path: file});
  const plan = await createImportPlan(f.request), row = plan.rows[0];
  assert.equal(row.status, 'Ready'); assert.equal(row.stats.messages, 2);
  assert.equal(row.compactionRecoveries, undefined); assert.ok(!row.warnings.some(w => w.includes('compaction links')));
  assert.match(await fs.readFile(row.snapshotPath, 'utf8'), /Replacement before compaction/);
});

test('native importer reads a recovered compaction history in full', {skip: !process.env.CLAUDESYNC_NATIVE_IMPORT_TEST}, async t => {
  const f = await memoryCompactionFixture(t), plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].status, 'Ready');
  const imported = await applyImportPlan({...f.request, planPath: plan.planPath});
  assert.equal(imported.rows[0].status, 'Imported');
  const server = new CodexAppServer({codexHome: f.request.codexHome, sourceHome: path.join(f.request.stateRoot, 'source-home')});
  try {
    await server.initialize();
    const read = await server.request('thread/read', {threadId: imported.rows[0].target, includeTurns: true});
    const text = JSON.stringify(read.thread.turns);
    for (const marker of ['Explain the sample', 'First preserved result', 'Final preserved result', 'Continue after verified compaction']) assert.ok(text.includes(marker));
    assert.ok(!text.includes('Generated recap')); assert.ok(!text.includes('Abandoned branch'));
  } finally { await server.close(); }
});

test('failed native imports stay recorded and an explicit recovery revision has a new identity', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const failed = await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f, {failed: true}));
  assert.equal(failed.rows[0].status, 'Failed');
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Failed');
  const recovery = await createImportPlan({...f.request, newRevision: true});
  assert.notEqual(recovery.rows[0].snapshotId, plan.rows[0].snapshotId);
  assert.equal(recovery.rows[0].replacesAttempt, plan.rows[0].snapshotPath);
  const result = await applyImportPlan({...f.request, planPath: recovery.planPath}, () => mockServer(f));
  assert.equal(result.rows[0].status, 'Imported');
  const ledger = JSON.parse(await fs.readFile(path.join(f.request.stateRoot, 'imports.json'), 'utf8'));
  assert.equal(ledger.abandonedAttempts.length, 1);
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Unchanged');
});

test('unknown outcome on one session does not block the rest of a folder', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f, {timeout: true}));
  f.request.records.push({...f.record, id: 'local_' + randomUUID(), title: 'Another synthetic session'});
  const plan = await createImportPlan(f.request), server = mockServer(f);
  const result = await applyImportPlan({...f.request, planPath: plan.planPath}, () => server);
  assert.equal(result.rows[0].status, 'NeedsInvestigation'); assert.equal(result.rows[1].status, 'Imported');
  assert.equal(server.calls.filter(call => call.method === 'externalAgentConfig/import').length, 1);
});

test('cosmetic projects-root spelling does not create duplicate source identities', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f));
  f.request.source.projectsRoot += path.sep;
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Unchanged');
});

test('failed recovery detection retains the original unknown attempt and cannot revive a blind retry', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f, {timeout: true}));
  const recovery = await createImportPlan({...f.request, newRevision: true});
  await applyImportPlan({...f.request, planPath: recovery.planPath}, () => mockServer(f, {detectError: true}));
  const plain = await createImportPlan(f.request);
  assert.equal(plain.rows[0].snapshotPath, first.rows[0].snapshotPath);
  const server = mockServer(f);
  assert.equal((await applyImportPlan({...f.request, planPath: plain.planPath}, () => server)).rows[0].status, 'NeedsInvestigation');
  assert.ok(!server.calls.some(call => call.method === 'externalAgentConfig/import'));
});

test('an in-flight changed revision is reconciled by a plain preview', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f));
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: 'Changed source'}}); await f.saveMessages();
  const changed = await createImportPlan({...f.request, newRevision: true});
  await applyImportPlan({...f.request, planPath: changed.planPath}, () => mockServer(f, {timeout: true}));
  const plain = await createImportPlan(f.request);
  assert.equal(plain.rows[0].status, 'Ready'); assert.equal(plain.rows[0].snapshotPath, changed.rows[0].snapshotPath);
});

test('a recovery preparation failure keeps the original native failure message', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f, {failed: true}));
  const recovery = await createImportPlan({...f.request, newRevision: true});
  await applyImportPlan({...f.request, planPath: recovery.planPath}, () => mockServer(f, {detectError: true}));
  const plain = await createImportPlan(f.request);
  assert.equal(plain.rows[0].status, 'Failed'); assert.match(plain.rows[0].reason, /Synthetic native failure/);
});

test('retrying the same failed plan preserves the native failure reason', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f, {failed: true}));
  const server = mockServer(f), retried = await applyImportPlan({...f.request, planPath: plan.planPath}, () => server);
  assert.equal(retried.rows[0].status, 'Failed'); assert.match(retried.rows[0].reason, /Synthetic native failure/);
  assert.ok(!server.calls.some(call => call.method === 'externalAgentConfig/import'));
});

test('cosmetic destination path spelling does not create another revision', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f));
  f.record.cwd += path.sep;
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Unchanged');
});

test('NewRevision recovers a known or completed pending import without duplicating it', async t => {
  const f = await fixture(t), first = await createImportPlan(f.request);
  const interrupted = await applyImportPlan({...f.request, planPath: first.planPath}, () => mockServer(f, {failNaming: true}));
  assert.equal(interrupted.rows[0].status, 'NeedsInvestigation');
  const knownPlan = await createImportPlan({...f.request, newRevision: true});
  assert.equal(knownPlan.rows[0].replacesAttempt, undefined);
  const server = mockServer(f);
  assert.equal((await applyImportPlan({...f.request, planPath: knownPlan.planPath}, () => server)).rows[0].status, 'Recovered');
  assert.ok(!server.calls.some(call => call.method === 'externalAgentConfig/import'));
  const g = await fixture(t), pending = await createImportPlan(g.request);
  await applyImportPlan({...g.request, planPath: pending.planPath}, () => mockServer(g, {timeout: true}));
  const proposed = await createImportPlan({...g.request, newRevision: true});
  const mapped = mockServer(g, {histories: [{importId: 'completed-late', successes: [{itemType: 'SESSIONS', source: pending.rows[0].snapshotPath, target: randomUUID()}]}]});
  assert.equal((await applyImportPlan({...g.request, planPath: proposed.planPath}, () => mapped)).rows[0].status, 'Recovered');
  assert.ok(!mapped.calls.some(call => call.method === 'externalAgentConfig/import'));
});

test('a pending replacement keeps its own identity on subsequent plain preview and same-plan retry', async t => {
  const f = await fixture(t), original = await createImportPlan(f.request);
  await applyImportPlan({...f.request, planPath: original.planPath}, () => mockServer(f, {timeout: true}));
  const replacement = await createImportPlan({...f.request, newRevision: true});
  await applyImportPlan({...f.request, planPath: replacement.planPath}, () => mockServer(f, {timeout: true}));
  const plain = await createImportPlan(f.request);
  assert.equal(plain.rows[0].snapshotPath, replacement.rows[0].snapshotPath);
  const mapped = mockServer(f, {histories: [{importId: 'replacement-complete', successes: [{itemType: 'SESSIONS', source: replacement.rows[0].snapshotPath, target: randomUUID()}]}]});
  assert.equal((await applyImportPlan({...f.request, planPath: replacement.planPath}, () => mapped)).rows[0].status, 'Recovered');
  assert.ok(!mapped.calls.some(call => call.method === 'externalAgentConfig/import'));
});

test('terminal transport failure leaves remaining rows unattempted, not uncertain', async t => {
  const f = await fixture(t);
  f.request.records.push({...f.record, id: 'local_' + randomUUID()}, {...f.record, id: 'local_' + randomUUID()});
  const plan = await createImportPlan(f.request), server = mockServer(f, {timeout: true, terminal: true});
  const result = await applyImportPlan({...f.request, planPath: plan.planPath}, () => server);
  assert.deepEqual(result.rows.map(row => row.status), ['NeedsInvestigation', 'NotAttempted', 'NotAttempted']);
  assert.equal(server.calls.filter(call => call.method === 'externalAgentConfig/import').length, 1);
  const ledger = JSON.parse(await fs.readFile(path.join(f.request.stateRoot, 'imports.json'), 'utf8'));
  assert.equal(Object.keys(ledger.entries).length, 1);
});

test('a request definitively rejected before sending leaves no false pending entry', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  const result = await applyImportPlan({...f.request, planPath: plan.planPath}, () => mockServer(f, {deadBeforeSend: true}));
  assert.equal(result.rows[0].status, 'NotAttempted');
  const ledger = JSON.parse(await fs.readFile(path.join(f.request.stateRoot, 'imports.json'), 'utf8'));
  assert.equal(Object.keys(ledger.entries).length, 0);
});

test('RPC timeout poisons the transport and later requests are explicitly unsubmitted', {skip: process.platform !== 'win32'}, async t => {
  const f = await fixture(t), executable = path.join(f.root, 'codex.js');
  await fs.writeFile(executable, 'process.stdin.resume(); process.stdin.on("data", () => {});');
  const server = new CodexAppServer({codexHome: f.request.codexHome, sourceHome: f.root, executable, timeoutMs: 100});
  try {
    await assert.rejects(server.initialize(), /timed out/);
    assert.ok(server.failure);
    await assert.rejects(server.request('externalAgentConfig/import'), error => error.notSubmitted && error.method === 'externalAgentConfig/import');
  } finally { await server.close(); }
});

test('rejects tampered destination and source paths', async t => {
  const f = await fixture(t), plan = await createImportPlan(f.request);
  await assert.rejects(applyImportPlan({...f.request, codexHome: path.join(f.root, 'other'), planPath: plan.planPath}), /destination/);
  f.record.transcripts = [{path: f.record.cardPath}];
  assert.match((await createImportPlan(f.request)).rows[0].reason, /escaped/);
});

test('Windows npm launcher resolves to Node without a shell or executing cmd text', async t => {
  const f = await fixture(t), bin = path.join(f.root, 'npm bin 日本 é');
  await fs.mkdir(path.join(bin, 'node_modules/@openai/codex/bin'), {recursive: true});
  await fs.writeFile(path.join(bin, 'codex.cmd'), 'Never execute shell text');
  const launcher = path.join(bin, 'node_modules/@openai/codex/bin/codex.js');
  await fs.writeFile(launcher, '// synthetic launcher');
  const resolved = resolveCodexLaunch('codex', {platform: 'win32', searchPath: bin});
  assert.equal(resolved.command, process.execPath); assert.deepEqual(resolved.prefix, [launcher]);
  const nativeBin = path.join(f.root, 'Native install 日本 é'); await fs.mkdir(nativeBin);
  const native = path.join(nativeBin, 'codex.exe'); await fs.writeFile(native, 'Synthetic path-discovery fixture');
  assert.deepEqual(resolveCodexLaunch('codex', {platform: 'win32', searchPath: nativeBin + ';' + bin}), {command: native, prefix: []});
  assert.deepEqual(resolveCodexLaunch(launcher, {platform: 'win32'}), {command: process.execPath, prefix: [launcher]});
  assert.throws(() => resolveCodexLaunch('codex', {platform: 'win32', searchPath: ';relative-folder;'}), /absolute PATH directory/);
  for (const script of ['codex.cmd', 'codex.ps1', 'codex.js', 'CODEX.JS']) {
    assert.throws(() => resolveCodexLaunch(script, {platform: 'win32', searchPath: bin}), /absolute script path/);
  }
});

test('workspace aliases preview their physical destination, including case-only re-previews', {skip: process.platform !== 'win32'}, async t => {
  const f = await fixture(t), alias = path.join(f.root, 'ProjectAlias');
  await fs.symlink(f.record.cwd, alias, 'junction'); f.record.cwd = alias;
  const first = await createImportPlan(f.request);
  assert.equal(first.rows[0].cwd, await fs.realpath(alias)); assert.equal(first.rows[0].requestedCwd, alias); assert.equal(first.rows[0].status, 'Ready');
  f.record.cwd = alias.toLowerCase() + path.sep;
  const again = await createImportPlan(f.request);
  assert.equal(again.rows[0].status, 'Ready'); assert.equal(again.rows[0].snapshotPath, first.rows[0].snapshotPath);
  assert.equal(again.rows[0].snapshotHash, first.rows[0].snapshotHash);
});

test('native importer: tools, archive, repeat, separate revision and readable history', {skip: !process.env.CLAUDESYNC_NATIVE_IMPORT_TEST}, async t => {
  const f = await fixture(t); f.record.archived = true;
  for (const message of f.messages) message.timestamp = '2020-01-01T00:00:00Z';
  f.messages[1].message.content.push({type: 'tool_use', id: 'tool_sample', name: 'Read', input: {file_path: 'sample.txt'}});
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: [{type: 'tool_result', tool_use_id: 'tool_sample', content: 'Synthetic result'}]}}); await f.saveMessages();
  const boundary = {type: 'system', subtype: 'compact_boundary', uuid: randomUUID(), parentUuid: null, logicalParentUuid: f.messages.at(-1).uuid};
  const summary = {...f.messages[0], uuid: randomUUID(), parentUuid: boundary.uuid, isCompactSummary: true, message: {role: 'user', content: 'Internal recap'}};
  const afterCompact = {...f.messages[0], uuid: randomUUID(), parentUuid: summary.uuid, message: {role: 'user', content: 'Question after compaction'}};
  f.messages.push(boundary, summary, afterCompact); await f.saveMessages();
  const plan = await createImportPlan(f.request);
  const imported = await applyImportPlan({...f.request, planPath: plan.planPath});
  const target = imported.rows[0].target;
  assert.equal(imported.rows[0].status, 'Imported');
  assert.equal((await createImportPlan(f.request)).rows[0].status, 'Unchanged');
  f.record.archived = false;
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages.at(-1).uuid, message: {role: 'user', content: 'New revision question'}}); await f.saveMessages();
  const next = await createImportPlan({...f.request, newRevision: true});
  const result = await applyImportPlan({...f.request, planPath: next.planPath});
  assert.notEqual(result.rows[0].target, target);
  const server = new CodexAppServer({codexHome: f.request.codexHome, sourceHome: path.join(f.request.stateRoot, 'source-home')});
  try {
    await server.initialize();
    const histories = await server.request('externalAgentConfig/import/readHistories');
    assert.ok(histories.data.some(history => history.successes.some(item => item.itemType === 'SESSIONS' && item.target === target)));
    const old = await server.request('thread/read', {threadId: target, includeTurns: true});
    const latest = await server.request('thread/read', {threadId: result.rows[0].target, includeTurns: true});
    assert.equal(latest.thread.name, 'Release planning');
    assert.match(JSON.stringify(old.thread.turns), /external_agent_tool_call: Read/);
    assert.match(JSON.stringify(old.thread.turns), /Synthetic result/);
    assert.match(JSON.stringify(old.thread.turns), /Explain the sample/);
    assert.match(JSON.stringify(old.thread.turns), /Question after compaction/);
    assert.ok(!JSON.stringify(old.thread.turns).includes('Internal recap'));
    assert.ok(!JSON.stringify(old.thread.turns).includes('New revision question'));
    assert.match(JSON.stringify(latest.thread.turns), /New revision question/);
    const archived = await server.request('thread/list', {archived: true, limit: 20});
    assert.ok(archived.data.some(thread => thread.id === target));
  } finally { await server.close(); }
  // Simulate losing the completion acknowledgement after native import succeeds.
  const ledgerPath = path.join(f.request.stateRoot, 'imports.json');
  const ledger = JSON.parse(await fs.readFile(ledgerPath, 'utf8'));
  const recoveryTarget = result.rows[0].target;
  const old = Object.values(ledger.entries).find(entry => entry.target === recoveryTarget);
  old.phase = 'pending'; delete old.target;
  await fs.writeFile(ledgerPath, JSON.stringify(ledger));
  const recovered = await applyImportPlan({...f.request, planPath: next.planPath});
  assert.equal(recovered.rows[0].status, 'Recovered'); assert.equal(recovered.rows[0].target, recoveryTarget);
});

test('native importer supports a selection exceeding the default 50-chat picker', {skip: !process.env.CLAUDESYNC_NATIVE_IMPORT_TEST}, async t => {
  const f = await fixture(t);
  const seed = f.request.records[0];
  f.request.records = Array.from({length: 51}, (_, i) => ({...seed, id: 'local_' + randomUUID(), title: `Synthetic conversation ${i + 1}`}));
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows.filter(row => row.status === 'Ready').length, 51);
  const result = await applyImportPlan({...f.request, planPath: plan.planPath});
  assert.equal(result.rows.filter(row => row.status === 'Imported').length, 51);
  assert.equal(new Set(result.rows.map(row => row.target)).size, 51);
});

test('native importer uses the physical workspace path shown by preview', {skip: !process.env.CLAUDESYNC_NATIVE_IMPORT_TEST || process.platform !== 'win32'}, async t => {
  const f = await fixture(t), alias = path.join(f.root, 'WorkspaceAlias');
  await fs.symlink(f.record.cwd, alias, 'junction'); f.record.cwd = alias;
  const plan = await createImportPlan(f.request);
  assert.equal(plan.rows[0].cwd, await fs.realpath(alias)); assert.equal(plan.rows[0].requestedCwd, alias);
  const result = await applyImportPlan({...f.request, planPath: plan.planPath});
  assert.equal(result.rows[0].status, 'Imported');
});

test('native importer preserves image/PDF links and normalized server-tool history', {skip: !process.env.CLAUDESYNC_NATIVE_IMPORT_TEST}, async t => {
  const f = await fixture(t);
  f.messages[0].message.content = [{type: 'text', text: 'Synthetic attachment'}, {type: 'image', source: {type: 'base64', media_type: 'image/png', data: samplePNG}}, {type: 'document', source: {type: 'base64', media_type: 'application/pdf', data: samplePDF.toString('base64')}}];
  f.messages[1].message.content.push({type: 'tool_reference', tool_name: 'SampleRead'}, {type: 'server_tool_use', id: 'srvtool_sample', name: 'advisor', input: {}},
    {type: 'advisor_tool_result', tool_use_id: 'srvtool_sample', content: {type: 'advisor_redacted_result', encrypted_content: 'opaque-provider-sample'}},
    {type: 'advisor_tool_result', tool_use_id: 'srvtool_failed', content: {type: 'advisor_tool_result_error', error_code: 'too_many_requests'}});
  f.messages[1].message.content.push({type: 'tool_use', id: 'long_tool', name: 'SampleRead', input: {file_path: 'sample.txt', custom: 'x'.repeat(6000) + 'Input tail Ω😀'}});
  f.messages.push({...f.messages[0], uuid: randomUUID(), parentUuid: f.messages[1].uuid, message: {role: 'user', content: [{type: 'text', text: ''}, {type: 'tool_result', tool_use_id: 'long_tool', is_error: true, content: [{type: 'text', text: 'y'.repeat(12000) + 'Output tail Ω😀'}, {type: 'image', source: {type: 'base64', media_type: 'image/png', data: samplePNG}}, {type: 'document', source: {type: 'base64', media_type: 'application/pdf', data: samplePDF.toString('base64')}}]}]}});
  await f.saveMessages();
  const plan = await createImportPlan(f.request), result = await applyImportPlan({...f.request, planPath: plan.planPath});
  assert.equal(result.rows[0].status, 'Imported'); assert.equal(result.rows[0].warnings.length, 3);
  const server = new CodexAppServer({codexHome: f.request.codexHome, sourceHome: path.join(f.request.stateRoot, 'source-home')});
  try {
    await server.initialize();
    const read = await server.request('thread/read', {threadId: result.rows[0].target, includeTurns: true});
    const text = JSON.stringify(read.thread.turns);
    assert.match(text, /Open original image/); assert.match(text, /Claude server tool call/); assert.match(text, /SampleRead/);
    assert.match(text, /Open original document/); assert.match(text, /too_many_requests/);
    assert.ok(text.includes('Input tail Ω😀')); assert.ok(text.includes('Output tail Ω😀'));
    const finalTurn = read.thread.turns.at(-1);
    const finalItems = finalTurn.items;
    assert.ok(finalItems.some(item => item.type === 'agentMessage' && item.text.includes('Output tail Ω😀')));
    for (const asset of plan.rows[0].assets) assert.ok([...text.matchAll(new RegExp(asset.hash, 'g'))].length >= 2);
    assert.ok(!text.includes('external unsupported block')); assert.ok(!text.includes('opaque-provider-sample'));
    assert.deepEqual(await fs.readFile(plan.rows[0].assets[0].path), Buffer.from(samplePNG, 'base64'));
    assert.deepEqual(await fs.readFile(plan.rows[0].assets[1].path), samplePDF);
  } finally { await server.close(); }
});
