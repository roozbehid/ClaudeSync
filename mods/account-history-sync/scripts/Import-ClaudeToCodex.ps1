#requires -Version 5.1
<#
Import selected local Claude Desktop Code conversations as new Codex snapshots.
Plan stages a private preview without starting Codex or changing either history.
Import requires the saved plan. No model turns or direct Codex database writes.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [ValidateSet('Profiles','Choices','Plan','Import')][string]$Mode='Plan',
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'profiles.json'),
    [string]$Source,
    [ValidateSet('Folder','Session','All')][string]$Scope='Folder',
    [string]$ScopeFolder,
    [string]$ScopeSession,
    [string]$DestinationFolder,
    [string]$CodexHome,
    [string]$StateRoot,
    [string]$Plan,
    [switch]$NewRevision,
    [switch]$AsJson,
    [string]$CodexExecutable='codex',
    [string]$NodeExecutable='node'
)
$ErrorActionPreference='Stop'
# Dot-sourcing the existing engine binds its parameters. Retain this command's options.
$options=@{Action=$Mode; Config=$ConfigPath; Source=$Source; Scope=$Scope; Folder=$ScopeFolder; Session=$ScopeSession;
    CodexHome=$CodexHome; StateRoot=$StateRoot; Plan=$Plan; DestinationFolder=$DestinationFolder; NewRevision=[bool]$NewRevision; AsJson=[bool]$AsJson; Executable=$CodexExecutable; Node=$NodeExecutable}
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
$options.Config=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.Config)
if($options.DestinationFolder){$options.DestinationFolder=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.DestinationFolder)}
if($options.Executable -match '[\\/]'){$options.Executable=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.Executable)}
if($options.Node -match '[\\/]'){$options.Node=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.Node)}

function Get-CodexImportTranscriptPaths([string]$ProjectsRoot) {
    $paths=@{}
    foreach($directory in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force){
        [void](Assert-CHPath $directory.FullName $ProjectsRoot)
        foreach($file in Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.jsonl'){
            if($file.BaseName -notmatch ('^'+$script:GuidPattern+'$')){continue}
            [void](Assert-CHPath $file.FullName $ProjectsRoot)
            $paths[$file.BaseName]=@($paths[$file.BaseName])+@($file.FullName)
        }
    }
    $paths
}

if (-not $options.CodexHome) {
    $options.CodexHome=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $env:USERPROFILE '.codex'}
}
$target=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.CodexHome)
if($target.Length -gt [IO.Path]::GetPathRoot($target).Length){$target=$target.TrimEnd([char[]]@([char]92,[char]47))}
[void](Assert-CHPath $target $target)
if (-not $options.StateRoot) {
    $options.StateRoot=Join-Path $env:LOCALAPPDATA ('ClaudeHistorySync\codex-imports\'+(Get-CHHash (ConvertTo-CHBytes $target.ToLowerInvariant())))
}
$options.StateRoot=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.StateRoot)
$privateRoot=Assert-CHPath $options.StateRoot $options.StateRoot
if ($options.Action -eq 'Import') {
    if (-not $options.Plan) { throw 'Import requires -Plan with the saved path printed by Plan.' }
    if ($options.Source -or $options.Folder -or $options.Session -or $options.NewRevision -or $options.DestinationFolder) { throw 'Import uses the saved plan. Source, folder selections, and NewRevision belong to Plan.' }
    $request=@{action='Import';stateRoot=$privateRoot;codexHome=$target;planPath=$PSCmdlet.GetUnresolvedProviderPathFromPSPath($options.Plan);codexExecutable=$options.Executable}
    if (-not $PSCmdlet.ShouldProcess($target,'Import the saved Claude conversation snapshots')) { return }
    $saved=[IO.File]::ReadAllText($request.planPath)|ConvertFrom-Json
    if($saved.kind -ne 'claude-to-codex' -or $saved.version -ne 1){throw 'Unsupported import plan.'}
    foreach($pair in @(@{Expected=$saved.codexHome;Actual=$target},@{Expected=$saved.stateRoot;Actual=$privateRoot})){
        if($pair.Expected -isnot [string] -or [string]::IsNullOrWhiteSpace($pair.Expected)){throw 'Plan destination or state directory does not match. Create a new preview.'}
        $expectedPath=[IO.Path]::GetFullPath(($pair.Expected -replace '^\\\\\?\\','')).TrimEnd([char[]]@([char]92,[char]47))
        $actualPath=[IO.Path]::GetFullPath(($pair.Actual -replace '^\\\\\?\\','')).TrimEnd([char[]]@([char]92,[char]47))
        if(-not $expectedPath.Equals($actualPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Plan destination or state directory does not match. Use the preview options or create a new preview.'}
    }
    $context=Get-CHConfig $saved.source.configPath '' '' $false
    $sourceProfile=Resolve-CHProfile $context.Catalog $saved.source.profileId
    $context.Config.Profiles=@($sourceProfile)
    $current=Get-CHRecords $context
    $selection=Get-CHScopeFiles $current.Records[$sourceProfile.Name] $saved.scope.mode $saved.scope.folder $saved.scope.session
    $currentIds=@($selection.Keys|ForEach-Object{$_ -replace '\.json$',''}|Sort-Object)
    $plannedIds=@($saved.rows|ForEach-Object{$_.id}|Sort-Object)
    if(($currentIds -join "`n") -cne ($plannedIds -join "`n")){throw 'Source scope changed after preview. Create a new plan.'}
    $currentPaths=Get-CodexImportTranscriptPaths $context.Config.ProjectsRoot
    foreach($row in @($saved.rows|Where-Object status -eq 'Ready')){
        if($current.Tombstones.ContainsKey(($row.id -replace '^local_',''))){throw 'Source deletion markers changed after preview. Create a new plan.'}
        foreach($transcript in $row.transcripts){
            if($current.Tombstones.ContainsKey([string]$transcript.id)){throw 'Source deletion markers changed after preview. Create a new plan.'}
            $matchingPaths=@($currentPaths[$transcript.id]|Where-Object{$_})
            $plannedPaths=if($transcript.copies){@($transcript.copies)}else{@($transcript.path)}
            if((@($matchingPaths|Sort-Object) -join "`n") -ine (@($plannedPaths|Sort-Object) -join "`n")){throw 'Source transcript selection changed after preview. Create a new plan.'}
        }
    }
}
else {
    $context=Get-CHConfig $options.Config '' '' $false
    if ($options.Action -eq 'Profiles') {
        $answer=@($context.Catalog|ForEach-Object{[pscustomobject]@{ProfileId=$_.Name;Email=$_.Email;Alias=$_.Alias}})
        if($options.AsJson){ConvertTo-Json -InputObject $answer -Depth 10}else{$answer}; return
    }
    if (-not $options.Source) { throw 'Choose -Source using an ID or email from -Mode Profiles.' }
    $sourceProfile=Resolve-CHProfile $context.Catalog $options.Source
    $context.Config.Profiles=@($sourceProfile)
    if ($options.Action -eq 'Choices') {
        $answer=Get-CHScopeChoices $context
        if($options.AsJson){$answer|ConvertTo-Json -Depth 15}else{$answer.Folders|Format-Table; $answer.Sessions|Format-Table}; return
    }
    $data=Get-CHRecords $context
    $records=$data.Records[[string]$sourceProfile.Name]
    $selected=Get-CHScopeFiles $records $options.Scope $options.Folder $options.Session
    $transcriptPaths=Get-CodexImportTranscriptPaths $context.Config.ProjectsRoot
    $rows=@(foreach($name in @($selected.Keys|Sort-Object)) {
        $entry=$records[$name]; $card=$entry.Record; $blocked=''; $paths=@()
        if($data.Tombstones.ContainsKey([string]$entry.Id)){$blocked='The Desktop session has a deletion marker.'}
        elseif($entry.Pending){$blocked='No CLI conversation has started.'}
        elseif($entry.Kind -notin @('Local','EnvironmentScoped')){$blocked='Only local Windows Code transcripts are supported; remote, scheduled, and cloud-task sessions are skipped.'}
        else {
            foreach($id in @(Get-CHCliChain $card)) {
                if($data.Tombstones.ContainsKey($id)){$blocked='A continuation transcript has a deletion marker.';break}
                $matchingTranscripts=@($transcriptPaths[$id]|Where-Object{$_})
                if(-not $matchingTranscripts.Count){$blocked='A local continuation transcript is missing.';break}
                $paths+=@{id=$id;path=$matchingTranscripts[0];copies=$matchingTranscripts}
            }
        }
        $destinationCwd=if($options.DestinationFolder){[IO.Path]::GetFullPath($options.DestinationFolder)}else{[string]$card.cwd}
        @{id=[string]$card.sessionId;title=[string]$card.title;cwd=$destinationCwd;sourceCwd=[string]$card.cwd;folder=(Get-CHFolder $card);parent=[string](Get-CHLineageParent $card);
          archived=[bool]$card.isArchived;cardPath=$entry.File;cardHash=$entry.FileHash.ToLowerInvariant();transcripts=$paths;blockedReason=$blocked}
    })
    $request=@{action='Plan';stateRoot=$privateRoot;codexHome=$target;source=@{profileId=$sourceProfile.Name;profileRoot=$sourceProfile.FullPath;projectsRoot=$context.Config.ProjectsRoot;sessionsRoot=$context.Config.SessionsRoot;configPath=$context.ConfigPath};
        scope=@{mode=$options.Scope;folder=$options.Folder;session=$options.Session};records=$rows;newRevision=$options.NewRevision}
}

try {
    if($options.Node -match '[\\/]'){
        if(-not [IO.File]::Exists($options.Node)){throw 'Missing Node executable.'}
        $nodePath=$options.Node
    }else{$nodePath=@(Get-Command $options.Node -CommandType Application -ErrorAction Stop)[0].Source}
}
catch {throw 'Node.js 22 or later is required. Put node.exe on PATH or specify -NodeExecutable with its full path.'}
if([IO.Path]::GetExtension($nodePath) -ine '.exe'){throw 'NodeExecutable must select a native .exe executable; command wrappers are not supported. Use the full path to node.exe.'}
$nodeVersion=(& $nodePath -p 'process.versions.node'|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^(\d+)\.\d+\.\d+(?:[-+].*)?$' -or [int]$Matches[1] -lt 22){
    throw 'Node.js 22 or later is required. Select a supported runtime with -NodeExecutable. No import state was written.'
}
# Private staging must be a dedicated directory, never a source/destination root
# or an ancestor of one. Protect-CHDirectory changes permissions on this directory.
$protectedRoots=@($target,$PSScriptRoot,$env:USERPROFILE)
if($options.Action -eq 'Plan'){$protectedRoots+=@($request.source.projectsRoot,$request.source.sessionsRoot)}
else{$protectedRoots+=@($saved.source.projectsRoot,$saved.source.sessionsRoot)}
$privatePath=$privateRoot.TrimEnd('\')
if($privatePath -eq [IO.Path]::GetPathRoot($privateRoot).TrimEnd('\')){throw 'StateRoot must be a dedicated private staging directory.'}
foreach($protectedRoot in $protectedRoots){
    $protectedPath=[IO.Path]::GetFullPath($protectedRoot).TrimEnd('\')
    if($privatePath.Equals($protectedPath,[StringComparison]::OrdinalIgnoreCase) -or
       $protectedPath.StartsWith($privatePath+'\',[StringComparison]::OrdinalIgnoreCase) -or
       (($protectedRoot -ne $env:USERPROFILE) -and $privatePath.StartsWith($protectedPath+'\',[StringComparison]::OrdinalIgnoreCase))){
        throw 'StateRoot must be separate from source history, the Codex home, and the checkout.'
    }
}
$marker=Join-Path $privateRoot '.claudesync-codex-import-state'
if([IO.Directory]::Exists($privateRoot)){
    if([IO.File]::Exists($marker)){
        [void](Assert-CHPath $marker $privateRoot)
        if([IO.File]::ReadAllText($marker) -ne 'ClaudeSync-Codex-Import-State-v1'){throw 'Unrecognized import state marker.'}
    } elseif(@(Get-ChildItem -LiteralPath $privateRoot -Force|Select-Object -First 1).Count){throw 'StateRoot must be new, empty, or an existing ClaudeSync import-state directory. Its permissions were not changed.'}
}
Protect-CHDirectory $privateRoot
if(-not [IO.File]::Exists($marker)){[IO.File]::WriteAllText($marker,'ClaudeSync-Codex-Import-State-v1',[Text.UTF8Encoding]::new($false))}
# An explicit CODEX_HOME must exist before the native CLI starts. Only Import
# initializes a new destination; existing Codex directories keep their ACLs.
if($options.Action -eq 'Import' -and @($saved.rows|Where-Object status -eq 'Ready').Count -gt 0 -and -not [IO.Directory]::Exists($target)){
    [void](Assert-CHPath $target $target)
    Protect-CHDirectory $target
}
$requestPath=Join-Path $privateRoot ('request-'+[guid]::NewGuid().ToString('N')+'.json')
$previousOutputEncoding=[Console]::OutputEncoding
try {
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllBytes($requestPath,(ConvertTo-CHBytes $request))
    $json=& $nodePath (Join-Path $PSScriptRoot 'tools\Import-ClaudeToCodex.mjs') $requestPath
    $exitCode=$LASTEXITCODE
    $answer=($json -join "`n")|ConvertFrom-Json
    if($answer.error){throw $answer.error}
    if($exitCode -ne 0){throw "Node importer failed (exit $exitCode). Check its diagnostic output."}
    if($options.AsJson){$answer|ConvertTo-Json -Depth 60;return}
    if($options.Action -eq 'Plan'){
        Write-Output "Codex home: $($answer.codexHome)"
        if($options.DestinationFolder){Write-Output "Requested destination project folder: $([IO.Path]::GetFullPath($options.DestinationFolder))"}
        foreach($row in $answer.rows){
            if($row.requestedCwd -and $row.cwd -and $row.requestedCwd.TrimEnd('\') -ine $row.cwd.TrimEnd('\')){
                Write-Output "Resolved project folder for '$($row.title)': $($row.cwd) (requested: $($row.requestedCwd))"
            }
        }
    }
    $answer.rows|Select-Object @{Name='Title';Expression={$_.title}},@{Name='Status';Expression={$_.status}},@{Name='Messages';Expression={$_.stats.messages}},@{Name='Reason';Expression={$_.reason}}|Format-Table -Wrap
    foreach($row in $answer.rows){foreach($warning in @($row.warnings)){if($warning){Write-Output "$($row.title): $warning"}}}
    if($options.Action -eq 'Plan') {
        foreach($note in $answer.notes){Write-Output $note}
        Write-Output "Saved plan: $($answer.planPath)"
        Write-Output 'Review the rows, then run -Mode Import -Plan with this path and the same CodexHome/StateRoot options.'
    } else {
        Write-Output "Receipt: $($answer.receiptPath)"
        $answer.rows|Where-Object target|Select-Object title,target|Format-Table
    }
} finally { [Console]::OutputEncoding=$previousOutputEncoding; if([IO.File]::Exists($requestPath)){Remove-Item -LiteralPath $requestPath} }
