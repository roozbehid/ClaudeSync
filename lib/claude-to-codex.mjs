import {createHash, randomUUID} from 'node:crypto';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {CodexAppServer} from './codex-app-server.mjs';

const VERSION = 1;
const STITCHER_VERSION = 5;
export const hash = value => createHash('sha256').update(value).digest('hex');
const revisionKey = row => `${row.sourceKey}/${row.revision}`;
const canonical = value => path.resolve(value.replace(/^\\\\\?\\/, '')).toLowerCase();
const samePath = (a, b) => typeof a === 'string' && typeof b === 'string' && canonical(a) === canonical(b);
function within(file, root) {
  const relative = path.relative(path.resolve(root), path.resolve(file));
  if (relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw new Error('A path escaped its configured root.');
}
async function regularPath(file) {
  // Ascend drive paths without the extended prefix: dirname of its namespace
  // root is not a filesystem directory and cannot be inspected with lstat.
  const drivePath = file.startsWith('\\\\?\\') && /^[a-z]:\\/i.test(file.slice(4)) ? file.slice(4) : file;
  let cursor = path.resolve(drivePath);
  while (true) {
    try { if ((await fs.lstat(cursor)).isSymbolicLink()) throw new Error(`Refusing a linked path: ${cursor}`); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
}
async function readJSON(file, fallback) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT' && fallback !== undefined) return fallback; throw error; }
}
async function atomicJSON(file, value) {
  const temp = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temp, 'wx', 0o600);
  try { await handle.writeFile(JSON.stringify(value, null, 2)); await handle.sync(); }
  finally { await handle.close(); }
  try {
    for (let attempt = 0; ; attempt++) {
      try { await fs.rename(temp, file); break; }
      catch (error) {
        if (!['EPERM', 'EBUSY', 'EACCES'].includes(error.code) || attempt >= 5) throw error;
        await new Promise(resolve => setTimeout(resolve, 50 * (attempt + 1)));
      }
    }
  } finally {
    try { await fs.unlink(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
async function immutableSnapshot(file, data, expectedHash) {
  const temp = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temp, 'wx', 0o600);
  try { await handle.writeFile(data); await handle.sync(); }
  finally { await handle.close(); }
  try {
    // Publish an already-complete file without replacing an existing revision.
    try { await fs.link(temp, file); }
    catch (error) { if (error.code !== 'EEXIST') throw error; if (hash(await fs.readFile(file)) !== expectedHash) throw new Error('A staged revision changed unexpectedly.'); }
  } finally { await fs.unlink(temp); }
}
function snapshotId(sourceKey, revision) {
  const bytes = Buffer.from(hash(`${sourceKey}/${revision}`).slice(0, 32), 'hex');
  bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
async function ledgerFor(stateRoot, codexHome) {
  const ledger = await readJSON(path.join(stateRoot, 'imports.json'), {version: VERSION, codexHome, entries: {}, latest: {}});
  if (ledger.version !== VERSION || !samePath(ledger.codexHome, codexHome) || !ledger.entries || !ledger.latest || typeof ledger.entries !== 'object' || typeof ledger.latest !== 'object' || Array.isArray(ledger.entries) || Array.isArray(ledger.latest)) throw new Error('Import state is invalid or belongs to another destination/version.');
  return ledger;
}

function decodeAttachmentBase64(data) {
  const encoded = data.replace(/\s/g, '');
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded) || encoded.length % 4 === 1) throw new Error('Invalid attachment base64.');
  const bytes = Buffer.from(encoded, 'base64');
  if (!bytes.length || bytes.toString('base64').replace(/=+$/, '') !== encoded.replace(/=+$/, '')) throw new Error('Invalid attachment base64.');
  return bytes;
}

// Preserve readable history, not Anthropic signatures or executable tool state.
function portableContent(content, stats, attachments) {
  if (typeof content === 'string') return [{type: 'text', text: content}];
  if (!Array.isArray(content)) throw new Error('Invalid message content.');
  return content.flatMap(block => {
    if (!block || typeof block !== 'object') throw new Error('Invalid content block.');
    switch (block.type) {
      case 'text':
        if (typeof block.text !== 'string') throw new Error('Invalid text block.');
        return [{type: 'text', text: block.text}];
      case 'tool_use':
        if (typeof block.name !== 'string' || typeof block.id !== 'string' || !block.input || typeof block.input !== 'object') throw new Error('Invalid tool call.');
        stats.toolCalls++;
        // Native conversion abbreviates inputs and can discard fields beside a command/file.
        return [{type: 'text', text: `[external_agent_tool_call: ${block.name}]\n${JSON.stringify(block, null, 2)}\n[/external_agent_tool_call]`}];
      case 'server_tool_use':
        if (typeof block.name !== 'string' || typeof block.id !== 'string' || !block.input || typeof block.input !== 'object') throw new Error('Invalid server tool call.');
        stats.toolCalls++; stats.serverToolCalls++;
        return [{type: 'text', text: `[Claude server tool call]\n${JSON.stringify({id: block.id, name: block.name, input: block.input}, null, 2)}`}];
      case 'tool_reference':
        if (typeof block.tool_name !== 'string') throw new Error('Invalid tool reference.');
        stats.toolReferences++;
        return [{type: 'text', text: `[Claude tool reference: ${block.tool_name}]`}];
      case 'tool_addition': case 'tool_removal':
        if (!block.tool || !['string', 'object'].includes(typeof block.tool)) throw new Error('Invalid tool definition change.');
        stats.toolDefinitionChanges++;
        return [{type: 'text', text: `[Claude ${block.type}]\n${JSON.stringify(block.tool, null, 2)}`}];
      case 'advisor_tool_result': {
        if (typeof block.tool_use_id !== 'string' || !block.content || typeof block.content !== 'object') throw new Error('Invalid advisor result.');
        stats.toolResults++; stats.advisorResults++;
        const result = block.content;
        if (result.type === 'advisor_tool_result_error' && typeof result.error_code === 'string') {
          stats.advisorErrors++;
          return [{type: 'text', text: `[Claude advisor error for ${block.tool_use_id}]\n${result.error_code}`}];
        }
        if (result.type === 'advisor_redacted_result' && typeof result.encrypted_content === 'string') {
          stats.omittedEncryptedAdvisorResults++;
          return [{type: 'text', text: `[Claude advisor result for ${block.tool_use_id}: encrypted provider-only response; readable advice is unavailable in the source transcript.]`}];
        }
        if (result.type !== 'advisor_result' || typeof result.text !== 'string') throw new Error(`Unsupported advisor result: ${result.type}`);
        return [{type: 'text', text: `[Claude advisor result for ${block.tool_use_id}]\n${result.text}`}];
      }
      case 'tool_result':
        if (typeof block.tool_use_id !== 'string') throw new Error('Invalid tool result.');
        stats.toolResults++;
        // Resolve nested attachments before rendering full text; native tool_result
        // conversion truncates results and would lose links beyond its character cap.
        return [{...block, type: 'imported_tool_result', content: portableContent(block.content ?? '', stats, attachments)}];
      case 'image': {
        const source = block.source;
        const extensions = {'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif'};
        if (source?.type !== 'base64' || typeof source.data !== 'string' || !extensions[source.media_type]) throw new Error('Unsupported image source; embedded PNG, JPEG, WebP and GIF are supported.');
        const bytes = decodeAttachmentBase64(source.data);
        const valid = source.media_type === 'image/png' ? bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))
          : source.media_type === 'image/jpeg' ? bytes.subarray(0, 3).equals(Buffer.from('ffd8ff', 'hex'))
          : source.media_type === 'image/webp' ? bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP'
          : ['GIF87a', 'GIF89a'].includes(bytes.toString('ascii', 0, 6));
        if (!valid) throw new Error('Image bytes do not match the declared format.');
        const assetHash = hash(bytes);
        attachments.set(assetHash, {hash: assetHash, mediaType: source.media_type, extension: extensions[source.media_type], bytes});
        stats.images++;
        return [{type: 'imported_image', assetHash, mediaType: source.media_type}];
      }
      case 'document': {
        const source = block.source;
        if (source?.type !== 'base64' || source.media_type !== 'application/pdf' || typeof source.data !== 'string') throw new Error('Unsupported document source; embedded base64 PDF documents are supported.');
        const bytes = decodeAttachmentBase64(source.data);
        if (bytes.toString('ascii', 0, 5) !== '%PDF-') throw new Error('Document bytes do not match the declared PDF format.');
        const assetHash = hash(bytes);
        attachments.set(assetHash, {hash: assetHash, mediaType: source.media_type, extension: 'pdf', bytes});
        const metadata = {};
        for (const key of ['title', 'context', 'citations']) if (block[key] !== undefined) metadata[key] = block[key];
        stats.documents++;
        return [{type: 'imported_document', assetHash, mediaType: source.media_type, metadata}];
      }
      case 'thinking': case 'redacted_thinking':
        stats.omittedReasoningBlocks++; return [];
      default: throw new Error(`Unsupported content block: ${String(block.type)}. Attachments and unknown blocks are not silently dropped.`);
    }
  });
}

function persistedCompactionTail(boundary, nodes, positions, ambiguous) {
  const fail = () => { throw new Error('Compaction references a missing message and its persisted-message metadata cannot verify the earlier history.'); };
  const metadata = boundary.compactMetadata, segment = metadata?.preservedSegment, kept = metadata?.preservedMessages;
  const ids = kept?.uuids, all = kept?.allUuids, missing = boundary.logicalParentUuid;
  const uniqueIds = list => Array.isArray(list) && list.length > 0 && list.every(id => typeof id === 'string' && id.length > 0) && new Set(list).size === list.length;
  if (!segment || !kept || !uniqueIds(ids) || !uniqueIds(all) || typeof missing !== 'string' || nodes.has(missing) || ambiguous.has(boundary.uuid)) fail();
  const persisted = new Set(ids);
  if (persisted.has(missing) || all.at(-1) !== missing || segment.headUuid !== ids[0] || segment.tailUuid !== ids.at(-1) || segment.anchorUuid !== kept.anchorUuid) fail();
  if (JSON.stringify(all.filter(id => persisted.has(id))) !== JSON.stringify(ids)) fail();
  // The producer's raw-only IDs are intentionally excluded by its persistence
  // filter. Do not infer missing persisted messages from an arbitrary neighbour.
  if (all.some(id => !persisted.has(id) && nodes.has(id))) fail();
  const boundaryPosition = positions.get(boundary.uuid);
  for (const id of ids) {
    const node = nodes.get(id);
    if (!node || node.isSidechain || node.isCompactSummary || ambiguous.has(id) || !(positions.get(id) < boundaryPosition)) fail();
  }
  const anchorReachesBoundary = anchor => {
    if (anchor?.type !== 'user' || anchor.isCompactSummary !== true || anchor.isSidechain || ambiguous.has(anchor.uuid) || !(positions.get(anchor.uuid) > boundaryPosition)) return false;
    const visited = new Set([anchor.uuid]); let cursor = anchor.parentUuid;
    while (cursor && cursor !== boundary.uuid) {
      if (visited.has(cursor)) return false;
      visited.add(cursor);
      const node = nodes.get(cursor);
      if (node?.type !== 'attachment' || node.isSidechain || ambiguous.has(cursor) || !(positions.get(cursor) > boundaryPosition && positions.get(cursor) < positions.get(anchor.uuid))) return false;
      cursor = node.parentUuid;
    }
    return cursor === boundary.uuid;
  };
  const anchor = nodes.get(kept.anchorUuid);
  if (!anchorReachesBoundary(anchor)) fail();
  if ([...nodes.values()].filter(node => anchorReachesBoundary(node)).length !== 1) fail();
  const visited = new Set(), span = new Set(); let cursor = segment.tailUuid, root, inSegment = true;
  while (cursor) {
    if (visited.has(cursor)) fail();
    visited.add(cursor);
    if (inSegment) span.add(cursor);
    if (cursor === segment.headUuid) inSegment = false;
    const node = nodes.get(cursor);
    if (!node || node.isSidechain || node.isCompactSummary || ambiguous.has(cursor) || !(positions.get(cursor) < boundaryPosition) || !['user', 'assistant', 'system', 'attachment'].includes(node.type) || (node.type === 'system' && node.subtype === 'compact_boundary')) fail();
    root = node; cursor = node.parentUuid;
  }
  if (inSegment || ids.some(id => !span.has(id)) || [...span].some(id => !persisted.has(id)) || root?.type !== 'user' || root.isMeta || root.parentUuid != null) fail();
  return segment.tailUuid;
}

export async function stitchTranscripts(transcripts, projectsRoot) {
  const nodes = new Map(), ordered = [], included = new Set(), sources = [];
  const positions = new Map(), ambiguous = new Set(), recoveries = new Map();
  let position = 0;
  let totalBytes = 0;
  for (const source of transcripts) {
    const copies = source.copies ?? [source.path];
    if (!Array.isArray(copies) || !copies.length || copies.length > 16) throw new Error('Invalid or excessive transcript copies.');
    const candidates = []; let candidateBytes = 0;
    for (const file of copies) {
      within(file, projectsRoot); await regularPath(file);
      const size = (await fs.stat(file)).size;
      if (size > 128 * 1024 * 1024) throw new Error('Transcript exceeds the 128 MiB limit.');
      candidateBytes += size;
      if (candidateBytes > 256 * 1024 * 1024) throw new Error('Transcript copies exceed the 256 MiB verification limit.');
      const bytes = await fs.readFile(file);
      candidates.push(bytes); sources.push({path: file, hash: hash(bytes)});
    }
    candidates.sort((a, b) => a.length - b.length);
    const bytes = candidates.at(-1);
    for (const candidate of candidates) if (!bytes.subarray(0, candidate.length).equals(candidate)) throw new Error('Ambiguous transcript copies contain diverging history.');
    totalBytes += bytes.length;
    if (totalBytes > 128 * 1024 * 1024) throw new Error('Transcript chain exceeds the 128 MiB limit.');
    const text = bytes.toString('utf8').replace(/^\uFEFF/, '');
    if (text.trim() && !text.endsWith('\n')) throw new Error('Transcript ends with an incomplete JSONL record. Wait for Claude to finish writing.');
    let leaf = null;
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      const record = JSON.parse(line);
      position++;
      if (!record || typeof record !== 'object') throw new Error('Invalid transcript record.');
      const isMessage = record.type === 'user' || record.type === 'assistant';
      if (isMessage && (typeof record.uuid !== 'string' || record.message?.role !== record.type)) throw new Error('Message identity or role is invalid.');
      if (typeof record.uuid === 'string') {
        const previous = nodes.get(record.uuid);
        const identity = message => message && ({...message, usage: undefined});
        if (previous && JSON.stringify(identity(previous.message)) !== JSON.stringify(identity(record.message))) throw new Error('Conflicting repeated message ID in continuation chain.');
        if (previous) {
          const structure = node => JSON.stringify([node.type, node.parentUuid ?? null, node.logicalParentUuid ?? null, !!node.isSidechain, !!node.isCompactSummary, node.subtype === 'compact_boundary' ? node.compactMetadata : null]);
          if (structure(previous) !== structure(record)) ambiguous.add(record.uuid);
        }
        if (!previous) { nodes.set(record.uuid, record); positions.set(record.uuid, position); }
        if (isMessage && !record.isSidechain && !record.isMeta) leaf = record.uuid;
      }
    }
    if (!leaf) throw new Error('A continuation transcript has no main conversation messages.');
    const branch = [], visited = new Set();
    while (leaf) {
      if (visited.has(leaf)) throw new Error('Cyclic transcript ancestry.');
      visited.add(leaf);
      const record = nodes.get(leaf);
      if (!record) throw new Error('Transcript ancestry references a missing message.');
      if (record.isSidechain) throw new Error('Main conversation references a sidechain.');
      branch.push(record);
      if (record.type === 'system' && record.subtype === 'compact_boundary') {
        leaf = record.logicalParentUuid || record.parentUuid;
        if (!leaf) throw new Error('Compaction boundary has no link to earlier history; full history cannot be verified.');
        if (record.logicalParentUuid && !nodes.has(record.logicalParentUuid) && record.compactMetadata?.preservedMessages) {
          leaf = persistedCompactionTail(record, nodes, positions, ambiguous);
          recoveries.set(record.uuid, {boundaryUuid: record.uuid, memoryOnlyUuid: record.logicalParentUuid, persistedTailUuid: leaf, persistedMessages: record.compactMetadata.preservedMessages.uuids.length});
        }
      } else leaf = record.parentUuid;
    }
    branch.reverse();
    const shared = branch.find(record => included.has(record.uuid));
    if (shared) {
      // A later file may fork back before the old leaf. Replace that tail;
      // concatenating both leaves would resurrect the abandoned response.
      ordered.splice(ordered.findIndex(record => record.uuid === shared.uuid));
      included.clear(); for (const record of ordered) included.add(record.uuid);
    }
    for (const record of branch) if (!included.has(record.uuid)) { included.add(record.uuid); ordered.push(record); }
  }
  const stats = {messages: 0, userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, omittedReasoningBlocks: 0,
    serverToolCalls: 0, advisorResults: 0, advisorErrors: 0, omittedEncryptedAdvisorResults: 0, toolReferences: 0, toolDefinitionChanges: 0, images: 0, documents: 0};
  const attachments = new Map();
  const messages = [];
  for (const record of ordered) {
    if (!['user', 'assistant'].includes(record.type) || record.isMeta || record.isCompactSummary) continue;
    const content = portableContent(record.message.content, stats, attachments);
    if (!content.length) continue;
    // Match native handling of tool-result-only envelopes without promoting
    // external tool output into new user instructions. Empty text is ignored.
    const onlyResults = content.some(block => block.type === 'imported_tool_result') && content.every(block => block.type === 'imported_tool_result' || (block.type === 'text' && !block.text.length));
    const type = record.type === 'user' && onlyResults ? 'assistant' : record.type;
    messages.push({uuid: record.uuid, type, timestamp: record.timestamp, content});
    stats.messages++; stats[type === 'user' ? 'userMessages' : 'assistantMessages']++;
  }
  if (!stats.userMessages) throw new Error('No portable user messages were found.');
  return {messages, stats, sources, attachments: [...attachments.values()], compactionRecoveries: [...recoveries.values()].filter(recovery => included.has(recovery.boundaryUuid))};
}

function linkAttachments(content, assets) {
  return content.map(block => {
    if (block.type === 'imported_image' || block.type === 'imported_document') {
      const asset = assets.get(block.assetHash);
      const label = block.type === 'imported_image' ? 'image' : 'document';
      const metadata = block.metadata && Object.keys(block.metadata).length ? `\n[Original document metadata]\n${JSON.stringify(block.metadata, null, 2)}` : '';
      return {type: 'text', text: `[Imported ${label} attachment, ${asset.mediaType}; preserved as a local file]\n[Open original ${label}](<${asset.path.replaceAll('\\', '/')}>)${metadata}`};
    }
    if (block.type === 'imported_tool_result') {
      const {type, content: nested, ...metadata} = block;
      const text = linkAttachments(nested, assets).map(child => child.text).join('\n');
      return {type: 'text', text: `[external_agent_tool_result${block.is_error === true ? ': error' : ''}]\n[Original tool-result metadata]\n${JSON.stringify(metadata, null, 2)}\n${text}\n[/external_agent_tool_result]`};
    }
    return block;
  });
}

export async function createImportPlan(request) {
  const {stateRoot, codexHome, source, records} = request;
  await regularPath(stateRoot); await regularPath(codexHome);
  await fs.mkdir(path.join(stateRoot, 'plans'), {recursive: true, mode: 0o700});
  const ledger = await ledgerFor(stateRoot, codexHome);
  const plan = {version: VERSION, stitcherVersion: STITCHER_VERSION, kind: 'claude-to-codex', id: randomUUID(), createdAt: new Date().toISOString(), stateRoot, codexHome, source, scope: request.scope, newRevision: !!request.newRevision, rows: [],
    notes: ['Creates immutable Codex snapshots. Existing imported threads are never updated.', 'Child sessions become separate Codex threads; original relationships are recorded in the private receipt.', 'Tool calls and definitions become readable text. Images and embedded PDFs are preserved as linked local files, not native inline attachments. Provider reasoning/signatures and encrypted advisor payloads cannot be transferred as readable text.']};
  for (const record of records) {
    const row = {...record, requestedCwd: record.cwd, status: 'Skipped', reason: record.blockedReason || '', sourceKey: hash(JSON.stringify([source.profileId.toLowerCase(), canonical(source.projectsRoot), record.id.toLowerCase()]))};
    plan.rows.push(row);
    if (row.reason) continue;
    try {
      if (!path.isAbsolute(record.cwd)) throw new Error('The source working directory must be an absolute Windows path.');
      try {
        if (!(await fs.stat(record.cwd)).isDirectory()) throw new Error('Not a directory');
        // Codex resolves workspace aliases during import; preview that exact path.
        row.cwd = await fs.realpath(record.cwd);
      }
      catch { throw new Error('Working directory is unavailable. Preview with -DestinationFolder pointing to an existing project directory.'); }
      within(record.cardPath, source.profileRoot); await regularPath(record.cardPath);
      if (hash(await fs.readFile(record.cardPath)) !== record.cardHash) throw new Error('Source card changed while planning. Preview again.');
      const stitched = await stitchTranscripts(record.transcripts, source.projectsRoot);
      row.sources = stitched.sources; row.stats = stitched.stats;
      row.warnings = [];
      if (stitched.compactionRecoveries.length) {
        row.compactionRecoveries = stitched.compactionRecoveries;
        row.warnings.push(`${stitched.compactionRecoveries.length} compaction links were reconnected using verified persisted-message metadata; memory-only record IDs are not transcript messages.`);
      }
      if (row.stats.images) row.warnings.push(`${row.stats.images} images will be preserved as linked local attachments; native inline image display is not recreated.`);
      if (row.stats.documents) row.warnings.push(`${row.stats.documents} PDF documents will be preserved as linked local attachments; document contents are not embedded as native Codex attachments.`);
      if (row.stats.omittedEncryptedAdvisorResults) row.warnings.push(`${row.stats.omittedEncryptedAdvisorResults} encrypted advisor responses have no readable source text; placeholders are retained.`);
      const assets = new Map(); row.assets = [];
      for (const attachment of stitched.attachments) {
        const file = path.join(stateRoot, 'assets', attachment.hash + '.' + attachment.extension);
        await regularPath(file); await fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
        await immutableSnapshot(file, attachment.bytes, attachment.hash);
        // Link bytes must remain stable when the same state directory is spelled differently.
        const asset = {path: await fs.realpath(file), hash: attachment.hash, mediaType: attachment.mediaType, bytes: attachment.bytes.length};
        assets.set(attachment.hash, asset); row.assets.push(asset);
      }
      row.revision = hash(JSON.stringify({stitcher: STITCHER_VERSION, messages: stitched.messages, title: record.title, cwd: canonical(row.cwd), parent: record.parent, archived: record.archived}));
      const existing = ledger.entries[revisionKey(row)];
      if (existing?.phase === 'complete') { row.status = 'Unchanged'; row.target = existing.target; row.reason = existing.notice || 'This revision was already imported.'; continue; }
      if (existing && !existing.target && request.newRevision) row.replacesAttempt = existing.snapshotPath;
      if (existing?.phase === 'failed' && !request.newRevision) { row.status = 'Failed'; row.reason = existing.lastError || 'Native import failed. NewRevision can create a separate recovery attempt.'; continue; }
      if (ledger.latest[row.sourceKey] && ledger.latest[row.sourceKey] !== row.revision && !request.newRevision && !existing) {
        row.status = 'Changed'; row.reason = 'Source changed since import. Preview with -NewRevision to create a separate thread.'; continue;
      }
      row.snapshotId = snapshotId(row.sourceKey, row.revision + (row.replacesAttempt ? '/' + randomUUID() : ''));
      row.snapshotPath = path.join(stateRoot, 'source-home', '.claude', 'projects', hash(canonical(row.cwd)).slice(0, 24), row.snapshotId + '.jsonl');
      if (existing && !row.replacesAttempt) {
        if (!existing.snapshotPath) throw new Error('Incomplete receipt has no staged path. Keep it for investigation.');
        within(existing.snapshotPath, path.join(stateRoot, 'source-home'));
        row.snapshotPath = existing.snapshotPath; row.snapshotId = path.basename(existing.snapshotPath, '.jsonl');
      }
      await regularPath(row.snapshotPath);
      try {
        const staged = await fs.readFile(row.snapshotPath, 'utf8');
        const priorCwd = JSON.parse(staged.slice(0, staged.indexOf('\n'))).cwd;
        if (!samePath(priorCwd, row.cwd)) throw new Error('Staged working directory does not match this preview.');
        row.cwd = priorCwd;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      let parent = null;
      const data = stitched.messages.map(message => {
        const result = {type: message.type, uuid: message.uuid, parentUuid: parent, sessionId: row.snapshotId, cwd: row.cwd,
          timestamp: message.timestamp, isSidechain: false, message: {role: message.type, content: linkAttachments(message.content, assets)}};
        parent = message.uuid; return JSON.stringify(result);
      }).join('\n') + '\n';
      row.snapshotHash = hash(data);
      await regularPath(row.snapshotPath);
      await fs.mkdir(path.dirname(row.snapshotPath), {recursive: true, mode: 0o700});
      await immutableSnapshot(row.snapshotPath, data, row.snapshotHash);
      row.status = 'Ready'; row.reason = row.replacesAttempt ? 'Create a separate recovery snapshot. The previous attempt may already exist and will be kept.' : existing ? 'Reconcile the previous attempt before importing.' : 'Create a new Codex thread.';
    } catch (error) { row.reason = error.message; }
  }
  const planPath = path.join(stateRoot, 'plans', plan.id + '.json');
  await atomicJSON(planPath, plan);
  return {...plan, planPath};
}

function importedMappings(histories) {
  if (!Array.isArray(histories.data)) throw new Error('Unsupported native import-history response; no imports were submitted.');
  const mappings = new Map();
  for (const history of [...histories.data].sort((a, b) => (a.completedAtMs || 0) - (b.completedAtMs || 0))) {
    if (!Array.isArray(history.successes)) throw new Error('Unsupported native import-history entry; no imports were submitted.');
    for (const success of history.successes) {
    if (success.itemType === 'SESSIONS' && success.source && success.target) mappings.set(canonical(success.source), {target: success.target, importId: history.importId});
    }
  }
  return mappings;
}

export async function applyImportPlan(request, serverFactory = options => new CodexAppServer(options)) {
  const {stateRoot, codexHome} = request;
  await regularPath(stateRoot); await regularPath(codexHome);
  within(request.planPath, path.join(stateRoot, 'plans')); await regularPath(request.planPath);
  const plan = await readJSON(request.planPath);
  if (plan.version !== VERSION || plan.kind !== 'claude-to-codex' || !samePath(plan.stateRoot, stateRoot) || !samePath(plan.codexHome, codexHome)) throw new Error('Plan version or destination does not match.');
  if (plan.stitcherVersion !== STITCHER_VERSION) throw new Error('This plan uses an outdated content conversion. Create a new preview before importing.');
  const lockPath = path.join(stateRoot, 'import.lock');
  let lock;
  try { lock = await fs.open(lockPath, 'wx', 0o600); }
  catch (error) { if (error.code === 'EEXIST') throw new Error('Another import may be running. Inspect import.lock before removing a stale lock.'); throw error; }
  let server;
  try {
    await lock.writeFile(JSON.stringify({pid: process.pid, planId: plan.id}));
    const ledger = await ledgerFor(stateRoot, codexHome);
    const ready = plan.rows.filter(row => row.status === 'Ready');
    // Check every source before starting Codex or submitting any work.
    for (const row of ready) {
      within(row.cardPath, plan.source.profileRoot); await regularPath(row.cardPath);
      if (hash(await fs.readFile(row.cardPath)) !== row.cardHash) throw new Error('Source card changed after preview. Create a new plan.');
      for (const source of row.sources) {
        within(source.path, plan.source.projectsRoot); await regularPath(source.path);
        if (hash(await fs.readFile(source.path)) !== source.hash) throw new Error('Source transcript changed after preview. Create a new plan.');
      }
      within(row.snapshotPath, path.join(stateRoot, 'source-home')); await regularPath(row.snapshotPath);
      if (hash(await fs.readFile(row.snapshotPath)) !== row.snapshotHash) throw new Error('Staged transcript changed after preview. Create a new plan.');
      for (const asset of row.assets ?? []) {
        within(asset.path, path.join(await fs.realpath(stateRoot), 'assets')); await regularPath(asset.path);
        if (hash(await fs.readFile(asset.path)) !== asset.hash) throw new Error('Linked attachment changed after preview. Create a new plan.');
      }
      const latest = ledger.latest[row.sourceKey];
      if (latest && latest !== row.revision && !plan.newRevision && !ledger.entries[revisionKey(row)]) throw new Error('Another revision was imported after this preview. Create a new plan with -NewRevision.');
    }
    const result = {action: 'Import', planPath: request.planPath, receiptPath: path.join(stateRoot, 'plans', plan.id + '.result.json'), rows: plan.rows.map(row => ({id: row.id, title: row.title, parent: row.parent, status: row.status, reason: row.reason, target: row.target, stats: row.stats, warnings: row.warnings, assets: row.assets}))};
    if (!ready.length) { await atomicJSON(result.receiptPath, result); return result; }
    const sourceHome = path.join(stateRoot, 'source-home');
    server = serverFactory({codexHome, sourceHome, executable: request.codexExecutable || 'codex'});
    const initialized = await server.initialize();
    if (!samePath(initialized.codexHome, codexHome)) throw new Error('Codex initialized a different destination home.');
    const mappings = importedMappings(await server.request('externalAgentConfig/import/readHistories'));
    let detectedSessions;
    for (const row of ready) {
      const key = revisionKey(row), answer = result.rows.find(item => item.id === row.id);
      if (server.failure) { Object.assign(answer, {status: 'NotAttempted', reason: 'Codex connection unavailable. No request was submitted for this row; retry the saved plan.'}); continue; }
      let replacement, pendingWritten = false, submissionStarted = false;
      try {
      let entry = ledger.entries[key];
      let fresh = false;
      if (entry?.phase === 'complete') { Object.assign(answer, {status: 'Unchanged', target: entry.target, reason: 'Already imported.'}); continue; }
      if (row.replacesAttempt && !samePath(entry?.snapshotPath, row.snapshotPath)) {
        if (!plan.newRevision || !entry || !samePath(entry.snapshotPath, row.replacesAttempt)) throw new Error('Recovery attempt changed after preview. Create a new plan.');
        replacement = entry;
        const oldMapping = mappings.get(canonical(row.replacesAttempt));
        if (oldMapping) entry = ledger.entries[key] = {...entry, ...oldMapping, phase: 'created'};
        else entry = undefined;
      }
      const recovered = mappings.get(canonical(row.snapshotPath));
      if (recovered) entry = ledger.entries[key] = {...entry, ...recovered, phase: 'created', snapshotPath: row.snapshotPath, sourceKey: row.sourceKey, revision: row.revision, parent: row.parent};
      if (entry?.phase === 'failed') { Object.assign(answer, {status: 'Failed', reason: entry.lastError, target: entry.target}); continue; }
      if (entry && !entry.target) throw new Error('Previous import has an unknown outcome and no completed native history mapping. Keep the receipt for investigation; no automatic resubmission was made.');
      if (!entry) {
        if (!detectedSessions) {
          const detection = await server.request('externalAgentConfig/detect', {includeHome: true, cwds: [], maxSessions: 1000000, maxSessionAgeDays: 365000, migrationSource: 'claude-code'});
          detectedSessions = new Map(detection.items.filter(item => item.itemType === 'SESSIONS').flatMap(item => item.details?.sessions ?? []).map(session => [canonical(session.path), session]));
        }
        const detected = detectedSessions.get(canonical(row.snapshotPath));
        if (!detected) throw new Error('Codex did not detect the selected staged transcript. No import was submitted.');
        if (server.failure) throw Object.assign(new Error('Codex connection unavailable before submission.'), {notSubmitted: true, method: 'externalAgentConfig/detect'});
        // Persist before submission. A lost acknowledgement must never become a blind retry.
        if (replacement) (ledger.abandonedAttempts ??= []).push({...replacement, key, abandonedAt: new Date().toISOString(), reason: 'Explicit separate recovery revision'});
        entry = ledger.entries[key] = {phase: 'pending', snapshotPath: row.snapshotPath, sourceKey: row.sourceKey, revision: row.revision, parent: row.parent};
        pendingWritten = true;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
        submissionStarted = true;
        const imported = await server.request('externalAgentConfig/import', {migrationSource: 'claude-code', source: 'claude-sync', migrationItems: [{itemType: 'SESSIONS', description: 'Import selected Claude conversation snapshot', details: {sessions: [detected]}}]});
        entry.importId = imported.importId;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
        const completed = await server.waitFor('externalAgentConfig/import/completed', event => event.importId === imported.importId);
        const successes = (completed.itemTypeResults ?? []).flatMap(item => item.successes ?? []);
        const failures = (completed.itemTypeResults ?? []).flatMap(item => item.failures ?? []);
        const success = successes.find(item => item.itemType === 'SESSIONS' && samePath(item.source, row.snapshotPath) && item.target);
        if (!success) {
          entry.phase = failures.length ? 'failed' : 'unknown'; entry.failures = failures;
          entry.lastError = failures.map(item => item.message).join(' ') || 'Native import did not return a verified source/target mapping; outcome unknown.';
          await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
          Object.assign(answer, {status: entry.phase === 'failed' ? 'Failed' : 'NeedsInvestigation', reason: entry.lastError}); continue;
        }
        entry.target = success.target; entry.phase = 'created';
        fresh = true;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
      }
      const read = await server.request('thread/read', {threadId: entry.target, includeTurns: false});
      if (read.thread?.id !== entry.target || (fresh && !samePath(read.thread.cwd, row.cwd))) throw new Error('Imported thread identity or working directory did not match.');
      if (!fresh) {
        // The thread may have been continued since the interrupted attempt.
        // Recover its mapping without changing any existing title/archive state.
        entry.phase = 'complete'; entry.completedAt = new Date().toISOString();
        entry.notice = 'Recovered conversation; existing Codex title/archive/folder were kept after interruption. Check them in Codex.';
        ledger.latest[row.sourceKey] = row.revision;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
        Object.assign(answer, {status: 'Recovered', target: entry.target, reason: entry.notice}); continue;
      }
      if (!entry.named && row.title) {
        await server.request('thread/name/set', {threadId: entry.target, name: row.title}); entry.named = true;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
      }
      if (!entry.archived && row.archived) {
        await server.request('thread/archive', {threadId: entry.target}); entry.archived = true;
        await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
      }
      entry.phase = 'complete'; entry.completedAt = new Date().toISOString();
      ledger.latest[row.sourceKey] = row.revision;
      await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
      Object.assign(answer, {status: 'Imported', target: entry.target, reason: recovered ? 'Recovered from native import history.' : 'New Codex snapshot created.'});
      } catch (error) {
        if (pendingWritten && (!submissionStarted || (error.notSubmitted && error.method === 'externalAgentConfig/import'))) {
          if (replacement) ledger.entries[key] = replacement; else delete ledger.entries[key];
          if (replacement) ledger.abandonedAttempts.pop();
          await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
        }
        const entry = ledger.entries[key];
        if (entry) {
          if (replacement && entry === replacement) entry.lastRecoveryError = error.message; else entry.lastError = error.message;
          await atomicJSON(path.join(stateRoot, 'imports.json'), ledger);
        }
        Object.assign(answer, {status: error.notSubmitted && !entry?.target ? 'NotAttempted' : 'NeedsInvestigation', reason: error.message, target: entry?.target});
      }
    }
    await atomicJSON(result.receiptPath, result);
    return result;
  } finally {
    try { if (server) await server.close(); }
    finally { await lock.close(); await fs.unlink(lockPath); }
  }
}
