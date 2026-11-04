# Import Claude conversations into Codex

Import local Windows **Claude Desktop Code** conversations as new, readable Codex
threads. Select a project folder or a session and its descendants, preview the
result, then import that saved snapshot. This is an initial standalone feature;
the History sync mod still handles Claude account-to-account sync only.

Requires Windows PowerShell 5.1 or PowerShell 7, Node.js 22 or later, and a Codex
CLI with the external-agent session import API. Native integration tests pass
with Codex CLI **0.160.0**. The API is experimental; other versions need testing.
No model turn is started and no API key is requested. Codex itself may perform
normal background network activity. ClaudeSync does not edit Codex databases.

## Other Windows computers

The importer is command-line only; there is no Codex import button in the mod.
The checkout can live on any local drive. It discovers Claude Desktop profiles
on that computer, reads the source roots from `profiles.json`, and uses that
Windows user's profile and LocalAppData for default destination and private state.
The shipped configuration contains no personal account IDs or project paths.

Install PowerShell, Node.js 22 or later and a compatible Codex CLI on each PC.
Use `-NodeExecutable` or `-CodexExecutable` with a full executable path when a
tool is installed outside PATH. Paths containing spaces and Unicode are supported.
`-NodeExecutable` requires a native `.exe`; `.cmd` and `.bat` wrappers are rejected
so Windows command-shell expansion cannot reinterpret paths.
The Node version is checked before private staging is written.
Import initializes a missing destination home with private Windows permissions;
preview leaves it absent, and existing destination permissions are preserved.

Run `-Mode Profiles` and `-Mode Choices` on the new PC, then create a fresh preview.
Select that PC's source folder and use `-DestinationFolder` to map removed or
different worktree paths to an existing local project. This copies conversation
history; it does not copy project files or rewrite paths inside historical text.

Saved plans, journals and linked attachment paths belong to their local computer
and destination. They are not a portable export bundle: copying a plan to another
PC is not supported. Keep the original private state directory for its imports,
and preview afresh against the source history available on the other computer.
macOS and Linux are not supported by this Windows Desktop importer.

## Select and preview

```powershell
# Read-only account and source-folder/session discovery.
.\Import-ClaudeToCodex.ps1 -Mode Profiles
.\Import-ClaudeToCodex.ps1 -Mode Choices -Source 'source@example.com'

# Include the folder's subdirectories and descendant sessions in other worktrees.
.\Import-ClaudeToCodex.ps1 -Source 'source@example.com' `
    -Scope Folder -ScopeFolder 'C:\Projects\SampleProject'

# Or select a session; its descendants are included, its ancestors are not.
.\Import-ClaudeToCodex.ps1 -Source 'source@example.com' `
    -Scope Session -ScopeSession 'local_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
```

`Plan` is the default mode. It reads source history and writes a private plan and
staged transcript copies, without starting Codex or modifying either app's
history. `-Scope All` explicitly selects the source account's entire catalog.
Use `-AsJson` for structured output.

The preview identifies each session as:

| Status | Meaning |
| --- | --- |
| Ready | Creates a new Codex thread from the staged conversation. |
| Unchanged | This source revision has already been imported by this tool. |
| Changed | The source differs from the previous import; the existing Codex thread is kept. |
| Skipped | Cannot import this session; the row gives the reason. |
| Failed | Codex reported a failure; the private journal retains its details. |
| NeedsInvestigation | An earlier attempt is ambiguous or recovery needs attention; other sessions can continue. |
| Recovered | An interrupted import was found; its current title/archive were kept to preserve any subsequent Codex edits. |
| NotAttempted | The Codex connection failed; no import request was sent for this row. Retry the saved plan. |

Preview rows marked Changed, Skipped, or Failed are not imported. If every row has one of
these statuses, Import makes no changes to Codex.

## Import the saved plan

```powershell
.\Import-ClaudeToCodex.ps1 -Mode Import -Plan 'C:\path\printed\by\preview.json'
```

Use the actual plan path printed by Preview. Source transcript/card hashes and
scope membership are checked again before importing. If Claude has written more
content or changed the selection, preview again. Let selected sessions finish
their current turn before previewing and importing.
Saved plans from an older content-conversion version are rejected; create a new
preview after an importer update instead of reusing an outdated snapshot.

The destination is `$env:CODEX_HOME`, or `%USERPROFILE%\.codex` when unset.
`-CodexHome 'C:\path\to\codex-home'` chooses another local installation. Keep the
same destination option for Plan and Import. Source account selection does not
select a Codex account: the destination is the specified local Codex home.

Codex requires an existing working directory. If a Claude worktree was removed,
or you want the imported sessions in another project directory, specify the
destination while previewing:

```powershell
.\Import-ClaudeToCodex.ps1 -Source 'source@example.com' `
    -Scope Folder -ScopeFolder 'C:\Projects\SampleProject' `
    -DestinationFolder 'C:\Projects\SampleProject'
```

This maps every selected conversation to that directory. The saved plan retains
both the original and destination paths. Project files and worktree changes must
already be available where you intend to continue; they are not copied.
Workspace aliases such as junctions resolve to the physical path Codex uses.
The preview records the requested path and shows the resolved destination when
it differs, so you can review the actual project location before importing.

After import, use the printed Codex thread ID with `codex resume <id>`, or refresh
the destination app's history. Visibility and continuation in the installed
desktop UI have not been manually verified. This feature creates new threads;
it does not modify existing Codex conversations or copy project files.

## Changes and repeated imports

An unchanged revision is skipped. Source identity includes the Claude profile,
projects root, and Desktop session ID; the destination has its own import state.
Do not delete that state if you want duplicate detection and crash recovery.

To bring over a changed conversation, preview explicitly with `-NewRevision`:

```powershell
.\Import-ClaudeToCodex.ps1 -Source 'source@example.com' `
    -Scope Folder -ScopeFolder 'C:\Projects\SampleProject' -NewRevision
```

Import the resulting plan normally. This creates a **separate thread** and keeps
the earlier import, including any work continued in Codex. Automatic updates and
merging Codex-written turns into an imported conversation are not supported.

## What transfers

- User and assistant text on the active transcript ancestry. Verified local CLI
  continuation files are joined in order, with repeated message IDs deduplicated.
- Tool calls and results as complete labeled text, including full input fields,
  error flags, and results. This avoids native tool-record shortening. Tool-only
  results use assistant messages, matching Codex's native role mapping; mixed
  user text and results keep the user role.
  Tool references, dynamic tool definitions, and server/advisor calls are retained
  as labeled text; they do not enable tools or start running tasks in Codex.
- Embedded PNG, JPEG, WebP and GIF images as exact-byte local attachments with
  links at their original positions in the transcript. Codex's native importer
  does not reconstruct inline images. Keep the private asset directory available
  to open or inspect those images; the files are not uploaded to a cloud account.
- Embedded base64 PDF documents as exact-byte linked local attachments, retaining
  their position and any title, context and citation metadata as readable text.
  PDF pages are not automatically rendered or extracted into the conversation.
- Desktop title, working directory, and archive state on the new Codex thread.
- Selected child conversations as separate Codex threads. The private receipt
  retains their original parent IDs; Codex's UI tree is not reconstructed.

Compaction boundaries are followed through their logical parent so earlier
messages remain included. Some Claude versions point at an in-memory record
that is intentionally never written. The importer can reconnect such a boundary
only when explicit persisted-message metadata, a unique summary anchor, and an
intact earlier ancestry all agree. Missing persisted records still block import;
the preview reports each verified reconnection.
Generated compaction recaps, provider thinking/signature
blocks, and internal Claude metadata are omitted. Encrypted advisor responses
cannot be decrypted by this tool: the preview counts them and the transcript
retains a labeled placeholder. Plaintext advisor responses and recorded advisor
errors are preserved as labeled text. Unrecognized advisor-result variants block
the session and are reported in the preview. Documents available only through a
URL or provider file ID remain blocked; preview never downloads remote files.
Unsupported attachments and unknown content blocks block that session rather
than being silently discarded. Remote/WSL, scheduled, cloud-task, pending,
missing, malformed, and tombstoned transcript chains are skipped with reasons.
Duplicate files are accepted only when the longest file is an exact byte-prefix
extension of every other copy. Every copy is hashed and rechecked. Diverging
copies remain blocked. Repeated messages may differ in usage accounting only;
changed message content is never silently deduplicated.
There is a 128 MiB combined source-transcript limit per selected conversation.

## Private state and interrupted imports

Plans, transcript snapshots, and the import journal live under
`%LOCALAPPDATA%\ClaudeHistorySync\codex-imports\<destination-hash>` with private
Windows permissions. They contain conversation content and account/project
metadata. Keep them out of Git and public issue reports. `-StateRoot` chooses a
different private directory; use that same option for Plan and Import.

The importer waits for native completion and records the returned source/target
mapping. After an interrupted import, retry the **same plan**: completed native
history is consulted before any retry. An unknown outcome without a mapping
is reported for investigation; it is never blindly resubmitted. Other selected
sessions can continue. Preserve the journal
and printed plan. A crash may leave `import.lock`; verify its recorded process is
no longer running before removing that specific lock file.

After investigating a failed or ambiguous attempt, `-NewRevision` can explicitly
preview a separate recovery snapshot. Its native session identity is new, and
the old attempt remains recorded. A known target or completed history mapping is
recovered first instead of duplicated. If no mapping can be found, the old thread
may already exist, so a separate recovery revision can produce two copies;
neither copy is overwritten or deleted. After a transport timeout, remaining
rows are marked NotAttempted and can be retried with the same saved plan.

Custom staging directories must be new, empty, or marked as previously owned by
this importer. The tool refuses to change permissions on unrelated populated
folders. Staged revisions are published atomically and retained for recovery;
they are not automatically pruned. Native requests allow up to ten minutes.

Windows npm installs are launched through the package's JavaScript entry point
without executing a command shell. Use `-CodexExecutable 'C:\path\to\codex.exe'`
or the package's `codex.js` path if automatic discovery cannot find your CLI.

There is no automatic Undo of a native import. Earlier conversations are kept;
unwanted imported threads can be archived using Codex's own controls.

## Development checks

```powershell
.\Test-ClaudeToCodex.ps1
node --test .\tests\claude-to-codex.test.mjs

# Explicit native integration test, using synthetic conversations and an isolated
# Codex home. It does not use the real source profile or destination history.
$env:CLAUDESYNC_NATIVE_IMPORT_TEST='1'
try { node --test .\tests\claude-to-codex.test.mjs; .\Test-ClaudeToCodex.ps1 }
finally { Remove-Item Env:CLAUDESYNC_NATIVE_IMPORT_TEST }
```

Native API references: [Codex App Server](https://learn.chatgpt.com/docs/app-server)
and [Import from another agent](https://learn.chatgpt.com/docs/import).
