#requires -Version 5.1
[CmdletBinding()]
param([string]$FixtureDirectory = (Join-Path $PSScriptRoot 'test-fixtures'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
function New-BothPlan($Context, [string]$Winner='', [bool]$WithScheduled=$false,
    [string]$Resolution='Changes') {
    if ($Winner -and -not $PSBoundParameters.ContainsKey('Resolution')) { $Resolution = 'Profile' }
    New-CHPlan -Context $Context -Winner $Winner -WithScheduled $WithScheduled -Resolution $Resolution -Direction Both
}
$script:Assertions = 0
function Assert-Test($Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "FAILED: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Test ($caught -and $caught -match $Pattern) $Message
}
# Keep all test operations inside independent generated fixture directories.
$fixtureRoot = Join-Path $FixtureDirectory ([guid]::NewGuid().ToString('N'))
Protect-CHDirectory $fixtureRoot
$script:Case = 0
function New-Fixture {
    $script:Case++
    $root = Join-Path $fixtureRoot ([string]$script:Case)
    $sessions = Join-Path $root 'sessions'; $projects = Join-Path $root 'projects'
    $p1 = '11111111-1111-4111-8111-111111111111\22222222-2222-4222-8222-222222222222'
    $p2 = '33333333-3333-4333-8333-333333333333\44444444-4444-4444-8444-444444444444'
    foreach ($path in @((Join-Path $sessions $p1), (Join-Path $sessions $p2), (Join-Path $projects 'project'))) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $cfg = [ordered]@{FormatVersion=1; SessionsRoot=$sessions; ProjectsRoot=$projects; Profiles=@(@{Name='A';Path=$p1}, @{Name='B';Path=$p2})}
    $config = Join-Path $root 'profiles.json'
    [IO.File]::WriteAllBytes($config, (ConvertTo-CHBytes $cfg))
    Get-CHConfig $config
}
function Add-Record($Context, [string]$Profile, [string]$Id, [string]$Title='Before', [bool]$Archived=$false, $Extra=@{}) {
    $cli = $Id
    $record = [ordered]@{sessionId=('local_' + $Id); cliSessionId=$cli; cwd='C:\project'; originCwd='C:\project';
        title=$Title; isArchived=$Archived; createdAt=1; lastActivityAt=1; model='claude-sonnet'; permissionMode='plan';
        bridgeSessionIds=@('account-private-link'); remoteMcpServersConfig=@(@{uuid='account-private';url='https://example.invalid/private'})}
    foreach ($key in $Extra.Keys) { $record[$key]=$Extra[$key] }
    $p = Resolve-CHProfile $Context.Config.Profiles $Profile
    $path = Join-Path $p.FullPath ('local_' + $Id + '.json')
    [IO.File]::WriteAllBytes($path, (ConvertTo-CHBytes $record))
    $transcript = Join-Path $Context.Config.ProjectsRoot ('project\' + $cli + '.jsonl')
    [IO.File]::WriteAllText($transcript, '{"fixture":"transcript must remain untouched"}')
    $path
}
function Set-Record($Path, [string]$Title, $Archived=$null) {
    $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $j.title = $Title
    if ($null -ne $Archived) { $j.isArchived = [bool]$Archived }
    [IO.File]::WriteAllBytes($Path, (ConvertTo-CHBytes $j))
}
function Apply-Plan($Context, $Plan) {
    $result = @(Invoke-CHApply $Context $Plan)
    $line = @($result | Where-Object { $_ -is [string] -and $_.StartsWith('Backup: ') })[0]
    if (-not $line) { throw 'Test expected a backup path.' }
    $line.Substring(8)
}
$id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

# Verify the real guard before mocking it for isolated fixture tests.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$entryScript = Join-Path $ctx.ConfigDirectory 'Sync-ClaudeHistory.ps1'
[IO.File]::Copy((Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1'), $entryScript)
$engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
$preview = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $entryScript -Mode Sync -WhatIf)
Assert-Test ($LASTEXITCODE -eq 0 -and @($preview | Where-Object { $_ -like '*Plan: 1 additions*' }).Count -eq 1) 'Standalone entry point resolves adjacent config and runs WhatIf'
Assert-Test (-not [IO.Directory]::Exists($ctx.StateRoot)) 'Standalone WhatIf creates no state'
if (Get-Process -Name Claude -ErrorAction SilentlyContinue) {
    Assert-Throws { Invoke-CHApply $ctx (New-BothPlan $ctx '') } 'Fully exit Claude' 'Running Claude blocks writes'
    Assert-Test (-not [IO.Directory]::Exists($ctx.StateRoot)) 'Process guard creates no sync state'
}
function Assert-CHStopped { } # Only fixture calls below; live-mode validation is tested separately.
$plan = New-BothPlan $ctx ''
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Missing session is planned'
Assert-Test (-not [IO.Directory]::Exists($ctx.StateRoot)) 'Plan is read-only'
$transcript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $id + '.jsonl')
$transcriptHash = Get-CHFileHash $transcript
$aHash = Get-CHFileHash $a
$backup = Apply-Plan $ctx $plan
$undoPreview = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $entryScript -Mode Undo -Backup $backup -WhatIf)
Assert-Test ($LASTEXITCODE -eq 0 -and @($undoPreview | Where-Object { $_ -like '*Undo plan:*' }).Count -eq 1) 'Standalone Undo infers its pair from receipt'
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
$j = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($j.title -eq 'Before') 'Added session retains history title'
Assert-Test ($j.permissionMode -eq 'default' -and @($j.bridgeSessionIds).Count -eq 0 -and @($j.remoteMcpServersConfig).Count -eq 0) 'New card excludes account links, MCP config, and elevated permissions'
Assert-Test ((Get-CHFileHash $a) -eq $aHash -and (Get-CHFileHash $transcript) -eq $transcriptHash) 'Original and transcript unchanged'
Assert-Test ((New-BothPlan $ctx '').Operations.Count -eq 0) 'Repeated sync is idempotent'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test (-not [IO.File]::Exists($b) -and (Get-CHFileHash $a) -eq $aHash) 'Undo removes only added card'
Assert-Test (@(Get-ChildItem -LiteralPath $backup -Filter 'retained-*').Count -ge 1) 'Undo retains additions rather than deleting data'
Assert-Test ((Get-CHUndo $ctx $backup).Operations.Count -eq 0) 'Undo is idempotent'

# Baseline tracking, conflicts, preserving target settings, and archive cache.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$b = Add-Record $ctx 'B' $id 'Before' $false @{permissionMode='default';bridgeSessionIds=@('B-link')}
Apply-Plan $ctx (New-BothPlan $ctx '') | Out-Null
Set-Record $a 'Updated' $true
$plan = New-BothPlan $ctx ''
Assert-Test (@($plan.Report | Where-Object Action -eq 'Update').Count -eq 1) 'One changed profile propagates'
$beforeB = Get-CHFileHash $b
$beforeBTime = [IO.File]::GetLastWriteTimeUtc($b)
$backup = Apply-Plan $ctx $plan
$j = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($j.title -eq 'Updated' -and $j.isArchived) 'Title and archive flag synchronize'
Assert-Test ($j.permissionMode -eq 'default' -and $j.bridgeSessionIds[0] -eq 'B-link' -and $j.remoteMcpServersConfig[0].uuid -eq 'account-private') 'Existing target permissions and remote setup preserved'
$idx = Join-Path $ctx.Config.Profiles[1].FullPath 'archived-sessions.idx'
$j = [IO.File]::ReadAllText($idx) | ConvertFrom-Json
Assert-Test ($j.archived -contains ('local_' + $id)) 'Archive cache follows metadata'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test ((Get-CHFileHash $b) -eq $beforeB) 'Undo restores exact prior bytes'
Assert-Test ([IO.File]::GetLastWriteTimeUtc($b) -eq $beforeBTime) 'Undo restores prior modification time for newest comparisons'
Apply-Plan $ctx (New-BothPlan $ctx '') | Out-Null
Set-Record $a 'A changed'
Set-Record $b 'B changed'
$plan = New-BothPlan $ctx ''
Assert-Test (@($plan.Report | Where-Object Action -eq 'Conflict').Count -eq 1) 'Both changes conflict'
Assert-Test (@($plan.Operations | Where-Object Area -eq 'desktop').Count -eq 0) 'Conflicts do not overwrite files'
Assert-Test (@((New-BothPlan $ctx 'B').Report | Where-Object Action -eq 'Update').Count -eq 1) 'Explicit preferred profile resolves conflict'
Assert-Throws { New-BothPlan $ctx 'other' } 'unknown or ambiguous' 'Unconfigured winner refused'
$backup = Apply-Plan $ctx (New-BothPlan $ctx 'B')
Set-Record $a 'Newer after sync'
Assert-Throws { Get-CHUndo $ctx $backup } 'changed after sync' 'Undo refuses newer edits'

# Deletion markers and manual removals must never resurrect records.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
[IO.File]::WriteAllText((Join-Path $ctx.Config.Profiles[1].FullPath ('deleted_' + $id)), '1')
Assert-Test (@((New-BothPlan $ctx '').Report | Where-Object Detail -eq 'Deletion marker present').Count -eq 1) 'Deletion tombstone prevents resurrection'
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$backup = Apply-Plan $ctx (New-BothPlan $ctx '')
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
[void](Assert-CHPath $b $fixtureRoot)
Move-Item -LiteralPath $b -Destination (Join-Path $ctx.StateRoot 'fixture-removed.json')
Assert-Test (@((New-BothPlan $ctx '').Report | Where-Object Detail -like 'Previously synced*').Count -eq 1) 'Missing previously synced record stays removed'

# WSL/SSH cards synchronize even when the transcript lives on another OS/host.
foreach ($extra in @(@{wslConfig=@{distro='Ubuntu'};sshRemoteTranscriptPath='/wsl/a.jsonl'}, @{sshRemoteTranscriptPath='/remote/a.jsonl';sshConfig=@{host='example.invalid';user='fixture'}})) {
    $ctx = New-Fixture
    Add-Record $ctx 'A' $id 'Before' $false $extra | Out-Null
    $transcript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $id + '.jsonl')
    [void](Assert-CHPath $transcript $fixtureRoot)
    Move-Item -LiteralPath $transcript -Destination (Join-Path $ctx.Config.ProjectsRoot 'remote-fixture.bin')
    $plan = New-BothPlan $ctx ''
    Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'WSL/SSH card included without local transcript'
    Apply-Plan $ctx $plan | Out-Null
    $j = [IO.File]::ReadAllText((Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json'))) | ConvertFrom-Json
    Assert-Test ($j.sshRemoteTranscriptPath -eq $extra.sshRemoteTranscriptPath) 'Remote transcript reference preserved'
    Assert-Test ((New-BothPlan $ctx '').Operations.Count -eq 0) 'Remote card sync is idempotent'
}
# Scheduled history is opt-in, and does not copy schedule registration.
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Before' $false @{scheduledTaskId='task'} | Out-Null
Assert-Test (@((New-BothPlan $ctx '').Report | Where-Object Action -eq 'Skipped').Count -eq 1) 'Scheduled history excluded by default'
$plan = New-BothPlan $ctx '' $true
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Scheduled history included when requested'
Apply-Plan $ctx $plan | Out-Null
$j = [IO.File]::ReadAllText((Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json'))) | ConvertFrom-Json
Assert-Test (-not $j.scheduledTaskId -and $j.title -eq 'Before') 'Scheduled copy is ordinary history, not an active schedule'

# Local parents can spawn cloud tasks without making their local history cloud-only.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id 'Local cloud parent' $false @{cloudSpawnedTasks=@(@{sessionId='source-cloud'})}
$sourceHash = Get-CHFileHash $a
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Local cloud parent with transcript is included'
Apply-Plan $ctx $plan | Out-Null
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
$j = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($j.title -eq 'Local cloud parent' -and -not $j.PSObject.Properties['cloudSpawnedTasks']) 'New local parent card excludes source cloud links'
Assert-Test ((Get-CHFileHash $a) -eq $sourceHash) 'Local parent source remains untouched'
Assert-Test ((New-CHPlan $ctx -Direction AtoB).Operations.Count -eq 0) 'Local parent sync is idempotent'
$j | Add-Member -NotePropertyName cloudSpawnedTasks -NotePropertyValue @(@{sessionId='destination-cloud'})
[IO.File]::WriteAllBytes($b, (ConvertTo-CHBytes $j))
Set-Record $a 'Renamed local parent'
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$j = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($j.title -eq 'Renamed local parent' -and $j.cloudSpawnedTasks[0].sessionId -eq 'destination-cloud') 'Updates retain destination cloud links while syncing title'
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Missing transcript parent' $false @{cloudSpawnedTasks=@(@{sessionId='cloud'})} | Out-Null
$transcript = Join-Path $ctx.Config.ProjectsRoot ('project\\' + $id + '.jsonl')
[void](Assert-CHPath $transcript $fixtureRoot)
Move-Item -LiteralPath $transcript -Destination (Join-Path $ctx.Config.ProjectsRoot 'fixture-transcript.bin')
Assert-Test (@((New-CHPlan $ctx -Direction AtoB).Report | Where-Object Detail -eq 'Local transcript missing').Count -eq 1) 'Cloud links do not bypass local transcript requirement'

# Parent links are synced history, including repair of cards from older versions.
$ctx = New-Fixture
$parentId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$rootId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$rootCard = Add-Record $ctx 'A' $rootId 'Root'
$parentCard = Add-Record $ctx 'A' $parentId 'Parent' $false @{spawnedFrom=@{sessionId=('local_' + $rootId);taskId='parent-task';sideSession=$true;name='Parent'}}
$a = Add-Record $ctx 'A' $id 'Child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);taskId='child-task';title='Parent';sideSession=$true;name='Child';wakeParent=$true};forkedFromSessionId=('local_' + $parentId);forkedAtMessageUuid=$rootId;lineageDetached=$false;cloudSpawnedTasks=@(@{sessionId='account-bound'})}
$sourceHash = Get-CHFileHash $a
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 3) 'Parent chain can be added regardless of filename order'
Apply-Plan $ctx $plan | Out-Null
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
$child = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($child.spawnedFrom.sessionId -eq ('local_' + $parentId) -and $child.spawnedFrom.sideSession -and $child.spawnedFrom.taskId -eq 'child-task' -and $child.spawnedFrom.name -eq 'Child') 'New side-session cards retain their complete parent metadata'
Assert-Test ($child.forkedFromSessionId -eq ('local_' + $parentId) -and $child.forkedAtMessageUuid -eq $rootId -and $child.lineageDetached -eq $false) 'Fork origin, message, and attachment state are preserved'
Assert-Test (-not $child.PSObject.Properties['cloudSpawnedTasks'] -and $child.permissionMode -eq 'default') 'Lineage preservation does not copy cloud ownership or elevated permissions'
Assert-Test ((New-CHPlan $ctx -Direction AtoB).Operations.Count -eq 0) 'A fully synced parent chain is idempotent'

# Recreate a legacy destination and baseline that did not track lineage at all.
foreach ($field in $script:LineageFields) { $child.PSObject.Properties.Remove($field) }
$child | Add-Member -NotePropertyName fixtureDestinationSetting -NotePropertyValue 'retain-me'
[IO.File]::WriteAllBytes($b, (ConvertTo-CHBytes $child))
$legacyHash = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $child @($script:HistoryFields | Where-Object { $_ -notin $script:LineageFields })))
$baselinePath = Join-Path $ctx.StateRoot 'baseline.json'
$legacyBaseline = [IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
$legacyBaseline.Entries.('local_' + $id + '.json') = $legacyHash
[IO.File]::WriteAllBytes($baselinePath, (ConvertTo-CHBytes $legacyBaseline))
$missingLinkHash = Get-CHFileHash $b
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Report | Where-Object { $_.File -eq ('local_' + $id + '.json') -and $_.Action -eq 'Update' }).Count -eq 1) 'Same-title legacy card is updated solely to repair lineage'
$rows = @(Get-CHPreviewRows $ctx $plan)
$row = @($rows | Where-Object File -eq ('local_' + $id + '.json'))[0]
Assert-Test (-not $row.Before.ParentSessionId -and $row.After.ParentSessionId -eq ('local_' + $parentId) -and $row.ChangedFields -contains 'spawnedFrom') 'Preview reports the repaired parent and changed lineage fields'
$backup = Apply-Plan $ctx $plan
$repaired = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($repaired.spawnedFrom.sideSession -and $repaired.fixtureDestinationSetting -eq 'retain-me') 'Repair restores parent link while preserving destination settings'
Assert-Test ((Get-CHFileHash $a) -eq $sourceHash) 'Lineage repair leaves the source untouched'
Assert-Test ((New-CHPlan $ctx -Direction AtoB).Operations.Count -eq 0) 'Repaired legacy cards are idempotent'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test ((Get-CHFileHash $b) -eq $missingLinkHash) 'Undo restores exact pre-repair bytes'
$changesPlan = New-CHPlan $ctx -Direction Both -Resolution Changes
Assert-Test (@($changesPlan.Report | Where-Object { $_.File -eq ('local_' + $id + '.json') -and $_.Action -eq 'Update' }).Count -eq 1) 'Old baseline still identifies the lineage-bearing copy as changed in Changes mode'

# Missing/excluded parents and deletion markers must never create orphan chains.
foreach ($parentMode in @('Absent', 'Environment', 'Deleted', 'MissingTranscript', 'IdentityConflict')) {
    $ctx = New-Fixture
    if ($parentMode -ne 'Absent') {
        $extra = if ($parentMode -eq 'Environment') { @{envScopeId='account-bound'} } else { @{} }
        Add-Record $ctx 'A' $parentId 'Parent' $false $extra | Out-Null
    }
    if ($parentMode -eq 'Deleted') { [IO.File]::WriteAllText((Join-Path $ctx.Config.Profiles[0].FullPath ('deleted_' + $parentId)), '1') }
    if ($parentMode -in @('Environment', 'MissingTranscript')) {
        $parentTranscript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $parentId + '.jsonl')
        [IO.File]::Move($parentTranscript, (Join-Path $ctx.ConfigDirectory 'parent-transcript.fixture'))
    }
    if ($parentMode -eq 'IdentityConflict') {
        Add-Record $ctx 'B' $parentId 'Other parent identity' $false @{cliSessionId='cccccccc-cccc-4ccc-8ccc-cccccccccccc'} | Out-Null
        [IO.File]::WriteAllText((Join-Path $ctx.Config.ProjectsRoot 'project\cccccccc-cccc-4ccc-8ccc-cccccccccccc.jsonl'), '{"fixture":"different session"}')
    }
    Add-Record $ctx 'A' $id 'Child' $true @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}} | Out-Null
    Add-Record $ctx 'A' $rootId 'Grandchild' $true @{spawnedFrom=@{sessionId=('local_' + $id);sideSession=$true}} | Out-Null
    $plan = New-CHPlan $ctx -Direction AtoB
    Assert-Test (@($plan.Report | Where-Object { $_.File -in @(('local_' + $id + '.json'), ('local_' + $rootId + '.json')) -and $_.Action -eq 'Skipped' -and $_.Detail -match 'Parent' }).Count -eq 2) "Unavailable $parentMode parent skips the entire dependent chain"
    Assert-Test (@($plan.Operations | Where-Object { $_.RelativePath -like '*archived-sessions.idx' -or $_.RelativePath -like ('*local_' + $id + '.json') -or $_.RelativePath -like ('*local_' + $rootId + '.json') }).Count -eq 0) 'Rejected lineage creates no child or archive-index operations'
}
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Cycle child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}} | Out-Null
Add-Record $ctx 'A' $parentId 'Cycle parent' $false @{spawnedFrom=@{sessionId=('local_' + $id);sideSession=$true}} | Out-Null
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Report | Where-Object { $_.Action -eq 'Skipped' -and $_.Detail -match 'cycle|unavailable' }).Count -eq 2) 'Cyclic ancestry is not copied'
Assert-Test (@($plan.Operations | Where-Object Area -eq 'desktop').Count -eq 0) 'Cycles generate no Desktop writes'
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Detached child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true};lineageDetached=$true} | Out-Null
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Intentionally detached ancestry does not require a live parent'
Apply-Plan $ctx $plan | Out-Null
$detached = [IO.File]::ReadAllText((Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json'))) | ConvertFrom-Json
Assert-Test ($detached.lineageDetached -and $detached.spawnedFrom.sessionId -eq ('local_' + $parentId)) 'Detached historical ancestry is preserved without reattaching'
$ctx = New-Fixture
Add-Record $ctx 'A' $parentId 'Actual fork parent' | Out-Null
Add-Record $ctx 'A' $id 'User fork' $false @{spawnedFrom=@{sessionId=('local_' + $rootId);sideSession=$true;userFork=$true};forkedFromSessionId=('local_' + $parentId)} | Out-Null
Assert-Test (@((New-CHPlan $ctx -Direction AtoB).Report | Where-Object Action -eq 'Add').Count -eq 2) 'User fork uses its effective fork parent rather than an inherited spawn parent'
$ctx = New-Fixture
foreach ($profile in @('A', 'B')) { Add-Record $ctx $profile $parentId 'Parent' | Out-Null }
$a = Add-Record $ctx 'A' $id 'Existing child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}}
$b = Add-Record $ctx 'B' $id 'Existing child' $false @{spawnedFrom=@{sessionId=('local_' + $rootId);sideSession=$true};lineageDetached=$true}
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$child = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test ($child.spawnedFrom.sessionId -eq ('local_' + $parentId) -and -not $child.PSObject.Properties['lineageDetached']) 'Changed parent and attachment metadata are reconciled even when titles match'
$source = [IO.File]::ReadAllText($a) | ConvertFrom-Json
foreach ($field in $script:LineageFields) { $source.PSObject.Properties.Remove($field) }
[IO.File]::WriteAllBytes($a, (ConvertTo-CHBytes $source))
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$child = [IO.File]::ReadAllText($b) | ConvertFrom-Json
Assert-Test (-not $child.PSObject.Properties['spawnedFrom']) 'A parent link removed in the authoritative source is also removed in the destination'
$ctx = New-Fixture
foreach ($profile in @('A', 'B')) { Add-Record $ctx $profile $parentId 'Deleted parent' | Out-Null }
[IO.File]::WriteAllText((Join-Path $ctx.Config.Profiles[0].FullPath ('deleted_' + $parentId)), '1')
Add-Record $ctx 'A' $id 'Child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}} | Out-Null
Assert-Test (@((New-CHPlan $ctx -Direction AtoB).Report | Where-Object { $_.File -eq ('local_' + $id + '.json') -and $_.Detail -match 'deletion marker' }).Count -eq 1) 'A physically present but deleted parent cannot acquire new child links'
foreach ($extra in @(@{spawnedFrom='not-an-object'}, @{spawnedFrom=@{sideSession=$true}}, @{forkedFromSessionId=123}, @{lineageDetached='false'})) {
    $ctx = New-Fixture
    Add-Record $ctx 'A' $id 'Malformed lineage' $false $extra | Out-Null
    Assert-Throws { New-CHPlan $ctx -Direction AtoB } 'Invalid.*parent reference|Invalid lineageDetached' 'Malformed lineage is rejected before writing'
}

# Round-trip history after continuing a copied session in another worktree.
$ctx = New-Fixture
$parentId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$grandchildId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$aParent = Add-Record $ctx 'A' $parentId 'Round-trip parent' $false @{cwd='C:\worktrees\original';originCwd='C:\worktrees\original'}
$aChild = Add-Record $ctx 'A' $id 'Existing child' $false @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}}
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$bParent = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $parentId + '.json')
$bChild = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
$parent = [IO.File]::ReadAllText($bParent) | ConvertFrom-Json
Assert-Test ($parent.cwd -eq 'C:\worktrees\original' -and $parent.originCwd -eq 'C:\worktrees\original') 'New cards retain the source working directories'
$parent.cwd = 'C:\worktrees\continued'; $parent.originCwd = 'C:\worktrees\continued'
[IO.File]::WriteAllBytes($bParent, (ConvertTo-CHBytes $parent))
Assert-Test ((New-CHPlan $ctx -Direction BtoA).Operations.Count -eq 0) 'Directory-only changes do not overwrite destination paths or create history changes'
Set-Record $bParent 'Round-trip parent completed' $true
Set-Record $bChild 'Existing child completed' $true
$bGrandchild = Add-Record $ctx 'B' $grandchildId 'New grandchild' $true @{cwd='C:\worktrees\continued';originCwd='C:\worktrees\continued';spawnedFrom=@{sessionId=('local_' + $id);sideSession=$true}}
$sourceHashes = @{}; foreach ($path in @($bParent, $bChild, $bGrandchild)) { $sourceHashes[$path] = Get-CHFileHash $path }
$beforeParent = Get-CHFileHash $aParent; $beforeChild = Get-CHFileHash $aChild
$plan = New-CHPlan $ctx -Direction BtoA
Assert-Test (@($plan.Report | Where-Object Action -eq 'Update').Count -eq 2 -and @($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Moved parent and existing child update while its new descendant is added on return sync'
Assert-Test (@($plan.Report | Where-Object { $_.Action -in @('Conflict', 'Skipped') }).Count -eq 0) 'Worktree changes block neither the parent nor its descendant chain'
$rows = @(Get-CHPreviewRows $ctx $plan)
Assert-Test (@($rows | Where-Object { $_.After.Archived }).Count -eq 3) 'Return preview shows the entire chain archived'
$backup = Apply-Plan $ctx $plan
$returnedParent = [IO.File]::ReadAllText($aParent) | ConvertFrom-Json
$returnedChild = [IO.File]::ReadAllText($aChild) | ConvertFrom-Json
$aGrandchild = Join-Path $ctx.Config.Profiles[0].FullPath ('local_' + $grandchildId + '.json')
$returnedGrandchild = [IO.File]::ReadAllText($aGrandchild) | ConvertFrom-Json
Assert-Test ($returnedParent.isArchived -and $returnedParent.title -eq 'Round-trip parent completed' -and $returnedChild.isArchived -and $returnedGrandchild.isArchived) 'Return sync applies history and archive flags to parent and descendants'
Assert-Test ($returnedParent.cwd -eq 'C:\worktrees\original' -and $returnedParent.originCwd -eq 'C:\worktrees\original') 'Return sync preserves the existing destination working directories'
Assert-Test ($returnedGrandchild.cwd -eq 'C:\worktrees\continued' -and $returnedGrandchild.spawnedFrom.sessionId -eq ('local_' + $id)) 'New descendant keeps source paths and parent lineage'
$index = [IO.File]::ReadAllText((Join-Path $ctx.Config.Profiles[0].FullPath 'archived-sessions.idx')) | ConvertFrom-Json
Assert-Test (@($index.archived).Count -eq 3 -and $index.archived -contains ('local_' + $parentId) -and $index.archived -contains ('local_' + $id) -and $index.archived -contains ('local_' + $grandchildId)) 'Destination archive index contains the complete returned chain'
Assert-Test (@($sourceHashes.Keys | Where-Object { (Get-CHFileHash $_) -ne $sourceHashes[$_] }).Count -eq 0) 'Return sync leaves all source cards unchanged'
Assert-Test ((New-CHPlan $ctx -Direction BtoA).Operations.Count -eq 0) 'Return sync is idempotent despite different directories'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test ((Get-CHFileHash $aParent) -eq $beforeParent -and (Get-CHFileHash $aChild) -eq $beforeChild -and -not [IO.File]::Exists($aGrandchild)) 'Undo restores exact pre-return cards and removes only the new descendant'
Apply-Plan $ctx (New-CHPlan $ctx -Direction BtoA) | Out-Null
foreach ($path in @($bParent, $bChild, $bGrandchild)) { $card = [IO.File]::ReadAllText($path) | ConvertFrom-Json; Set-Record $path $card.title $false }
Apply-Plan $ctx (New-CHPlan $ctx -Direction BtoA) | Out-Null
$index = [IO.File]::ReadAllText((Join-Path $ctx.Config.Profiles[0].FullPath 'archived-sessions.idx')) | ConvertFrom-Json
Assert-Test (@($index.archived).Count -eq 0 -and -not ([IO.File]::ReadAllText($aParent) | ConvertFrom-Json).isArchived) 'Unarchiving also propagates across different working directories'

# Real session/environment mismatches must still reject both card and child writes.
foreach ($difference in @(@{cliSessionId='cccccccc-cccc-4ccc-8ccc-cccccccccccc'}, @{wslConfig=@{distro='Other'}}, @{sshConfig=@{host='other.invalid'}}, @{sshRemoteTranscriptPath='/other/session.jsonl'})) {
    $ctx = New-Fixture
    Add-Record $ctx 'A' $parentId 'Source parent' $true | Out-Null
    Add-Record $ctx 'B' $parentId 'Different destination identity' $false $difference | Out-Null
    if ($difference.cliSessionId) {
        [IO.File]::WriteAllText((Join-Path $ctx.Config.ProjectsRoot ('project\' + $difference.cliSessionId + '.jsonl')), '{"fixture":"different session"}')
    }
    Add-Record $ctx 'A' $id 'Child' $true @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}} | Out-Null
    $plan = New-CHPlan $ctx -Direction AtoB
    Assert-Test (@($plan.Report | Where-Object { $_.File -eq ('local_' + $parentId + '.json') -and $_.Action -eq 'Conflict' }).Count -eq 1) 'Different CLI or remote environment identity still conflicts'
    Assert-Test (@($plan.Report | Where-Object { $_.File -eq ('local_' + $id + '.json') -and $_.Action -eq 'Skipped' }).Count -eq 1 -and @($plan.Operations | Where-Object Area -eq 'desktop').Count -eq 0) 'Conflicting parent still blocks dependent child and archive-index writes'
}

# A verified local CLI continuation moves its pointer and history together.
$ctx = New-Fixture
$continuedId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$a = Add-Record $ctx 'A' $parentId 'Before continuation'
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $parentId + '.json')
$continued = [IO.File]::ReadAllText($b) | ConvertFrom-Json
$continued.cliSessionId = $continuedId
$continued | Add-Member -NotePropertyName priorCliSessionIds -NotePropertyValue @($parentId)
$continued | Add-Member -NotePropertyName completedTurns -NotePropertyValue 469
$continued.title = 'Continued history'; $continued.isArchived = $true
$continued.cwd = 'C:\continued-worktree'
[IO.File]::WriteAllBytes($b, (ConvertTo-CHBytes $continued))
$newTranscript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $continuedId + '.jsonl')
[IO.File]::WriteAllText($newTranscript, '{"fixture":"new continuation transcript"}')
Add-Record $ctx 'B' $id 'Continuation child' $true @{spawnedFrom=@{sessionId=('local_' + $parentId);sideSession=$true}} | Out-Null
$beforeA = Get-CHFileHash $a; $sourceHash = Get-CHFileHash $b
$plan = New-CHPlan $ctx -Direction BtoA
Assert-Test (@($plan.Report | Where-Object Action -eq 'Update').Count -eq 1 -and @($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Verified local continuation and child can return to the original account'
$rows = @(Get-CHPreviewRows $ctx $plan)
$row = @($rows | Where-Object File -eq ('local_' + $parentId + '.json'))[0]
Assert-Test ($row.Before.CliSessionId -eq $parentId -and $row.After.CliSessionId -eq $continuedId -and $row.ChangedFields -contains 'cliSessionId' -and $row.ChangedFields -contains 'priorCliSessionIds' -and $row.Detail -match 'CLI continuation') 'Preview exposes the transcript pointer transition and prior IDs'
Assert-Test (@((New-CHPlan $ctx -Direction AtoB).Report | Where-Object Detail -like 'Source is an older CLI continuation*').Count -eq 1) 'One-way sync cannot roll a destination back to an ancestor CLI'
[IO.File]::SetLastWriteTimeUtc($a, [datetime]::UtcNow.AddDays(1))
Assert-Test (@((New-CHPlan $ctx -Direction Both -Resolution Newest).Report | Where-Object Detail -like 'CLI continuation differs*').Count -eq 1) 'Automatic newest policy cannot mistake an ancestor resume for the current continuation'
Assert-Test (@((New-CHPlan $ctx -Direction BtoA -Resolution Changes).Report | Where-Object Detail -like 'CLI continuation differs*').Count -eq 1) 'Change-based policy requires an authoritative source for pointer transitions'
$plan = New-CHPlan $ctx -Direction BtoA
$backup = Apply-Plan $ctx $plan
$returned = [IO.File]::ReadAllText($a) | ConvertFrom-Json
Assert-Test ($returned.cliSessionId -eq $continuedId -and @($returned.priorCliSessionIds).Count -eq 1 -and $returned.priorCliSessionIds[0] -eq $parentId -and $returned.completedTurns -eq 469 -and $returned.title -eq 'Continued history' -and $returned.isArchived) 'Continuation pointer, chain, title, turns and archive flag move as one unit'
Assert-Test ($returned.cwd -eq 'C:\project' -and (Get-CHFileHash $b) -eq $sourceHash) 'Continuation update preserves destination paths and source bytes'
Assert-Test ((New-CHPlan $ctx -Direction BtoA).Operations.Count -eq 0) 'Pointer-aware reconciliation is idempotent'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test ((Get-CHFileHash $a) -eq $beforeA) 'Undo restores the exact old pointer and its history'
# A shared ancestor does not authorize replacing a different successor branch.
$branched = [IO.File]::ReadAllText($a) | ConvertFrom-Json
$branchId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
$branched.cliSessionId = $branchId
$branched | Add-Member -NotePropertyName priorCliSessionIds -NotePropertyValue @($parentId)
[IO.File]::WriteAllBytes($a, (ConvertTo-CHBytes $branched))
[IO.File]::WriteAllText((Join-Path $ctx.Config.ProjectsRoot ('project\' + $branchId + '.jsonl')), '{"fixture":"different branch"}')
$branchPlan = New-CHPlan $ctx -Direction BtoA
Assert-Test (@($branchPlan.Report | Where-Object Action -eq 'Conflict').Count -eq 1 -and @($branchPlan.Report | Where-Object Action -eq 'Skipped').Count -eq 1 -and @($branchPlan.Operations | Where-Object Area -eq 'desktop').Count -eq 0) 'Sibling CLI branches and their dependent child writes stay blocked even with source-wins policy'
# Missing/deleted continuation segments cannot become new history references.
$branched.cliSessionId = $parentId; $branched.PSObject.Properties.Remove('priorCliSessionIds')
[IO.File]::WriteAllBytes($a, (ConvertTo-CHBytes $branched))
$oldTranscript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $parentId + '.jsonl')
[IO.File]::Move($oldTranscript, (Join-Path $ctx.ConfigDirectory 'old-transcript.fixture'))
Assert-Test (@((New-CHPlan $ctx -Direction BtoA).Report | Where-Object { $_.File -eq ('local_' + $parentId + '.json') -and $_.Action -eq 'Skipped' }).Count -eq 1) 'Missing ancestor transcript blocks rollover'
[IO.File]::Move((Join-Path $ctx.ConfigDirectory 'old-transcript.fixture'), $oldTranscript)
# A missing intermediate segment is checked even when both current IDs exist.
$continued.priorCliSessionIds = @($branchId, $parentId)
$branched | Add-Member -NotePropertyName priorCliSessionIds -NotePropertyValue @($branchId)
[IO.File]::WriteAllBytes($a, (ConvertTo-CHBytes $branched)); [IO.File]::WriteAllBytes($b, (ConvertTo-CHBytes $continued))
$intermediateTranscript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $branchId + '.jsonl')
[IO.File]::Move($intermediateTranscript, (Join-Path $ctx.ConfigDirectory 'intermediate.fixture'))
Assert-Test (@((New-CHPlan $ctx -Direction BtoA).Report | Where-Object Detail -eq 'CLI continuation transcript missing or deleted').Count -eq 1) 'Missing intermediate transcript blocks rollover even when both current transcripts exist'
[IO.File]::Move((Join-Path $ctx.ConfigDirectory 'intermediate.fixture'), $intermediateTranscript)
[IO.File]::WriteAllText((Join-Path $ctx.Config.Profiles[0].FullPath ('deleted_' + $branchId)), '1')
Assert-Test (@((New-CHPlan $ctx -Direction BtoA).Report | Where-Object Detail -eq 'CLI continuation transcript missing or deleted').Count -eq 1) 'Deletion of an earlier CLI segment blocks rollover'

foreach ($prior in @(@('not-a-guid'), @($parentId, $parentId), @($continuedId), 'not-an-array', @($null))) {
    $ctx = New-Fixture
    $path = Add-Record $ctx 'A' $id 'Malformed continuation' $false @{priorCliSessionIds=$prior}
    # The current ID duplicated in its prior list is also invalid.
    if ($prior -is [array] -and $prior.Count -eq 1 -and $prior[0] -eq $continuedId) {
        $card = [IO.File]::ReadAllText($path) | ConvertFrom-Json; $card.cliSessionId = $continuedId
        [IO.File]::WriteAllBytes($path, (ConvertTo-CHBytes $card))
    }
    Assert-Throws { New-CHPlan $ctx -Direction AtoB } 'Invalid CLI continuation history' 'Malformed or cyclic CLI history fails before writes'
}

# A pointer-only rollover must not be mistaken for matching history summaries.
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Same metadata' | Out-Null
Add-Record $ctx 'B' $id 'Same metadata' $false @{cliSessionId=$continuedId;priorCliSessionIds=@($id)} | Out-Null
[IO.File]::WriteAllText((Join-Path $ctx.Config.ProjectsRoot ('project\' + $continuedId + '.jsonl')), '{"fixture":"continued transcript"}')
$plan = New-CHPlan $ctx -Direction BtoA
Assert-Test (@($plan.Report | Where-Object Action -eq 'Update').Count -eq 1) 'Pointer-only continuation still plans an update'
foreach ($profile in $ctx.Config.Profiles) {
    $path = Join-Path $profile.FullPath ('local_' + $id + '.json')
    $card = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $card | Add-Member -NotePropertyName wslConfig -NotePropertyValue @{distro='SameRemoteEnvironment'}
    [IO.File]::WriteAllBytes($path, (ConvertTo-CHBytes $card))
}
Assert-Test (@((New-CHPlan $ctx -Direction BtoA).Report | Where-Object Action -eq 'Conflict').Count -eq 1) 'Remote CLI rollover remains blocked even for matching remote configuration'

# Legacy history-only hashes remain usable when the complete pointers match.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id 'Legacy baseline'
$b = Add-Record $ctx 'B' $id 'Legacy baseline'
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$baselinePath = Join-Path $ctx.StateRoot 'baseline.json'
$baseline = [IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
$legacyRecord = [IO.File]::ReadAllText($a) | ConvertFrom-Json
$baseline.Entries.('local_' + $id + '.json') = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $legacyRecord $script:HistoryFields))
[IO.File]::WriteAllBytes($baselinePath, (ConvertTo-CHBytes $baseline))
Set-Record $a 'New history'
Assert-Test (@((New-CHPlan $ctx -Direction Both -Resolution Changes).Report | Where-Object Action -eq 'Update').Count -eq 1) 'Legacy history hashes can select one-sided history changes after full CLI-chain equality is verified'
Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
$baseline = [IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
Assert-Test ($baseline.Entries.('local_' + $id + '.json').StartsWith('v2:') -and (New-CHPlan $ctx -Direction AtoB).Operations.Count -eq 0) 'Successful sync replaces legacy hash with an idempotent pointer-aware baseline'

# Scoped local sessions copy history without transferring account scope IDs.
foreach ($extra in @(@{envScopeId='scope'}, @{envScopeId='scope';cloudSpawnedTasks=@(@{sessionId='cloud'})}, @{envScopeId='scope';wslConfig=@{distro='fixture'}})) {
    $ctx = New-Fixture
    $a = Add-Record $ctx 'A' $id 'Scoped local' $false $extra
    $sourceHash = Get-CHFileHash $a
    $transcript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $id + '.jsonl')
    $transcriptHash = Get-CHFileHash $transcript
    $plan = New-CHPlan $ctx -Direction AtoB
    Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Scoped session with local transcript is eligible'
    $backup = Apply-Plan $ctx $plan
    $b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
    $copy = [IO.File]::ReadAllText($b) | ConvertFrom-Json
    Assert-Test ($copy.title -eq 'Scoped local' -and -not $copy.PSObject.Properties['envScopeId'] -and -not $copy.PSObject.Properties['cloudSpawnedTasks']) 'New scoped card omits source scope and cloud links'
    Assert-Test ((Get-CHFileHash $a) -eq $sourceHash) 'Scoped sync leaves source card unchanged'
    Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
    Assert-Test (-not [IO.File]::Exists($b)) 'Scoped card addition can be undone'
    Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
    $copy | Add-Member -NotePropertyName envScopeId -NotePropertyValue 'destination-scope'
    [IO.File]::WriteAllBytes($b, (ConvertTo-CHBytes $copy))
    Set-Record $a 'Renamed scoped local'
    Apply-Plan $ctx (New-CHPlan $ctx -Direction AtoB) | Out-Null
    $copy = [IO.File]::ReadAllText($b) | ConvertFrom-Json
    Assert-Test ($copy.title -eq 'Renamed scoped local' -and $copy.envScopeId -eq 'destination-scope') 'Scoped updates preserve destination scope'
    Assert-Test ((Get-CHFileHash $transcript) -eq $transcriptHash) 'Scoped sync leaves transcript unchanged'
    Assert-Test ((New-CHPlan $ctx -Direction AtoB).Operations.Count -eq 0) 'Scoped sync is idempotent'
    [IO.File]::Move($transcript, (Join-Path $ctx.ConfigDirectory 'scoped-transcript.fixture'))
    $plan = New-CHPlan $ctx -Direction AtoB
    Assert-Test (@($plan.Report | Where-Object Detail -eq 'Account-bound environment scope without local transcript').Count -eq 1 -and $plan.Operations.Count -eq 0) 'Scoped cards without local transcripts stay excluded, including remote metadata'
}
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$transcript = Join-Path $ctx.Config.ProjectsRoot ('project\' + $id + '.jsonl')
[void](Assert-CHPath $transcript $fixtureRoot)
Move-Item -LiteralPath $transcript -Destination (Join-Path $ctx.Config.ProjectsRoot 'fixture-transcript.bin')
Assert-Test (@((New-BothPlan $ctx '').Report | Where-Object Detail -eq 'Local transcript missing').Count -eq 1) 'Missing transcript skipped'
[IO.File]::WriteAllText($a, '{invalid-json')
Assert-Throws { New-BothPlan $ctx '' } 'Cannot safely read' 'Malformed metadata fails before any writes'

# Valid Desktop cards can exist before a CLI ID is assigned. Skip the card,
# rather than blocking other history or accepting a fabricated CLI identity.
foreach ($missing in @($null, '', '   ')) {
    $ctx = New-Fixture
    $pending = Add-Record $ctx 'A' $id 'Pending' $true @{cliSessionId=$missing;wslConfig=@{distro='fixture'}}
    $readyId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Add-Record $ctx 'A' $readyId 'Ready' | Out-Null
    $pendingHash = Get-CHFileHash $pending
    $plan = New-CHPlan $ctx -Direction AtoB
    Assert-Test (@($plan.Report | Where-Object { $_.File -eq ('local_' + $id + '.json') -and $_.Action -eq 'Skipped' -and $_.Detail -like '*CLI session ID missing*' }).Count -eq 1) 'Pending card is explained as skipped'
    Assert-Test (@($plan.Inventory | Where-Object Status -eq 'Pending').Count -eq 1) 'Pending card remains visible in inventory'
    Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Pending card does not block a ready session'
    Assert-Test (-not [IO.Directory]::Exists($ctx.StateRoot) -and (Get-CHFileHash $pending) -eq $pendingHash) 'Pending-card preview leaves history and state unchanged'
    $indexOperation = @($plan.Operations | Where-Object RelativePath -like '*archived-sessions.idx')
    Assert-Test (-not $indexOperation.Count) 'Pending archived source does not enter destination index'
}
$ctx = New-Fixture
$pending = Add-Record $ctx 'B' $id 'Target pending' $false @{cliSessionId=$null}
Add-Record $ctx 'A' $id 'Ready source' | Out-Null
$plan = New-CHPlan $ctx -Direction AtoB
Assert-Test (@($plan.Operations | Where-Object Area -eq 'desktop').Count -eq 0) 'Pending destination is not overwritten by a ready source'
foreach ($invalid in @(@{cliSessionId='not-a-guid'}, @{cliSessionId=@($id)}, @{sessionId='local_mismatch';cliSessionId=$null}, @{cwd='';cliSessionId=$null})) {
    $ctx = New-Fixture
    Add-Record $ctx 'A' $id 'Malformed identity' $false $invalid | Out-Null
    Assert-Throws { New-CHPlan $ctx -Direction AtoB } 'Invalid session identity' 'Malformed identities still fail closed'
}

# Refuse stale plans and unknown index formats.
$ctx = New-Fixture
Add-Record $ctx 'A' $id 'Renamed source' $true | Out-Null
Add-Record $ctx 'B' $id 'Original destination' $false | Out-Null
$newId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
Add-Record $ctx 'A' $newId 'New archived session' $true | Out-Null
$plan=New-CHPlan $ctx -Direction AtoB
$rows=@(Get-CHPreviewRows $ctx $plan)
$changed=@($rows | Where-Object File -eq ('local_'+$id+'.json'))[0]
Assert-Test ($changed.Title -eq 'Renamed source' -and $changed.Before.Title -eq 'Original destination' -and $changed.After.Title -eq 'Renamed source') 'Comparison shows real source and before/after destination titles'
Assert-Test (-not $changed.Before.Archived -and $changed.After.Archived) 'Comparison shows planned archiving'
Assert-Test ($plan.Snapshot.Records[$ctx.Config.Profiles[1].Name][('local_'+$id+'.json')].Record.title -eq 'Original destination') 'Building a plan does not mutate the before snapshot'
Assert-Test ($changed.ChangedFields -contains 'title' -and $changed.ChangedFields -contains 'isArchived') 'Comparison identifies changed title and archive fields'
$added=@($rows | Where-Object File -eq ('local_'+$newId+'.json'))[0]
Assert-Test ($null -eq $added.Before -and $added.After.Title -eq 'New archived session' -and $added.After.Archived) 'New archived card has an absent before and populated after'
$ctx=New-Fixture
Add-Record $ctx 'A' $id 'Source conflict' $true | Out-Null
Add-Record $ctx 'B' $id 'Destination conflict' $false @{cliSessionId=$newId} | Out-Null
Add-Record $ctx 'B' $newId 'Destination only' $true | Out-Null
$plan=New-CHPlan $ctx -Direction AtoB
$rows=@(Get-CHPreviewRows $ctx $plan)
$conflict=@($rows | Where-Object Action -eq 'Conflict')[0]
Assert-Test ($conflict.Before.Title -eq 'Destination conflict' -and $conflict.After.Title -eq 'Destination conflict' -and -not $conflict.After.Archived) 'Conflicted comparison shows destination remaining unchanged'
$retained=@($rows | Where-Object Title -eq 'Destination only')[0]
Assert-Test ($retained.Action -eq 'Skipped' -and $retained.Before.Archived -and $retained.After.Archived) 'Destination-only archive remains in before and after'
$ctx=New-Fixture
Add-Record $ctx 'A' $id 'Already matches' | Out-Null
Add-Record $ctx 'B' $id 'Already matches' | Out-Null
$rows=@(Get-CHPreviewRows $ctx (New-CHPlan $ctx -Direction AtoB))
Assert-Test ($rows.Count -eq 1 -and $rows[0].Action -eq 'Unchanged') 'Comparison includes unchanged sessions omitted from the change report'

# Refuse stale plans and unknown index formats.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$plan = New-BothPlan $ctx ''
Set-Record $a 'Changed during planning'
Assert-Throws { Invoke-CHApply $ctx $plan } 'changed during planning' 'Stale source snapshot refused'
Assert-Test (-not [IO.Directory]::Exists($ctx.StateRoot)) 'Stale snapshot refused before backup mutation'
[IO.File]::WriteAllText((Join-Path $ctx.Config.Profiles[1].FullPath 'archived-sessions.idx'), '{"v":99,"archived":[]}')
Assert-Throws { New-BothPlan $ctx '' } 'Unknown archived' 'Unknown index format fails closed'
Assert-Throws { Assert-CHPath (Join-Path $fixtureRoot '..\escape.txt') $fixtureRoot } 'escaped' 'Path traversal refused'
$junction = Join-Path $fixtureRoot 'junction'
New-Item -ItemType Junction -Path $junction -Target $ctx.ConfigDirectory | Out-Null
Assert-Throws { Assert-CHPath (Join-Path $junction 'profiles.json') $fixtureRoot } 'reparse point' 'Junction path refused'

# Prepared backups also recover interrupted syncs, without replaying unwritten files.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$b = Add-Record $ctx 'B' $id 'Other'
$beforeB = Get-CHFileHash $b
$backup = Apply-Plan $ctx (New-BothPlan $ctx 'A')
$manifestPath = Join-Path $backup 'manifest.json'
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$manifest.Status = 'prepared'
[IO.File]::WriteAllBytes($manifestPath, (ConvertTo-CHBytes $manifest))
$state = Join-Path $ctx.StateRoot 'baseline.json'
[void](Assert-CHPath $state $fixtureRoot)
Move-Item -LiteralPath $state -Destination (Join-Path $ctx.StateRoot 'fixture-unwritten-baseline.bin')
$undo = Get-CHUndo $ctx $backup
Assert-Test (@($undo.Operations | Where-Object { $_.Entry.Area -eq 'state' }).Count -eq 0) 'Interrupted sync skips an unwritten state file'
Invoke-CHUndo $ctx $undo | Out-Null
Assert-Test ((Get-CHFileHash $b) -eq $beforeB) 'Prepared backup restores a partially applied sync'

# Undo verifies backups before writing.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$b = Add-Record $ctx 'B' $id 'Other'
$backup = Apply-Plan $ctx (New-BothPlan $ctx 'A')
$snapshot = Get-ChildItem -LiteralPath $backup -Filter 'before-*.bin' | Select-Object -First 1
[IO.File]::WriteAllText($snapshot.FullName, 'corrupted')
Assert-Throws { Get-CHUndo $ctx $backup } 'Backup hash mismatch' 'Corrupted backup refused'
Assert-Test ((Get-Acl -LiteralPath $ctx.StateRoot).AreAccessRulesProtected) 'State directory blocks inherited access'
Assert-Test (@((Get-Acl -LiteralPath $ctx.StateRoot).Access).Count -eq 2) 'State directory has only user and SYSTEM access rules'

# Fixed-profile policy really wins even if only the other profile changed.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$b = Add-Record $ctx 'B' $id
Apply-Plan $ctx (New-BothPlan $ctx '') | Out-Null
Set-Record $a 'Only A changed' $true
$plan = New-BothPlan $ctx 'B' $false 'Profile'
Assert-Test (@($plan.Report | Where-Object { $_.Detail -like 'B -> A; chosen profile wins*' }).Count -eq 1) 'Fixed winner overrides unilateral change on another profile'
Apply-Plan $ctx $plan | Out-Null
$j = [IO.File]::ReadAllText($a) | ConvertFrom-Json
Assert-Test ($j.title -eq 'Before' -and -not $j.isArchived) 'Fixed profile wins for title and archive status'
Assert-Throws { New-BothPlan $ctx '' $false 'Profile' } 'requires -WinnerProfile' 'Fixed policy needs a winner'
Assert-Throws { New-BothPlan $ctx 'B' $false 'Newest' } 'only to Policy Profile' 'Conflicting policy arguments refused'

# Newest policy uses UTC file times for two divergent copies with no baseline.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id 'Older'
$b = Add-Record $ctx 'B' $id 'Newer'
[IO.File]::SetLastWriteTimeUtc($a, [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime())
[IO.File]::SetLastWriteTimeUtc($b, [datetime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime())
$plan = New-BothPlan $ctx '' $false 'Newest'
Assert-Test (@($plan.Report | Where-Object { $_.Detail -like 'B -> A; newest*' }).Count -eq 1) 'Newest divergent file wins on first sync'
Apply-Plan $ctx $plan | Out-Null
Assert-Test (([IO.File]::ReadAllText($a) | ConvertFrom-Json).title -eq 'Newer') 'Newest winner writes correct metadata'
Set-Record $a 'Changed A'
Set-Record $b 'Changed B'
[IO.File]::SetLastWriteTimeUtc($a, [datetime]::Parse('2026-02-02T00:00:00Z').ToUniversalTime())
[IO.File]::SetLastWriteTimeUtc($b, [datetime]::Parse('2026-02-01T00:00:00Z').ToUniversalTime())
Assert-Test (@((New-BothPlan $ctx '' $false 'Newest').Report | Where-Object { $_.Detail -like 'A -> B; newest*' }).Count -eq 1) 'Newest timestamp breaks both-changed conflict'
[IO.File]::SetLastWriteTimeUtc($b, [IO.File]::GetLastWriteTimeUtc($a))
Assert-Test (@((New-BothPlan $ctx '' $false 'Newest').Report | Where-Object Action -eq 'Conflict').Count -eq 1) 'Timestamp ties remain conflicts'

# Archive-only changes count without a new message or lastActivityAt update.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id
$b = Add-Record $ctx 'B' $id
Apply-Plan $ctx (New-BothPlan $ctx '') | Out-Null
Set-Record $a 'Before' $true
[IO.File]::SetLastWriteTimeUtc($b, [datetime]::UtcNow.AddDays(1)) # Unchanged history, newer focus-only file write.
$plan = New-BothPlan $ctx '' $false 'Newest'
Assert-Test (@($plan.Report | Where-Object ArchiveChanged).Count -eq 1) 'Archive-only change is reported'
Assert-Test (@($plan.Report | Where-Object { $_.Detail -like 'A -> B; only this copy changed; archive' }).Count -eq 1) 'Archive change beats unchanged history with newer file time'
Apply-Plan $ctx $plan | Out-Null
foreach ($path in @($a, $b)) {
    $j = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $idx = [IO.File]::ReadAllText((Join-Path ([IO.Path]::GetDirectoryName($path)) 'archived-sessions.idx')) | ConvertFrom-Json
    Assert-Test ($j.isArchived -and $j.lastActivityAt -eq 1 -and $idx.archived -contains ('local_' + $id)) 'Both profiles archive with unchanged message timestamp and consistent cache'
}
Set-Record $b 'Before' $false
$plan = New-BothPlan $ctx '' $false 'Newest'
Assert-Test (@($plan.Report | Where-Object { $_.Detail -like 'B -> A; only this copy changed; unarchive' }).Count -eq 1) 'Unarchive propagates in the other direction'
Apply-Plan $ctx $plan | Out-Null
foreach ($path in @($a, $b)) {
    $j = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $idx = [IO.File]::ReadAllText((Join-Path ([IO.Path]::GetDirectoryName($path)) 'archived-sessions.idx')) | ConvertFrom-Json
    Assert-Test (-not $j.isArchived -and $idx.archived -notcontains ('local_' + $id)) 'Both profiles unarchive with consistent cache'
}
Assert-Test ((New-BothPlan $ctx '' $false 'Newest').Operations.Count -eq 0) 'Archive reconciliation remains idempotent'

# Generic selectors: email labels, pair order independence, and ambiguous orgs.
$ctx = New-Fixture
$configFile = $ctx.ConfigPath
$cfg = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
$paths = @($cfg.Profiles.Path)
$cfg.FormatVersion=2; $cfg.Profiles=@()
[IO.File]::WriteAllBytes($configFile, (ConvertTo-CHBytes $cfg))
$labels = [ordered]@{FormatVersion=1; Profiles=@(@{Path=$paths[0];Email='a@example.test'},@{Path=$paths[1];Email='b@example.test'})}
[IO.File]::WriteAllBytes((Join-Path $ctx.ConfigDirectory 'profile-labels.json'), (ConvertTo-CHBytes $labels))
$discovery = Get-CHConfig $configFile '' '' $false
Assert-Test ($discovery.Catalog.Count -eq 2 -and $discovery.Config.Profiles.Count -eq 0) 'Discovery needs no selected profiles'
$pair = Get-CHConfig $configFile 'a@example.test' 'b@example.test'
Assert-Test ($pair.Config.Profiles[0].EmailSource -eq 'User label' -and $pair.Config.Profiles[1].Email -eq 'b@example.test') 'Generic email selectors find user-labelled profiles'
$reverse = Get-CHConfig $configFile 'b@example.test' 'a@example.test'
Assert-Test ($pair.Signature -eq $reverse.Signature -and $pair.StateRoot -eq $reverse.StateRoot) 'Swapping profile order keeps same baseline and backups'
Assert-Throws { Get-CHConfig $configFile } 'Choose -ProfileA' 'No hidden default account pair'
Assert-Throws { Get-CHConfig $configFile 'a@example.test' 'a@example.test' } 'must be different' 'Same profile cannot sync with itself'
$labels.Profiles[1].Email='a@example.test'
[IO.File]::WriteAllBytes((Join-Path $ctx.ConfigDirectory 'profile-labels.json'), (ConvertTo-CHBytes $labels))
Assert-Throws { Get-CHConfig $configFile 'a@example.test' $paths[1] } 'unknown or ambiguous' 'Ambiguous email requires exact profile ID'
Assert-Test ((Get-CHConfig $configFile $paths[0] $paths[1]).Config.Profiles.Count -eq 2) 'Exact profile IDs resolve even when email is ambiguous'
$third = '55555555-5555-4555-8555-555555555555\66666666-6666-4666-8666-666666666666'
[IO.Directory]::CreateDirectory((Join-Path $cfg.SessionsRoot $third)) | Out-Null
$otherPair = Get-CHConfig $configFile $paths[0] $third
Assert-Test ($otherPair.Signature -ne $pair.Signature -and $otherPair.StateRoot -ne $pair.StateRoot) 'Other profile pair has separate state and backups'
# Default direction writes only B, including its index, regardless of B's newer timestamp.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id 'Source title' $true
$b = Add-Record $ctx 'B' $id 'Destination title'
$otherId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$bOnly = Add-Record $ctx 'B' $otherId 'Destination only'
$aIndex = Join-Path $ctx.Config.Profiles[0].FullPath 'archived-sessions.idx'
$bIndex = Join-Path $ctx.Config.Profiles[1].FullPath 'archived-sessions.idx'
[IO.File]::WriteAllText($aIndex, '{"v":1,"archived":[]}') # Deliberately stale source cache.
[IO.File]::WriteAllText($bIndex, '{ "v": 1, "archived": ["local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"] }')
[IO.File]::SetLastWriteTimeUtc($b, [datetime]::UtcNow.AddDays(1))
$sourceHash = Get-CHFileHash $a; $sourceIndexHash = Get-CHFileHash $aIndex
$sourceTime = [IO.File]::GetLastWriteTimeUtc($a); $sourceIndexTime = [IO.File]::GetLastWriteTimeUtc($aIndex)
$destIndexHash = Get-CHFileHash $bIndex; $destIndexTime = [IO.File]::GetLastWriteTimeUtc($bIndex)
$plan = New-CHPlan $ctx
Assert-Test ($plan.Direction -eq 'AtoB' -and $plan.Policy -eq 'Profile') 'Default is source-authoritative AtoB'
Assert-Test (@($plan.Report | Where-Object { $_.Detail -eq 'Destination-only card; reverse copying disabled' }).Count -eq 1) 'Destination-only cards are skipped'
Assert-Test (@($plan.Operations | Where-Object { $_.Area -eq 'desktop' -and -not $_.RelativePath.StartsWith($ctx.Config.Profiles[1].Path + '\') }).Count -eq 0) 'All one-way desktop operations stay inside B'
$backup = Apply-Plan $ctx $plan
Assert-Test ((Get-CHFileHash $a) -eq $sourceHash -and (Get-CHFileHash $aIndex) -eq $sourceIndexHash) 'Source card and stale source index stay byte-identical'
Assert-Test ([IO.File]::GetLastWriteTimeUtc($a) -eq $sourceTime -and [IO.File]::GetLastWriteTimeUtc($aIndex) -eq $sourceIndexTime) 'Source modification times stay unchanged'
Assert-Test (-not [IO.File]::Exists((Join-Path $ctx.Config.Profiles[0].FullPath ('local_' + $otherId + '.json')))) 'No reverse copy for destination-only card'
Assert-Test (([IO.File]::ReadAllText($b) | ConvertFrom-Json).title -eq 'Source title') 'Source wins despite newer destination timestamp'
$index = [IO.File]::ReadAllText($bIndex) | ConvertFrom-Json
Assert-Test ($index.archived -contains ('local_' + $id) -and $index.archived -contains ('local_' + $otherId)) 'Destination index updates eligible card and preserves unrelated entries'
$receipt = [IO.File]::ReadAllText((Join-Path $backup 'manifest.json')) | ConvertFrom-Json
$indexReceipt = @($receipt.Entries | Where-Object { $_.RelativePath -eq ($ctx.Config.Profiles[1].Path + '\archived-sessions.idx') })
Assert-Test ($receipt.Direction -eq 'AtoB' -and $indexReceipt.Count -eq 1 -and (Get-CHFileHash (Join-Path $backup $indexReceipt[0].Snapshot)) -eq $destIndexHash) 'Receipt contains exact verified index backup and direction'
Assert-Test ((New-CHPlan $ctx).Operations.Count -eq 0) 'One-way repeat does not repair source cache'
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup) | Out-Null
Assert-Test ((Get-CHFileHash $bIndex) -eq $destIndexHash -and [IO.File]::GetLastWriteTimeUtc($bIndex) -eq $destIndexTime) 'Undo restores exact index bytes and time'

# Reverse direction is explicit; policies cannot sneak in reverse writes.
$plan = New-CHPlan -Context $ctx -Direction BtoA
Assert-Test (@($plan.Report | Where-Object Action -eq 'Add').Count -eq 1) 'Explicit BtoA imports B-only card'
Assert-Test (@($plan.Operations | Where-Object { $_.Area -eq 'desktop' -and -not $_.RelativePath.StartsWith($ctx.Config.Profiles[0].Path + '\') }).Count -eq 0) 'BtoA writes only A'
$bHash = Get-CHFileHash $b; $bIndexHash = Get-CHFileHash $bIndex
Apply-Plan $ctx $plan | Out-Null
Assert-Test ((Get-CHFileHash $b) -eq $bHash -and (Get-CHFileHash $bIndex) -eq $bIndexHash) 'Reverse direction leaves B source untouched'
Assert-Throws { New-CHPlan -Context $ctx -Winner B } 'must be the source' 'Default direction rejects a destination winner'
Set-Record $a 'Older A'
Set-Record $b 'Newer B'
[IO.File]::SetLastWriteTimeUtc($b, [datetime]::UtcNow.AddDays(1))
$plan = New-CHPlan -Context $ctx -Resolution Newest
Assert-Test (@($plan.Report | Where-Object Detail -eq 'Policy chose destination; reverse writing disabled').Count -eq 1) 'Explicit newest policy skips destination winner'
Assert-Test (@($plan.Operations | Where-Object { $_.Area -eq 'desktop' -and $_.RelativePath -like '*local_aaaaaaaa*' }).Count -eq 0) 'Newest policy never writes in reverse'
$both = New-CHPlan -Context $ctx -Direction Both
Assert-Test ($both.Policy -eq 'Newest' -and @($both.Report | Where-Object { $_.Detail -like 'B -> A; newest*' }).Count -eq 1) 'Explicit Both enables two-way newest resolution'

# Live mode enforces declared active source and destination-only writes.
$plan = New-CHPlan $ctx
Assert-Throws { Assert-CHWriteAccess $ctx $plan $true } 'requires -ActiveProfile' 'Live mode requires explicit active identity'
Assert-Throws { Assert-CHWriteAccess $ctx $plan $true 'B' } 'active destination' 'Live mode refuses active target'
Assert-Throws { Assert-CHWriteAccess $ctx $both $true 'A' } 'one-way Direction' 'Live mode refuses Both'
Assert-Throws { Assert-CHWriteAccess $ctx $plan $false 'A' } 'requires -AllowRunning' 'Active identity cannot silently bypass guard'
Assert-CHWriteAccess $ctx $plan $true 'A'
$sourceOp = New-CHOperation $ctx 'desktop' ($ctx.Config.Profiles[0].Path + '\archived-sessions.idx') (ConvertTo-CHBytes @{v=1;archived=@()})
$plan.Operations.Add($sourceOp)
Assert-Throws { Invoke-CHApply $ctx $plan $true 'A' } 'outside the destination' 'Apply rejects injected source writes even in live mode'
$plan.Operations.RemoveAt($plan.Operations.Count - 1)
function Assert-CHStopped { throw 'Fixture Claude running.' }
Assert-Throws { Invoke-CHApply $ctx $plan } 'Fixture Claude running' 'Ordinary apply still checks the process guard'
$liveResult = @(Invoke-CHApply $ctx $plan $true 'A')
Assert-Test (@($liveResult | Where-Object { $_ -like 'Sync complete.*' }).Count -eq 1) 'Live one-way apply bypasses the process guard for destination-only writes'
function Assert-CHStopped { }

# Standalone flags and inactive target index races.
$ctx = New-Fixture
$a = Add-Record $ctx 'A' $id 'Live source' $true
$entryScript = Join-Path $ctx.ConfigDirectory 'Sync-ClaudeHistory.ps1'
[IO.File]::Copy((Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1'), $entryScript)
$result = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $entryScript -Mode Sync -AllowRunning -ActiveProfile A)
Assert-Test ($LASTEXITCODE -eq 0 -and @($result | Where-Object { $_ -like 'Direction: AtoB. Policy: Profile.*' }).Count -eq 1) 'Standalone live flags use source-authoritative default'
$liveBackupLine = @($result | Where-Object { $_ -like 'Backup: *' })[0]
$liveReceipt = [IO.File]::ReadAllText((Join-Path $liveBackupLine.Substring(8) 'manifest.json')) | ConvertFrom-Json
Assert-Test ($liveReceipt.AllowRunning) 'Live mode is recorded in backup receipt'
$b = Join-Path $ctx.Config.Profiles[1].FullPath ('local_' + $id + '.json')
$bIndex = Join-Path $ctx.Config.Profiles[1].FullPath 'archived-sessions.idx'
Set-Record $a 'Source changed again' $false
$plan = New-CHPlan $ctx
$beforeB = Get-CHFileHash $b
[IO.File]::WriteAllText($bIndex, '{"v":1,"archived":[]}')
Assert-Throws { Invoke-CHApply $ctx $plan $true 'A' } 'planned file changed' 'Live apply rejects target index changes after planning'
Assert-Test ((Get-CHFileHash $b) -eq $beforeB) 'Index race is caught before any card writes'
Write-Output "PASS: $script:Assertions assertions. Fixtures: $fixtureRoot"
