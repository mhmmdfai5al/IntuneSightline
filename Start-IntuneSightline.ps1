#Requires -Version 7.0
<#
    .SYNOPSIS
        Starts IntuneSightline.

        Preflight checks the environment, then serves the tool shell on the
        loopback interface. Sign-in happens in the page: enter a tenant and
        application ID and press Connect.

    .EXAMPLE
        ./Start-IntuneSightline.ps1

    .EXAMPLE
        ./Start-IntuneSightline.ps1 -PreflightOnly
#>
[CmdletBinding()]
param(
    [int]    $Port = 8787,
    [switch] $NoBrowserLaunch,
    [switch] $PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The one place this number is written. The status bar reads it, and the
# update check compares it against the latest GitHub release.
$script:SightlineVersion = '1.0.0'

$root = $PSScriptRoot

foreach ($file in @('Platform.ps1', 'Auth.ps1', 'Graph.ps1', 'Batch.ps1', 'Intune.ps1', 'Output.ps1', 'Workbook.ps1', 'Jobs.ps1', 'Tools.ps1', 'Preflight.ps1')) {
    . (Join-Path $root "core/$file")
}
. (Join-Path $root 'shell/Server.ps1')

$toolsRoot = Join-Path $root 'tools'

Write-Host ''
Write-Host "IntuneSightline  ·  $(Get-SightlinePlatform)  ·  PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor White

$checks = @(Test-SightlinePrerequisites -ToolsRoot $toolsRoot)
if (-not (Write-SightlinePreflight -Checks $checks)) {
    throw 'One or more prerequisites failed. Fix the items marked FAIL and try again.'
}

if ($PreflightOnly) {
    Write-Host 'Preflight only - stopping before the server starts.' -ForegroundColor DarkGray
    return
}

$saved = Get-SightlineConfig
if ($saved -and ($saved.PSObject.Properties.Name -contains 'TenantId') -and $saved.TenantId) {
    Write-Host "Last tenant  ·  $($saved.TenantId)" -ForegroundColor DarkGray
}

Write-Host 'Sign in from the page once it opens.' -ForegroundColor DarkGray

Start-SightlineServer -Root $root -Version $script:SightlineVersion -Port $Port -NoBrowserLaunch:$NoBrowserLaunch
