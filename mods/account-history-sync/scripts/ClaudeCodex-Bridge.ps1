#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Profiles','Choices','Plan','Resume','Import')][string]$Action='Profiles',
    [string]$ConfigPath,[string]$SourceProfile,
    [ValidateSet('Folder','Session')][string]$Scope='Folder',
    [string]$ScopeFolder,[string]$ScopeSession,[string]$DestinationFolder,
    [string]$CodexHome,[string]$NodeExecutable,[string]$CodexExecutable,[string]$PlanPath,
    [switch]$NewRevision
)
$ErrorActionPreference='Stop'
$uiRequest=@{Action=$Action;Config=$ConfigPath;Source=$SourceProfile;Scope=$Scope;Folder=$ScopeFolder;Session=$ScopeSession;DestinationFolder=$DestinationFolder;CodexHome=$CodexHome;NodeExecutable=$NodeExecutable;CodexExecutable=$CodexExecutable;Plan=$PlanPath;NewRevision=[bool]$NewRevision}
$previousOutputEncoding=[Console]::OutputEncoding
try {
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    . (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
    $dataRoot=Join-Path $env:LOCALAPPDATA 'ClaudeHistorySync'
    [void](Assert-CHPath $dataRoot $dataRoot)
    if(-not $uiRequest.Config){
        Protect-CHDirectory $dataRoot
        $uiRequest.Config=Join-Path $dataRoot 'profiles.json'
        if(-not [IO.File]::Exists($uiRequest.Config)){
            try {
                $stream=[IO.File]::Open($uiRequest.Config,'CreateNew','Write','None')
                try{$bytes=ConvertTo-CHBytes @{FormatVersion=2;SessionsRoot='Auto';ProjectsRoot='%USERPROFILE%\.claude\projects';Profiles=@()};$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
            }catch{if(-not [IO.File]::Exists($uiRequest.Config)){throw}}
        }
    }
    $config=[IO.Path]::GetFullPath($uiRequest.Config)
    $context=Get-CHConfig $config '' '' $false
    $invoke=@{ConfigPath=$config;AsJson=$true}
    if($uiRequest.Action -ne 'Profiles'){
        if($uiRequest.Source -notmatch ('^'+$script:GuidPattern+'\\'+$script:GuidPattern+'$')){throw 'Choose an available Claude source account.'}
        $profile=Resolve-CHProfile $context.Catalog $uiRequest.Source
        foreach($key in @('DestinationFolder','CodexHome','NodeExecutable','CodexExecutable')){
            if($uiRequest[$key]){
                if($uiRequest[$key] -notmatch '^[a-zA-Z]:[\\/]|^\\\\'){throw "$key must be a full Windows path, or left blank for automatic discovery."}
                $invoke[$key]=$uiRequest[$key]
            }
        }
    }
    $saved=$null
    if($uiRequest.Action -in @('Resume','Import')){
        $path=Assert-CHPath $uiRequest.Plan (Join-Path $dataRoot 'codex-imports')
        $saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        if($saved.kind -ne 'claude-to-codex' -or $saved.version -ne 1 -or $saved.source.profileId -ine $profile.Name -or
           [IO.Path]::GetFullPath($saved.source.configPath) -ine $config -or $saved.scope.mode -ne $uiRequest.Scope -or
           [string]$saved.scope.folder -ine [string]$uiRequest.Folder -or [string]$saved.scope.session -ine [string]$uiRequest.Session){throw 'The saved preview does not match this account and selection. Preview again.'}
        [void](Assert-CHPath $path (Join-Path $saved.stateRoot 'plans'))
        [void](Assert-CHPath $saved.stateRoot (Join-Path $dataRoot 'codex-imports'))
        if([bool]$saved.newRevision -ne $uiRequest.NewRevision){throw 'The revision choice changed. Preview again.'}
        if($uiRequest.CodexHome){
            $requestedHome=[IO.Path]::GetFullPath($uiRequest.CodexHome)
            if($requestedHome.Length -gt [IO.Path]::GetPathRoot($requestedHome).Length){$requestedHome=$requestedHome.TrimEnd([char[]]@([char]92,[char]47))}
            if($requestedHome -ine [string]$saved.codexHome){throw 'The Codex destination changed. Preview again.'}
        }
        foreach($row in $saved.rows){
            $expected=if($uiRequest.DestinationFolder){[IO.Path]::GetFullPath($uiRequest.DestinationFolder)}else{[string]$row.sourceCwd}
            if([string]$row.requestedCwd -ine $expected){throw 'The project-folder mapping changed. Preview again.'}
        }
        if($uiRequest.Action -eq 'Import'){
            $invoke.Remove('DestinationFolder');$invoke.CodexHome=$saved.codexHome;$invoke.StateRoot=$saved.stateRoot;$invoke.Mode='Import';$invoke.Plan=$path
            $data=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @invoke)|ConvertFrom-Json
        }else{$data=$saved}
        $planPath=$path
    }elseif($uiRequest.Action -eq 'Profiles'){
        $data=@{profiles=@($context.Catalog|ForEach-Object{@{Id=$_.Name;Label=$_.Label;Email=$_.Email}})}
    }else{
        $invoke.Source=$profile.Name
        if($uiRequest.Action -eq 'Choices'){$invoke.Mode='Choices'}
        else{
            $invoke.Mode='Plan';$invoke.Scope=$uiRequest.Scope
            if($uiRequest.Scope -eq 'Folder'){$invoke.ScopeFolder=$uiRequest.Folder}else{$invoke.ScopeSession=$uiRequest.Session}
            $invoke.NewRevision=$uiRequest.NewRevision
        }
        $data=(& (Join-Path $PSScriptRoot 'Import-ClaudeToCodex.ps1') @invoke)|ConvertFrom-Json
        $planPath=$data.planPath
    }
    $summary=[ordered]@{action=$uiRequest.Action}
    if($uiRequest.Action -eq 'Profiles'){$summary.profiles=$data.profiles}
    elseif($uiRequest.Action -eq 'Choices'){$summary.folders=@($data.Folders);$summary.sessions=@($data.Sessions)}
    else{
        $origins=@{};if($saved){foreach($row in $saved.rows){$origins[$row.id]=$row}}
        $summary.planPath=$planPath;$summary.codexHome=if($saved){$saved.codexHome}else{$data.codexHome}
        $summary.receiptPath=$data.receiptPath
        $summary.rows=@(foreach($row in $data.rows){
            $origin=if($origins.ContainsKey($row.id)){$origins[$row.id]}else{$row}
            [ordered]@{id=$row.id;title=$row.title;status=$row.status;reason=$row.reason;messages=$row.stats.messages;
                archived=[bool]$origin.archived;cwd=$origin.cwd;parent=$row.parent;warnings=@($row.warnings|Where-Object{$_});target=$row.target}
        })
    }
    $bytes=ConvertTo-CHBytes $summary
    if($bytes.Length -gt 4194304){throw 'The preview exceeds the display limit. Choose a smaller folder or a parent session.'}
    $resultRoot=Join-Path $dataRoot 'codex-ui'
    [void](Assert-CHPath $resultRoot $dataRoot);Protect-CHDirectory $resultRoot
    foreach($old in Get-ChildItem -LiteralPath $resultRoot -File -Filter '*.json'){
        if($old.Name -match '^[0-9a-f]{32}\.json$' -and $old.LastWriteTimeUtc -lt [datetime]::UtcNow.AddHours(-24)){
            [void](Assert-CHPath $old.FullName $resultRoot)
            try{[IO.File]::Delete($old.FullName)}
            catch [IO.IOException]{Write-Verbose 'An expired display file is still in use; cleanup will be retried.'}
            catch [UnauthorizedAccessException]{Write-Verbose 'An expired display file could not be removed; cleanup will be retried.'}
        }
    }
    $file=Join-Path $resultRoot ([guid]::NewGuid().ToString('N')+'.json')
    Write-CHAtomic $file $bytes
    @{Ok=$true;Action=$uiRequest.Action;ResultPath=$file;ResultBytes=$bytes.Length}|ConvertTo-Json -Compress
}catch{@{Ok=$false;Error=$_.Exception.Message}|ConvertTo-Json -Compress;exit 1}
finally{[Console]::OutputEncoding=$previousOutputEncoding}
