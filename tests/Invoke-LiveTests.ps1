#Requires -Version 7.0
<#
    .SYNOPSIS
        Runs every production tool against a real tenant and reports
        success or failure for each.

    .DESCRIPTION
        This needs a real, signed-in tenant and can never run in CI - that is
        what tests/Invoke-Checks.ps1 is for. This script exists to catch what
        static analysis cannot: whether a tool actually completes when it
        calls real Graph endpoints.

        It authenticates once, the same way the app itself does - the real
        PKCE loopback flow in core/Auth.ps1, not a reimplementation - then
        runs each tool in its own isolated runspace, mirroring exactly how
        core/Jobs.ps1 isolates a live job. Tools are not dot-sourced together
        into one script scope: two tools can define same-named local helpers
        (each journey tool has its own Find-SightlineXDevice, for instance),
        and loading them side by side risks one silently overriding the
        other - the exact class of bug a duplicate-function check exists to
        catch in source, and exactly as real a risk here at runtime.

        A tool "passes" if it completes without a thrown exception, its own
        result Status is not 'Failed', and - where it declares an output
        path - that path actually exists afterward. Nothing deeper: this is
        a smoke test, not a content check.

    .EXAMPLE
        ./tests/Invoke-LiveTests.ps1
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $ClientId,
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$coreRoot  = Join-Path $root 'core'
$toolsRoot = Join-Path $root 'tools'

foreach ($file in @('Platform.ps1', 'Auth.ps1', 'Graph.ps1', 'Batch.ps1', 'Intune.ps1', 'Output.ps1', 'Workbook.ps1', 'Tools.ps1')) {
    . (Join-Path $coreRoot $file)
}

# One small, centrally maintained file, not one per tool or per change. A rule
# says "when this field is set to this value, a file matching this pattern
# should exist afterward" - existence only, checked with Test-Path against a
# glob. It never opens a file to look inside it: whether a value is correct
# stays a human's call, always. Missing or empty is fine - this tier is purely
# additive to the baseline pass/fail from the input sweep.
$expectationsPath = Join-Path $PSScriptRoot 'live-test-expectations.json'
$expectations = @(if (Test-Path $expectationsPath) {
    Get-Content -Raw $expectationsPath | ConvertFrom-Json
} else { @() })

# --- Sign in, once, the real way ---------------------------------------------
Write-Host "IntuneSightline live test run" -ForegroundColor Cyan
Write-Host "Signs in the same way the app itself does, then runs every production tool." -ForegroundColor DarkGray
Write-Host ''

$configPath = Join-Path $root 'config.json'
$saved = if (Test-Path $configPath) { Get-Content -Raw $configPath | ConvertFrom-Json } else { $null }

if (-not $TenantId) {
    $default = if ($saved -and $saved.tenantId) { $saved.tenantId } else { '' }
    $prompt = if ($default) { "Tenant ID [$default]" } else { 'Tenant ID' }
    $entered = Read-Host $prompt
    $TenantId = if ($entered) { $entered } else { $default }
}
if (-not $TenantId) { throw 'A tenant ID is required.' }

if (-not $ClientId) {
    $default = if ($saved -and $saved.clientId) { $saved.clientId } else { '' }
    $prompt = if ($default) { "Application (client) ID [$default]" } else { 'Application (client) ID' }
    $entered = Read-Host $prompt
    $ClientId = if ($entered) { $entered } else { $default }
}
if (-not $ClientId) { throw 'An application ID is required.' }

Write-Host ''
Write-Host 'Opening the sign-in page...' -ForegroundColor DarkGray
[void](Connect-SightlineGraphInteractive -TenantId $TenantId -ClientId $ClientId)
$authContext = Export-SightlineAuthContext

# --- One real device per platform, reused for that platform's tool ----------
Write-Host ''
Write-Host 'One real device per platform, to test the journey tools. Leave blank to skip that platform.' -ForegroundColor DarkGray

$devicesByPlatform = @{
    'Windows'    = Read-Host '  Windows device name or serial'
    'iOS/iPadOS' = Read-Host '  iOS/iPadOS device name or serial'
    'macOS'      = Read-Host '  macOS device name or serial'
    'Android'    = Read-Host '  Android device name or serial'
}

# --- Build parameters for each production tool, from its own manifest -------
# Every field not device-related is filled from the manifest's own declared
# default - the same default the launch page's form would already show -
# rather than duplicated or guessed here.
function Get-SightlineBaselineParameters {
    param($Tool, [string] $Device)

    $parameters = @{}
    foreach ($field in @($Tool.Fields)) {
        $value = if ($field.PSObject.Properties.Name -contains 'default') { $field.default } else { $null }
        if ($field.id -in @('devices', 'serialNumbers')) { $value = $Device }
        $parameters[$field.id] = $value
    }
    return $parameters
}

function Get-SightlineTestVariations {
    <#
        Every input a tool declares, discovered from its own manifest rather
        than known ahead of time - a boolean added to any tool tomorrow is
        already visible here the moment it exists, with no change to this
        script. One field varies per case, everything else stays at its
        baseline, so a failure names the one thing that changed rather than
        being lost among several at once.

        Text fields the script has no domain knowledge to fill meaningfully
        (a setting name, an activity type) are left at baseline - only the
        device field is ever substituted, and only booleans and selects are
        swept, since those are the two field types whose entire input space
        the manifest actually declares.
    #>
    param($Tool, [hashtable] $Baseline)

    $cases = [System.Collections.Generic.List[object]]::new()
    $cases.Add([pscustomobject]@{ Label = 'baseline'; Parameters = $Baseline })

    foreach ($field in @($Tool.Fields)) {
        if ($field.type -eq 'boolean') {
            $default = if ($field.PSObject.Properties.Name -contains 'default') { [bool]$field.default } else { $false }
            $flipped = $Baseline.Clone()
            $flipped[$field.id] = -not $default
            $cases.Add([pscustomobject]@{ Label = "$($field.id)=$(-not $default)"; Parameters = $flipped })
        }
        elseif ($field.type -eq 'select' -and $field.PSObject.Properties.Name -contains 'options') {
            $currentDefault = if ($field.PSObject.Properties.Name -contains 'default') { [string]$field.default } else { $null }
            foreach ($option in @($field.options)) {
                if ([string]$option -eq $currentDefault) { continue }
                $variant = $Baseline.Clone()
                $variant[$field.id] = $option
                $cases.Add([pscustomobject]@{ Label = "$($field.id)=$option"; Parameters = $variant })
            }
        }
    }

    return $cases
}

$devicePlatformFor = @{
    'device-journey'  = 'Windows'
    'apple-journey'   = 'iOS/iPadOS'
    'macos-journey'   = 'macOS'
    'android-journey' = 'Android'
}

# --- Run each tool in its own isolated runspace, mirroring Start-SightlineJob
function Invoke-SightlineLiveTest {
    param($Tool, [string] $Label, [hashtable] $Parameters, [hashtable] $AuthContext, [string] $CoreRoot, [object[]] $Expectations = @())

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions  = 'ReuseThread'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace

    $script = {
        param($CoreRoot, $ToolPath, $Parameters, $AuthContext)

        foreach ($file in @('Platform.ps1', 'Auth.ps1', 'Graph.ps1', 'Batch.ps1', 'Intune.ps1', 'Output.ps1', 'Workbook.ps1')) {
            . (Join-Path $CoreRoot $file)
        }
        Import-SightlineAuthContext -Context $AuthContext

        $report = { param([int]$Percent, [string]$Step) }

        . $ToolPath
        return Invoke-Tool -Parameters $Parameters -ReportProgress $report
    }

    [void]$shell.AddScript($script).AddArgument($CoreRoot).AddArgument($Tool.EntryPointPath).AddArgument($Parameters).AddArgument($AuthContext)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = [pscustomobject]@{
        ToolId   = $Tool.Id
        ToolName = $Tool.Name
        Case     = $Label
        Passed   = $false
        Status   = 'Unknown'
        Message  = ''
        Seconds  = 0
    }

    try {
        $asyncResult = $shell.BeginInvoke()
        $completed = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromMinutes(10))

        if (-not $completed) {
            $shell.Stop()
            $outcome.Status  = 'Timeout'
            $outcome.Message = 'Did not finish within 10 minutes.'
        }
        elseif ($shell.HadErrors) {
            $outcome.Status  = 'Exception'
            $outcome.Message = ($shell.Streams.Error | Select-Object -First 1 -ExpandProperty Exception).Message
        }
        else {
            $result = $shell.EndInvoke($asyncResult) | Select-Object -Last 1
            $outputExists = if ($result.OutputPath) { Test-Path $result.OutputPath } else { $true }

            $outcome.Status  = $result.Status
            $outcome.Message = $result.Message
            $outcome.Passed  = ($result.Status -ne 'Failed') -and $outputExists
            if (-not $outputExists) { $outcome.Message += ' [declared output path does not exist]' }

            # File-existence expectations, only checked once the baseline pass
            # already holds - a rule failing on a tool that already failed
            # would just be noise on top of the real problem.
            if ($outcome.Passed -and $result.OutputPath) {
                foreach ($rule in $Expectations) {
                    $fieldId = $rule.when.fieldId
                    if (-not $Parameters.ContainsKey($fieldId)) { continue }
                    if ([string]$Parameters[$fieldId] -ne [string]$rule.when.value) { continue }

                    $matched = @(Get-ChildItem -Path $result.OutputPath -Filter $rule.expectFilePattern -File -ErrorAction SilentlyContinue)
                    if ($matched.Count -eq 0) {
                        $outcome.Passed = $false
                        $outcome.Status = 'Missing expected file'
                        $outcome.Message += " [expected a file matching '$($rule.expectFilePattern)' - none found]"
                    }
                }
            }
        }
    }
    catch {
        $outcome.Status  = 'Exception'
        $outcome.Message = $_.Exception.Message
    }
    finally {
        $sw.Stop()
        $outcome.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $shell.Dispose()
        $runspace.Close()
        $runspace.Dispose()
    }

    return $outcome
}

# --- Run every production tool -----------------------------------------------
# Get-SightlineTools already excludes hidden tools at the source - nothing
# further to filter here.
$tools = @(Get-SightlineTools -ToolsRoot $toolsRoot)
$results = [System.Collections.Generic.List[object]]::new()

Write-Host ''
Write-Host "Running $($tools.Count) production tool(s)..." -ForegroundColor Cyan

foreach ($tool in $tools) {
    $platform = $devicePlatformFor[$tool.Id]
    $device   = if ($platform) { $devicesByPlatform[$platform] } else { $null }

    if ($platform -and -not $device) {
        $results.Add([pscustomobject]@{
            ToolId = $tool.Id; ToolName = $tool.Name; Case = 'baseline'; Passed = $null
            Status = 'Skipped'; Message = "No $platform device given."; Seconds = 0
        })
        Write-Host "  $($tool.Name): skipped (no $platform device given)" -ForegroundColor DarkYellow
        continue
    }

    $baseline = Get-SightlineBaselineParameters -Tool $tool -Device $device
    $variations = @(Get-SightlineTestVariations -Tool $tool -Baseline $baseline)
    Write-Host "  $($tool.Name): $($variations.Count) case(s)" -ForegroundColor Cyan

    foreach ($case in $variations) {
        Write-Host "    [$($case.Label)]: running..." -NoNewline
        $outcome = Invoke-SightlineLiveTest -Tool $tool -Label $case.Label -Parameters $case.Parameters -AuthContext $authContext -CoreRoot $coreRoot -Expectations $expectations
        $results.Add($outcome)

        if ($outcome.Passed) {
            Write-Host "`r    [$($case.Label)]: PASS ($($outcome.Seconds)s)" -ForegroundColor Green
        } else {
            Write-Host "`r    [$($case.Label)]: FAIL - $($outcome.Status) - $($outcome.Message)" -ForegroundColor Red
        }
    }
}

# --- Summary and log -----------------------------------------------------------
Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
$results | Format-Table ToolId, Case, Status, Passed, Seconds, Message -AutoSize -Wrap

$passCount = @($results | Where-Object { $_.Passed -eq $true }).Count
$failCount = @($results | Where-Object { $_.Passed -eq $false }).Count
$skipCount = @($results | Where-Object { $null -eq $_.Passed }).Count
Write-Host "$passCount passed, $failCount failed, $skipCount skipped." -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })

if (-not $LogPath) {
    $LogPath = Join-Path $root "live-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("IntuneSightline live test - $(Get-Date -Format 'u')")
$lines.Add("Tenant: $TenantId")
$lines.Add('')
foreach ($r in $results) {
    $status = if ($null -eq $r.Passed) { 'SKIP' } elseif ($r.Passed) { 'PASS' } else { 'FAIL' }
    $lines.Add("$status  $($r.ToolId) [$($r.Case)]  $($r.Seconds)s  $($r.Status)  $($r.Message)")
}
$lines.Add('')
$lines.Add("$passCount passed, $failCount failed, $skipCount skipped.")
Set-Content -Path $LogPath -Value $lines -Encoding UTF8

Write-Host ''
Write-Host "Log written to $LogPath" -ForegroundColor DarkGray

exit $(if ($failCount -gt 0) { 1 } else { 0 })
