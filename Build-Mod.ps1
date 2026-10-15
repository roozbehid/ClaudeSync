#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$package = Join-Path $PSScriptRoot 'mods\account-history-sync'
$scripts = Join-Path $package 'scripts'
[IO.Directory]::CreateDirectory($scripts) | Out-Null
[IO.File]::Copy((Join-Path $PSScriptRoot 'Sync-ClaudeHistory.ps1'), (Join-Path $scripts 'Sync-ClaudeHistory.ps1'), $true)
Write-Output "Bundled current directional engine into $package"
