#requires -Version 5.1
[CmdletBinding()]
param([string]$FixtureDirectory=(Join-Path $env:TEMP 'ClaudeSync-scope-tests'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
$root=Join-Path $FixtureDirectory ([guid]::NewGuid().ToString('N'))
Protect-CHDirectory $root
$script:Assertions=0; $script:Case=0
function Check($Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "FAILED: $Message" }
}
function Throws([scriptblock]$Work, [string]$Pattern, [string]$Message) {
    $errorText=''; try { & $Work | Out-Null } catch { $errorText=$_.Exception.Message }
    Check ($errorText -match $Pattern) $Message
}
function Fixture {
    $script:Case++
    $caseRoot=Join-Path $root $script:Case
    $sessions=Join-Path $caseRoot 'sessions'; $projects=Join-Path $caseRoot 'projects'
    $profiles=@(@{Name='A';Path='11111111-1111-4111-8111-111111111111\22222222-2222-4222-8222-222222222222'},@{Name='B';Path='33333333-3333-4333-8333-333333333333\44444444-4444-4444-8444-444444444444'})
    foreach($path in @((Join-Path $sessions $profiles[0].Path),(Join-Path $sessions $profiles[1].Path),(Join-Path $projects 'project'))) { [IO.Directory]::CreateDirectory($path)|Out-Null }
    $config=Join-Path $caseRoot 'profiles.json'
    [IO.File]::WriteAllBytes($config,(ConvertTo-CHBytes @{FormatVersion=1;SessionsRoot=$sessions;ProjectsRoot=$projects;Profiles=$profiles}))
    Get-CHConfig $config
}
function Card($Context,[string]$Profile,[string]$Id,[string]$Folder,[string]$Title,[bool]$Archived=$false,[string]$Parent='') {
    $record=@{sessionId=('local_'+$Id);cliSessionId=$Id;cwd=$Folder;originCwd=$Folder;title=$Title;isArchived=$Archived;createdAt=1;lastActivityAt=1}
    if($Parent){$record.spawnedFrom=@{sessionId=('local_'+$Parent);sideSession=$true}}
    $profilePath=(Resolve-CHProfile $Context.Config.Profiles $Profile).FullPath
    $path=Join-Path $profilePath ('local_'+$Id+'.json')
    [IO.File]::WriteAllBytes($path,(ConvertTo-CHBytes $record))
    [IO.File]::WriteAllText((Join-Path $Context.Config.ProjectsRoot ('project\'+$Id+'.jsonl')),'{"fixture":"transcript"}')
    $path
}
function Apply($Context,$Plan) {
    $result=@(Invoke-CHApply $Context $Plan $true 'A')
    (@($result|Where-Object {$_ -is [string] -and $_.StartsWith('Backup: ')})[0]).Substring(8)
}
$parent='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$child='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$grandchild='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$unrelated='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$nested='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
$onlyTarget='ffffffff-ffff-4fff-8fff-ffffffffffff'
$ctx=Fixture
$a=Card $ctx A $parent 'C:\Projects\VRGame' 'Parent complete' $true
Card $ctx A $child 'C:\Worktrees\Child' 'Child complete' $true $parent|Out-Null
Card $ctx A $grandchild 'C:\Worktrees\Grandchild' 'Grandchild complete' $true $child|Out-Null
Card $ctx A $nested 'C:\Projects\VRGame\Assets' 'Nested folder' $true|Out-Null
Card $ctx A $unrelated 'C:\Projects\VRGame-other' 'Unrelated source'|Out-Null
$b=Card $ctx B $parent 'C:\Projects\VRGame' 'Old parent'
Card $ctx B $child 'C:\Worktrees\Child' 'Old child' $false $parent|Out-Null
$untouched=Card $ctx B $unrelated 'C:\Projects\VRGame-other' 'Keep target' $true
$targetOnly=Card $ctx B $onlyTarget 'C:\Other' 'Target only' $true
$indexPath=Join-Path $ctx.Config.Profiles[1].FullPath 'archived-sessions.idx'
[IO.File]::WriteAllBytes($indexPath,(ConvertTo-CHBytes @{v=1;archived=@(('local_'+$unrelated),('local_'+$onlyTarget))}))
Protect-CHDirectory $ctx.StateRoot
$statePath=Join-Path $ctx.StateRoot 'baseline.json'
$baselineEntries=@{}; $baselineEntries['local_'+$unrelated+'.json']='unchanged-baseline'
[IO.File]::WriteAllBytes($statePath,(ConvertTo-CHBytes @{FormatVersion=1;Signature=$ctx.Signature;Entries=$baselineEntries}))
$beforeOther=Get-CHFileHash $untouched; $beforeTargetOnly=Get-CHFileHash $targetOnly; $beforeParent=Get-CHFileHash $b
$folderPlan=New-CHPlan $ctx -Scope Folder -ScopeFolder 'c:/projects/vrgame/'
Check ($folderPlan.Scope.Count -eq 4 -and $folderPlan.Report.Count -eq 4) 'Folder scope includes subfolders and descendants in other worktrees, excluding sibling path prefixes'
Check (@(Get-CHPreviewRows $ctx $folderPlan).Count -eq 4) 'Scoped preview omits unrelated destination and source sessions'
$sessionPlan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$parent)
Check ($sessionPlan.Scope.Count -eq 3 -and -not $sessionPlan.SelectedFiles.ContainsKey('local_'+$nested+'.json')) 'Session scope includes its full descendant tree, not other sessions in the same folder'
$childPlan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$child)
Check ($childPlan.Scope.Count -eq 2 -and -not $childPlan.SelectedFiles.ContainsKey('local_'+$parent+'.json')) 'Selecting a child includes its own descendants without importing its ancestor'
$leafPlan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$nested)
Check ($leafPlan.Scope.Count -eq 1) 'Selecting a leaf syncs that session alone'
$choices=Get-CHScopeChoices $ctx
Check (@($choices.Folders|Where-Object Path -eq 'C:\Projects\VRGame').Count -eq 1 -and @($choices.Sessions|Where-Object Id -eq ('local_'+$parent)).Count -eq 1) 'Source folder and session choices use actual metadata'
Check ((New-CHPlan $ctx -Direction Both).Scope.Count -eq 6) 'All-history two-way scope counts the union of both accounts'
$injected=New-CHOperation $ctx desktop ($ctx.Config.Profiles[1].Path+'\local_'+$unrelated+'.json') ([IO.File]::ReadAllBytes($untouched))
$sessionPlan.Operations.Add($injected)
Throws { Assert-CHWriteAccess $ctx $sessionPlan $true A } 'outside the selected scope' 'Write guard rejects an injected unrelated card'
# Unrelated activity does not invalidate a scoped snapshot.
Card $ctx A $unrelated 'C:\Projects\VRGame-other' 'Unrelated changed while planning'|Out-Null
Assert-CHSnapshot $ctx $folderPlan $true A
Check $true 'Unrelated history edits do not invalidate a scoped plan'
$sourceHash=Get-CHFileHash $a
$backup=Apply $ctx $folderPlan
Check ((Get-CHFileHash $untouched) -eq $beforeOther -and (Get-CHFileHash $targetOnly) -eq $beforeTargetOnly) 'Scoped apply leaves unrelated destination cards byte-for-byte unchanged'
Check ((Get-CHFileHash $a) -eq $sourceHash) 'Scoped apply does not write the open source'
$index=[IO.File]::ReadAllText($indexPath)|ConvertFrom-Json
Check (@($index.archived).Count -eq 6 -and $index.archived -contains ('local_'+$unrelated) -and $index.archived -contains ('local_'+$onlyTarget)) 'Archive-index updates preserve unrelated entries'
$baseline=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
Check ($baseline.Entries.('local_'+$unrelated+'.json') -eq 'unchanged-baseline') 'Scoped reconciliation preserves unrelated baseline entries'
$receipt=[IO.File]::ReadAllText((Join-Path $backup 'manifest.json'))|ConvertFrom-Json
Check ($receipt.Scope.Mode -eq 'Folder' -and $receipt.Scope.Count -eq 4) 'Backup receipt records the exact selected scope'
Check ((New-CHPlan $ctx -Scope Folder -ScopeFolder 'C:\Projects\VRGame').Operations.Count -eq 0) 'Repeating a folder sync is idempotent'
function Assert-CHStopped {} # Undo below operates only on generated fixtures.
Invoke-CHUndo $ctx (Get-CHUndo $ctx $backup)|Out-Null
Check ((Get-CHFileHash $b) -eq $beforeParent -and (Get-CHFileHash $untouched) -eq $beforeOther) 'Scoped Undo restores selected cards without changing unrelated cards'
Throws {New-CHPlan $ctx -Scope Folder -ScopeFolder 'C:\Projects\VRGame' -Direction Both} 'one-way' 'Scoped two-way sync is rejected'
Throws {New-CHPlan $ctx -Scope Folder -ScopeFolder 'VRGame'} 'full source folder' 'Folder basenames cannot ambiguously select projects'
Throws {New-CHPlan $ctx -Scope Folder -ScopeFolder 'C:\Missing'} 'No source sessions' 'An empty folder selection fails instead of falling back to all history'
Throws {New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$onlyTarget)} 'no longer in the source' 'Destination-only session cannot be chosen as a source root'
Throws {New-CHPlan $ctx -Scope All -ScopeFolder 'C:\Projects\VRGame'} 'Choose Folder' 'Conflicting scope parameters are rejected'
$ctx=Fixture
Card $ctx A $parent '/home/VRGame' 'Remote upper-case folder'|Out-Null
Card $ctx A $unrelated '/home/vrgame' 'Remote lower-case folder'|Out-Null
$plan=New-CHPlan $ctx -Scope Folder -ScopeFolder '/home/VRGame'
Check ($plan.Scope.Count -eq 1 -and $plan.SelectedFiles.ContainsKey('local_'+$parent+'.json')) 'Unix folder matching preserves case distinctions'
Check ((Get-CHScopeChoices $ctx).Folders.Count -eq 2) 'Folder choices preserve distinct case-sensitive source folders'
$ctx=Fixture
Card $ctx A $parent 'C:\VRGame' 'Parent'|Out-Null
$detached=Card $ctx A $child 'C:\Other' 'Detached child' $false $parent
$card=[IO.File]::ReadAllText($detached)|ConvertFrom-Json
$card|Add-Member -NotePropertyName lineageDetached -NotePropertyValue $true
[IO.File]::WriteAllBytes($detached,(ConvertTo-CHBytes $card))
Check ((New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$parent)).Scope.Count -eq 1) 'Explicitly detached sessions do not rejoin a selected parent tree'
$ctx=Fixture
Card $ctx A $parent 'C:\Project' 'Parent'|Out-Null
Card $ctx A $child 'C:\Project' 'Child' $false $parent|Out-Null
$plan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$child)
Check ($plan.Scope.Count -eq 1 -and @($plan.Report|Where-Object Action -eq Skipped).Count -eq 1 -and @($plan.Operations|Where-Object Area -eq desktop).Count -eq 0) 'A child with a missing destination parent is skipped without silently importing ancestors'
Card $ctx B $parent 'C:\Project' 'Parent'|Out-Null
$plan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$child)
Check (@($plan.Report|Where-Object Action -eq Add).Count -eq 1) 'A child can sync alone when its matching parent already exists'
Card $ctx B $parent 'C:\Project' 'Changed required ancestor'|Out-Null
Throws {Assert-CHSnapshot $ctx $plan $true A} 'changed during planning' 'Changes to unselected but required ancestors invalidate the plan'
$plan=New-CHPlan $ctx -Scope Session -ScopeSession ('local_'+$child)
Card $ctx A $grandchild 'C:\Other' 'New descendant' $false $child|Out-Null
Throws {Assert-CHSnapshot $ctx $plan $true A} 'tree changed' 'New descendants appearing during planning require a fresh preview'

# Exercise the public bridge, including its file transfer and armed-scope guard.
$engine=if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'}
$bridge=Join-Path $PSScriptRoot 'mods\account-history-sync\scripts\HistorySync-Bridge.ps1'
function Bridge([string]$Action,[string]$Mode='All',[string]$Selection='', [switch]$Keep) {
    $argv=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$bridge,'-Action',$Action,'-ConfigPath',$ctx.ConfigPath,'-SourceProfile','A','-TargetProfile','B','-OwnerSession','scope-test','-SessionId',$parent,'-Scope',$Mode)
    if($Mode -eq 'Session'){$argv+=@('-ScopeSession',$Selection)}
    if($Mode -eq 'Folder'){$argv+=@('-ScopeFolder',$Selection)}
    if($Action -eq 'Choices'){$argv+='-PreviewFile'}
    if($Keep){$argv+='-KeepLease'}
    $output=@(& $engine @argv)
    $result=($output -join "`n")|ConvertFrom-Json
    Check (($LASTEXITCODE -eq 0) -eq [bool]$result.Ok) 'Bridge process status agrees with its JSON result'
    $result
}
$answer=Bridge Choices
Check ($answer.Ok -and $answer.PreviewPath -and $answer.PreviewBytes -gt 0) 'Scope choices transfer through a private file rather than bounded stdout'
$choices=[IO.File]::ReadAllText($answer.PreviewPath)|ConvertFrom-Json
Check ($choices.Action -eq 'Choices' -and $choices.Sessions.Count -eq 3 -and $choices.Folders.Count -eq 2) 'Bridge choice file contains source titles, IDs and original folders'
$answer=Bridge Plan Session ('local_'+$child)
Check ($answer.Ok -and $answer.Scope.Count -eq 2 -and $answer.Rows.Count -eq 2 -and $answer.Additions -eq 2) 'Bridge preview enforces session-tree scope'
$answer=Bridge Arm Session ('local_'+$child)
Check $answer.Ok 'Auto-sync can arm for a specific session tree'
$answer=Bridge Sync All '' -Keep
Check (-not $answer.Ok -and $answer.Error -match 'scope') 'An armed session-tree lease cannot silently expand into all-history sync'
Check (-not [IO.File]::Exists((Join-Path $ctx.Config.Profiles[1].FullPath ('local_'+$child+'.json')))) 'Scope mismatch is rejected before writing history'
$answer=Bridge Sync Session ('local_'+$child) -Keep
Check ($answer.Ok -and $answer.Additions -eq 2 -and $answer.Scope.Mode -eq 'Session') 'Bridge manual/automatic apply writes only the armed session tree'
$answer=Bridge Release
Check $answer.Ok 'Scoped controller lease releases normally'
$cliOutput=@(& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1') -Mode Plan -ConfigPath $ctx.ConfigPath -ProfileA A -ProfileB B -Scope Session -ScopeSession ('local_'+$child))
Check ($LASTEXITCODE -eq 0 -and @($cliOutput|Where-Object {$_ -like 'Scope: Session. 2 source sessions selected.*'}).Count -eq 1) 'Standalone Plan forwards scope arguments and reports the selected source count'
Write-Output "PASS: $script:Assertions assertions. Fixtures: $root"
