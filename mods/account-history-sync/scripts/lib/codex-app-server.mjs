import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {existsSync} from 'node:fs';
import path from 'node:path';

export function resolveCodexLaunch(executable, {platform = process.platform, searchPath = process.env.PATH || ''} = {}) {
  if (platform !== 'win32') return {command: executable, prefix: []};
  if (/\.(js|cmd|ps1)$/i.test(executable) && !path.isAbsolute(executable)) throw new Error('Use an absolute script path with -CodexExecutable, or use the default codex command for PATH discovery.');
  if (/\.js$/i.test(executable)) return {command: process.execPath, prefix: [executable]};
  let shim = /\.(cmd|ps1)$/i.test(executable) ? path.resolve(executable) : null;
  if (!shim && !/[\\/]/.test(executable)) {
    const directories = searchPath.split(';').map(value => value.replace(/^"|"$/g, ''));
    for (const directory of directories) {
      if (!directory || !path.isAbsolute(directory)) continue;
      const native = path.join(directory, /\.exe$/i.test(executable) ? executable : executable + '.exe');
      if (existsSync(native)) return {command: native, prefix: []};
      const candidate = path.join(directory, executable + '.cmd');
      if (existsSync(candidate)) { shim = candidate; break; }
    }
    if (!shim) throw new Error('Codex was not found in an absolute PATH directory. Use -CodexExecutable with its full executable or JavaScript launcher path.');
  }
  if (shim) {
    const launcher = path.join(path.dirname(shim), 'node_modules', '@openai', 'codex', 'bin', 'codex.js');
    if (!existsSync(launcher)) throw new Error('Cannot resolve this Codex script shim. Use -CodexExecutable with the native codex.exe or the npm package codex.js launcher.');
    return {command: process.execPath, prefix: [launcher]};
  }
  return {command: executable, prefix: []};
}

// Use only local import/read APIs. This client never starts a model turn.
export class CodexAppServer {
  constructor({codexHome, sourceHome, executable = 'codex', timeoutMs = 600000}) {
    this.timeoutMs = timeoutMs;
    this.nextId = 0;
    this.pending = new Map();
    this.events = [];
    this.waiters = new Set();
    this.diagnostics = '';
    const launch = resolveCodexLaunch(executable);
    this.child = spawn(launch.command, [...launch.prefix, 'app-server', '-c', 'features.remote_plugin=false', '--listen', 'stdio://'], {
      cwd: sourceHome, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
      env: {...process.env, CODEX_HOME: codexHome, USERPROFILE: sourceHome},
    });
    this.child.stderr.on('data', chunk => { this.diagnostics = (this.diagnostics + chunk).slice(-8000); });
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', code => this.fail(new Error(`Codex app-server exited (${code}). ${this.diagnostics}`)));
    this.child.stdin.on('error', error => this.fail(error));
    this.lines = createInterface({input: this.child.stdout});
    this.lines.on('line', line => {
      let message;
      try { message = JSON.parse(line); }
      catch { this.fail(new Error('Codex app-server returned invalid JSON.')); return; }
      if (message.id != null && message.method) {
        this.child.stdin.write(JSON.stringify({id: message.id, error: {code: -32601, message: 'Interactive requests are not supported by this importer.'}}) + '\n');
      } else if (message.id != null) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        clearTimeout(pending.timer); this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`Codex ${pending.method}: ${message.error.message}`));
        else pending.resolve(message.result);
      } else if (message.method) {
        this.events.push(message);
        if (this.events.length > 256) this.events.shift();
        for (const waiter of this.waiters) if (waiter.matches(message)) waiter.finish(message.params);
      }
    });
  }

  fail(error) {
    this.failure = error;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    for (const waiter of this.waiters) waiter.finish(null, error);
  }

  request(method, params = {}) {
    if (this.failure) return Promise.reject(Object.assign(new Error(this.failure.message), {notSubmitted: true, method}));
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      const timer = setTimeout(() => {
        this.fail(new Error(`Codex ${method} timed out; any submitted import has an unknown outcome. Retry the same plan to reconcile it.`));
      }, this.timeoutMs);
      this.pending.set(id, {resolve, reject, timer, method});
      this.child.stdin.write(JSON.stringify({id, method, params}) + '\n');
    });
  }

  waitFor(method, predicate) {
    const matches = message => message.method === method && predicate(message.params);
    const earlier = this.events.find(matches);
    if (earlier) return Promise.resolve(earlier.params);
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      const waiter = {matches, finish: (params, error) => {
        clearTimeout(timer); this.waiters.delete(waiter);
        if (error) reject(error); else resolve(params);
      }};
      const timer = setTimeout(() => this.fail(new Error('Import completion timed out; outcome unknown. Retry the same plan to reconcile it.')), this.timeoutMs);
      this.waiters.add(waiter);
    });
  }

  async initialize() {
    const result = await this.request('initialize', {
      clientInfo: {name: 'claude_sync_import', version: '0.1.0'}, capabilities: {experimentalApi: true},
    });
    this.child.stdin.write(JSON.stringify({method: 'initialized'}) + '\n');
    return result;
  }

  async close() {
    this.child.stdin.end();
    if (this.child.exitCode != null || this.child.signalCode != null) return;
    await new Promise(resolve => {
      const timer = setTimeout(() => { this.child.kill(); resolve(); }, 2000);
      this.child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
  }
}
