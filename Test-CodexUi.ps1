#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
& (Join-Path $PSScriptRoot 'Build-Mod.ps1')|Out-Null
$fixture=Join-Path $env:TEMP ('ClaudeSync-codex-ui-'+[guid]::NewGuid().ToString('N'))
Protect-CHDirectory $fixture
$savedEnv=@{USERPROFILE=$env:USERPROFILE;APPDATA=$env:APPDATA;LOCALAPPDATA=$env:LOCALAPPDATA;CODEX_HOME=$env:CODEX_HOME}
$script:Count=0
function Check($ok,$message){$script:Count++;if(-not $ok){throw "FAILED: $message"}}
try {
    $env:USERPROFILE=Join-Path $fixture ('Windows User '+[char]0x5B57)
    $env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local'
    $env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
    $env:CODEX_HOME=Join-Path $fixture 'Codex home'
    $sessions=Join-Path $fixture 'Sessions';$projects=Join-Path $fixture 'Projects';$folder=Join-Path $fixture 'Sample project'
    $source='11111111-1111-4111-8111-111111111111\22222222-2222-4222-8222-222222222222'
    $other='33333333-3333-4333-8333-333333333333\44444444-4444-4444-8444-444444444444'
    foreach($dir in @((Join-Path $sessions $source),(Join-Path $sessions $other),(Join-Path $projects 'synthetic'),$folder)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    $config=Join-Path $fixture 'profiles.json'
    [IO.File]::WriteAllBytes($config,(ConvertTo-CHBytes @{FormatVersion=2;SessionsRoot=$sessions;ProjectsRoot=$projects;Profiles=@()}))
    $parent='local_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$child='local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    foreach($id in @($parent,$child)){
        $cli=[guid]::NewGuid().ToString();$first=[guid]::NewGuid().ToString();$second=[guid]::NewGuid().ToString()
        $cwd=if($id -eq $parent){$folder}else{Join-Path $fixture 'Child worktree'}
        [IO.Directory]::CreateDirectory($cwd)|Out-Null
        $card=@{sessionId=$id;cliSessionId=$cli;cwd=$cwd;title=if($id -eq $parent){'Release planning'}else{'Child research'};isArchived=($id -eq $child)}
        if($id -eq $child){$card.spawnedFrom=@{sessionId=$parent}}
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $sessions $source) ($id+'.json')),(ConvertTo-CHBytes $card))
        $lines=@(@{type='user';uuid=$first;parentUuid=$null;sessionId=$cli;cwd=$cwd;timestamp='2026-01-01T00:00:00Z';message=@{role='user';content='Synthetic UI question'}},@{type='assistant';uuid=$second;parentUuid=$first;sessionId=$cli;cwd=$cwd;timestamp='2026-01-01T00:00:01Z';message=@{role='assistant';content='Synthetic UI answer'}})|ForEach-Object{[Text.Encoding]::UTF8.GetString((ConvertTo-CHBytes $_))}
        [IO.File]::WriteAllText((Join-Path $projects ('synthetic\'+$cli+'.jsonl')),(($lines -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
    }
    $bridge=Join-Path $PSScriptRoot 'mods\account-history-sync\scripts\ClaudeCodex-Bridge.ps1'
    function Call-Ui([hashtable]$Arguments){
        $Arguments.ConfigPath=$config
        $raw=(& $bridge @Arguments)-join "`n"
        $envelope=$raw|ConvertFrom-Json
        if(-not $envelope.Ok){return @{Envelope=$envelope;Data=$null}}
        Check ($raw.Length -lt 1024 -and $envelope.ResultBytes -le 4194304) 'Large UI results travel through a bounded private file'
        $bytes=[IO.File]::ReadAllBytes($envelope.ResultPath)
        Check ($bytes.Length -eq $envelope.ResultBytes) 'Transfer byte count matches the UTF-8 result file'
        @{Envelope=$envelope;Data=([Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json)}
    }
    $profiles=Call-Ui @{Action='Profiles'}
    Check ($profiles.Data.profiles.Count -eq 2) 'Profiles discovers accounts without requiring an account pair'
    $childInfo=[Diagnostics.ProcessStartInfo]::new()
    $childInfo.FileName=Join-Path $PSHOME 'powershell.exe'
    $childInfo.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Profiles -ConfigPath "{1}"' -f $bridge,$config
    $childInfo.UseShellExecute=$false
    $childInfo.RedirectStandardOutput=$true
    $childInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $bridgeProcess=[Diagnostics.Process]::Start($childInfo)
    try{
        $childEnvelope=$bridgeProcess.StandardOutput.ReadToEnd()|ConvertFrom-Json
        $bridgeProcess.WaitForExit()
        Check ($bridgeProcess.ExitCode -eq 0 -and $childEnvelope.Ok -and
            $childEnvelope.ResultPath.StartsWith($env:LOCALAPPDATA,[StringComparison]::Ordinal) -and
            [IO.File]::Exists($childEnvelope.ResultPath)) 'Child-process result paths round-trip through UTF-8 for non-ASCII Windows profiles'
    }finally{$bridgeProcess.Dispose()}
    $choices=Call-Ui @{Action='Choices';SourceProfile=$source}
    Check ($choices.Data.sessions.Count -eq 2) 'Choices belongs to the explicitly selected source'
    $argsBase=@{SourceProfile=$source;Scope='Session';ScopeSession=$parent;DestinationFolder=$folder}
    $p=@{}+$argsBase;$p.Action='Plan';$plan=Call-Ui $p
    Check ($plan.Envelope.Ok) ('Plan helper failed: '+$plan.Envelope.Error)
    Check ($plan.Data.rows.Count -eq 2 -and @($plan.Data.rows|Where-Object status -eq 'Ready').Count -eq 2) ('Parent preview includes children in a separate worktree: '+($plan.Data.rows|Select-Object title,status,reason|ConvertTo-Json -Compress))
    Check (@($plan.Data.rows|Where-Object archived).Count -eq 1) 'Preview retains archive state'
    Check (-not [IO.Directory]::Exists($env:CODEX_HOME)) 'UI preview does not initialize Codex'
    $resultRoot=Join-Path $env:LOCALAPPDATA 'ClaudeHistorySync\codex-ui'
    $expired=Join-Path $resultRoot ('0'*32+'.json');$unrelated=Join-Path $resultRoot 'keep.json'
    [IO.File]::WriteAllText($expired,'Disposable old transfer');[IO.File]::WriteAllText($unrelated,'Keep unrelated file')
    [IO.File]::SetLastWriteTimeUtc($expired,[datetime]::UtcNow.AddDays(-2));[IO.File]::SetLastWriteTimeUtc($unrelated,[datetime]::UtcNow.AddDays(-2))
    Check (-not ($plan.Data.rows[0].PSObject.Properties.Name -contains 'sources')) 'UI summary omits raw source paths and transcript contents'
    $r=@{}+$argsBase;$r.Action='Resume';$r.PlanPath=$plan.Data.planPath
    $resume=Call-Ui $r
    Check ($resume.Data.planPath -eq $plan.Data.planPath -and $resume.Data.rows.Count -eq 2) 'Resume reads the same frozen plan without importing'
    Check (-not [IO.File]::Exists($expired) -and [IO.File]::Exists($unrelated) -and [IO.File]::Exists($plan.Data.planPath)) 'Only expired generated display files are removed; saved plans and other files remain'
    $folderArgs=@{Action='Plan';SourceProfile=$source;Scope='Folder';ScopeFolder=$folder;DestinationFolder=$folder}
    $folderPlan=Call-Ui $folderArgs
    Check ($folderPlan.Data.rows.Count -eq 2) 'Folder preview includes descendant sessions in other worktrees'
    $folderResume=@{}+$folderArgs;$folderResume.Action='Resume';$folderResume.PlanPath=$folderPlan.Data.planPath
    Check ((Call-Ui $folderResume).Data.rows.Count -eq 2) 'Folder preview can be restored with the same selection'
    $rootPlan=[IO.File]::ReadAllText($plan.Data.planPath)|ConvertFrom-Json
    $rootPlan.codexHome=[IO.Path]::GetPathRoot($fixture)
    $rootPlanFile=Join-Path ([IO.Path]::GetDirectoryName($plan.Data.planPath)) ('root-'+[guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllBytes($rootPlanFile,(ConvertTo-CHBytes $rootPlan))
    $rootResume=@{}+$r;$rootResume.PlanPath=$rootPlanFile;$rootResume.CodexHome=$rootPlan.codexHome
    Check ((Call-Ui $rootResume).Envelope.Ok) 'Drive-root destination comparison works in read-only Resume; no root import is attempted'
    $wrongFolder=@{}+$folderResume;$wrongFolder.Action='Import';$wrongFolder.ScopeFolder=Join-Path $fixture 'Wrong folder'
    Check (-not (Call-Ui $wrongFolder).Envelope.Ok) 'Changed source folder cannot import an earlier preview'
    foreach($key in @('SourceProfile','ScopeSession','DestinationFolder','CodexHome','NewRevision')){
        $bad=@{}+$r;$bad.Action='Import'
        $bad[$key]=switch($key){'SourceProfile'{$other};'ScopeSession'{$child};'NewRevision'{$true};default{Join-Path $fixture 'Different'}}
        $rejected=Call-Ui $bad
        Check (-not $rejected.Envelope.Ok -and -not [IO.Directory]::Exists($env:CODEX_HOME)) 'Changed source, selection, mapping or revision cannot import an earlier preview'
    }
    $bad=@{}+$r;$bad.PlanPath=$config
    Check (-not (Call-Ui $bad).Envelope.Ok) 'Saved plans outside private import storage are rejected'
    if($env:CLAUDESYNC_NATIVE_IMPORT_TEST){
        $i=@{}+$r;$i.Action='Import';$import=Call-Ui $i
        Check (@($import.Data.rows|Where-Object status -eq 'Imported').Count -eq 2 -and [IO.File]::Exists($import.Data.receiptPath)) 'Packaged UI helper imports the exact synthetic parent tree'
        Check (@($import.Data.rows|Where-Object archived).Count -eq 1) 'Import results retain archive state from the saved preview'
        $again=Call-Ui $i
        Check (@($again.Data.rows|Where-Object status -eq 'Unchanged').Count -eq 2) 'Explicit replay reconciles the same saved plan without duplicate imports'
        $folderImport=@{}+$folderResume;$folderImport.Action='Import'
        Check (@((Call-Ui $folderImport).Data.rows|Where-Object status -eq 'Unchanged').Count -eq 2) 'Folder import uses the same source identities as a previously imported parent tree'
    }
    Write-Output "$script:Count Codex UI bridge assertions passed. Synthetic fixtures: $fixture"
}finally{foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}}
