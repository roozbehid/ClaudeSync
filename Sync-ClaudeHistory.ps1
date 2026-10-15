#requires -Version 5.1
<#
Standalone, offline sync of Claude Desktop Code history on this Windows user.
Plan and Inventory are read-only. Sync defaults to ProfileA -> ProfileB.
AllowRunning requires a declared active source profile and one-way writes.
Dot-source this file to load functions without running the command.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Profiles', 'Plan', 'Sync', 'Inventory', 'Undo')][string]$Mode = 'Plan',
    [string]$ConfigPath,
    [string]$ProfileA,
    [string]$ProfileB,
    [ValidateSet('AtoB', 'BtoA', 'Both')][string]$Direction = 'AtoB',
    [ValidateSet('Changes', 'Profile', 'Newest')][string]$Policy,
    [string]$WinnerProfile,
    [switch]$AllowRunning,
    [string]$ActiveProfile,
    [switch]$IncludeScheduled,
    [string]$Backup
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'profiles.json' }
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:HistoryFields = @('title', 'titleSource', 'isArchived', 'lastActivityAt',
    'completedTurns', 'titleTurn', 'postTurnSummary', 'postTurnSummaryFor',
    'lastAssistantUuid', 'model', 'effort', 'branch', 'sourceBranch', 'writtenBranches')
$script:IdentityFields = @('sessionId', 'cliSessionId', 'cwd', 'originCwd', 'wslConfig', 'sshConfig', 'sshRemoteTranscriptPath')
$script:CloneFields = $script:IdentityFields + $script:HistoryFields + @(
    'createdAt', 'lastFocusedAt', 'worktreePath', 'worktreeName', 'gitAnchors',
    'priorCliSessionIds', 'forkedFromSessionId', 'sshRemoteProcessId')

function Get-CHHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Get-CHFileHash([string]$Path) {
    if ([IO.File]::Exists($Path)) { Get-CHHash ([IO.File]::ReadAllBytes($Path)) }
    else { 'ABSENT' }
}
function ConvertTo-CHBytes($Value) {
    ,([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 80 -Compress)))
}
function Assert-CHPath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -ne $base -and -not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A path escaped its configured root.'
    }
    # Inspect all existing ancestors, including those above Root, for junctions.
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a reparse point: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $full
}
function Assert-CHStopped {
    if (Get-Process -Name Claude -ErrorAction SilentlyContinue) {
        throw 'Fully exit Claude Desktop and Claude Code before Sync or Undo. No process was stopped.'
    }
}
function Protect-CHDirectory([string]$Path) {
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    # Set-Acl may attempt to persist an audit section on an existing directory,
    # which needs SeSecurityPrivilege. Persist only the sections modified above.
    $directory = [IO.DirectoryInfo]::new($Path)
    if ($directory.PSObject.Methods['SetAccessControl']) { $directory.SetAccessControl($acl) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl) }
}
function Write-CHAtomic([string]$Path, [byte[]]$Bytes) {
    $temp = $Path + '.sync-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $before = Get-CHFileHash $Path
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ([IO.File]::Exists($Path)) {
            # Reflection preserves an actual null backup filename in both PS 5.1
            # and PS 7, rather than converting PowerShell null to an empty path.
            $method = [IO.File].GetMethod('Replace', [type[]]@([string], [string], [string]))
            for ($attempt=0; $attempt -lt 5; $attempt++) {
                try { [void]$method.Invoke($null, [object[]]@($temp, $Path, $null)); break }
                catch {
                    $cause = $_.Exception
                    while ($cause.InnerException) { $cause = $cause.InnerException }
                    $code = $cause.HResult -band 65535
                    # Retry transient ReplaceFile failures only while both names
                    # and the old destination bytes survive unchanged.
                    if ($attempt -ge 4 -or $code -notin @(32, 33, 1175) -or -not [IO.File]::Exists($temp) -or (Get-CHFileHash $Path) -ne $before) {
                        throw "Atomic write failed for $Path (Windows code $code): $($cause.Message)"
                    }
                    Start-Sleep -Milliseconds (100 * ($attempt + 1))
                }
            }
        }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally { if ([IO.File]::Exists($temp)) { Remove-Item -LiteralPath $temp } }
}
function Get-CHEmails([string]$LabelsPath) {
    # These are CLI settings and their backups, not .credentials.json, Desktop
    # token caches, browser cookies, or OS credential stores. Read only identity.
    $files = @()
    $settings = Join-Path $env:USERPROFILE '.claude.json'
    if ([IO.File]::Exists($settings)) { $files += Get-Item -LiteralPath $settings }
    $backups = @()
    $backups += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Filter '.claude.json.backup*' -File -Force -ErrorAction SilentlyContinue)
    $backupDir = Join-Path $env:USERPROFILE '.claude\backups'
    if ([IO.Directory]::Exists($backupDir)) { $backups += @(Get-ChildItem -LiteralPath $backupDir -Filter '.claude.json.backup*' -File -Force) }
    $files += @($backups | Sort-Object LastWriteTimeUtc -Descending)
    $emails = @{}
    foreach ($f in $files) {
        try {
            if ($f.Length -gt 16777216 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $text = [IO.File]::ReadAllText($f.FullName)
            if ($PSVersionTable.PSEdition -eq 'Core') { $doc = $text | ConvertFrom-Json -AsHashtable }
            else {
                # Desktop/CLI settings can contain project keys differing only
                # in casing, which ConvertFrom-Json in PS 5.1 cannot preserve.
                Add-Type -AssemblyName System.Web.Extensions
                $parser = [Web.Script.Serialization.JavaScriptSerializer]::new()
                $parser.MaxJsonLength = 16777216
                $doc = $parser.DeserializeObject($text)
            }
            $identity = $doc['oauthAccount']
            $accountId = [string]$identity['accountUuid']; $orgId = [string]$identity['organizationUuid']; $email = [string]$identity['emailAddress']
            $id = $accountId + '\' + $orgId
            if ($accountId -match ('^' + $script:GuidPattern + '$') -and $orgId -match ('^' + $script:GuidPattern + '$') -and $email -match '^[^\s@]+@[^\s@]+$' -and -not $emails.ContainsKey($id)) { $emails[$id] = [pscustomobject]@{Email=$email; Source='CLI settings'} }
        }
        catch { continue } # Missing/unreadable labels must not prevent listing history.
    }
    if ($LabelsPath -and [IO.File]::Exists($LabelsPath)) {
        [void](Assert-CHPath $LabelsPath ([IO.Path]::GetDirectoryName($LabelsPath)))
        $labels = [IO.File]::ReadAllText($LabelsPath) | ConvertFrom-Json
        if ($labels.FormatVersion -ne 1) { throw 'Unsupported profile-labels.json version.' }
        foreach ($entry in $labels.Profiles) {
            if ($entry.Path -notmatch ('^' + $script:GuidPattern + '\\' + $script:GuidPattern + '$') -or $entry.Email -notmatch '^[^\s@]+@[^\s@]+$') { throw 'Invalid profile email label.' }
            if (-not $emails.ContainsKey([string]$entry.Path)) { $emails[[string]$entry.Path] = [pscustomobject]@{Email=[string]$entry.Email; Source='User label'} }
        }
    }
    $emails
}
function Find-CHSessionsRoot {
    $candidates = @()
    $regular = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    if ([IO.Directory]::Exists($regular)) { $candidates += $regular }
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if ([IO.Directory]::Exists($packages)) {
        foreach ($package in Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*') {
            $candidate = Join-Path $package.FullName 'LocalCache\Roaming\Claude\claude-code-sessions'
            if ([IO.Directory]::Exists($candidate)) { $candidates += $candidate }
        }
    }
    if ($candidates.Count -ne 1) { throw 'Cannot choose a unique Desktop history directory. Set SessionsRoot in profiles.json to the desired absolute path.' }
    $candidates[0]
}
function Resolve-CHProfile($Catalog, [string]$Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector)) { throw 'Choose profiles using -ProfileA and -ProfileB; use -Mode Profiles to list IDs and known emails.' }
    $matches = @($Catalog | Where-Object {
        $_.Name -eq $Selector -or $_.AccountId -eq $Selector -or $_.Email -eq $Selector -or $_.Alias -eq $Selector
    })
    if ($matches.Count -ne 1) { throw "Profile selector '$Selector' is unknown or ambiguous. Use the full account-GUID\organization-GUID ID from -Mode Profiles." }
    $matches[0]
}
function Get-CHConfig([string]$Path, [string]$SelectorA='', [string]$SelectorB='', [bool]$RequirePair=$true) {
    $configFile = Assert-CHPath $Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    $c = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
    if ($c.FormatVersion -notin @(1, 2)) { throw 'Unsupported configuration version.' }
    if ($c.SessionsRoot -eq 'Auto') { $c.SessionsRoot = Find-CHSessionsRoot }
    foreach ($key in @('SessionsRoot', 'ProjectsRoot')) {
        $value = [Environment]::ExpandEnvironmentVariables([string]$c.$key)
        if (-not [IO.Path]::IsPathRooted($value) -or -not [IO.Directory]::Exists($value)) { throw "Missing configured $key directory." }
        $c.$key = Assert-CHPath $value $value
    }
    $configured = @($c.Profiles | Where-Object { $null -ne $_ })
    $aliases = @{}; $configuredPaths = @{}
    foreach ($p in $configured) {
        if ($p.Path -notmatch ('^' + $script:GuidPattern + '\\' + $script:GuidPattern + '$')) { throw 'Profile paths must be account-GUID\organization-GUID.' }
        if ($configuredPaths.ContainsKey([string]$p.Path)) { throw 'Repeated configured profile path.' }
        $configuredPaths[[string]$p.Path] = $p
        if ($p.Name) {
            if ($aliases.ContainsKey([string]$p.Name)) { throw 'Profile aliases must be unique.' }
            $aliases[[string]$p.Name] = $true
        }
    }
    $configDirectory = [IO.Path]::GetDirectoryName($configFile)
    $emails = Get-CHEmails (Join-Path $configDirectory 'profile-labels.json')
    $catalog = [Collections.Generic.List[object]]::new()
    foreach ($account in Get-ChildItem -LiteralPath $c.SessionsRoot -Directory -Force) {
        if ($account.Name -notmatch ('^' + $script:GuidPattern + '$')) { continue }
        [void](Assert-CHPath $account.FullName $c.SessionsRoot)
        foreach ($org in Get-ChildItem -LiteralPath $account.FullName -Directory -Force) {
            if ($org.Name -notmatch ('^' + $script:GuidPattern + '$')) { continue }
            $full = Assert-CHPath $org.FullName $c.SessionsRoot
            $id = $account.Name + '\' + $org.Name
            $custom = $configuredPaths[$id]
            $email = if ($custom.Email) { [string]$custom.Email } elseif ($emails.ContainsKey($id)) { [string]$emails[$id].Email } else { '' }
            $emailSource = if ($custom.Email) { 'Config label' } elseif ($emails.ContainsKey($id)) { [string]$emails[$id].Source } else { 'Unknown' }
            if ($email -and $email -notmatch '^[^\s@]+@[^\s@]+$') { throw 'Invalid configured email label.' }
            $label = if ($email) { $email } elseif ($custom.Name) { [string]$custom.Name } else { $account.Name }
            $catalog.Add([pscustomobject]@{
                Name=$id; Path=$id; Label=$label; Alias=[string]$custom.Name; Email=$email; EmailSource=$emailSource;
                AccountId=$account.Name; OrganizationId=$org.Name; FullPath=$full
            })
        }
    }
    $selected = @()
    if ($SelectorA -or $SelectorB) {
        $selected = @((Resolve-CHProfile $catalog $SelectorA), (Resolve-CHProfile $catalog $SelectorB))
    }
    elseif ($configured.Count -eq 2) {
        $selected = @((Resolve-CHProfile $catalog $configured[0].Path), (Resolve-CHProfile $catalog $configured[1].Path))
    }
    elseif ($RequirePair) { throw 'Choose -ProfileA and -ProfileB using IDs or emails from -Mode Profiles, or configure exactly two Profiles in profiles.json.' }
    if ($selected.Count -eq 2 -and $selected[0].Name -eq $selected[1].Name) { throw 'The profiles must be different.' }
    $c.Profiles = $selected
    $stateHome = Assert-CHPath (Join-Path $configDirectory 'state') $configDirectory
    $signature = ''; $stateRoot = $stateHome
    if ($selected.Count -eq 2) {
        $signature = Get-CHHash (ConvertTo-CHBytes @($c.SessionsRoot, $c.ProjectsRoot, @($selected.Path | Sort-Object)))
        $stateRoot = Assert-CHPath (Join-Path $stateHome ('pairs\' + $signature)) $stateHome
    }
    [pscustomobject]@{ Config=$c; Catalog=$catalog; ConfigPath=$configFile; ConfigDirectory=$configDirectory; StateHome=$stateHome; StateRoot=$stateRoot; Signature=$signature }
}
function Get-CHKind($Record) {
    if ($Record.wslConfig) { return 'WSL' }
    if ($Record.sshRemoteProcessId -or $Record.sshRemoteTranscriptPath -or $Record.sshConfig) { return 'SSH' }
    if ($Record.scheduledTaskId) { return 'Scheduled' }
    if (@($Record.cloudSpawnedTasks | Where-Object { $null -ne $_ }).Count) { return 'LocalWithCloudTasks' }
    if ($Record.envScopeId) { return 'EnvironmentScoped' }
    'Local'
}
function Select-CHFields($Record, [string[]]$Fields) {
    $out = [ordered]@{}
    foreach ($key in $Fields) {
        if ($null -ne $Record.PSObject.Properties[$key]) { $out[$key] = $Record.$key }
    }
    [pscustomobject]$out
}
function Get-CHViewHash($Record) { Get-CHHash (ConvertTo-CHBytes (Select-CHFields $Record $script:HistoryFields)) }
function Get-CHRecords($Context) {
    $c = $Context.Config
    $transcripts = @{}
    foreach ($project in Get-ChildItem -LiteralPath $c.ProjectsRoot -Directory -Force) {
        $projectPath = Assert-CHPath $project.FullName $c.ProjectsRoot
        foreach ($file in Get-ChildItem -LiteralPath $projectPath -File -Filter '*.jsonl') {
            if ($file.BaseName -match ('^' + $script:GuidPattern + '$')) {
                [void](Assert-CHPath $file.FullName $c.ProjectsRoot)
                $transcripts[$file.BaseName] = $true
            }
        }
    }
    $records = @{}
    $tombstones = @{}
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($p in $c.Profiles) {
        $perProfile = @{}
        foreach ($f in Get-ChildItem -LiteralPath $p.FullPath -File -Force) {
            if ($f.Name -match ('^deleted_(' + $script:GuidPattern + ')$')) { $tombstones[$Matches[1]] = $true; continue }
            if ($f.Name -notmatch ('^local_(' + $script:GuidPattern + ')\.json$')) { continue }
            $id = $Matches[1]
            [void](Assert-CHPath $f.FullName $c.SessionsRoot)
            try {
                $bytes = [IO.File]::ReadAllBytes($f.FullName)
                $j = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                if ($j.sessionId -isnot [string] -or $j.sessionId -ne ('local_' + $id)) {
                    throw 'Invalid session identity: Desktop session ID does not match the filename.'
                }
                if ($j.cwd -isnot [string] -or [string]::IsNullOrWhiteSpace($j.cwd)) { throw 'Invalid session identity: working directory is missing.' }
                # Desktop persists cards before a CLI has started (including failed
                # WSL launches). Keep them in the inventory, but never copy them or
                # use them to reconcile an archive index until they have a CLI ID.
                $pending = $null -eq $j.cliSessionId -or ($j.cliSessionId -is [string] -and [string]::IsNullOrWhiteSpace($j.cliSessionId))
                if (-not $pending -and ($j.cliSessionId -isnot [string] -or $j.cliSessionId -notmatch ('^' + $script:GuidPattern + '$'))) {
                    throw 'Invalid session identity: CLI session ID is not a GUID.'
                }
                if ($null -ne $j.PSObject.Properties['isArchived'] -and $j.isArchived -isnot [bool]) { throw 'Invalid archive flag.' }
                $kind = Get-CHKind $j
                $hasTranscript = $transcripts.ContainsKey([string]$j.cliSessionId)
                $perProfile[$f.Name] = [pscustomobject]@{
                    Record=$j; Kind=$kind; Pending=$pending; HasTranscript=$hasTranscript; File=$f.FullName;
                    FileHash=(Get-CHHash $bytes); ViewHash=(Get-CHViewHash $j); Id=$id; ModifiedUtc=$f.LastWriteTimeUtc
                }
                $inventory.Add([pscustomobject]@{Profile=$p.Label; ProfileId=$p.Name; File=$f.Name; Kind=$kind; Status=$(if ($pending) { 'Pending' } else { 'Ready' }); LocalTranscript=$hasTranscript; Archived=[bool]$j.isArchived; ModifiedUtc=$f.LastWriteTimeUtc})
            }
            catch { throw "Cannot safely read $($p.Name)/$($f.Name): $($_.Exception.Message)" }
        }
        $records[[string]$p.Name] = $perProfile
    }
    [pscustomobject]@{Records=$records; Tombstones=$tombstones; Inventory=$inventory}
}
function New-CHOperation($Context, [string]$Area, [string]$RelativePath, [byte[]]$Bytes) {
    $root = if ($Area -eq 'desktop') { $Context.Config.SessionsRoot } elseif ($Area -eq 'state') { $Context.StateRoot } else { throw 'Invalid operation area.' }
    $path = Assert-CHPath (Join-Path $root $RelativePath) $root
    [pscustomobject]@{Area=$Area; RelativePath=$RelativePath; Path=$path; Before=(Get-CHFileHash $path); After=(Get-CHHash $Bytes); Bytes=$Bytes}
}
function New-CHPlan($Context, [string]$Winner='', [bool]$WithScheduled=$false,
    [ValidateSet('Changes', 'Profile', 'Newest')][string]$Resolution,
    [ValidateSet('AtoB', 'BtoA', 'Both')][string]$Direction='AtoB') {
    $c = $Context.Config
    $aName = [string]$c.Profiles[0].Name; $bName = [string]$c.Profiles[1].Name
    $directionSource = if ($Direction -eq 'AtoB') { $aName } elseif ($Direction -eq 'BtoA') { $bName } else { '' }
    $directionTarget = if ($Direction -eq 'AtoB') { $bName } elseif ($Direction -eq 'BtoA') { $aName } else { '' }
    if (-not $Resolution) { $Resolution = if ($Winner -or $directionSource) { 'Profile' } else { 'Newest' } }
    $winningName = $null
    if ($Resolution -eq 'Profile') {
        if (-not $Winner -and $directionSource) { $Winner = $directionSource }
        if (-not $Winner) { throw 'Policy Profile requires -WinnerProfile with an email, profile ID, or configured alias.' }
        $winningName = (Resolve-CHProfile $c.Profiles $Winner).Name
        if ($directionSource -and $winningName -ne $directionSource) { throw 'WinnerProfile must be the source for the selected Direction. Use BtoA or Both to write ProfileA.' }
    }
    elseif ($Winner) { throw 'WinnerProfile applies only to Policy Profile.' }
    $data = Get-CHRecords $Context
    $stateFile = Assert-CHPath (Join-Path $Context.StateRoot 'baseline.json') $Context.StateRoot
    $stateBefore = Get-CHFileHash $stateFile
    $baseline = @{}
    if ([IO.File]::Exists($stateFile)) {
        $old = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
        if ($old.FormatVersion -ne 1 -or $old.Signature -ne $Context.Signature) { throw 'Sync state belongs to another profile pair. Use a separate tool/config folder.' }
        foreach ($entry in $old.Entries.PSObject.Properties) { $baseline[$entry.Name] = [string]$entry.Value }
    }
    $next = @{} + $baseline
    $reconciled = @{}
    $ops = [Collections.Generic.List[object]]::new()
    $report = [Collections.Generic.List[object]]::new()
    $allNames = @(@($data.Records[$aName].Keys) + @($data.Records[$bName].Keys) | Sort-Object -Unique)
    foreach ($name in $allNames) {
        $a = $data.Records[$aName][$name]; $b = $data.Records[$bName][$name]
        if ($directionSource -and -not $data.Records[$directionSource].ContainsKey($name)) {
            $report.Add([pscustomobject]@{File=$name; Action='Skipped'; Detail='Destination-only card; reverse copying disabled'})
            continue
        }
        $present = @(@($a, $b) | Where-Object { $null -ne $_ })
        $reason = $null
        if (@($present | Where-Object Pending).Count) { $reason = 'Unfinished Desktop session: CLI session ID missing; card left untouched' }
        # Spawned cloud tasks are account-specific links on a local parent, not
        # evidence that the parent runs in the cloud. CloneFields excludes those
        # links; updates retain the destination's own links. Still reject actual
        # account-bound scopes, including cards with other environment indicators.
        elseif (@($present | Where-Object { $_.Record.envScopeId }).Count) { $reason = 'Account-bound environment scope' }
        elseif (-not $WithScheduled -and @($present | Where-Object { $_.Record.scheduledTaskId }).Count) { $reason = 'Scheduled history requires -IncludeScheduled' }
        elseif (@($present | Where-Object { -not $_.HasTranscript -and $_.Kind -notin @('WSL', 'SSH') }).Count) { $reason = 'Local transcript missing' }
        elseif (@($present | Where-Object { $data.Tombstones.ContainsKey($_.Id) -or $data.Tombstones.ContainsKey([string]$_.Record.cliSessionId) }).Count) { $reason = 'Deletion marker present' }
        elseif ($present.Count -eq 1 -and $baseline.ContainsKey($name)) { $reason = 'Previously synced record removed; no resurrection' }
        if ($reason) { $report.Add([pscustomobject]@{File=$name; Action='Skipped'; Detail=$reason}); continue }
        if ($a -and $b) {
            $ai = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $a.Record $script:IdentityFields))
            $bi = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $b.Record $script:IdentityFields))
            if ($ai -ne $bi) { $report.Add([pscustomobject]@{File=$name; Action='Conflict'; Detail='Session/project identity differs'}); continue }
            if ($a.ViewHash -eq $b.ViewHash) { $next[$name] = $a.ViewHash; $reconciled[$name] = $true; continue }
            $sourceName = $null
            $decision = ''
            if ($Resolution -eq 'Profile') { $sourceName = $winningName; $decision = 'chosen profile wins' }
            elseif ($baseline.ContainsKey($name)) {
                if ($a.ViewHash -eq $baseline[$name]) { $sourceName = $bName }
                elseif ($b.ViewHash -eq $baseline[$name]) { $sourceName = $aName }
                if ($sourceName) { $decision = 'only this copy changed' }
            }
            if (-not $sourceName -and $Resolution -eq 'Newest') {
                if ($a.ModifiedUtc -gt $b.ModifiedUtc) { $sourceName = $aName }
                elseif ($b.ModifiedUtc -gt $a.ModifiedUtc) { $sourceName = $bName }
                if ($sourceName) { $decision = 'newest session-file modification wins' }
            }
            if (-not $sourceName) {
                $detail = if ($Resolution -eq 'Newest') { 'Modification times tied; choose -Policy Profile -WinnerProfile' } else { 'Both changed or no common baseline; choose -Policy Newest or -Policy Profile -WinnerProfile' }
                $report.Add([pscustomobject]@{File=$name; Action='Conflict'; Detail=$detail}); continue
            }
        }
        else { $sourceName = if ($a) { $aName } else { $bName }; $decision = 'missing history card' }
        if ($directionSource -and $sourceName -ne $directionSource) {
            $report.Add([pscustomobject]@{File=$name; Action='Skipped'; Detail='Policy chose destination; reverse writing disabled'})
            continue
        }
        $targetName = if ($sourceName -eq $aName) { $bName } else { $aName }
        $source = $data.Records[$sourceName][$name]
        $target = $data.Records[$targetName][$name]
        $sourceProfile = @($c.Profiles | Where-Object { $_.Name -eq $sourceName })[0]
        $profile = @($c.Profiles | Where-Object { $_.Name -eq $targetName })[0]
        $archiveChange = $target -and ([bool]$target.Record.isArchived -ne [bool]$source.Record.isArchived)
        $archiveDetail = if ($archiveChange) { if ($source.Record.isArchived) { '; archive' } else { '; unarchive' } } else { '' }
        if ($target) {
            # Preserve the target's own permissions, MCP setup, remote links, and unknown fields.
            # Do not mutate the destination snapshot while constructing a plan.
            # Preview comparisons and stale-plan checks need its original values.
            $out = [Text.Encoding]::UTF8.GetString((ConvertTo-CHBytes $target.Record)) | ConvertFrom-Json
            foreach ($key in $script:HistoryFields) {
                if ($null -ne $source.Record.PSObject.Properties[$key]) { $out | Add-Member -NotePropertyName $key -NotePropertyValue $source.Record.$key -Force }
                else { $out.PSObject.Properties.Remove($key) }
            }
            $action = 'Update'
        }
        else {
            # Create a history card, not a copy of account-specific settings or remote access.
            $out = Select-CHFields $source.Record $script:CloneFields
            $out | Add-Member -NotePropertyName permissionMode -NotePropertyValue 'default'
            $out | Add-Member -NotePropertyName remoteMcpServersConfig -NotePropertyValue @()
            $out | Add-Member -NotePropertyName bridgeSessionIds -NotePropertyValue @()
            $out | Add-Member -NotePropertyName steeredByRemoteClient -NotePropertyValue $false
            $action = 'Add'
        }
        $op = New-CHOperation $Context 'desktop' (Join-Path $profile.Path $name) (ConvertTo-CHBytes $out)
        # Use the hashes from the read snapshot, rather than silently accepting a later write.
        $op.Before = if ($target) { $target.FileHash } else { 'ABSENT' }
        $ops.Add($op)
        $next[$name] = $source.ViewHash
        $reconciled[$name] = $true
        $report.Add([pscustomobject]@{File=$name; Action=$action; Detail="$($sourceProfile.Label) -> $($profile.Label); $decision$archiveDetail"; ArchiveChanged=[bool]$archiveChange})
    }
    # One-way sync never repairs the source cache, even when cards agree.
    foreach ($p in $c.Profiles) {
        if ($directionTarget -and $p.Name -ne $directionTarget) { continue }
        $changes = @{}
        foreach ($name in $reconciled.Keys) {
            $existing = $data.Records[[string]$p.Name][$name]
            if ($existing) { $changes[$name] = $existing.Record }
        }
        foreach ($op in @($ops | Where-Object { $_.Area -eq 'desktop' -and $_.RelativePath.StartsWith($p.Path + '\', [StringComparison]::OrdinalIgnoreCase) })) {
            $changes[[IO.Path]::GetFileName($op.RelativePath)] = [Text.Encoding]::UTF8.GetString($op.Bytes) | ConvertFrom-Json
        }
        if (-not $changes.Count) { continue }
        $indexPath = Assert-CHPath (Join-Path $p.FullPath 'archived-sessions.idx') $c.SessionsRoot
        $indexBefore = Get-CHFileHash $indexPath
        $index = if ($indexBefore -ne 'ABSENT') { [IO.File]::ReadAllText($indexPath) | ConvertFrom-Json } else { [pscustomobject]@{v=1; archived=@()} }
        if ($index.v -ne 1 -or $null -eq $index.PSObject.Properties['archived'] -or $index.archived -isnot [array] -or @($index.PSObject.Properties.Name | Where-Object { $_ -notin @('v', 'archived') }).Count) { throw 'Unknown archived-sessions.idx format; refusing sync.' }
        $archived = @{}
        foreach ($id in $index.archived) {
            if ($id -notmatch ('^local_' + $script:GuidPattern + '$')) { throw 'Invalid archived session ID.' }
            $archived[[string]$id] = $true
        }
        $beforeIds = @($archived.Keys | Sort-Object)
        foreach ($j in $changes.Values) {
            if ($j.isArchived) { $archived[[string]$j.sessionId] = $true } else { $archived.Remove([string]$j.sessionId) }
        }
        $afterIds = @($archived.Keys | Sort-Object)
        if (($beforeIds -join ',') -eq ($afterIds -join ',')) { continue }
        $indexOp = New-CHOperation $Context 'desktop' (Join-Path $p.Path 'archived-sessions.idx') (ConvertTo-CHBytes ([ordered]@{v=1; archived=$afterIds}))
        $indexOp.Before = $indexBefore
        if ($indexOp.After -ne $indexBefore) { $ops.Add($indexOp) }
    }
    $ordered = [ordered]@{}
    foreach ($key in @($next.Keys | Sort-Object)) { $ordered[$key] = $next[$key] }
    $stateOp = New-CHOperation $Context 'state' 'baseline.json' (ConvertTo-CHBytes ([ordered]@{FormatVersion=1; Signature=$Context.Signature; Entries=$ordered}))
    $stateOp.Before = $stateBefore
    if ($stateOp.Before -ne $stateOp.After) { $ops.Add($stateOp) }
    [pscustomobject]@{Operations=$ops; Report=$report; Inventory=$data.Inventory; Snapshot=$data;
        Direction=$Direction; SourceProfile=$directionSource; TargetProfile=$directionTarget; Policy=$Resolution}
}
function Get-CHPreviewRows($Context, $Plan) {
    if ($Plan.Direction -eq 'Both') { throw 'Before/after preview rows require one-way direction.' }
    $sourceId = $Plan.SourceProfile; $targetId = $Plan.TargetProfile
    $sourceRecords = $Plan.Snapshot.Records[$sourceId]; $targetRecords = $Plan.Snapshot.Records[$targetId]
    $reports = @{}; foreach ($entry in $Plan.Report) { $reports[$entry.File] = $entry }
    $planned = @{}
    foreach ($operation in $Plan.Operations) {
        if ($operation.Area -ne 'desktop' -or -not $operation.RelativePath.StartsWith($targetId + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $file = [IO.Path]::GetFileName($operation.RelativePath)
        if ($file -notmatch ('^local_' + $script:GuidPattern + '\.json$')) { continue }
        $planned[$file] = [Text.Encoding]::UTF8.GetString($operation.Bytes) | ConvertFrom-Json
    }
    function Preview-State($Entry) {
        if ($null -eq $Entry) { return $null }
        $title = if ($Entry.title -is [string] -and -not [string]::IsNullOrWhiteSpace($Entry.title)) { $Entry.title } else { 'Untitled session' }
        [pscustomobject]@{Title=$title; Archived=[bool]$Entry.isArchived; Model=[string]$Entry.model; Effort=[string]$Entry.effort;
            LastActivityAt=$Entry.lastActivityAt; CompletedTurns=$Entry.completedTurns}
    }
    foreach ($file in @(@($sourceRecords.Keys) + @($targetRecords.Keys) | Sort-Object -Unique)) {
        $source = $sourceRecords[$file]; $target = $targetRecords[$file]
        $beforeRecord = if ($target) { $target.Record } else { $null }
        $afterRecord = if ($planned.ContainsKey($file)) { $planned[$file] } else { $beforeRecord }
        $entry = $reports[$file]
        $before = Preview-State $beforeRecord; $after = Preview-State $afterRecord
        $sourceState = if ($source) { Preview-State $source.Record } else { $null }
        $title = if ($sourceState) { $sourceState.Title } elseif ($before) { $before.Title } else { 'Untitled session' }
        $changed = @()
        if ($planned.ContainsKey($file)) {
            $changed = @(foreach ($field in $script:HistoryFields) {
                $beforeFields = if ($null -ne $beforeRecord) { Select-CHFields $beforeRecord @($field) } else { [pscustomobject]@{} }
                $afterFields = Select-CHFields $afterRecord @($field)
                if ((Get-CHHash (ConvertTo-CHBytes $beforeFields)) -ne (Get-CHHash (ConvertTo-CHBytes $afterFields))) { $field }
            })
        }
        [pscustomobject]@{File=$file; Title=$title; Action=$(if ($entry) { $entry.Action } else { 'Unchanged' });
            Detail=$(if ($entry) { $entry.Detail } else { 'Already matches; no card change' });
            Source=$sourceState; Before=$before; After=$after; ChangedFields=$changed;
            Pending=[bool]($source.Pending -or $target.Pending)}
    }
}
function Assert-CHWriteAccess($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='') {
    if ($Plan.Direction -notin @('AtoB', 'BtoA', 'Both')) { throw 'Invalid plan direction.' }
    if ($Plan.Direction -ne 'Both') {
        $source = if ($Plan.Direction -eq 'AtoB') { $Context.Config.Profiles[0] } else { $Context.Config.Profiles[1] }
        $target = if ($Plan.Direction -eq 'AtoB') { $Context.Config.Profiles[1] } else { $Context.Config.Profiles[0] }
        if ($Plan.SourceProfile -ne $source.Name -or $Plan.TargetProfile -ne $target.Name) { throw 'Plan direction does not match the selected profiles.' }
        foreach ($op in $Plan.Operations) {
            if ($op.Area -eq 'desktop' -and -not $op.RelativePath.StartsWith($target.Path + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'One-way plan attempted a write outside the destination profile.'
            }
        }
    }
    if ($AllowRunning) {
        if ($Plan.Direction -eq 'Both') { throw 'AllowRunning requires one-way Direction; Both requires Claude closed.' }
        if (-not $ActiveProfile) { throw 'AllowRunning requires -ActiveProfile identifying the active source. The destination must be inactive.' }
        if ((Resolve-CHProfile $Context.Config.Profiles $ActiveProfile).Name -ne $Plan.SourceProfile) { throw 'ActiveProfile must be the source; refusing writes to the active destination.' }
    }
    else {
        if ($ActiveProfile) { throw 'ActiveProfile requires -AllowRunning.' }
        Assert-CHStopped
    }
}
function Assert-CHSnapshot($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='') {
    Assert-CHWriteAccess $Context $Plan $AllowRunning $ActiveProfile
    $fresh = Get-CHRecords $Context
    foreach ($p in $Context.Config.Profiles) {
        $old = $Plan.Snapshot.Records[[string]$p.Name]
        $new = $fresh.Records[[string]$p.Name]
        if ($old.Count -ne $new.Count) { throw 'History changed during planning. Run again.' }
        foreach ($key in $old.Keys) {
            if (-not $new.ContainsKey($key) -or $new[$key].FileHash -ne $old[$key].FileHash -or $new[$key].ModifiedUtc -ne $old[$key].ModifiedUtc) { throw 'History changed during planning. Run again.' }
        }
    }
    if ((($fresh.Tombstones.Keys | Sort-Object) -join ',') -ne (($Plan.Snapshot.Tombstones.Keys | Sort-Object) -join ',')) { throw 'Deletion markers changed during planning.' }
}
function Invoke-CHApply($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='') {
    Assert-CHSnapshot $Context $Plan $AllowRunning $ActiveProfile
    if (-not $Plan.Operations.Count) { Write-Output 'Already synchronized; nothing to write.'; return }
    [void](Assert-CHPath $Context.StateRoot $Context.StateRoot)
    Protect-CHDirectory $Context.StateRoot
    $lock = [IO.File]::Open((Join-Path $Context.StateRoot 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Assert-CHSnapshot $Context $Plan $AllowRunning $ActiveProfile
        $bundle = Assert-CHPath (Join-Path $Context.StateRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))) $Context.StateRoot
        [IO.Directory]::CreateDirectory($bundle) | Out-Null
        $entries = [Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($op in $Plan.Operations) {
            if ((Get-CHFileHash $op.Path) -ne $op.Before) { throw 'A planned file changed. Run again.' }
            $snapshot = 'before-' + $i + '.bin'
            if ($op.Before -ne 'ABSENT') {
                [IO.File]::Copy($op.Path, (Join-Path $bundle $snapshot))
                if ((Get-CHFileHash (Join-Path $bundle $snapshot)) -ne $op.Before) { throw 'Backup verification failed.' }
            }
            $entries.Add([pscustomobject]@{Area=$op.Area; RelativePath=$op.RelativePath; Before=$op.Before; After=$op.After; Snapshot=$snapshot})
            $i++
        }
        $manifest = [pscustomobject]@{FormatVersion=2; Signature=$Context.Signature; ProfilePaths=@($Context.Config.Profiles.Path);
            Direction=$Plan.Direction; SourceProfile=$Plan.SourceProfile; TargetProfile=$Plan.TargetProfile;
            AllowRunning=$AllowRunning; Status='prepared'; Entries=@($entries.ToArray())}
        $manifestPath = Join-Path $bundle 'manifest.json'
        Write-CHAtomic $manifestPath (ConvertTo-CHBytes $manifest)
        Write-Output "Backup: $bundle"
        foreach ($op in $Plan.Operations) {
            Assert-CHWriteAccess $Context $Plan $AllowRunning $ActiveProfile
            $root = if ($op.Area -eq 'desktop') { $Context.Config.SessionsRoot } else { $Context.StateRoot }
            [void](Assert-CHPath $op.Path $root)
            if ((Get-CHFileHash $op.Path) -ne $op.Before) { throw "A file changed; use Undo with backup $bundle before retrying." }
            Write-CHAtomic $op.Path $op.Bytes
            if ((Get-CHFileHash $op.Path) -ne $op.After) { throw "Write verification failed; use Undo with backup $bundle." }
        }
        $manifest.Status = 'complete'
        Write-CHAtomic $manifestPath (ConvertTo-CHBytes $manifest)
        Write-Output "Sync complete. $($Plan.Operations.Count) files written, including index/state files."
    }
    finally { $lock.Dispose() }
}
function Get-CHUndo($Context, [string]$Bundle) {
    if (-not $Bundle) { throw 'Undo requires -Backup with the full backup directory printed by Sync.' }
    $bundlePath = Assert-CHPath $Bundle (Join-Path $Context.StateRoot 'backups')
    $m = [IO.File]::ReadAllText((Join-Path $bundlePath 'manifest.json')) | ConvertFrom-Json
    if ($m.FormatVersion -ne 2 -or $m.Signature -ne $Context.Signature -or $m.Status -notin @('prepared', 'complete', 'undone')) { throw 'Backup does not belong to this configuration.' }
    $ops = [Collections.Generic.List[object]]::new()
    if ($m.Status -eq 'undone') { return [pscustomobject]@{Manifest=$m; Bundle=$bundlePath; Operations=$ops} }
    foreach ($entry in $m.Entries) {
        if ($entry.Area -eq 'desktop') {
            $allowed = $false
            foreach ($p in $Context.Config.Profiles) {
                $pattern = '^' + [regex]::Escape($p.Path) + '\\(local_' + $script:GuidPattern + '\.json|archived-sessions\.idx)$'
                if ($entry.RelativePath -match $pattern) { $allowed = $true }
            }
            if (-not $allowed) { throw 'Invalid Desktop path in backup.' }
            $root = $Context.Config.SessionsRoot
        }
        elseif ($entry.Area -eq 'state' -and $entry.RelativePath -eq 'baseline.json') { $root = $Context.StateRoot }
        else { throw 'Invalid backup area/path.' }
        if ($entry.Snapshot -notmatch '^before-[0-9]+\.bin$') { throw 'Invalid snapshot filename.' }
        $target = Assert-CHPath (Join-Path $root $entry.RelativePath) $root
        $snapshot = Assert-CHPath (Join-Path $bundlePath $entry.Snapshot) $bundlePath
        if ($entry.Before -ne 'ABSENT' -and (Get-CHFileHash $snapshot) -ne $entry.Before) { throw 'Backup hash mismatch; refusing restore.' }
        $current = Get-CHFileHash $target
        if ($current -eq $entry.Before) { continue } # Also handles interrupted runs and repeated Undo.
        if ($current -ne $entry.After) { throw "File changed after sync; refusing to overwrite: $($entry.RelativePath)" }
        $ops.Add([pscustomobject]@{Path=$target; Root=$root; Entry=$entry; Snapshot=$snapshot})
    }
    [pscustomobject]@{Manifest=$m; Bundle=$bundlePath; Operations=$ops}
}
function Invoke-CHUndo($Context, $Undo) {
    Assert-CHStopped
    Protect-CHDirectory $Context.StateRoot
    $lock = [IO.File]::Open((Join-Path $Context.StateRoot 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        foreach ($op in $Undo.Operations) {
            Assert-CHStopped
            [void](Assert-CHPath $op.Path $op.Root)
            if ((Get-CHFileHash $op.Path) -ne $op.Entry.After) { throw 'A file changed during Undo; refusing overwrite.' }
            if ($op.Entry.Before -eq 'ABSENT') {
                $retained = Assert-CHPath (Join-Path $Undo.Bundle ('retained-' + $op.Entry.Snapshot)) $Undo.Bundle
                Move-Item -LiteralPath $op.Path -Destination $retained
            }
            else {
                Write-CHAtomic $op.Path ([IO.File]::ReadAllBytes($op.Snapshot))
                [IO.File]::SetLastWriteTimeUtc($op.Path, [IO.File]::GetLastWriteTimeUtc($op.Snapshot))
            }
        }
        $Undo.Manifest.Status = 'undone'
        Write-CHAtomic (Join-Path $Undo.Bundle 'manifest.json') (ConvertTo-CHBytes $Undo.Manifest)
        Write-Output "Undo complete. $($Undo.Operations.Count) files restored; added files retained in the backup."
    }
    finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (($AllowRunning -or $ActiveProfile) -and $Mode -notin @('Plan', 'Sync')) { throw 'AllowRunning and ActiveProfile apply only to Plan or Sync; Undo requires Claude closed.' }
    if ($Mode -eq 'Profiles') {
        $discovery = Get-CHConfig $ConfigPath '' '' $false
        foreach ($p in $discovery.Catalog) {
            [pscustomobject]@{Email=$p.Email; EmailSource=$p.EmailSource; ProfileId=$p.Name; Alias=$p.Alias; Sessions=@(Get-ChildItem -LiteralPath $p.FullPath -File -Filter 'local_*.json').Count}
        }
        return
    }
    if ($Mode -eq 'Undo' -and -not $ProfileA -and -not $ProfileB) {
        $discovery = Get-CHConfig $ConfigPath '' '' $false
        if (-not $Backup) { throw 'Undo requires -Backup.' }
        $bundlePath = Assert-CHPath $Backup (Join-Path $discovery.StateHome 'pairs')
        $manifestPath = Assert-CHPath (Join-Path $bundlePath 'manifest.json') $bundlePath
        $receipt = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($receipt.FormatVersion -ne 2 -or @($receipt.ProfilePaths).Count -ne 2) { throw 'Unsupported backup manifest.' }
        $ProfileA = [string]$receipt.ProfilePaths[0]; $ProfileB = [string]$receipt.ProfilePaths[1]
    }
    $context = Get-CHConfig $ConfigPath $ProfileA $ProfileB
    if ($Mode -eq 'Inventory') { (Get-CHRecords $context).Inventory; return }
    if ($Mode -eq 'Undo') {
        $undoPlan = Get-CHUndo $context $Backup
        Write-Output "Undo plan: $($undoPlan.Operations.Count) files."
        if ($undoPlan.Manifest.Status -eq 'undone') { Write-Output 'This backup was already undone.'; return }
        if ($PSCmdlet.ShouldProcess('the configured Claude history profiles', 'Restore this sync backup')) { Invoke-CHUndo $context $undoPlan }
        return
    }
    Write-Host 'Reading Desktop history records and transcript filenames (offline)...'
    $planArgs = @{Context=$context; Winner=$WinnerProfile; WithScheduled=[bool]$IncludeScheduled; Direction=$Direction}
    if ($Policy) { $planArgs.Resolution = $Policy }
    $plan = New-CHPlan @planArgs
    if ($AllowRunning -or $ActiveProfile -or ($Mode -eq 'Sync' -and -not $WhatIfPreference)) {
        Assert-CHWriteAccess $context $plan ([bool]$AllowRunning) $ActiveProfile
    }
    $plan.Report
    Write-Output "Direction: $Direction. Policy: $($plan.Policy). Plan: $(@($plan.Report | Where-Object Action -eq 'Add').Count) additions, $(@($plan.Report | Where-Object Action -eq 'Update').Count) updates, $(@($plan.Report | Where-Object Action -eq 'Conflict').Count) conflicts, $(@($plan.Report | Where-Object Action -eq 'Skipped').Count) skipped; $(@($plan.Report | Where-Object ArchiveChanged).Count) archive/unarchive changes."
    if ($Mode -eq 'Sync' -and $PSCmdlet.ShouldProcess('the configured Claude history profiles', "Back up and sync local history ($Direction)")) { Invoke-CHApply $context $plan ([bool]$AllowRunning) $ActiveProfile }
}
