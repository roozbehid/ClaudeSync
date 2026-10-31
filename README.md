# ClaudeSync

**Bring your local Claude Desktop Code history across accounts on Windows.**

ClaudeSync copies eligible Code-tab history cards from one account/organization
profile to another on the same Windows user. Preview the changes first, sync in
one direction by default, and keep a verified backup for Undo.

Use the standalone PowerShell tool, or install the optional **History sync** mod
for an account picker, before/after preview, manual sync, and automatic syncing
into an inactive account.

> Community project, unaffiliated with Anthropic. Desktop's local history format
> is undocumented. Automated fixture tests cover file operations and recovery;
> a complete real-account sync and account-switch workflow has not been verified.

## Features

- **Preview first:** list profiles and compare planned changes without editing history.
- **Choose the direction:** source-to-destination by default; reverse or explicitly
  enable two-way sync in the standalone tool.
- **Choose the scope:** sync one session with its descendants, a project folder
  such as VRGame, or all eligible history. Preview and sync use the same selection.
- **Keep metadata consistent:** synchronize titles, archive status, activity
  summaries, and eligible Windows, WSL, and SSH history references.
- **Recover changes:** exact-byte backups, hash checks, and an explicit Undo command.
- **Stay local:** the standalone sync engine requires no API keys, model calls,
  router service, or network connection.
- **Optional in-app controls:** a History sync pane with account selection,
  filters, comparison rows, and session-local automatic sync permission.

This copies history cards and environment references. Native Windows transcripts
already share `%USERPROFILE%\.claude\projects`; remote transcripts stay on their
existing host. Cloud session ownership, ordinary Chat/Cowork history, credentials,
SSH keys, and schedule registrations are outside the sync scope.

## Requirements

- Windows, with Claude Desktop Code history for at least two profiles under the
  same Windows user.
- Windows PowerShell 5.1 or PowerShell 7.
- A local filesystem that supports private Windows folder permissions for state
  and backups. Administrator rights are not required.
- For the optional mod: Claude Code Mods support enabled in the environment
  running the session. Availability and UI placement depend on the host.

Node.js is only needed for development tests and the separate DOM experiment.

## Quick start

Clone or download this repository and open PowerShell in its folder:

```powershell
git clone https://github.com/roozbehid/ClaudeSync.git
Set-Location ClaudeSync

# Discover profiles. This is read-only.
.\Sync-ClaudeHistory.ps1 -Mode Profiles

# Replace these with emails, aliases, or full IDs from the profile list.
$source = 'source@example.com'
$destination = 'destination@example.com'

# Preview source -> destination. This is read-only.
.\Sync-ClaudeHistory.ps1 -Mode Plan -ProfileA $source -ProfileB $destination
```

Review the plan, fully exit Claude Desktop and Claude Code, then run:

```powershell
.\Sync-ClaudeHistory.ps1 -Mode Sync -ProfileA $source -ProfileB $destination
```

Keep the backup path printed by the command. Reopen Desktop and check the
receiving account. You do not need to sign out before syncing.

If local execution policy blocks the script, invoke it explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-ClaudeHistory.ps1 -Mode Profiles
```

The default direction is `AtoB`. Use `-Direction BtoA` to reverse it, or
`-Direction Both` for explicit two-way sync. Source wins by default in one-way
mode; two-way mode defaults to the `Newest` policy. Deletions never propagate.
Read the [standalone guide](docs/standalone-guide.md) for conflict policies,
archive behavior, live sync, eligibility, configuration, and recovery details.

## In-app History sync mod

Build the plugin from the canonical sync script, then install the local marketplace:

```powershell
.\Build-Mod.ps1
claude plugin marketplace add .
claude plugin install account-history-sync@account-history-tools --scope user
```

Open a native Windows Code session, reload plugins, and look for **History sync**.
Confirm the source account, choose an inactive destination, then use **Preview**
before **Sync now** or **Start auto-sync**. Automatic sync starts paused in each
session. Pause it before switching accounts.

See the [mod guide](mods/account-history-sync/README.md) for loading,
configuration, compatibility notes, and troubleshooting.

For a simulated UI demonstration, open
[docs/history-sync-preview.html](docs/history-sync-preview.html) locally in a
browser. It uses synthetic accounts and performs no real sync operations.
The [DOM launchers](experiments/dom-launchers/README.md) are a separate,
experimental way to compare sidebar, header, and floating controls.

## Undo

Close Claude, inspect the backup with a dry run, then remove `-WhatIf` to restore:

```powershell
.\Sync-ClaudeHistory.ps1 -Mode Undo -Backup 'C:\path\to\printed\backup' -WhatIf
```

Undo refuses to overwrite files changed since the sync. Keep interrupted-run
receipts as well: each individual write is atomic, but a whole sync is not a
transaction with Desktop. See [Backups and Undo](docs/standalone-guide.md#backups-and-undo).

## Configuration and privacy

The included `profiles.json` uses automatic Desktop discovery and has no saved
account pair. For manual labels, copy `profile-labels.example.json` to
`profile-labels.json` and replace its synthetic values locally. That local labels
file is ignored by Git.

For customized roots and saved pairs, use a private configuration outside the
checkout, or an ignored `profiles.local.json`, and pass `-ConfigPath`.
The mod stores configuration and state under `%LOCALAPPDATA%\ClaudeHistorySync`
by default.

State and backups can contain account IDs, paths, session titles, and summaries.
Keep them private. Review diagnostic and preview output before attaching it to an
issue. Research files, generated fixtures, backups, logs, and local identity
labels are excluded from this repository; tests and the preview use synthetic data.

## Development

```powershell
# Rebuild the bundled engine after editing Sync-ClaudeHistory.ps1.
.\Build-Mod.ps1

# Isolated file-operation and bridge tests.
.\Test-SyncClaudeHistory.ps1 -FixtureDirectory "$env:TEMP\ClaudeSync-tests"
.\Test-ModBridge.ps1
.\Test-SyncScopes.ps1

# Independent controller/UI tests.
node --test .\mods\account-history-sync\tests\controller.test.mjs

# Native mod tests, when the host permits Mods to load.
claude plugin test .\mods\account-history-sync
```

Fixture tests do not modify your real account history. To regenerate the
interactive preview, run `node .\tools\Build-UiPreview.mjs`. DOM fixture test
instructions and Node version requirements are in the experiment's README.

| Location | Purpose |
| --- | --- |
| `Sync-ClaudeHistory.ps1` | Canonical standalone sync engine |
| `mods/account-history-sync/` | Official Mods controller, UI, and PowerShell bridge |
| `docs/standalone-guide.md` | Detailed command reference and behavior |
| `docs/history-sync-preview.html` | Synthetic interactive preview |
| `experiments/dom-launchers/` | Optional experimental Desktop launchers |
| `tools/` | Development utilities |

When reporting an issue, include tool/host versions and a redacted error. Use
synthetic examples instead of uploading account history, transcripts, or backups.
