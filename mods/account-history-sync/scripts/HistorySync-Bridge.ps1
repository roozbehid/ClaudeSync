#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Profiles', 'Plan', 'Arm', 'Sync', 'Release')][string]$Action = 'Profiles',
    [string]$SourceProfile,
    [string]$TargetProfile,
    [string]$OwnerSession,
    [string]$SessionId,
    [string]$ConfigPath,
    [switch]$KeepLease
)
$ErrorActionPreference = 'Stop'
# Dot-sourcing the engine has its own param block; retain bridge arguments first.
$request = @{Action=$Action; Source=$SourceProfile; Target=$TargetProfile; Owner=$OwnerSession; Session=$SessionId; Config=$ConfigPath; KeepLease=[bool]$KeepLease}
$messageBuffer = [Collections.Generic.List[object]]::new()
try {
    . (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
    function Get-SessionProfiles($Context) {
        if (-not $request.Session) { return }
        if ($request.Session -notmatch ('^' + $script:GuidPattern + '$')) { throw 'Invalid current session ID.' }
        foreach ($profile in $Context.Catalog) {
            foreach ($file in Get-ChildItem -LiteralPath $profile.FullPath -File -Filter 'local_*.json') {
                $cardPath = Assert-CHPath $file.FullName $Context.Config.SessionsRoot
                # Never use global CLI login settings as Desktop's current identity.
                $card = [IO.File]::ReadAllText($cardPath) | ConvertFrom-Json
                if ($card.cliSessionId -eq $request.Session -and $card.sessionId -eq $file.BaseName) {
                    $profile.Name
                    break
                }
            }
        }
    }
    function Assert-SessionSource($Context) {
        $matches = @(Get-SessionProfiles $Context)
        if ($matches.Count -and $Context.Config.Profiles[0].Name -notin $matches) {
            throw 'This session belongs to a different local profile. Refresh and confirm the open account before syncing.'
        }
    }
    if (-not $request.Config) {
        $dataRoot = Join-Path $env:LOCALAPPDATA 'ClaudeHistorySync'
        [void](Assert-CHPath $dataRoot $dataRoot)
        Protect-CHDirectory $dataRoot
        $request.Config = Join-Path $dataRoot 'profiles.json'
        if (-not [IO.File]::Exists($request.Config)) {
            $seed = [ordered]@{FormatVersion=2; SessionsRoot='Auto'; ProjectsRoot='%USERPROFILE%\.claude\projects'; Profiles=@()}
            # CreateNew prevents another discovery process from replacing configuration.
            try {
                $seedStream = [IO.File]::Open($request.Config, 'CreateNew', 'Write', 'None')
                try { $seedBytes = ConvertTo-CHBytes $seed; $seedStream.Write($seedBytes, 0, $seedBytes.Length) }
                finally { $seedStream.Dispose() }
            }
            catch { if (-not [IO.File]::Exists($request.Config)) { throw } }
        }
    }
    $bridgeConfig = [IO.Path]::GetFullPath($request.Config)
    $bridgeRoot = [IO.Path]::GetDirectoryName($bridgeConfig)
    if ($request.Action -eq 'Profiles') {
        $discovery = Get-CHConfig $bridgeConfig '' '' $false
        $profiles = @($discovery.Catalog | ForEach-Object {
            [ordered]@{Id=$_.Name; Label=$_.Label; Email=$_.Email; EmailSource=$_.EmailSource;
                OrganizationId=$_.OrganizationId; Sessions=@(Get-ChildItem -LiteralPath $_.FullPath -File -Filter 'local_*.json').Count}
        })
        $matches = @(Get-SessionProfiles $discovery)
        $answer = [ordered]@{Ok=$true; Action='Profiles'; Profiles=$profiles; SessionProfiles=$matches;
            CurrentProfile=$(if ($matches.Count -eq 1) { $matches[0] } else { '' }); ConfigPath=$bridgeConfig}
    }
    elseif ($request.Action -eq 'Plan') {
        $context = Get-CHConfig $bridgeConfig $request.Source $request.Target
        Assert-SessionSource $context
        $syncPlan = New-CHPlan -Context $context -Direction AtoB
        $answer = [ordered]@{Ok=$true; Action='Plan'; Writes=$syncPlan.Operations.Count;
            Additions=@($syncPlan.Report | Where-Object Action -eq 'Add').Count;
            Updates=@($syncPlan.Report | Where-Object Action -eq 'Update').Count;
            Conflicts=@($syncPlan.Report | Where-Object Action -eq 'Conflict').Count;
            Skipped=@($syncPlan.Report | Where-Object Action -eq 'Skipped').Count;
            Report=@($syncPlan.Report | Select-Object -First 1000 File,Action,Detail);
            ReportTotal=$syncPlan.Report.Count; ReportTruncated=($syncPlan.Report.Count -gt 1000); ConfigPath=$bridgeConfig}
        $rows = @(Get-CHPreviewRows $context $syncPlan)
        $answer.Rows = @($rows | Select-Object -First 1000)
        $answer.RowsTotal = $rows.Count
        $answer.RowsTruncated = $rows.Count -gt 1000
    }
    else {
        if (-not $request.Owner -or $request.Owner.Length -gt 128) { throw 'An owner session ID is required.' }
        $leaseRoot = Assert-CHPath (Join-Path $bridgeRoot 'mod-control') $bridgeRoot
        Protect-CHDirectory $leaseRoot
        $leasePath = Assert-CHPath (Join-Path $leaseRoot 'lease.json') $leaseRoot
        $leaseLock = [IO.File]::Open((Join-Path $leaseRoot 'controller.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $lease = if ([IO.File]::Exists($leasePath)) { [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json } else { $null }
            $ownsLease = $lease -and $lease.Owner -eq $request.Owner
            if ($request.Action -eq 'Release') {
                if ($ownsLease) { Write-CHAtomic $leasePath (ConvertTo-CHBytes @{Owner=''; Source=''; Target=''; ExpiresUtc='1970-01-01T00:00:00Z'}) }
                $answer = [ordered]@{Ok=$true; Action='Release'}
            }
            else {
                $context = Get-CHConfig $bridgeConfig $request.Source $request.Target
                Assert-SessionSource $context
                $sourceId = $context.Config.Profiles[0].Name
                $targetId = $context.Config.Profiles[1].Name
                if ($lease -and -not $ownsLease -and [datetime]::Parse($lease.ExpiresUtc).ToUniversalTime() -gt [datetime]::UtcNow) {
                    throw 'Auto-sync is controlled by another session. Pause it there or wait three minutes after it ends.'
                }
                if ($request.Action -eq 'Sync' -and $request.KeepLease -and
                    (-not $ownsLease -or $lease.Source -ne $sourceId -or $lease.Target -ne $targetId)) {
                    throw 'Auto-sync must be armed for this source and destination before writing.'
                }
                $nextLease = @{Owner=$request.Owner; Source=$sourceId; Target=$targetId; ExpiresUtc=[datetime]::UtcNow.AddMinutes(3).ToString('o')}
                Write-CHAtomic $leasePath (ConvertTo-CHBytes $nextLease)
                if ($request.Action -eq 'Arm') {
                    $answer = [ordered]@{Ok=$true; Action='Arm'; Source=$sourceId; Target=$targetId}
                }
                else {
                    try {
                        # Recalculate immediately before writing; never apply a UI preview.
                        $syncPlan = New-CHPlan -Context $context -Direction AtoB
                        Invoke-CHApply -Context $context -Plan $syncPlan -AllowRunning $true -ActiveProfile $sourceId | ForEach-Object { $messageBuffer.Add($_) }
                        $backupLine = @($messageBuffer | Where-Object { $_ -is [string] -and $_.StartsWith('Backup: ') } | Select-Object -First 1)
                        $answer = [ordered]@{Ok=$true; Action='Sync'; Writes=$syncPlan.Operations.Count;
                            Additions=@($syncPlan.Report | Where-Object Action -eq 'Add').Count;
                            Updates=@($syncPlan.Report | Where-Object Action -eq 'Update').Count;
                            Conflicts=@($syncPlan.Report | Where-Object Action -eq 'Conflict').Count;
                            Skipped=@($syncPlan.Report | Where-Object Action -eq 'Skipped').Count;
                            Backup=$(if ($backupLine.Count) { $backupLine[0].Substring(8) } else { '' }); ConfigPath=$bridgeConfig}
                    }
                    finally {
                        if (-not $request.KeepLease) { Write-CHAtomic $leasePath (ConvertTo-CHBytes @{Owner=''; Source=''; Target=''; ExpiresUtc='1970-01-01T00:00:00Z'}) }
                    }
                }
            }
        }
        finally { $leaseLock.Dispose() }
    }
    $answer | ConvertTo-Json -Depth 20 -Compress
}
catch {
    # Include a prepared backup printed before an interrupted apply, when available.
    $failureMessages = @($messageBuffer | Where-Object { $_ -is [string] -and $_.StartsWith('Backup: ') } | Select-Object -First 1)
    [ordered]@{Ok=$false; Error=$_.Exception.Message;
        Backup=$(if ($failureMessages.Count) { $failureMessages[0].Substring(8) } else { '' })} | ConvertTo-Json -Compress
    exit 1
}
