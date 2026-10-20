#requires -Version 5.1
[CmdletBinding()]
param([string]$FixtureDirectory = (Join-Path $env:TEMP 'ClaudeSync-mod-tests'))
$ErrorActionPreference = 'Stop'
$testDirectory = Join-Path $FixtureDirectory ([guid]::NewGuid().ToString('N'))
$sourceScript = Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1'
$bridgeScript = Join-Path $PSScriptRoot 'mods\account-history-sync\scripts\HistorySync-Bridge.ps1'
$bundledScript = Join-Path $PSScriptRoot 'mods\account-history-sync\scripts\Sync-ClaudeHistory.ps1'
. $sourceScript
$testCount = 0
function Check($Condition, [string]$Message) {
    $script:testCount++
    if (-not $Condition) { throw "FAILED: $Message" }
}
Check ((Get-CHFileHash $sourceScript) -eq (Get-CHFileHash $bundledScript)) 'Bundled engine matches the canonical script'
Protect-CHDirectory $testDirectory
$sessions = Join-Path $testDirectory 'sessions'
$projects = Join-Path $testDirectory 'projects'
$sourceId = '11111111-1111-4111-8111-111111111111\22222222-2222-4222-8222-222222222222'
$targetId = '33333333-3333-4333-8333-333333333333\44444444-4444-4444-8444-444444444444'
$sessionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$targetOnlyId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
foreach ($path in @((Join-Path $sessions $sourceId), (Join-Path $sessions $targetId), (Join-Path $projects 'project'))) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
}
$fixtureConfig = Join-Path $testDirectory 'profiles.json'
[IO.File]::WriteAllBytes($fixtureConfig, (ConvertTo-CHBytes @{FormatVersion=2; SessionsRoot=$sessions; ProjectsRoot=$projects; Profiles=@()}))
function Add-FixtureCard([string]$ProfileId, [string]$Id, [string]$Title, [bool]$Archived) {
    $record = @{sessionId=('local_' + $Id);cliSessionId=$Id;cwd='C:\fixture';originCwd='C:\fixture';title=$Title;isArchived=$Archived;createdAt=1;lastActivityAt=1;permissionMode='default'}
    $path = Join-Path (Join-Path $sessions $ProfileId) ('local_' + $Id + '.json')
    [IO.File]::WriteAllBytes($path, (ConvertTo-CHBytes $record))
    [IO.File]::WriteAllText((Join-Path $projects ('project\' + $Id + '.jsonl')), '{"fixture":true}')
    $path
}
$sourceCard = Add-FixtureCard $sourceId $sessionId 'Source title' $true
$targetCard = Add-FixtureCard $targetId $sessionId 'Target title' $false
$targetOnly = Add-FixtureCard $targetId $targetOnlyId 'Target-only title' $true
$sourceIndex = Join-Path (Join-Path $sessions $sourceId) 'archived-sessions.idx'
$targetIndex = Join-Path (Join-Path $sessions $targetId) 'archived-sessions.idx'
[IO.File]::WriteAllText($sourceIndex, '{"v":1,"archived":[]}')
[IO.File]::WriteAllText($targetIndex, '{ "v":1, "archived":["local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"] }')
$beforeSource = Get-CHFileHash $sourceCard; $beforeSourceIndex = Get-CHFileHash $sourceIndex
$beforeTargetIndex = Get-CHFileHash $targetIndex
$engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
function Call-Bridge([string]$Action, [string]$Owner='one', [string]$Source=$sourceId, [string]$Target=$targetId, [bool]$Persistent=$false, [string]$Script=$bridgeScript, [string]$CurrentSession='') {
    $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-Action', $Action,
        '-ConfigPath', $fixtureConfig, '-SourceProfile', $Source, '-TargetProfile', $Target, '-OwnerSession', $Owner)
    if ($Persistent) { $argsList += '-KeepLease' }
    if ($CurrentSession) { $argsList += @('-SessionId', $CurrentSession) }
    $output = @(& $engine @argsList)
    $code = $LASTEXITCODE
    $parsed = ($output -join "`n") | ConvertFrom-Json
    Check (($code -eq 0) -eq [bool]$parsed.Ok) 'JSON result agrees with the process exit status'
    $parsed
}
$result = Call-Bridge Profiles
Check ($result.Profiles.Count -eq 2) 'Profile discovery uses machine-readable IDs'
$result = Call-Bridge Plan
Check ($result.Ok) ("Preview succeeds: " + $result.Error)
Check ($result.Updates -eq 1 -and $result.Skipped -eq 1) 'Preview reports directional update and destination-only skip'
Check ($result.ReportTotal -eq $result.Report.Count -and -not $result.ReportTruncated) 'Preview reports whether its per-file details are complete'
Check ($result.RowsTotal -eq 2 -and -not $result.RowsTruncated) 'Bridge exposes before/after rows and comparison coverage'
$changed=@($result.Rows | Where-Object Action -eq 'Update')[0]
Check ($changed.Title -eq 'Source title' -and $changed.Before.Title -eq 'Target title' -and $changed.After.Title -eq 'Source title' -and $changed.After.Archived) 'Bridge comparison preserves before title and shows planned archiving'
Check (-not [IO.Directory]::Exists((Join-Path $testDirectory 'state')) -and -not [IO.Directory]::Exists((Join-Path $testDirectory 'mod-control'))) 'Configured discovery and preview do not create sync state or lease'
$pendingId='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$pendingPath=Add-FixtureCard $sourceId $pendingId 'Not started' $true
$pendingCard=Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
$pendingCard.PSObject.Properties.Remove('cliSessionId')
[IO.File]::WriteAllBytes($pendingPath,(ConvertTo-CHBytes $pendingCard))
$pendingHash=Get-CHFileHash $pendingPath
$result=Call-Bridge Plan
Check ($result.Ok -and @($result.Report | Where-Object Detail -like '*CLI session ID missing*').Count -eq 1) 'Bridge preview reports an unfinished card instead of failing all history'
Check ((Get-CHFileHash $pendingPath) -eq $pendingHash -and (Get-CHFileHash $targetIndex) -eq $beforeTargetIndex) 'Pending-card preview does not modify source or destination'
$result = Call-Bridge Profiles -CurrentSession $sessionId
Check ($result.SessionProfiles.Count -eq 2 -and -not $result.CurrentProfile) 'A copied session does not falsely identify the current account'
$result = Call-Bridge Profiles -CurrentSession $targetOnlyId
Check ($result.CurrentProfile -eq $targetId -and $result.SessionProfiles.Count -eq 1) 'Unique current session identifies its local profile'
$result = Call-Bridge Profiles -CurrentSession 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
Check (-not $result.CurrentProfile -and $result.SessionProfiles.Count -eq 0) 'New or CLI-only session has no guessed source'
$result = Call-Bridge Profiles -CurrentSession 'invalid'
Check (-not $result.Ok -and $result.Error -like '*Invalid current session*') 'Malformed current session IDs are rejected'
$result = Call-Bridge Plan -CurrentSession $targetOnlyId
Check (-not $result.Ok -and $result.Error -like '*different local profile*') 'Preview refuses a source inconsistent with the running session'
$result = Call-Bridge Sync -CurrentSession $targetOnlyId
Check (-not $result.Ok -and (Get-CHFileHash $sourceCard) -eq $beforeSource -and (Get-CHFileHash $targetIndex) -eq $beforeTargetIndex) 'Write refuses a mismatched current source before history changes'
$result = Call-Bridge Plan -CurrentSession $sessionId
Check ($result.Ok) 'A session-local confirmed source can preview a duplicated session'
$result = Call-Bridge Plan -CurrentSession 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
Check ($result.Ok) 'Explicit current-account confirmation supports sessions without a Desktop card'
$result = Call-Bridge Arm
Check ($result.Ok) 'First controller can arm'
$result = Call-Bridge Arm two $targetId $sourceId
Check (-not $result.Ok -and $result.Error -like '*another session*') 'Opposite controller cannot arm while lease is held'
$result = Call-Bridge Sync two $targetId $sourceId
Check (-not $result.Ok) 'Another session cannot manually bypass the controller lease'
$result = Call-Bridge Sync one $targetId $sourceId $true
Check (-not $result.Ok -and $result.Error -like '*must be armed*') 'Auto-sync cannot change its armed pair'
$result = Call-Bridge Sync one $sourceId $targetId $true
Check ($result.Ok -and $result.Updates -eq 1 -and $result.Backup) 'Armed one-way sync returns its backup'
Check ((Get-CHFileHash $sourceCard) -eq $beforeSource -and (Get-CHFileHash $sourceIndex) -eq $beforeSourceIndex) 'Bridge sync preserves source card and index'
Check (([IO.File]::ReadAllText($targetCard) | ConvertFrom-Json).title -eq 'Source title') 'Bridge copies source metadata'
Check (-not [IO.File]::Exists((Join-Path (Join-Path $sessions $sourceId) ('local_' + $targetOnlyId + '.json')))) 'Bridge never reverse-copies destination-only cards'
$receipt = [IO.File]::ReadAllText((Join-Path $result.Backup 'manifest.json')) | ConvertFrom-Json
$indexEntry = @($receipt.Entries | Where-Object RelativePath -eq ($targetId + '\archived-sessions.idx'))[0]
Check ((Get-CHFileHash (Join-Path $result.Backup $indexEntry.Snapshot)) -eq $beforeTargetIndex) 'Bridge backup preserves exact destination index bytes'
$result = Call-Bridge Release two
Check ($result.Ok) 'Releasing another session lease is a no-op'
$result = Call-Bridge Arm two $targetId $sourceId
Check (-not $result.Ok) 'Non-owner release does not steal the lease'
$result = Call-Bridge Release one
Check ($result.Ok) 'Owner can release'
$result = Call-Bridge Sync two $targetId $sourceId
Check ($result.Ok -and $result.Additions -eq 1) 'Explicit reverse selection works after release'
$leasePath = Join-Path $testDirectory 'mod-control\lease.json'
Check (([IO.File]::ReadAllText($leasePath) | ConvertFrom-Json).Owner -eq '') 'Manual sync releases its transient lease'
$result = Call-Bridge Arm one
$lease = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
$lease.ExpiresUtc='1970-01-01T00:00:00Z'
[IO.File]::WriteAllBytes($leasePath, (ConvertTo-CHBytes $lease))
$result = Call-Bridge Arm two
Check ($result.Ok) 'Expired lease can be reclaimed'
$held = [IO.File]::Open((Join-Path $testDirectory 'mod-control\controller.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try { $result = Call-Bridge Sync two $sourceId $targetId $true; Check (-not $result.Ok) 'Concurrent bridge lock prevents simultaneous operations' }
finally { $held.Dispose() }
Call-Bridge Release two | Out-Null

# Inject an interruption only into a fixture copy of the engine to test error receipts.
$fixtureScripts = Join-Path $testDirectory 'interrupted-helper'
[IO.Directory]::CreateDirectory($fixtureScripts) | Out-Null
$fixtureBridge = Join-Path $fixtureScripts 'HistorySync-Bridge.ps1'
[IO.File]::Copy($bridgeScript, $fixtureBridge)
$fixtureEngine = [IO.File]::ReadAllText($bundledScript).Replace('Write-CHAtomic $op.Path $op.Bytes', "if (`$op.RelativePath -like '*archived-sessions.idx') { throw 'Fixture interrupted index write' }; Write-CHAtomic `$op.Path `$op.Bytes")
[IO.File]::WriteAllText((Join-Path $fixtureScripts 'Sync-ClaudeHistory.ps1'), $fixtureEngine)
$card = [IO.File]::ReadAllText($sourceCard) | ConvertFrom-Json
$card.title='Changed source'; $card.isArchived=$false
[IO.File]::WriteAllBytes($sourceCard, (ConvertTo-CHBytes $card))
$result = Call-Bridge Sync one $sourceId $targetId $false $fixtureBridge
Check (-not $result.Ok -and $result.Error -like '*Fixture interrupted*' -and $result.Backup) 'Interrupted sync returns a retained prepared backup path'
$receipt = [IO.File]::ReadAllText((Join-Path $result.Backup 'manifest.json')) | ConvertFrom-Json
Check ($receipt.Status -eq 'prepared') 'Interrupted backup is recoverable and never marked complete'

# Large, real JSON responses must cross the same file transport used by the mod.
# Long titles exercise the byte limit independently of the 1,000-row cap.
foreach ($number in 1..10) {
    $largeId = 'dddddddd-dddd-4ddd-8ddd-{0:d12}' -f $number
    Add-FixtureCard $sourceId $largeId ('Preview fixture ' + ('x' * 200000)) $false | Out-Null
}
$largeSourceHash = Get-CHFileHash $sourceCard
$largeTargetHash = Get-CHFileHash $targetCard
$previewOutput = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridgeScript -Action Plan -ConfigPath $fixtureConfig -SourceProfile $sourceId -TargetProfile $targetId -SessionId $sessionId -PreviewFile)
$previewCode = $LASTEXITCODE
$previewManifestText = $previewOutput -join "`n"
$previewManifest = $previewManifestText | ConvertFrom-Json
Check ($previewCode -eq 0 -and $previewManifest.Ok -and $previewManifest.Action -eq 'Plan') 'Large preview returns a successful file manifest'
Check ($previewManifestText.Length -lt 2048) 'Large preview stdout stays small enough for process capture'
$previewBytes = [IO.File]::ReadAllBytes($previewManifest.PreviewPath)
Check ($previewBytes.Length -eq $previewManifest.PreviewBytes -and $previewBytes.Length -le 4194304) 'Preview file respects the host fs.read byte limit'
$largePreview = [Text.Encoding]::UTF8.GetString($previewBytes) | ConvertFrom-Json
Check ($largePreview.Ok -and $largePreview.RowsTotal -gt $largePreview.Rows.Count -and $largePreview.RowsTruncated) 'Byte-limited preview remains complete JSON and explicitly reports omitted rows'
Check ($largePreview.ReportTruncated -eq ($largePreview.Report.Count -lt $largePreview.ReportTotal)) 'Byte-limited report reports its actual coverage'
Check ((Get-CHFileHash $sourceCard) -eq $largeSourceHash -and (Get-CHFileHash $targetCard) -eq $largeTargetHash) 'File-transport preview never changes source or target history'
Write-Output "PASS: $testCount assertions. Fixtures: $testDirectory"
