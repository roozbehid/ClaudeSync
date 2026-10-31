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
    [switch]$AllowOpenDestination,
    [string]$ActiveProfile,
    [switch]$IncludeScheduled,
    [ValidateSet('All', 'Folder', 'Session')][string]$Scope = 'All',
    [string]$ScopeFolder,
    [string]$ScopeSession,
    [string]$Backup
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'profiles.json' }
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:LineageFields = @('spawnedFrom', 'forkedFromSessionId', 'forkedAtMessageUuid', 'lineageDetached')
$script:HistoryFields = @('title', 'titleSource', 'isArchived', 'lastActivityAt',
    'completedTurns', 'titleTurn', 'postTurnSummary', 'postTurnSummaryFor',
    'lastAssistantUuid', 'model', 'effort', 'branch', 'sourceBranch', 'writtenBranches') + $script:LineageFields
$script:IdentityFields = @('sessionId', 'cliSessionId', 'wslConfig', 'sshConfig', 'sshRemoteTranscriptPath')
$script:CliFields = @('cliSessionId', 'priorCliSessionIds')
$script:SyncFields = $script:HistoryFields + $script:CliFields
# A continuing session can move between worktrees. Paths are needed for new
# cards, but are not identity and must not overwrite an existing account's paths.
$script:LocationFields = @('cwd', 'originCwd')
$script:CloneFields = $script:IdentityFields + $script:HistoryFields + @(
    'createdAt', 'lastFocusedAt', 'worktreePath', 'worktreeName', 'gitAnchors',
    'priorCliSessionIds', 'sshRemoteProcessId') + $script:LocationFields

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
        # Avoid PowerShell provider calls for every ancestor of every transcript.
        # Still inspect each path afresh; caching would miss a replaced junction.
        $attributes = $null
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch {
            $cause = $_.Exception
            while ($cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]) { throw }
        }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a reparse point: $cursor"
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
function Get-CHDesktopDataRoots {
    # Electron children advertise the data directory even when the main process
    # does not. This follows relocations without depending on an app version,
    # Store publisher ID, or the name/location of the data directory.
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'Claude.exe' AND SessionId = $session" -Property CommandLine -ErrorAction Stop)
    }
    catch {
        # Process inspection can be unavailable; closed-app discovery still works.
        Write-Verbose "Cannot inspect Claude's data directory: $($_.Exception.Message)"
        return
    }
    foreach ($process in $processes) {
        $argument = [regex]::Match([string]$process.CommandLine,
            '(?:^|\s)(?:"--user-data-dir=([^"]+)"|--user-data-dir(?:=|\s+)(?:"([^"]+)"|([^\s"]+)))(?=\s|$)')
        if (-not $argument.Success) { continue }
        foreach ($group in 1..3) {
            if ($argument.Groups[$group].Success) {
                $path = $argument.Groups[$group].Value
                if ([IO.Path]::IsPathRooted($path)) { [IO.Path]::GetFullPath($path) }
                break
            }
        }
    }
}
function Find-CHSessionsRoot {
    $activeRoots = @(Get-CHDesktopDataRoots | Sort-Object -Unique)
    $dataRoots = @($activeRoots)
    if (-not $activeRoots.Count) {
        # Bounded, read-only fallback for a stopped Desktop. Enumerate installation
        # names rather than pinning a particular Store family or release.
        foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
            if (-not $base -or -not [IO.Directory]::Exists($base)) { continue }
            foreach ($directory in Get-ChildItem -LiteralPath $base -Directory -Filter 'Claude*') {
                $dataRoots += $directory.FullName
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $dataRoots += @(Get-ChildItem -LiteralPath $directory.FullName -Directory | Select-Object -ExpandProperty FullName)
            }
        }
        if ($env:LOCALAPPDATA) {
            $packages = Join-Path $env:LOCALAPPDATA 'Packages'
            if ([IO.Directory]::Exists($packages)) {
                foreach ($package in Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*') {
                    $dataRoots += Join-Path $package.FullName 'LocalCache\Roaming\Claude'
                }
            }
        }
    }
    $candidates = @(@(foreach ($root in $dataRoots) {
        $candidate = Join-Path $root 'claude-code-sessions'
        if ([IO.Directory]::Exists($candidate)) { Assert-CHPath $candidate $candidate }
    }) | Sort-Object -Unique)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) {
        throw ("Cannot choose a unique Desktop history directory. Candidates: " + ($candidates -join '; ') + '. Close other Desktop installations, or set SessionsRoot in profiles.json to the desired absolute path.')
    }
    if ($activeRoots.Count) {
        throw ("No claude-code-sessions directory exists in the running Desktop data directories: " + ($activeRoots -join '; ') + '. Open a Code session first, or set SessionsRoot in profiles.json to the desired absolute path.')
    }
    throw 'Cannot find a Desktop history directory. Open Claude Desktop and a Code session so its data directory can be detected, or set SessionsRoot in profiles.json to the desired absolute path.'
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
        if (-not [IO.Path]::IsPathRooted($value) -or -not [IO.Directory]::Exists($value)) {
            $hint = if ($key -eq 'SessionsRoot') { ' Use SessionsRoot: "Auto" to follow the running Desktop installation, or correct the explicit path.' } else { '' }
            throw "Missing configured $key directory: $value.$hint"
        }
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
function Get-CHViewHash($Record) {
    # Prefix separates pointer-aware hashes from legacy history-only baselines.
    # Old entries still prevent resurrection; they never authorize pointer changes.
    'v2:' + (Get-CHHash (ConvertTo-CHBytes (Select-CHFields $Record $script:SyncFields)))
}
function Get-CHCliChain($Record) {
    $seen = @{}
    $prior = $Record.priorCliSessionIds
    if ($null -ne $prior -and $prior -isnot [array]) { throw 'Invalid CLI continuation history: expected an array.' }
    foreach ($id in @($prior) + @($Record.cliSessionId)) {
        if ($null -eq $id -and $null -eq $prior) { continue }
        if ($id -isnot [string] -or $id -notmatch ('^' + $script:GuidPattern + '$') -or $seen.ContainsKey($id)) {
            throw 'Invalid CLI continuation history: IDs must be distinct GUIDs.'
        }
        $seen[$id] = $true
        $id
    }
}
function Get-CHCliRelation($Left, $Right) {
    $stable = @($script:IdentityFields | Where-Object { $_ -ne 'cliSessionId' })
    if ((Get-CHHash (ConvertTo-CHBytes (Select-CHFields $Left $stable))) -ne
        (Get-CHHash (ConvertTo-CHBytes (Select-CHFields $Right $stable)))) { return 'Conflict' }
    $leftChain = @(Get-CHCliChain $Left); $rightChain = @(Get-CHCliChain $Right)
    $shared = [Math]::Min($leftChain.Count, $rightChain.Count)
    for ($i=0; $i -lt $shared; $i++) { if ($leftChain[$i] -ne $rightChain[$i]) { return 'Conflict' } }
    if ($leftChain.Count -eq $rightChain.Count) { return 'Same' }
    # Remote continuation can also change host-specific transcript references;
    # only verified local continuation is supported here.
    foreach ($record in @($Left, $Right)) {
        if ($record.wslConfig -or $record.sshConfig -or $record.sshRemoteTranscriptPath -or $record.sshRemoteProcessId) { return 'Conflict' }
    }
    if ($leftChain.Count -gt $rightChain.Count) { 'LeftContinues' } else { 'RightContinues' }
}
function Get-CHLineageParent($Record) {
    # Match Desktop's effective lineage: a detached card has no attached parent;
    # a user fork can supersede its inherited spawnedFrom reference.
    if ($Record.lineageDetached -eq $true) { return }
    $spawn = $Record.spawnedFrom
    $fork = [string]$Record.forkedFromSessionId
    if ($spawn.sideSession -eq $true -and -not $spawn.userFork -and
        (-not $fork -or $fork -eq $spawn.sessionId -or $fork -eq $spawn.deletedParent.sessionId)) {
        return [string]$spawn.sessionId
    }
    if ($fork) { return $fork }
    if ($spawn) { return [string]$spawn.sessionId }
}
function Get-CHFolder($Record) {
    if ($Record.originCwd -is [string] -and -not [string]::IsNullOrWhiteSpace($Record.originCwd)) { return $Record.originCwd }
    [string]$Record.cwd
}
function Get-CHScopeFiles($Records, [string]$Scope, [string]$Folder, [string]$Session) {
    $selected = @{}
    if ($Scope -eq 'All') {
        if ($Folder -or $Session) { throw 'Choose Folder or Session scope before specifying a selection.' }
        foreach ($name in $Records.Keys) { $selected[$name] = $true }
        return ,$selected
    }
    if ($Scope -eq 'Session') {
        if ($Folder -or $Session -notmatch ('^local_' + $script:GuidPattern + '$')) { throw 'Choose a valid source Desktop session ID for Session scope.' }
        $name = $Session + '.json'
        if (-not $Records.ContainsKey($name)) { throw 'Selected session is no longer in the source. Refresh sessions.' }
        $selected[$name] = $true
    }
    elseif ($Scope -eq 'Folder') {
        if ($Session -or [string]::IsNullOrWhiteSpace($Folder) -or -not [IO.Path]::IsPathRooted($Folder)) { throw 'Choose a full source folder path for Folder scope.' }
        $prefix = $Folder.Replace('/', '\').TrimEnd('\')
        $comparison = if ($Folder -match '^[A-Za-z]:[\\/]|^\\\\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        foreach ($name in $Records.Keys) {
            $path = (Get-CHFolder $Records[$name].Record).Replace('/', '\').TrimEnd('\')
            if ($path.Equals($prefix, $comparison) -or $path.StartsWith($prefix + '\', $comparison)) { $selected[$name] = $true }
        }
        if (-not $selected.Count) { throw 'No source sessions match this folder. Refresh folders or choose another path.' }
    }
    else { throw 'Invalid sync scope.' }
    # Include all descendants, including children running in separate worktrees.
    do {
        $added = $false
        foreach ($name in $Records.Keys) {
            if ($selected.ContainsKey($name)) { continue }
            $parent = Get-CHLineageParent $Records[$name].Record
            if ($parent -and $selected.ContainsKey($parent + '.json')) { $selected[$name] = $true; $added = $true }
        }
    } while ($added)
    ,$selected
}
function Get-CHScopeChoices($Context) {
    $data = Get-CHRecords $Context
    $records = $data.Records[[string]$Context.Config.Profiles[0].Name]
    $folders = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    $sessions = @(foreach ($entry in $records.Values) {
        $folder = Get-CHFolder $entry.Record
        if (-not $folders.ContainsKey($folder)) { $folders[$folder] = 0 }
        $folders[$folder]++
        [pscustomobject]@{Id=$entry.Record.sessionId; Title=[string]$entry.Record.title; Folder=$folder; Parent=(Get-CHLineageParent $entry.Record)}
    })
    [pscustomobject]@{Folders=@(foreach ($path in @($folders.Keys | Sort-Object)) { [pscustomobject]@{Path=$path; Count=$folders[$path]} }); Sessions=@($sessions | Sort-Object Title,Id)}
}
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
                if (-not $pending) { [void]@(Get-CHCliChain $j) }
                if ($null -ne $j.PSObject.Properties['isArchived'] -and $j.isArchived -isnot [bool]) { throw 'Invalid archive flag.' }
                if ($null -ne $j.spawnedFrom -and ($j.spawnedFrom -isnot [pscustomobject] -or $j.spawnedFrom.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($j.spawnedFrom.sessionId))) { throw 'Invalid spawnedFrom parent reference.' }
                if ($null -ne $j.forkedFromSessionId -and ($j.forkedFromSessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($j.forkedFromSessionId))) { throw 'Invalid fork parent reference.' }
                if ($null -ne $j.lineageDetached -and $j.lineageDetached -isnot [bool]) { throw 'Invalid lineageDetached flag.' }
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
    [pscustomobject]@{Records=$records; Tombstones=$tombstones; Inventory=$inventory; Transcripts=$transcripts}
}
function New-CHOperation($Context, [string]$Area, [string]$RelativePath, [byte[]]$Bytes) {
    $root = if ($Area -eq 'desktop') { $Context.Config.SessionsRoot } elseif ($Area -eq 'state') { $Context.StateRoot } else { throw 'Invalid operation area.' }
    $path = Assert-CHPath (Join-Path $root $RelativePath) $root
    [pscustomobject]@{Area=$Area; RelativePath=$RelativePath; Path=$path; Before=(Get-CHFileHash $path); After=(Get-CHHash $Bytes); Bytes=$Bytes}
}
function New-CHPlan($Context, [string]$Winner='', [bool]$WithScheduled=$false,
    [ValidateSet('Changes', 'Profile', 'Newest')][string]$Resolution,
    [ValidateSet('AtoB', 'BtoA', 'Both')][string]$Direction='AtoB',
    [ValidateSet('All', 'Folder', 'Session')][string]$Scope='All', [string]$ScopeFolder='', [string]$ScopeSession='') {
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
    if ($Scope -ne 'All' -and $Direction -eq 'Both') { throw 'Folder and Session scopes require one-way sync.' }
    $scopeSource = if ($directionSource) { $directionSource } else { $aName }
    $selection = Get-CHScopeFiles $data.Records[$scopeSource] $Scope $ScopeFolder $ScopeSession
    $selectedFiles = if ($Scope -ne 'All') { $selection } else { $null }
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
    $scopeCount = if ($Direction -eq 'Both') { $allNames.Count } else { $selection.Count }
    foreach ($name in $allNames) {
        if ($null -ne $selectedFiles -and -not $selectedFiles.ContainsKey($name)) { continue }
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
        # links; updates retain the destination's own links. Desktop also assigns
        # envScopeId to local sessions. Require a local transcript to admit scoped
        # cards; CloneFields omits that account-specific ID from new copies.
        elseif (@($present | Where-Object { $_.Record.envScopeId -and -not $_.HasTranscript }).Count) { $reason = 'Account-bound environment scope without local transcript' }
        elseif (-not $WithScheduled -and @($present | Where-Object { $_.Record.scheduledTaskId }).Count) { $reason = 'Scheduled history requires -IncludeScheduled' }
        elseif (@($present | Where-Object { -not $_.HasTranscript -and $_.Kind -notin @('WSL', 'SSH') }).Count) { $reason = 'Local transcript missing' }
        elseif (@($present | Where-Object { $data.Tombstones.ContainsKey($_.Id) -or $data.Tombstones.ContainsKey([string]$_.Record.cliSessionId) }).Count) { $reason = 'Deletion marker present' }
        elseif ($present.Count -eq 1 -and $baseline.ContainsKey($name)) { $reason = 'Previously synced record removed; no resurrection' }
        if ($reason) { $report.Add([pscustomobject]@{File=$name; Action='Skipped'; Detail=$reason}); continue }
        if ($a -and $b) {
            $relation = Get-CHCliRelation $a.Record $b.Record
            if ($relation -eq 'Conflict') { $report.Add([pscustomobject]@{File=$name; Action='Conflict'; Detail='Session/project identity differs or CLI continuation branches'}); continue }
            if ($relation -ne 'Same' -and $Resolution -ne 'Profile') {
                $report.Add([pscustomobject]@{File=$name; Action='Conflict'; Detail='CLI continuation differs; choose -Policy Profile -WinnerProfile for the continuing source'}); continue
            }
            if ($a.ViewHash -eq $b.ViewHash) { $next[$name] = $a.ViewHash; $reconciled[$name] = $true; continue }
            $sourceName = $null
            $decision = ''
            if ($Resolution -eq 'Profile') { $sourceName = $winningName; $decision = 'chosen profile wins' }
            elseif ($baseline.ContainsKey($name)) {
                $aBaselineHash = $a.ViewHash; $bBaselineHash = $b.ViewHash
                # Legacy history-only hashes remain useful only after the full
                # current CLI chains have been verified equal above.
                if ($relation -eq 'Same' -and -not $baseline[$name].StartsWith('v2:')) {
                    $aBaselineHash = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $a.Record $script:HistoryFields))
                    $bBaselineHash = Get-CHHash (ConvertTo-CHBytes (Select-CHFields $b.Record $script:HistoryFields))
                }
                if ($aBaselineHash -eq $baseline[$name]) { $sourceName = $bName }
                elseif ($bBaselineHash -eq $baseline[$name]) { $sourceName = $aName }
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
        $continuationDetail = ''
        if ($target -and $source.Record.cliSessionId -ne $target.Record.cliSessionId) {
            if ((Get-CHCliRelation $source.Record $target.Record) -ne 'LeftContinues') {
                $report.Add([pscustomobject]@{File=$name; Action='Conflict'; Detail='Source is an older CLI continuation; refusing to replace the destination with older contents'}); continue
            }
            $chain = @(Get-CHCliChain $source.Record)
            if (@($chain | Where-Object { -not $data.Transcripts.ContainsKey($_) -or $data.Tombstones.ContainsKey($_) }).Count) {
                $report.Add([pscustomobject]@{File=$name; Action='Skipped'; Detail='CLI continuation transcript missing or deleted'}); continue
            }
            $continuationDetail = '; CLI continuation ' + $target.Record.cliSessionId + ' -> ' + $source.Record.cliSessionId
        }
        $sourceProfile = @($c.Profiles | Where-Object { $_.Name -eq $sourceName })[0]
        $profile = @($c.Profiles | Where-Object { $_.Name -eq $targetName })[0]
        $archiveChange = $target -and ([bool]$target.Record.isArchived -ne [bool]$source.Record.isArchived)
        $archiveDetail = if ($archiveChange) { if ($source.Record.isArchived) { '; archive' } else { '; unarchive' } } else { '' }
        if ($target) {
            # Preserve the target's own permissions, MCP setup, remote links, and unknown fields.
            # Do not mutate the destination snapshot while constructing a plan.
            # Preview comparisons and stale-plan checks need its original values.
            $out = [Text.Encoding]::UTF8.GetString((ConvertTo-CHBytes $target.Record)) | ConvertFrom-Json
            foreach ($key in $script:SyncFields) {
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
        $report.Add([pscustomobject]@{File=$name; Action=$action; Detail="$($sourceProfile.Label) -> $($profile.Label); $decision$archiveDetail$continuationDetail"; ArchiveChanged=[bool]$archiveChange})
    }
    # Validate against the final projected destination, independent of filename
    # order. Never create a link to a skipped/deleted/mismatched parent or a cycle.
    # Revert rejected operations before constructing archive indexes and baseline.
    $projected = @{}; $cardOperations = [Collections.Generic.List[object]]::new()
    foreach ($p in $c.Profiles) {
        $cards = @{}
        foreach ($entry in $data.Records[[string]$p.Name].GetEnumerator()) { $cards[$entry.Key] = $entry.Value.Record }
        $projected[[string]$p.Name] = $cards
        foreach ($operation in $ops) {
            if ($operation.Area -ne 'desktop' -or -not $operation.RelativePath.StartsWith($p.Path + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $file = [IO.Path]::GetFileName($operation.RelativePath)
            $cards[$file] = [Text.Encoding]::UTF8.GetString($operation.Bytes) | ConvertFrom-Json
            $other = if ($p.Name -eq $aName) { $bName } else { $aName }
            $cardOperations.Add([pscustomobject]@{Operation=$operation; File=$file; Target=$p.Name; Source=$other})
        }
    }
    do {
        $removed = $false
        foreach ($entry in @($cardOperations.ToArray())) {
            $cards = $projected[[string]$entry.Target]
            $card = $cards[$entry.File]
            $seen = @{}; $reason = ''
            while ($null -ne $card) {
                if ($seen.ContainsKey([string]$card.sessionId)) { $reason = 'Parent lineage contains a cycle'; break }
                $seen[[string]$card.sessionId] = $true
                $parentId = Get-CHLineageParent $card
                if (-not $parentId) { break }
                if ($parentId -notmatch ('^local_' + $script:GuidPattern + '$')) { $reason = 'Parent lineage is not a local Desktop history reference'; break }
                $parentFile = $parentId + '.json'
                if (-not $cards.ContainsKey($parentFile)) { $reason = 'Parent history unavailable in destination (missing, skipped, or deleted): ' + $parentId; break }
                $sourceParent = $data.Records[[string]$entry.Source][$parentFile]
                $parent = $cards[$parentFile]
                $parentCliId = [string]$parent.cliSessionId
                if ($data.Tombstones.ContainsKey($parentId.Substring(6)) -or ($parentCliId -and $data.Tombstones.ContainsKey($parentCliId))) { $reason = 'Parent history has a deletion marker: ' + $parentId; break }
                if ($sourceParent -and (Get-CHCliRelation $sourceParent.Record $parent) -ne 'Same') {
                    $reason = 'Parent session/project identity differs: ' + $parentId; break
                }
                $card = $parent
            }
            if (-not $reason) { continue }
            [void]$ops.Remove($entry.Operation)
            [void]$cardOperations.Remove($entry)
            $existing = $data.Records[[string]$entry.Target][$entry.File]
            if ($existing) { $cards[$entry.File] = $existing.Record } else { $cards.Remove($entry.File) }
            if ($baseline.ContainsKey($entry.File)) { $next[$entry.File] = $baseline[$entry.File] } else { $next.Remove($entry.File) }
            $reconciled.Remove($entry.File)
            $row = @($report | Where-Object File -eq $entry.File)[0]
            $row.Action = 'Skipped'; $row.Detail = $reason; $row.ArchiveChanged = $false
            $removed = $true
        }
    } while ($removed)
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
    $readFiles = @{}
    if ($null -ne $selectedFiles) {
        foreach ($name in $selectedFiles.Keys) { $readFiles[$name] = $true }
        do {
            $added = $false
            foreach ($profileRecords in $data.Records.Values) {
                foreach ($name in @($readFiles.Keys)) {
                    $entry = $profileRecords[$name]
                    if (-not $entry) { continue }
                    $parent = Get-CHLineageParent $entry.Record
                    if ($parent -and -not $readFiles.ContainsKey($parent + '.json')) { $readFiles[$parent + '.json'] = $true; $added = $true }
                }
            }
        } while ($added)
    }
    [pscustomobject]@{Operations=$ops; Report=$report; Inventory=$data.Inventory; Snapshot=$data;
        Scope=[pscustomobject]@{Mode=$Scope; Folder=$ScopeFolder; Session=$ScopeSession; Count=$scopeCount}; SelectedFiles=$selectedFiles; ReadFiles=$readFiles;
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
            CliSessionId=[string]$Entry.cliSessionId; PriorCliSessionIds=@($Entry.priorCliSessionIds | Where-Object { $null -ne $_ });
            LastActivityAt=$Entry.lastActivityAt; CompletedTurns=$Entry.completedTurns;
            ParentSessionId=(Get-CHLineageParent $Entry); SideSession=[bool]$Entry.spawnedFrom.sideSession; LineageDetached=[bool]$Entry.lineageDetached}
    }
    foreach ($file in @(@($sourceRecords.Keys) + @($targetRecords.Keys) | Sort-Object -Unique)) {
        if ($null -ne $Plan.SelectedFiles -and -not $Plan.SelectedFiles.ContainsKey($file)) { continue }
        $source = $sourceRecords[$file]; $target = $targetRecords[$file]
        $beforeRecord = if ($target) { $target.Record } else { $null }
        $afterRecord = if ($planned.ContainsKey($file)) { $planned[$file] } else { $beforeRecord }
        $entry = $reports[$file]
        $before = Preview-State $beforeRecord; $after = Preview-State $afterRecord
        $sourceState = if ($source) { Preview-State $source.Record } else { $null }
        $title = if ($sourceState) { $sourceState.Title } elseif ($before) { $before.Title } else { 'Untitled session' }
        $changed = @()
        if ($planned.ContainsKey($file)) {
            $changed = @(foreach ($field in $script:SyncFields) {
                $beforeFields = if ($null -ne $beforeRecord) { Select-CHFields $beforeRecord @($field) } else { [pscustomobject]@{} }
                $afterFields = Select-CHFields $afterRecord @($field)
                if ((Get-CHHash (ConvertTo-CHBytes $beforeFields)) -ne (Get-CHHash (ConvertTo-CHBytes $afterFields))) { $field }
            })
        }
        [pscustomobject]@{File=$file; Title=$title; Action=$(if ($entry) { $entry.Action } else { 'Unchanged' });
            Folder=$(if ($source) { Get-CHFolder $source.Record } else { Get-CHFolder $target.Record });
            Detail=$(if ($entry) { $entry.Detail } else { 'Already matches; no card change' });
            Source=$sourceState; Before=$before; After=$after; ChangedFields=$changed;
            Pending=[bool]($source.Pending -or $target.Pending)}
    }
}
function Assert-CHWriteAccess($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='', [bool]$AllowOpenDestination=$false) {
    if ($Plan.Direction -notin @('AtoB', 'BtoA', 'Both')) { throw 'Invalid plan direction.' }
    if ($Plan.Direction -ne 'Both') {
        $source = if ($Plan.Direction -eq 'AtoB') { $Context.Config.Profiles[0] } else { $Context.Config.Profiles[1] }
        $target = if ($Plan.Direction -eq 'AtoB') { $Context.Config.Profiles[1] } else { $Context.Config.Profiles[0] }
        if ($Plan.SourceProfile -ne $source.Name -or $Plan.TargetProfile -ne $target.Name) { throw 'Plan direction does not match the selected profiles.' }
        foreach ($op in $Plan.Operations) {
            if ($op.Area -eq 'desktop' -and -not $op.RelativePath.StartsWith($target.Path + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'One-way plan attempted a write outside the destination profile.'
            }
            if ($op.Area -eq 'desktop' -and $null -ne $Plan.SelectedFiles) {
                $file = [IO.Path]::GetFileName($op.RelativePath)
                if ($file -ne 'archived-sessions.idx' -and -not $Plan.SelectedFiles.ContainsKey($file)) { throw 'Plan attempted a write outside the selected scope.' }
            }
        }
    }
    if ($AllowOpenDestination) {
        if ($AllowRunning -or $ActiveProfile) { throw 'AllowOpenDestination is a separate manual mode; do not combine it with AllowRunning or ActiveProfile.' }
        if ($Plan.Direction -eq 'Both') { throw 'AllowOpenDestination requires one-way sync.' }
        if ($Plan.Scope.Mode -notin @('Folder','Session') -or $null -eq $Plan.SelectedFiles -or -not $Plan.SelectedFiles.Count) { throw 'AllowOpenDestination requires an explicit nonempty Folder or Session scope.' }
    }
    elseif ($AllowRunning) {
        if ($Plan.Direction -eq 'Both') { throw 'AllowRunning requires one-way Direction; Both requires Claude closed.' }
        if (-not $ActiveProfile) { throw 'AllowRunning requires -ActiveProfile identifying the active source. The destination must be inactive.' }
        if ((Resolve-CHProfile $Context.Config.Profiles $ActiveProfile).Name -ne $Plan.SourceProfile) { throw 'ActiveProfile must be the source; refusing writes to the active destination.' }
    }
    else {
        if ($ActiveProfile) { throw 'ActiveProfile requires -AllowRunning.' }
        Assert-CHStopped
    }
}
function Assert-CHSnapshot($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='', [bool]$AllowOpenDestination=$false) {
    Assert-CHWriteAccess $Context $Plan $AllowRunning $ActiveProfile $AllowOpenDestination
    $fresh = Get-CHRecords $Context
    if ($null -ne $Plan.SelectedFiles) {
        $selected = Get-CHScopeFiles $fresh.Records[$Plan.SourceProfile] $Plan.Scope.Mode $Plan.Scope.Folder $Plan.Scope.Session
        if ((($selected.Keys | Sort-Object) -join ',') -ne (($Plan.SelectedFiles.Keys | Sort-Object) -join ',')) { throw 'Selected session tree changed during planning. Run again.' }
    }
    foreach ($p in $Context.Config.Profiles) {
        $old = $Plan.Snapshot.Records[[string]$p.Name]
        $new = $fresh.Records[[string]$p.Name]
        if ($null -eq $Plan.SelectedFiles -and $old.Count -ne $new.Count) { throw 'History changed during planning. Run again.' }
        $keys = if ($null -eq $Plan.SelectedFiles) { @($old.Keys) } else { @($Plan.ReadFiles.Keys) }
        foreach ($key in $keys) {
            if (-not $old.ContainsKey($key) -and -not $new.ContainsKey($key)) { continue }
            if (-not $old.ContainsKey($key)) { throw 'History changed during planning. Run again.' }
            if (-not $new.ContainsKey($key) -or $new[$key].FileHash -ne $old[$key].FileHash -or $new[$key].ModifiedUtc -ne $old[$key].ModifiedUtc) { throw 'History changed during planning. Run again.' }
        }
    }
    if ((($fresh.Tombstones.Keys | Sort-Object) -join ',') -ne (($Plan.Snapshot.Tombstones.Keys | Sort-Object) -join ',')) { throw 'Deletion markers changed during planning.' }
}
function Invoke-CHApply($Context, $Plan, [bool]$AllowRunning=$false, [string]$ActiveProfile='', [bool]$AllowOpenDestination=$false) {
    Assert-CHSnapshot $Context $Plan $AllowRunning $ActiveProfile $AllowOpenDestination
    if (-not $Plan.Operations.Count) { Write-Output 'Already synchronized; nothing to write.'; return }
    [void](Assert-CHPath $Context.StateRoot $Context.StateRoot)
    Protect-CHDirectory $Context.StateRoot
    $lock = [IO.File]::Open((Join-Path $Context.StateRoot 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Assert-CHSnapshot $Context $Plan $AllowRunning $ActiveProfile $AllowOpenDestination
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
            Scope=$Plan.Scope;
            Direction=$Plan.Direction; SourceProfile=$Plan.SourceProfile; TargetProfile=$Plan.TargetProfile;
            AllowRunning=$AllowRunning; AllowOpenDestination=$AllowOpenDestination; Status='prepared'; Entries=@($entries.ToArray())}
        $manifestPath = Join-Path $bundle 'manifest.json'
        Write-CHAtomic $manifestPath (ConvertTo-CHBytes $manifest)
        Write-Output "Backup: $bundle"
        foreach ($op in $Plan.Operations) {
            Assert-CHWriteAccess $Context $Plan $AllowRunning $ActiveProfile $AllowOpenDestination
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
    if (($Scope -ne 'All' -or $ScopeFolder -or $ScopeSession) -and $Mode -notin @('Plan', 'Sync')) { throw 'Sync scope applies only to Plan or Sync. Undo restores the scope recorded in its backup.' }
    if (($AllowRunning -or $ActiveProfile -or $AllowOpenDestination) -and $Mode -notin @('Plan', 'Sync')) { throw 'Live-sync options apply only to Plan or Sync; Undo requires Claude closed.' }
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
    $planArgs = @{Context=$context; Winner=$WinnerProfile; WithScheduled=[bool]$IncludeScheduled; Direction=$Direction; Scope=$Scope; ScopeFolder=$ScopeFolder; ScopeSession=$ScopeSession}
    if ($Policy) { $planArgs.Resolution = $Policy }
    $plan = New-CHPlan @planArgs
    if ($AllowRunning -or $ActiveProfile -or $AllowOpenDestination -or ($Mode -eq 'Sync' -and -not $WhatIfPreference)) {
        Assert-CHWriteAccess $context $plan ([bool]$AllowRunning) $ActiveProfile ([bool]$AllowOpenDestination)
    }
    $plan.Report
    Write-Output "Scope: $($plan.Scope.Mode). $($plan.Scope.Count) source sessions selected. $($plan.Scope.Folder)$($plan.Scope.Session)"
    Write-Output "Direction: $Direction. Policy: $($plan.Policy). Plan: $(@($plan.Report | Where-Object Action -eq 'Add').Count) additions, $(@($plan.Report | Where-Object Action -eq 'Update').Count) updates, $(@($plan.Report | Where-Object Action -eq 'Conflict').Count) conflicts, $(@($plan.Report | Where-Object Action -eq 'Skipped').Count) skipped; $(@($plan.Report | Where-Object ArchiveChanged).Count) archive/unarchive changes."
    if ($Mode -eq 'Sync' -and $PSCmdlet.ShouldProcess('the configured Claude history profiles', "Back up and sync local history ($Direction)")) { Invoke-CHApply $context $plan ([bool]$AllowRunning) $ActiveProfile ([bool]$AllowOpenDestination) }
}
