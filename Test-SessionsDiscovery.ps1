#requires -Version 5.1
[CmdletBinding()]
param([string]$FixtureDirectory)
$ErrorActionPreference = 'Stop'
if (-not $FixtureDirectory) { $FixtureDirectory = Join-Path $PSScriptRoot 'test-fixtures' }
. (Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1')
$fixtureRoot = Join-Path $FixtureDirectory ('discovery-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$savedAppData = $env:APPDATA
$savedLocalAppData = $env:LOCALAPPDATA
$script:Processes = @()
$script:InspectionUnavailable = $false
$script:Assertions = 0
function Assert-Test($Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "FAILED: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Test ($caught -match $Pattern) $Message
}
function Get-CimInstance {
    param($ClassName, $Filter, $Property, $ErrorAction)
    Assert-Test ($ClassName -eq 'Win32_Process' -and $Filter -match "Name = 'Claude.exe' AND SessionId = \d+") 'Process query is limited to Claude in the current Windows session'
    if ($script:InspectionUnavailable) { throw 'Fixture: process inspection unavailable' }
    $script:Processes
}
function New-DiscoveryCase {
    $root = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $env:APPDATA = Join-Path $root 'Roaming'
    $env:LOCALAPPDATA = Join-Path $root 'Local'
    [void][IO.Directory]::CreateDirectory($env:APPDATA)
    [void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    $script:Processes = @()
    $script:InspectionUnavailable = $false
    $root
}
function New-History([string]$DataRoot) {
    $path = Join-Path $DataRoot 'claude-code-sessions'
    [void][IO.Directory]::CreateDirectory($path)
    $path
}
try {
    $root = New-DiscoveryCase
    $regular = New-History (Join-Path $env:APPDATA 'Claude')
    Assert-Test ((Find-CHSessionsRoot) -eq $regular) 'Regular installation is discovered while stopped'

    $root = New-DiscoveryCase
    $store = New-History (Join-Path $env:LOCALAPPDATA 'Packages\Claude_future-publisher\LocalCache\Roaming\Claude')
    Assert-Test ((Find-CHSessionsRoot) -eq $store) 'Store discovery has no fixed publisher ID'

    $root = New-DiscoveryCase
    $relocated = New-History (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_future-family')
    Assert-Test ((Find-CHSessionsRoot) -eq $relocated) 'Relocated Store data is discovered while stopped'
    $script:InspectionUnavailable = $true
    Assert-Test ((Find-CHSessionsRoot) -eq $relocated) 'Unavailable process inspection falls back to filesystem discovery'

    $root = New-DiscoveryCase
    $activeData = Join-Path $root 'Arbitrary Future Location\User Data'
    $active = New-History $activeData
    $old = New-History (Join-Path $env:APPDATA 'Claude')
    foreach ($argument in @(('--user-data-dir="' + $activeData + '"'), ('"--user-data-dir=' + $activeData + '"'), ('--user-data-dir "' + $activeData + '"'))) {
        $script:Processes = @([pscustomobject]@{CommandLine=('"C:\Apps\Claude.exe" --type=gpu-process ' + $argument + ' --other=1')})
        Assert-Test ((Find-CHSessionsRoot) -eq $active) 'Runtime data directory takes precedence over an old installation, including quoted arguments'
    }
    $plainData = Join-Path $env:LOCALAPPDATA 'Claude-New'
    [void](New-History $plainData)
    $script:Processes = @([pscustomobject]@{CommandLine='Claude.exe --user-data-dir=C:\Future\Data --type=renderer'})
    Assert-Test ((Get-CHDesktopDataRoots) -eq 'C:\Future\Data') 'Unquoted runtime directory is parsed'
    $script:Processes = @([pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + $activeData + '"')}, [pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + $activeData.ToUpperInvariant() + '"')})
    Assert-Test ((Find-CHSessionsRoot) -eq $active) 'Repeated Electron children and path casing do not create ambiguity'
    $script:Processes += [pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + $plainData + '"')}
    Assert-Throws { Find-CHSessionsRoot } 'Cannot choose a unique.*Candidates:' 'Multiple running data directories require an explicit choice'
    $script:Processes = @([pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + (Join-Path $root 'NotYetCreated') + '"')})
    Assert-Throws { Find-CHSessionsRoot } 'No claude-code-sessions directory.*running Desktop' 'Running Desktop with no history never falls back to stale history'

    $root = New-DiscoveryCase
    $first = New-History (Join-Path $env:APPDATA 'Claude')
    $second = New-History (Join-Path $env:LOCALAPPDATA 'Claude-Data\another-family')
    Assert-Throws { Find-CHSessionsRoot } 'Cannot choose a unique.*Candidates:' 'Multiple stopped installations are not guessed by age or count'
    $projects = Join-Path $root 'projects'
    [void][IO.Directory]::CreateDirectory($projects)
    $configPath = Join-Path $root 'profiles.json'
    $config = @{FormatVersion=2; SessionsRoot=$second; ProjectsRoot=$projects; Profiles=@()}
    [IO.File]::WriteAllBytes($configPath, (ConvertTo-CHBytes $config))
    $before = Get-CHFileHash $configPath
    Assert-Test ((Get-CHConfig $configPath '' '' $false).Config.SessionsRoot -eq $second) 'Explicit existing custom roots remain authoritative'
    Assert-Test ((Get-CHFileHash $configPath) -eq $before) 'Discovery does not rewrite configuration'
    $config.SessionsRoot = Join-Path $root 'missing-custom-root'
    [IO.File]::WriteAllBytes($configPath, (ConvertTo-CHBytes $config))
    Assert-Throws { Get-CHConfig $configPath '' '' $false } 'Missing configured SessionsRoot directory:.*Auto' 'Missing explicit root reports the path and automatic-discovery remedy'
    $config.SessionsRoot = 'Auto'
    [IO.File]::WriteAllBytes($configPath, (ConvertTo-CHBytes $config))
    $script:Processes = @([pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + [IO.Path]::GetDirectoryName($second) + '"')})
    Assert-Test ((Get-CHConfig $configPath '' '' $false).Config.SessionsRoot -eq $second) 'Auto configuration uses runtime discovery through the public engine entry'
    $nextData = Join-Path $root 'NextUpdate\Different Layout'
    $next = New-History $nextData
    $script:Processes = @([pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + $nextData + '"')})
    Assert-Test ((Get-CHConfig $configPath '' '' $false).Config.SessionsRoot -eq $next) 'Auto follows a subsequent relocation without changing configuration'

    $root = New-DiscoveryCase
    Assert-Throws { Find-CHSessionsRoot } 'Cannot find.*Open Claude Desktop' 'No installations gives an actionable error'
    $script:Processes = @([pscustomobject]@{CommandLine='Claude.exe --user-data-dir=relative-path'})
    Assert-Test (@(Get-CHDesktopDataRoots).Count -eq 0) 'Relative runtime directories are not resolved against the helper working directory'
    $linkedData = Join-Path $root 'LinkedData'
    $realData = Join-Path $root 'ActualData'
    [void](New-History $realData)
    [void](New-Item -ItemType Junction -Path $linkedData -Target $realData)
    $script:Processes = @([pscustomobject]@{CommandLine=('Claude.exe --user-data-dir="' + $linkedData + '"')})
    Assert-Throws { Find-CHSessionsRoot } 'Refusing a reparse point' 'Runtime discovery preserves the engine reparse-point guard'
    Write-Output "PASS: $script:Assertions discovery assertions. Fixtures: $fixtureRoot"
}
finally {
    $env:APPDATA = $savedAppData
    $env:LOCALAPPDATA = $savedLocalAppData
}
