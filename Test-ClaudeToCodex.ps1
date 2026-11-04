#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
$fixtureRoot=Join-Path $env:TEMP ('ClaudeSync-import-selection-'+[guid]::NewGuid().ToString('N'))
Protect-CHDirectory $fixtureRoot
$sessions=Join-Path $fixtureRoot 'sessions';$projects=Join-Path $fixtureRoot 'projects';$private=Join-Path $fixtureRoot 'import-state'
$profileId='11111111-1111-4111-8111-111111111111\22222222-2222-4222-8222-222222222222'
$profileDirectory=Join-Path $sessions $profileId
foreach($dir in @($profileDirectory,(Join-Path $projects 'synthetic'))){[IO.Directory]::CreateDirectory($dir)|Out-Null}
$config=Join-Path $fixtureRoot 'profiles.json'
[IO.File]::WriteAllBytes($config,(ConvertTo-CHBytes @{FormatVersion=2;SessionsRoot=$sessions;ProjectsRoot=$projects;Profiles=@(@{Name='Source';Path=$profileId})}))
$script:Count=0
function Check($ok,$message){$script:Count++;if(-not $ok){throw "FAILED: $message"}}
function Card([string]$id,[string]$cwd,[string]$parent='', [bool]$pending=$false) {
    [IO.Directory]::CreateDirectory($cwd)|Out-Null
    $cli=[guid]::NewGuid().ToString();$first=[guid]::NewGuid().ToString();$second=[guid]::NewGuid().ToString()
    $card=@{sessionId=('local_'+$id);cwd=$cwd;title='Synthetic session';isArchived=$false}
    if(-not $pending){$card.cliSessionId=$cli}
    if($parent){$card.spawnedFrom=@{sessionId=('local_'+$parent)}}
    [IO.File]::WriteAllBytes((Join-Path $profileDirectory ('local_'+$id+'.json')),(ConvertTo-CHBytes $card))
    $lines=@(
        @{type='user';uuid=$first;parentUuid=$null;sessionId=$cli;cwd=$cwd;timestamp='2026-01-01T00:00:00Z';message=@{role='user';content='Synthetic question'}},
        @{type='assistant';uuid=$second;parentUuid=$first;sessionId=$cli;cwd=$cwd;timestamp='2026-01-01T00:00:01Z';message=@{role='assistant';content='Synthetic answer'}}
    )|ForEach-Object{[Text.Encoding]::UTF8.GetString((ConvertTo-CHBytes $_))}
    [IO.File]::WriteAllText((Join-Path $projects ('synthetic\'+$cli+'.jsonl')),(($lines -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
    $card
}
$parent='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$child='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';$other='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$folder=Join-Path $fixtureRoot 'SampleProject'
$parentCard=Card $parent $folder
Card $child (Join-Path $fixtureRoot 'ChildWorktree') $parent|Out-Null
Card $other (Join-Path $fixtureRoot 'SampleProject-other')|Out-Null
$argsBase=@{ConfigPath=$config;Source='Source';CodexHome=(Join-Path $fixtureRoot 'codex');StateRoot=$private;AsJson=$true}
$plan=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Folder -ScopeFolder $folder)|ConvertFrom-Json
Check ($plan.rows.Count -eq 2) 'Folder import includes descendants in separate worktrees and excludes sibling prefixes'
Check (@($plan.rows|Where-Object status -eq Ready).Count -eq 2) 'Selected synthetic transcripts are ready'
Check (@($plan.rows|Where-Object id -eq ('local_'+$child))[0].parent -eq ('local_'+$parent)) 'Receipt retains original parent relationship'
Check (-not [IO.Directory]::Exists($argsBase.CodexHome)) 'Plan does not create or initialize destination storage'
foreach($mismatch in @('CodexHome','StateRoot')){
    $wrong=Join-Path $fixtureRoot ('Wrong '+$mismatch);$importArgs=@{Mode='Import';Plan=$plan.planPath;CodexHome=$argsBase.CodexHome;StateRoot=$private;AsJson=$true};$importArgs[$mismatch]=$wrong;$failure=''
    try{& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @importArgs|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'destination or state directory does not match' -and -not [IO.Directory]::Exists($wrong)) 'Mismatched destination/state options fail without creating directories'
}
$leaf=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$child))|ConvertFrom-Json
Check ($leaf.rows.Count -eq 1 -and $leaf.rows[0].id -eq ('local_'+$child)) 'Child selection imports itself without its ancestor'
$pending='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
Card $pending $folder '' $true|Out-Null
$pendingPlan=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$pending))|ConvertFrom-Json
Check ($pendingPlan.rows[0].status -eq 'Skipped' -and $pendingPlan.rows[0].reason -match 'No CLI') 'Pending cards have an explicit skip reason'
$choices=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Mode Choices)|ConvertFrom-Json
Check ($choices.Sessions.Count -eq 4) 'Choices returns source-only session catalog'
& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $plan.planPath -StateRoot $private -CodexHome $argsBase.CodexHome -WhatIf
Check (-not [IO.Directory]::Exists($argsBase.CodexHome)) 'WhatIf never starts Codex'
Card 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' $folder|Out-Null
$failure=''
try { & (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $plan.planPath -StateRoot $private -CodexHome $argsBase.CodexHome|Out-Null }
catch {$failure=$_.Exception.Message}
Check ($failure -match 'scope changed after preview') 'New source descendants or folder sessions invalidate the preview before starting Codex'
$oldCli=$parentCard.cliSessionId;$newCli=[guid]::NewGuid().ToString()
$parentCard.priorCliSessionIds=@($oldCli);$parentCard.cliSessionId=$newCli
[IO.File]::WriteAllBytes((Join-Path $profileDirectory ('local_'+$parent+'.json')),(ConvertTo-CHBytes $parentCard))
$oldLines=@([IO.File]::ReadAllLines((Join-Path $projects ('synthetic\'+$oldCli+'.jsonl'))))
$last=($oldLines[-1]|ConvertFrom-Json).uuid
$newMessage=@{type='user';uuid=[guid]::NewGuid().ToString();parentUuid=$last;sessionId=$newCli;cwd=$folder;timestamp='2026-01-01T00:00:02Z';message=@{role='user';content='Synthetic continuation'}}
$newPath=Join-Path $projects ('synthetic\'+$newCli+'.jsonl')
[IO.File]::WriteAllText($newPath,(($oldLines -join "`n")+"`n"+[Text.Encoding]::UTF8.GetString((ConvertTo-CHBytes $newMessage))+"`n"),[Text.UTF8Encoding]::new($false))
$rollover=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$parent))|ConvertFrom-Json
$parentRow=@($rollover.rows|Where-Object id -eq ('local_'+$parent))[0]
Check ($parentRow.status -eq 'Ready' -and $parentRow.stats.messages -eq 3 -and $parentRow.sources.Count -eq 2) 'CLI rollover combines prior and current transcripts and removes copied messages'
[IO.File]::WriteAllText((Join-Path $profileDirectory ('deleted_'+$oldCli)),'')
$deleted=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$parent))|ConvertFrom-Json
Check (@($deleted.rows|Where-Object id -eq ('local_'+$parent))[0].reason -match 'deletion marker') 'Tombstoned continuation history is never imported'
Remove-Item -LiteralPath (Join-Path $profileDirectory ('deleted_'+$oldCli))
Remove-Item -LiteralPath $newPath
$missing=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$parent))|ConvertFrom-Json
Check (@($missing.rows|Where-Object id -eq ('local_'+$parent))[0].reason -match 'missing') 'Missing continuation history produces a clear skip reason'
$unrelatedState=Join-Path $fixtureRoot 'UnrelatedDocuments'
[IO.Directory]::CreateDirectory($unrelatedState)|Out-Null
[IO.File]::WriteAllText((Join-Path $unrelatedState 'keep.txt'),'Keep permissions')
$beforeAcl=(Get-Acl -LiteralPath $unrelatedState).Sddl
$unsafeArgs=@{}+$argsBase;$unsafeArgs.StateRoot=$unrelatedState;$failure=''
try{& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @unsafeArgs -Scope Session -ScopeSession ('local_'+$child)|Out-Null}catch{$failure=$_.Exception.Message}
Check ($failure -match 'new, empty' -and (Get-Acl -LiteralPath $unrelatedState).Sddl -eq $beforeAcl) 'Unrelated populated staging folders retain their permissions'
[IO.File]::WriteAllText((Join-Path $profileDirectory ('deleted_'+$child)),'')
$deletedCard=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$child))|ConvertFrom-Json
Check ($deletedCard.rows[0].reason -match 'Desktop session has a deletion marker') 'Desktop deletion markers are respected'
Remove-Item -LiteralPath (Join-Path $profileDirectory ('deleted_'+$child))
$childPath=Join-Path $profileDirectory ('local_'+$child+'.json')
$childCard=[IO.File]::ReadAllText($childPath)|ConvertFrom-Json;$childCard.title='Synthetic '+[char]0x00e9+' '+[char]0x65e5
[IO.File]::WriteAllBytes($childPath,(ConvertTo-CHBytes $childCard))
$unicodePlan=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$child))|ConvertFrom-Json
Check ($unicodePlan.rows[0].title -ceq $childCard.title) 'Unicode titles survive the Node/PowerShell boundary'
$removedWorktree=Join-Path $fixtureRoot 'ChildWorktree'
Remove-Item -LiteralPath $removedWorktree
$noWorktree=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$child))|ConvertFrom-Json
Check ($noWorktree.rows[0].status -eq 'Skipped' -and $noWorktree.rows[0].reason -match 'DestinationFolder') 'Removed worktrees are identified before import'
$mapped=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @argsBase -Scope Session -ScopeSession ('local_'+$child) -DestinationFolder $folder)|ConvertFrom-Json
Check ($mapped.rows[0].status -eq 'Ready' -and $mapped.rows[0].cwd -eq $folder -and $mapped.rows[0].sourceCwd -eq $removedWorktree) 'Explicit destination mapping retains original working-directory metadata'
$childCli=[string]$childCard.cliSessionId
foreach($markerId in @($child,$childCli)){
    $deletion=Join-Path $profileDirectory ('deleted_'+$markerId)
    [IO.File]::WriteAllText($deletion,'');$failure=''
    try{& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $mapped.planPath -StateRoot $private -CodexHome $argsBase.CodexHome -AsJson|Out-Null}catch{$failure=$_.Exception.Message}
    Remove-Item -LiteralPath $deletion
    Check ($failure -match 'deletion markers changed after preview') 'Deletion markers added after preview invalidate the import before submission'
}
$duplicateDir=Join-Path $projects 'duplicate'
[IO.Directory]::CreateDirectory($duplicateDir)|Out-Null
$duplicatePath=Join-Path $duplicateDir ($childCli+'.jsonl')
[IO.File]::WriteAllBytes($duplicatePath,[IO.File]::ReadAllBytes((Join-Path $projects ('synthetic\'+$childCli+'.jsonl'))));$failure=''
try{& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $mapped.planPath -StateRoot $private -CodexHome $argsBase.CodexHome -AsJson|Out-Null}catch{$failure=$_.Exception.Message}
Remove-Item -LiteralPath $duplicatePath
Check ($failure -match 'transcript selection changed after preview') 'New ambiguous transcript copies invalidate the import before submission'
Push-Location $fixtureRoot
try{
    $relativeArgs=@{}+$argsBase
    $relativeArgs.ConfigPath='.\profiles.json';$relativeArgs.StateRoot='.\relative-state';$relativeArgs.CodexHome='.\alternate-codex'
    $relativePlan=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @relativeArgs -Scope Session -ScopeSession ('local_'+$child) -DestinationFolder '.\SampleProject')|ConvertFrom-Json
    Check ($relativePlan.codexHome -eq (Join-Path $fixtureRoot 'alternate-codex') -and $relativePlan.stateRoot -eq (Join-Path $fixtureRoot 'relative-state') -and $relativePlan.rows[0].status -eq 'Ready') 'Relative paths resolve against the PowerShell location, not the process directory'
}finally{Pop-Location}
# Relocate the distributable files, runtime, profile and project paths. No real
# account data is read and this preview must not initialize a Codex home.
$portableRoot=Join-Path $fixtureRoot ('Different PC '+[char]0x65e5+' '+[char]0x00e9)
$checkout=Join-Path $portableRoot 'Checkout [portable] & 100% with spaces'
foreach($relative in @('Import-ClaudeToCodex.ps1','Sync-ClaudeHistory.ps1','tools\Import-ClaudeToCodex.mjs','lib\claude-to-codex.mjs','lib\codex-app-server.mjs')){
    $destination=Join-Path $checkout $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
    [IO.File]::Copy((Join-Path $PSScriptRoot $relative),$destination)
}
[IO.File]::Copy($config,(Join-Path $checkout 'profiles.json'))
$runtime=Join-Path $portableRoot 'Custom runtime [standalone] & 100%\node.exe'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($runtime))|Out-Null
$actualNode=(& node -p 'process.execPath'|Out-String).Trim()
[IO.File]::Copy($actualNode,$runtime)
$savedEnvironment=@{USERPROFILE=$env:USERPROFILE;LOCALAPPDATA=$env:LOCALAPPDATA;APPDATA=$env:APPDATA;CODEX_HOME=$env:CODEX_HOME}
Push-Location $fixtureRoot
try{
    $env:USERPROFILE=Join-Path $portableRoot 'Another User'
    $env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local'
    $env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
    [Environment]::SetEnvironmentVariable('CODEX_HOME',$null,'Process')
    $portableArgs=@{Source='Source';Scope='Session';ScopeSession=('local_'+$child);DestinationFolder=$folder;NodeExecutable=$runtime;AsJson=$true}
    $portablePlan=(& (Join-Path $checkout 'Import-ClaudeToCodex.ps1') @portableArgs)|ConvertFrom-Json
    Check ($portablePlan.rows[0].status -eq 'Ready') 'A relocated checkout and standalone runtime work with spaces and Unicode from another current directory'
    Check ($portablePlan.codexHome -eq (Join-Path $env:USERPROFILE '.codex')) 'Default Codex home follows the current Windows profile'
    Check ($portablePlan.stateRoot.StartsWith($env:LOCALAPPDATA+'\',[StringComparison]::OrdinalIgnoreCase)) 'Private import state follows the current Windows LocalAppData'
    Check (-not [IO.Directory]::Exists($portablePlan.codexHome)) 'Portable preview does not initialize destination history'
    $env:CODEX_HOME=Join-Path $portableRoot 'Custom Codex home'
    $customPlan=(& (Join-Path $checkout 'Import-ClaudeToCodex.ps1') @portableArgs)|ConvertFrom-Json
    $env:CODEX_HOME+='\'
    $trailingPlan=(& (Join-Path $checkout 'Import-ClaudeToCodex.ps1') @portableArgs)|ConvertFrom-Json
    Check ($customPlan.codexHome -eq $env:CODEX_HOME.TrimEnd('\')) 'CODEX_HOME overrides the profile default'
    Check ($customPlan.stateRoot -eq $trailingPlan.stateRoot -and $customPlan.rows[0].snapshotPath -eq $trailingPlan.rows[0].snapshotPath) 'A trailing home separator keeps the same journal and snapshot identity'
    $wrapperRuntime=Join-Path $portableRoot 'Command wrapper.cmd'
    [IO.File]::WriteAllText($wrapperRuntime,"@echo off`r`necho 22.0.0`r`n")
    $wrapperArgs=@{}+$portableArgs;$wrapperArgs.NodeExecutable=$wrapperRuntime;$wrapperArgs.StateRoot=Join-Path $portableRoot 'Must stay absent'
    $failure=''
    try{& (Join-Path $checkout 'Import-ClaudeToCodex.ps1') @wrapperArgs|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'native .exe' -and -not [IO.Directory]::Exists($wrapperArgs.StateRoot)) 'Command wrappers are rejected before execution or private staging'
    if($env:CLAUDESYNC_NATIVE_IMPORT_TEST){
        $portableImport=(& (Join-Path $checkout 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $portablePlan.planPath -StateRoot $portablePlan.stateRoot -CodexHome $portablePlan.codexHome -NodeExecutable $runtime -AsJson)|ConvertFrom-Json
        Check ($portableImport.rows[0].status -eq 'Imported' -and $portableImport.rows[0].target -and [IO.File]::Exists($portableImport.receiptPath)) 'Relocated checkout and runtime import into a different isolated Windows profile'
    }
}finally{
    Pop-Location
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
}
if($env:CLAUDESYNC_NATIVE_IMPORT_TEST){
    Protect-CHDirectory $argsBase.CodexHome
    $imported=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $mapped.planPath -StateRoot $private -CodexHome $argsBase.CodexHome -AsJson)|ConvertFrom-Json
    Check ($imported.rows[0].status -eq 'Imported' -and $imported.rows[0].target -and [IO.File]::Exists($imported.receiptPath)) 'PowerShell-to-native end-to-end import creates a mapped synthetic thread and receipt'
    Protect-CHDirectory $relativePlan.codexHome
    Push-Location $fixtureRoot
    try{
        $relativePath='.\relative-state\plans\'+[IO.Path]::GetFileName($relativePlan.planPath)
        $relativeImport=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') -Mode Import -Plan $relativePath -StateRoot '.\relative-state' -CodexHome '.\alternate-codex' -AsJson)|ConvertFrom-Json
        Check ($relativeImport.rows[0].status -eq 'Imported') 'Native import resolves a relative saved-plan path from the current PowerShell location'
    }finally{Pop-Location}
}
Write-Output "$script:Count import-selection assertions passed. Synthetic fixtures: $fixtureRoot"
