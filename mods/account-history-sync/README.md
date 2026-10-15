# Account history sync mod

Windows plugin for Claude Code Mods. Once loaded, a **History sync** menu button
appears in the enabled Code-session locations. Click it, choose an
inactive destination in **Accounts**, then open **Sync** to preview, copy once,
or start automatic syncing. Copying is always from this
session's account into the destination. The source's Desktop metadata is never
changed. Archive indexes and cards in the destination get verified backups.

The mod matches the current session ID to local Desktop history cards. A unique
match supplies the source; check the displayed account before syncing. If the
session appears in several profiles (including previously copied sessions), or
has no Desktop card yet, click **Sync settings** and confirm which account is open.
That confirmation lasts only for this session. No global CLI login or saved source
choice is treated as Desktop's current account. A new session card is discovered
after a turn or on the next 30-second check.

Auto-sync checks saved files every 30 seconds and 1.5 seconds after a main-agent
turn completes. It uses PowerShell, without model calls. It starts paused in each
session and after hot reload. Pause before switching accounts. Choosing another
destination waits for any running copy and pauses automation. It does not run at
shutdown. The destination and Details preference are remembered, along with the
last successful result and eight recent backup receipts. Source confirmation and
automatic-sync permission stay session-local. Selecting another destination clears
its preview but keeps previous receipts with their original account direction.

## Controls

Version 0.4.0 defaults to **Compare all three locations**: an above-prompt button,
a SessionMode-area button, and a PromptHint-area button, labeled Prompt, Mode,
and Hint. A site appears only when the host asks the mod to render it; native
fixture tests validate all three, but do not prove this Desktop build paints each
one. **Accounts → Launcher placement** keeps one location or restores comparison.
The existing contents of each site are preserved.

By default, only a menu button appears at each enabled site. Account details,
results, and errors stay inside the pane; Pause also appears beside the button
while automation is running. The above-prompt launcher is omitted in subagent transcript panels.
Under **Accounts → Prompt controls**, choose **Menu button only**, **Status and
quick controls**, or **Hide**. Hiding it leaves `/history-sync` available.
This preference is remembered without starting or stopping a sync.

Three additional [DOM launchers](../../experiments/dom-launchers/README.md) provide
a sidebar entry, header menu, and floating button. They open this same pane by
activating its existing native button; they do not add another sync engine.
Their temporary loader supports a Store-build comparison through a loopback
DevTools session instead of patching installed files. Live injection needs a
Desktop restart; see the instructions and current verification status there.

The optional status band shows source → destination and the last sync time for
that direction, with Sync now, Sync settings, and collapsible Details.
The official API does not offer a global Desktop toolbar slot; the DOM experiment
adds its own controls to the page. Claude controls
where the band and pane are placed.

The menu has three sections:

- **Accounts**: confirm the source if needed and choose the inactive destination.
- **Sync**: preview changes, sync once, and start or pause automation.
- **Backups**: review recent backup paths, original directions, and interrupted copies.

## Before and after preview

Version 0.5.1 includes local conversations that spawned cloud tasks, provided
their local transcript exists. New destination cards omit the source's cloud
task links; existing cards keep their own links. Account-bound environment
scopes remain excluded.

Version 0.5.0 replaces the filename-heavy preview with a table showing the real
session title, destination state before, destination state after, and change.
Renames show the old title as well. Unchanged sessions are included; skipped
and conflicting sessions show the destination remaining unchanged. A session
without a saved title is labeled Untitled session. File IDs are available under
the row's Details button and in copied diagnostic data.

- **All / Active / Archived**: filters use the planned destination state. All
  also includes source cards that would remain absent, such as unfinished sessions.
- **Changes**: show all sessions, additions/updates, or conflicts/skipped entries.
- **Search titles**: matches both source and before/after destination titles.
- **Previous / Next**: 15 sessions per page, sorted by title.
- **Copy filtered table**: copies every matching row across pages as tab-separated
  text. Copy preview retains the complete held comparison regardless of filters.

Filtering, searching, paging, and copying do not run another plan, copy history,
or enable automatic sync. Comparisons use the original plan snapshot; constructing
a proposed update no longer mutates the destination snapshot. Up to 1,000
comparison rows are returned, with an explicit notice if a larger inventory is
truncated. Use Preview again to refresh the snapshot.

Version 0.4.1 adds **Copy diagnostics**, **Copy profile list**, **Copy preview**,
and **Copy backup path**. These copy through the clipboard API for the surface
where the button was pressed. Diagnostics retain the complete error; Copy preview
includes the held report beyond the panel's text display limit. A clipboard failure
shows feedback without changing sync permission or starting a helper.
Native Text elements do not expose a selection property, so these buttons provide
copying even when Desktop does not allow selecting the pane's text with the mouse.

No slash command is required. The [interactive preview](../../docs/history-sync-preview.html)
uses fixture accounts and simulated operations only. Claude controls the actual
styling and pane placement; this preview does not demonstrate host compatibility.

## Load and install

For first-time persistent installation in Desktop, open PowerShell and run:

```powershell
Set-Location C:\path\to\ClaudeSync
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Mod.ps1
claude plugin marketplace add C:\path\to\ClaudeSync
claude plugin install account-history-sync@account-history-tools --scope user
```

For an existing installation, update it instead:

```powershell
claude plugin marketplace update account-history-tools
claude plugin update account-history-sync@account-history-tools --scope user
```

Installation can be completed even while the rollout blocks execution. Then:

1. Open Claude Desktop and sign into the account you want to copy **from**.
2. Open the Code tab and a native Windows local session.
3. Run `/reload-plugins`, or start a fresh Code session. In `/plugin`, verify
   `account-history-sync` is installed and enabled.
4. Look for the **History sync · Prompt**, **Mode**, or **Hint** buttons at the
   sites Desktop renders. No slash command is needed. `/history-sync` is the fallback.
5. Click **History sync → Accounts**. Check **From**, then choose the other,
   inactive account in **To**. Confirm the open account if discovery is ambiguous.
6. Click **Continue to Sync**, then **Preview**, **Sync now**, or **Start auto-sync**.
   Open **Backups** to see receipts. Enable the optional status band for a Sync now shortcut.
7. Before changing accounts, click Pause auto-sync. Open a fresh session in the
   other account; check its source and choose the destination before restarting.

If the controls are missing and `/history-sync` is unknown, check the rollout
from PowerShell:

```powershell
claude plugin test C:\path\to\ClaudeSync\mods\account-history-sync
```

For a temporary CLI session instead of persistent installation:

```powershell
claude --plugin-dir C:\path\to\ClaudeSync\mods\account-history-sync
```

The menu button appears above Claude's prompt. `/history-sync` also opens its
settings pane. Desktop WSL sessions do not support Mods according to the current docs.

If the plugin is enabled but both its UI and `/history-sync` are missing, check
the session's environment first. Desktop can list the Windows-installed plugin
while the selected Code session runs in WSL, where plugins are unavailable.
Opening a native Windows Code session in the same signed-in account provides
the controller. Keep the other account inactive and confirm the displayed source
before copying. The controller can copy eligible WSL history cards from the
Windows side; WSL execution itself does not host this Mod.

For a read-only profile query from PowerShell:

```powershell
Set-Location C:\path\to\ClaudeSync
.\Sync-ClaudeHistory.ps1 -Mode Profiles
```

It lists full profile IDs, known email labels, their sources, and session counts.
Use `-ConfigPath "$env:LOCALAPPDATA\ClaudeHistorySync\profiles.json"` to query
the Mod's configured roots instead. Labels identify folders; this query does
not authenticate which Desktop account is currently open.

Anthropic documents engine **2.1.287 or later** as the Mods baseline. However,
Desktop **2.19675.0**, bundling **2.1.286**, was observed rendering this mod and
passed all three native fixture tests, including Desktop-surface menu interactions.
Observed loading is stronger evidence than assuming a build cannot load solely
from its version. The terminal CLI's rollout result is separate: CLI 2.1.288
still reported a cached disabled switch while Desktop's engine ran these tests.
No real account history sync or full account-switch test was performed.

For a missing UI, check that Desktop's session loaded the plugin, and run tests
with its actual worker executable. A terminal `claude --version` or test result
does not establish Desktop's engine or rollout state. Updating the plugin does
not update Desktop's Code engine.
See the [Desktop UI and loading review](../../docs/claude-ui-mod-review.md)
for evidence and ideas from the reference UI project.

## Commands

- `/history-sync` opens the settings pane (optional unless the launcher is hidden).
- `/history-sync accounts` opens account selection.
- `/history-sync backups` opens recent backup receipts.
- `/history-sync profiles` lists emails, IDs, and session counts.
- `/history-sync to <destination-email-or-id>` selects the inactive destination.
- `/history-sync preview` checks without writing Desktop history.
- `/history-sync sync` copies once, declaring the source active and destination inactive.
- `/history-sync start` enables automatic copying for this session with the same declaration.
- `/history-sync pause` waits for the current operation and releases the controller.
- `/history-sync status` prints status.

Ambiguous emails require full `account-GUID\organization-GUID` profile IDs.
CLI commands accept selectors without spaces. A compatibility `pair <source>
<destination>` command can confirm an unresolved source, but cannot reverse a
source already identified in this session. The destination is remembered;
permission to auto-sync is not remembered. Multiple sessions share an exclusive
controller lease. Pause the controller in its original session to switch control;
after a crashed or ended session, its lease expires within three minutes.

## Configuration and recovery

The helper initializes `%LOCALAPPDATA%\ClaudeHistorySync\profiles.json` with
automatic Desktop-root discovery. If discovery cannot choose a root, set
`SessionsRoot` to the absolute history directory in that config, after checking
which directory the running Desktop uses. Save a config backup before changing it.
For this Store installation, that root was verified under
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions`.
Discovery creates that private config but
does not edit history. Put `profile-labels.json` alongside it for manual email
labels. Settings, state, and backups live outside the plugin install/cache folder.

Desktop can save a correctly named card before its CLI session starts. A missing,
null, or empty CLI session ID now marks that card **Pending** in inventory and
**Skipped** in the plan. The card and its archive state stay untouched, including
when it is in the destination. Incorrect nonempty CLI IDs, filename/session-ID
mismatches, missing working directories, malformed JSON, and invalid archive flags
still stop the plan. Preview returns up to 1,000 report entries and explicitly
reports truncation beyond that limit.

For custom roots or existing labels, set `ACCOUNT_HISTORY_SYNC_CONFIG` to the full
path of a `profiles.json` before starting Claude, or through Claude's environment
settings. The script uses that config's directory for state and the mod controller.
It must support private Windows ACLs. Configuration and labels use the same format
as the standalone script. No credentials or tokens are copied into the plugin.

The Backups section shows up to eight recent receipts, and automatic failures pause syncing.
Use the standalone engine's Undo with that config and printed backup, after
closing Claude. Undo is deliberately not automated by the mod:

```powershell
.\Sync-ClaudeHistory.ps1 -Mode Undo -ConfigPath "$env:LOCALAPPDATA\ClaudeHistorySync\profiles.json" -Backup 'C:\printed\backup\path' -WhatIf
```

After reviewing, remove `-WhatIf` to restore. A timed-out helper can leave a
prepared receipt under `state\pairs\PAIR_HASH\backups`; inspect that before retrying.
Backups include conversation summaries and should stay private.

Mods' published API does not provide a current account ID. Matching a session's
local card is account-folder discovery, not authentication; check the source shown
in the UI. If ambiguous, the mod relies on your session-local confirmation.
Before preview, arming, or sync, the helper rejects a source outside the session's
matching profiles, when matches exist. It cannot verify that the destination is
inactive. File hashes and atomic replacement
reduce write races but cannot prevent Desktop from later writing cached metadata.
It syncs local history cards and environment references, not cloud session ownership,
credentials, or transcripts. See the repository README for eligibility and policies.

## Tests

```powershell
node --test .\mods\account-history-sync\tests\controller.test.mjs
.\Test-ModBridge.ps1
claude plugin test .\mods\account-history-sync
```

Node is needed only for the independent controller tests, not to run the mod.
PowerShell bridge tests use isolated local fixtures and never modify real history.
Claude's native test runner requires Mods to load in the executable running the tests.
Rebuild the fixture preview after changing the UI with `node .\tools\Build-UiPreview.mjs`.
The DOM fixture suite runs separately with `npm ci --ignore-scripts` and `npm test`
under `experiments/dom-launchers`; those packages are not shipped in the native plugin.
