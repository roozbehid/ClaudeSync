#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$desktopProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" | Where-Object { $_.ExecutablePath -match '\\app\\claude\.exe$' })
if ($desktopProcesses.Count) { throw 'Fully exit Claude Desktop from its tray icon before starting the DOM comparison. Save or pause running work first.' }
$nodeCommand = Get-Command node -ErrorAction Stop
$nodeVersion = & $nodeCommand.Source --version
if ([int]($nodeVersion.TrimStart('v').Split('.')[0]) -lt 22) { throw 'The DOM loader needs Node 22 or later.' }
$desktopPackage = Get-AppxPackage -Name Claude | Select-Object -First 1
$desktopExe = if ($desktopPackage) { Join-Path $desktopPackage.InstallLocation 'app\claude.exe' } else {
    $regularRoot = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    $latest = Get-ChildItem -LiteralPath $regularRoot -Directory -Filter 'app-*' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($latest) { Join-Path $latest.FullName 'claude.exe' }
}
if (-not $desktopExe -or -not (Test-Path -LiteralPath $desktopExe -PathType Leaf)) { throw 'Cannot locate the installed Claude Desktop executable.' }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
try { $comparisonPort = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
Write-Output "Starting Desktop with a temporary loopback DevTools endpoint on port $comparisonPort."
Write-Output 'This endpoint allows local processes to inspect Desktop during this comparison. Restart Desktop normally afterward to close it.'
Start-Process -FilePath $desktopExe -ArgumentList @('--remote-debugging-address=127.0.0.1',"--remote-debugging-port=$comparisonPort") -WindowStyle Hidden | Out-Null
# Verify that the listener belongs to the selected Desktop executable, not another process.
$deadline = [DateTime]::UtcNow.AddSeconds(25)
$connection = $null
while ([DateTime]::UtcNow -lt $deadline) {
    $connection = Get-NetTCPConnection -LocalPort $comparisonPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $connection) { throw 'Desktop did not expose a DevTools listener; this build may refuse the flag. No installed files were changed.' }
if ($connection.LocalAddress -notin @('127.0.0.1','::1')) { throw 'DevTools did not bind to loopback. Exit Desktop to close the listener; the injector will not connect.' }
$listenerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($connection.OwningProcess)"
if ($listenerProcess.ExecutablePath -ne $desktopExe) { throw 'The debugging listener belongs to another executable. The injector will not connect.' }
Write-Output 'Open a Code session. Keep this PowerShell window running; Ctrl+C removes the injected launchers.'
& $nodeCommand.Source (Join-Path $PSScriptRoot 'Attach-DesktopDom.mjs') --port $comparisonPort
if ($LASTEXITCODE -ne 0) { throw 'DOM injection failed. See the message above and restart Desktop normally.' }
