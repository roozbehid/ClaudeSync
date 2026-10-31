# Claude Desktop Code history sync

For controls above the session prompt that copy this account into an inactive
account, see the [Account history sync mod](../mods/account-history-sync/README.md).
It offers a destination picker, preview, manual sync, and automatic one-way sync.
Its runtime requires Mods to be enabled for your Claude environment.

Standalone PowerShell 5.1/7 tool for copying Code-tab history cards from one
selected account/organization profile to another on one Windows user. Sync is
one-way by default; both directions require `-Direction Both`. The script has
no built-in account IDs or email addresses. It needs no router service, Node,
Python, administrator rights, tokens, or network access. Move the whole folder
elsewhere if desired; keep `profiles.json` alongside the script.

Native Windows conversation transcripts already share
`%USERPROFILE%\.claude\projects`. WSL/SSH transcripts may live in the other OS or
remote host. The tool syncs Desktop's history cards and environment references.
It never writes transcripts, memory, credentials, global settings, ordinary Chat
history, Cowork, or cloud sessions. Desktop's local format is undocumented and
may change. Verification covers files and rollback; loading the new cards inside
Desktop has not been verified.

## Select profiles

```powershell
$tool = Join-Path (Get-Location) 'Sync-ClaudeHistory.ps1' # Run from this tool's folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Profiles
```

Profiles lists known emails, their sources, full profile IDs, optional aliases,
and session counts. Choose any pair by email, full ID, unique account UUID, or
configured alias. Replace the example emails below with values from the list:

```powershell
$a = 'a@example.com'
$b = 'b@example.com'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Plan -ProfileA $a -ProfileB $b
```

Plan is read-only and is the default mode. ProfileA is the source and ProfileB is
the destination. By default, fully exit Claude Desktop and Claude Code, then sync:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Sync -ProfileA $a -ProfileB $b
```

Add `-WhatIf` for another read-only preview. You do not need to sign out. Reopen
Desktop after the command finishes. The tool never closes processes and has no
scheduler or watcher. Ordinary Sync and Undo refuse writes while any `Claude`
process is running. Do not start Claude during those operations.

To copy in the reverse direction, use `-Direction BtoA`. To explicitly enable
both directions, use `-Direction Both`. Swapping ProfileA/ProfileB also reverses
the default copy direction. One-way sync never writes the source's cards or
archive index, and never copies destination-only cards back to the source.

## Sync while Claude is open

If A is active and B is inactive, opt into destination-only writes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Sync -ProfileA $a -ProfileB $b -AllowRunning -ActiveProfile $a
```

For B active and A inactive, add `-Direction BtoA -AllowRunning -ActiveProfile $b`.
The active profile must be the source. Both directions and live Undo are refused.
ActiveProfile is your declaration; the tool does not independently verify
Desktop's active login, cached profiles, or account switches. Keep the destination
inactive and do not switch accounts during a live sync. Shared file access does
not guarantee Desktop will not later overwrite externally edited metadata.

Existing destination cards and archive indexes are backed up before any history
writes. Each modifying run prints an Undo receipt. Missing indexes are recorded
as additions, so Undo can restore their absence. Changed files and source
snapshots are checked before applying; target hashes are rechecked before each
write. These checks do not provide a transaction with Desktop's own writes.

## Which copy wins

Default one-way sync uses the source as the winner, including when the destination
has a newer timestamp or different archive flag. `-Direction Both` defaults to
Newest. You can explicitly choose a policy for either mode:

| Policy | Behavior for differing copies of the same session |
| --- | --- |
| `Newest` (default for Both) | If the baseline shows only one history copy changed, use it. Otherwise choose the session JSON file with newer `LastWriteTimeUtc`. A timestamp tie remains a conflict. |
| `Profile` (default for one-way) | Use the source for one-way sync; for Both, requires `-WinnerProfile`. |
| `Changes` | Propagate one-sided history changes using the saved baseline; report conflicts when both changed or there is no common baseline. |

To choose a fixed winner:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Sync -ProfileA $a -ProfileB $b -Policy Profile -WinnerProfile $a
```

For `-WinnerProfile $b`, use `-Direction BtoA` or `-Direction Both`. Giving
WinnerProfile without a policy selects Profile automatically. In one-way mode
the winner must be the source. If explicit Newest or Changes chooses the
destination, that record is skipped; the tool never reverses direction. The
earlier `-PreferProfile original/alternate` interface was replaced.

The policy chooses the whole set of synchronized history fields for a session;
it does not merge independently conflicting titles and archive flags. Session
or remote environment identity conflicts are always skipped. Working-directory
changes do not change session identity: matching Desktop/CLI IDs can synchronize
history and archive flags across worktrees. Existing destination working directories
are preserved; new cards inherit the source directories. A fixed winner
does not delete sessions missing from it: one-way sync copies only source cards;
Both can copy new cards from either side, subject to deletion protection. Read
the conflict/skipped counts; those records do not prevent other records from syncing.

Desktop can continue a local conversation under a new CLI session ID. A Profile
winner (the default source in one-way sync) can advance an older copy when its full
ordered CLI history is an exact prefix of the winner's, and every referenced local
transcript exists without a deletion marker. Current/prior CLI IDs synchronize as
one unit with the history fields. Preview reports the old and new pointers. The
tool never rolls a newer continuation back to an older source, merges sibling
branches, or advances remote session pointers. Newest and Changes report a
conflict for differing continuations until an explicit Profile winner is chosen.
Existing history-only baselines remain usable for history changes when both full
CLI chains match; successful reconciliation upgrades them to pointer-aware hashes.

Newest uses **local metadata file modification time**, rather than the last chat
message timestamp. That includes archive/title changes without new messages.
There is no separate archive-event timestamp in the observed records, so file
time is a best-effort ordering: copies, external edits, and focus/settings writes
can change it. The baseline prevents an unchanged history copy from winning
merely because its file was touched later. On a first sync, or when both copies
changed, timestamps cannot prove the exact time of an individual archive/title
action. Sync-generated copies share a baseline and do not count as fresh history
changes on the next run.

## Sync one project or session tree

`-Scope All` is the standalone default. To limit both Plan and Sync to a project,
pass the same scope arguments to each command:

```powershell
.\Sync-ClaudeHistory.ps1 -Mode Plan -ProfileA $a -ProfileB $b -Scope Folder -ScopeFolder 'D:\Projects_Games\VRGame'
.\Sync-ClaudeHistory.ps1 -Mode Sync -ProfileA $a -ProfileB $b -Scope Folder -ScopeFolder 'D:\Projects_Games\VRGame'
```

Folder scope uses each source card's `originCwd`, falling back to `cwd`. It includes
subfolders and all descendants of matching sessions, even when they run in other
worktrees. It does not match similarly named sibling folders such as `VRGame-old`.
Use the full folder path; selecting a folder does not copy project files.

For one session, use `-Scope Session -ScopeSession 'local_DESKTOP_SESSION_GUID'`.
The ID is the Desktop card ID, not its current CLI transcript ID. All descendants
are included automatically. A leaf is synced alone. Ancestors are not implicitly
imported: if a selected child needs a parent missing from the destination, it is
skipped with a reason. Select its parent tree to import that parent as well.

Folder and Session scopes require a one-way direction. Unselected cards and their
baseline entries stay untouched; archive-index updates preserve unrelated entries.
Backups record the scope. An empty or stale selection fails instead of widening
to all history. Live sync still requires an inactive destination; the source can
remain open with `-AllowRunning -ActiveProfile` as described in the live-sync section.

## Archive and unarchive

**Both count as changes.** After establishing the common baseline, archive a
session in A, run AtoB Sync, then open B. The tool sets B's `isArchived` flag and
updates the archive cache. Unarchive works in
the selected direction, without a new chat turn or a changed `lastActivityAt` value.

If both history copies changed, the policy decides which archive status wins.
A fixed unarchived winner will unarchive the other copy. The tool also reconciles
`archived-sessions.idx` entries in the destination only, or both profiles with
Direction Both, including stale caches when the cards already agree. It leaves
cache entries for skipped/conflicting/deleted sessions alone. Plan reports
archive/unarchive counts.

## What gets synchronized

- Missing native Windows cards, provided the main local JSONL transcript exists.
- WSL/SSH cards and environment/transcript references, even without a transcript
  in the Windows store. No WSL or SSH connection is opened.
- Titles, archive flags, activity/turn summaries, model/effort, and branch history.
- Corresponding destination archive-cache entries (both with Direction Both),
  and a private baseline of hashes.

Existing target cards retain their own permissions, MCP configuration, Remote
Control links, focus timestamps, and unknown fields. New cards receive normal
default permissions and empty account-specific MCP/remote link lists. WSL/SSH
environment references remain attached; both logins still need access to the same
distribution/host and its existing transcript store. The tool does not install
WSL, add SSH hosts, copy SSH credentials, or verify remote transcript existence.

Scheduled history is optional:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Sync -ProfileA $a -ProfileB $b -IncludeScheduled
```

This copies past session cards, not schedule registrations or task ownership.
New cards are detached from `scheduledTaskId`; existing cards retain their own
references. No `scheduled-tasks.json` or `tasks.json` writes occur. Completion of
the scheduled run is not checked. Ordinary Sync requires Claude closed; live
one-way sync requires the destination inactive and uses the same checks as other
cards.

Deletions never propagate. A `deleted_UUID` marker in either selected profile
blocks copying the session. A missing card that was previously synced also stays
missing, avoiding resurrection after a marker disappears. Deleting a session in
one account does not automatically delete its card in the other account.

Each selected pair has separate state/backups under `state\pairs\PAIR_HASH`.
Swapping A/B or changing an alias keeps the same state; swapping A/B changes the
default source. Only matching or successfully copied cards advance the baseline.
Discovering profiles does not enroll them for sync. Inventory is read-only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Inventory -ProfileA $a -ProfileB $b
```

## Email labels and configuration

Automatic lookup reads only `oauthAccount.accountUuid`, `organizationUuid`, and
`emailAddress` from ordinary CLI `.claude.json` settings and known settings
backups. It does not read `.credentials.json`, decrypt Desktop token caches,
inspect cookies, or fetch accounts over the network. Some Desktop profiles have
no corresponding CLI identity settings, so their emails remain unknown.

Profiles reports `CLI settings`, `User label`, `Config label`, or `Unknown` as the
email source. `profile-labels.json` can label profiles manually:

```json
{
  "FormatVersion": 1,
  "Profiles": [
    { "Path": "ACCOUNT_GUID\\ORGANIZATION_GUID", "Email": "a@example.com" }
  ]
}
```

Labels are selectors, not authentication. User labels are marked explicitly and
are not represented as verified identity. Automatic identity labels take
precedence. If an email matches several organizations/profiles, use a full profile
ID. Empty organization folders appear with zero sessions and are not selected
automatically.

`profiles.json` defaults to `SessionsRoot: "Auto"`. It follows the running
Desktop's `--user-data-dir` in the current Windows session, so data-root moves
do not require a saved machine-specific path. With Desktop closed or process
inspection unavailable, it discovers regular, Store, and `Claude-Data`
installations under the current user's application-data directories. Ambiguous
roots are listed in an error instead of choosing one by age. Open Desktop to
identify the active installation, or set an explicit path. Existing explicit
paths stay authoritative; if one becomes stale, back up the config and switch
to `"Auto"` to follow Desktop again. Changes to the history folder name or format
may still require an engine update.
ProjectsRoot defaults to the ordinary Windows CLI transcript store and supports
environment-variable substitutions. To save a default pair, add exactly two
entries to its Profiles array:

```json
"Profiles": [
  { "Path": "ACCOUNT_A_GUID\\ORG_A_GUID", "Name": "work" },
  { "Path": "ACCOUNT_B_GUID\\ORG_B_GUID", "Name": "personal" }
]
```

Name is an optional alias; Email is an optional configured label. A/B command
arguments override the saved pair. Without a saved pair, Plan/Sync/Inventory need
both A/B arguments. Undo infers its pair from the selected backup receipt.

## Environments and cloud

A `local_UUID.json` filename alone does not prove a native Windows environment.
The inventory uses observed metadata fields, not a documented universal API:

| Kind | Indicator | Behavior |
| --- | --- | --- |
| WSL | `wslConfig`, including `distro` | Include |
| SSH | `sshRemoteProcessId`, `sshRemoteTranscriptPath`, or `sshConfig` | Include |
| Scheduled | `scheduledTaskId` | Optional via IncludeScheduled |
| LocalWithCloudTasks | Nonempty `cloudSpawnedTasks` | Include local parent when its transcript exists; omit cloud links from new cards |
| EnvironmentScoped | `envScopeId` | Include when a local transcript exists; omit source scope ID from new cards |
| Local | None of the above, with a main local transcript | Include |

Correctly named Desktop cards can exist before a CLI session starts. Inventory
marks cards without a CLI session ID as **Pending**; Plan reports them as skipped
and leaves the card and archive state untouched. They do not block other valid
history. A nonempty invalid CLI ID, mismatched Desktop ID, missing working
directory, malformed JSON, or invalid archive flag still fails validation.

The mod's Preview table uses real session titles and compares the destination's
original snapshot with its proposed state. Active/Archived filters use that
proposed state; conflicts and skipped cards remain unchanged. See the
[mod instructions](../mods/account-history-sync/README.md#before-and-after-preview).

Local session lineage (`spawnedFrom`, `forkedFromSessionId`,
`forkedAtMessageUuid`, and `lineageDetached`) is included in both copies and
updates. A card copied by an older version without its parent link is repaired
on the next source-to-destination sync, even if its title is unchanged. Preview
details show the parent before and after. Explicit detachment is preserved.
Parents and children can be copied together in any filename order. A child whose
parent or ancestor is unavailable, has a deletion marker, has a different session
identity, or forms a cycle is skipped with an explanation. No parent is resurrected
to repair a child, and account-bound cloud task links remain excluded.

Remote Control `bridgeSessionIds` do not prove cloud execution. A remotely
controlled local session still runs locally. There was no universal `isCloud`
flag in the inspected local cards. Real cloud sessions are server resources and
are outside this inventory; their absence from it does not mean none exist.

Likewise, `cloudSpawnedTasks` records children launched from a local parent. It
does not make that parent a cloud session. Its local title and history can sync;
new cards omit the source's cloud links, and updates retain the destination's
own links. Desktop can also assign an `envScopeId` to local sessions. These cards
are eligible when their local transcript exists, including when remote metadata
coexists. New cards omit the source scope ID; updates retain the destination's own
scope ID. Scoped cards without a local transcript remain excluded.

Copying a card or cloud ID cannot grant another account access to a private cloud
session. Official sharing can grant viewing access (Team within the organization,
or Public for Pro/Max), but does not transfer ownership or automatically populate
the second account's sidebar. Retrieve a cloud session locally with the owning
account through the official `--teleport` workflow before attempting a local
resume with another login. This tool does not automate teleport, create Desktop
cards from CLI-only history, or run model requests.

- [Desktop documentation](https://code.claude.com/docs/en/desktop)
- [Cloud handoff and sharing](https://code.claude.com/docs/en/claude-code-on-the-web)

## Backups and Undo

Every modifying Sync prints a unique backup under
`state\pairs\PAIR_HASH\backups`. It saves exact overwritten bytes, hashes for new
files, and the prior baseline. State is private to your Windows user and SYSTEM.
Backups contain conversation summaries: keep them private. They are incremental
metadata backups; earlier full transcript backups remain separate. Previous tool
versions are under tool-backups and are separate from history rollback.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Mode Undo -Backup 'C:\full\printed\backup\path' -WhatIf
```

Fully exit Claude, then remove WhatIf to restore. Undo verifies backup hashes and
refuses to overwrite files changed since sync. Added files move into retained
files inside the backup; they are not deleted. Original bytes and modification
times are restored. Conversation transcripts and later turns are never rewound.
Undo is repeatable and supports partially applied syncs. Undo multiple backups
newest first. The configuration must still point to the same history roots.

If a process starts or a file changes mid-sync, the command stops and retains a
prepared backup. Use the printed path to Undo before retrying. Each write is
atomic, but the whole group is not a single filesystem transaction. Do not discard
the receipt or backup after a failure.

## Verification

Test-SyncClaudeHistory.ps1 runs isolated fixture tests for selectors, policies,
newest timestamps, explicit two-way sync, destination-only one-way writes,
live-mode argument checks, archive-only changes, cache repair, conflicts,
deletion protection, stale plans/index races, exact index rollback, and backup
integrity. It replaces the ordinary process guard only in its fixture process;
production live mode requires AllowRunning and the declared active source.
Run it using PowerShell 5.1 or 7:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-SyncClaudeHistory.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-SyncScopes.ps1
```

If the workspace drive does not allow private folder ACLs, use
`-FixtureDirectory "$env:TEMP\ClaudeSync-tests"` to keep isolated tests on the
local temporary drive.
