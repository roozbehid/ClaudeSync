import {readFile} from 'node:fs/promises';
import {createImportPlan, applyImportPlan} from '../lib/claude-to-codex.mjs';

try {
  if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('Claude → Codex imports require Node.js 22 or later.');
  if (process.argv.length !== 3) throw new Error('Run Import-ClaudeToCodex.ps1 to select and preview the source.');
  const request = JSON.parse((await readFile(process.argv[2], 'utf8')).replace(/^\uFEFF/, ''));
  if (!['Plan', 'Import'].includes(request.action)) throw new Error('Unsupported import action.');
  const result = request.action === 'Plan' ? await createImportPlan(request) : await applyImportPlan(request);
  process.stdout.write(JSON.stringify(result));
} catch (error) {
  process.stdout.write(JSON.stringify({error: error.message}));
  process.exitCode = 1;
}
