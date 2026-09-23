Set-StrictMode -Version Latest

$ToolId      = 'compliance-failure-breakdown'
$ToolVersion = '1.0.0'

# The portal shows how many devices are non-compliant, not why. This tool
# reads the tenant-wide aggregate of compliance settings and ranks them by how
# many devices each one is failing - so the answer is "this one setting is
# wrong on 340 devices" instead of 340 separate mysteries.
#
# Three costs, kept deliberately distinct rather than blurred into one call:
#   - the ranked overview: one aggregate read, cheap regardless of fleet size
#   - the device list for one chosen setting: also cheap, one read
#   - the actual failure reason per device: NOT cheap - a call per device, and
#     a device with more than one non-compliant policy may cost more than one
#     call, because the reason lives per policy-state, not per device. Opt-in,
#     with its cost shown before it runs.

function Get-SightlinePlatformTypeValues {
    # deviceCompliancePolicySettingStateSummary.platformType is not filterable
    # server-side in any way this project has confirmed, and the aggregate
    # list itself is small (one row per distinct setting, not per device), so
    # filtering client-side against the full set of values Intune uses for a
    # platform is both simpler and no more expensive than guessing at $filter
    # syntax against an endpoint whose filterability is undocumented.
    param([Parameter(Mandatory)] [string] $Platform)

    switch ($Platform) {
        'Windows'    { @('windows10AndLater', 'windows81AndLater', 'windowsPhone81', 'windows10XProfile') }
        'iOS/iPadOS' { @('iOS') }
        'macOS'      { @('macOS') }
        'Android'    { @('android', 'androidForWork', 'androidWorkProfile', 'androidAOSP') }
        default      { @() }
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $platform      = [string]$Parameters.platform
    $drillSetting  = ([string]$Parameters.drillSetting).Trim()
    $includeReasons = [bool]$Parameters.includeReasons
    $writeHtml     = [bool]$Parameters.writeHtml
    $reportTheme   = if ($Parameters.ContainsKey('theme') -and $Parameters.theme -eq 'dark') { 'dark' } else { 'light' }
    $format        = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # --- Tier 1: the ranked overview, always on, always cheap ------------------
    & $ReportProgress 5 'Reading compliance setting summaries'

    $platformValues = @(Get-SightlinePlatformTypeValues -Platform $platform)
    $summaries = [System.Collections.Generic.List[object]]::new()
    $summaryFailure = $null

    try {
        $listed = Get-SightlineGraphCollection `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicySettingStateSummaries'
        $summaries = @($listed.Items | Where-Object {
            $pn = $_.PSObject.Properties.Name
            ($pn -contains 'platformType') -and ($platformValues -contains [string]$_.platformType)
        })
        $coverage.Add([pscustomobject]@{
            Source = 'deviceCompliancePolicySettingStateSummaries'; Count = $listed.Count
            Complete = $listed.Complete; Failure = $listed.Failure
        })
    }
    catch {
        $summaryFailure = $_.Exception.Message
        $coverage.Add([pscustomobject]@{
            Source = 'deviceCompliancePolicySettingStateSummaries'; Count = 0
            Complete = $false; Failure = $summaryFailure
        })
    }

    if ($summaryFailure) {
        return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
            -Message "Could not read compliance setting summaries - $summaryFailure"
    }

    $overviewRows = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $summaries) {
        $sn = $s.PSObject.Properties.Name
        $nonCompliant = if ($sn -contains 'nonCompliantDeviceCount') { [int]$s.nonCompliantDeviceCount } else { 0 }
        $overviewRows.Add([pscustomobject]@{
            SettingName    = if ($sn -contains 'settingName') { [string]$s.settingName } else { [string]$s.setting }
            NonCompliant   = $nonCompliant
            Error          = if ($sn -contains 'errorDeviceCount') { [int]$s.errorDeviceCount } else { 0 }
            Conflict       = if ($sn -contains 'conflictDeviceCount') { [int]$s.conflictDeviceCount } else { 0 }
            Compliant      = if ($sn -contains 'compliantDeviceCount') { [int]$s.compliantDeviceCount } else { 0 }
            NotApplicable  = if ($sn -contains 'notApplicableDeviceCount') { [int]$s.notApplicableDeviceCount } else { 0 }
            Id             = if ($sn -contains 'id') { [string]$s.id } else { '' }
        })
    }
    $overviewRows = @($overviewRows | Sort-Object NonCompliant -Descending)

    if ($overviewRows.Count -eq 0) {
        $warnings.Add("No compliance setting summaries were found for $platform. Either nothing is non-compliant, or no compliance policies target this platform.")
    }

    # --- Tier 2: drill into one setting's device list, opt-in, still cheap ----
    $deviceRows = [System.Collections.Generic.List[object]]::new()
    $drilledInto = $null

    if ($drillSetting) {
        & $ReportProgress 30 "Finding devices affected by '$drillSetting'"

        $match = @($overviewRows | Where-Object { $_.SettingName -eq $drillSetting })
        if ($match.Count -eq 0) {
            $warnings.Add("'$drillSetting' does not match a setting name in the overview exactly. No drill-down was performed. Setting names are case-sensitive and must match what the overview shows.")
        }
        else {
            $drilledInto = $match[0]
            try {
                $states = Get-SightlineGraphCollection `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicySettingStateSummaries/$($drilledInto.Id)/deviceComplianceSettingStates"
                foreach ($d in $states.Items) {
                    $dn = $d.PSObject.Properties.Name
                    $deviceRows.Add([pscustomobject]@{
                        DeviceId    = if ($dn -contains 'deviceId') { [string]$d.deviceId } else { '' }
                        DeviceName  = if ($dn -contains 'deviceName') { [string]$d.deviceName } else { '' }
                        UserPrincipalName = if ($dn -contains 'userPrincipalName') { [string]$d.userPrincipalName } else { '' }
                        State       = if ($dn -contains 'state') { [string]$d.state } else { '' }
                        GracePeriodExpires = if ($dn -contains 'complianceGracePeriodExpirationDateTime') { [string]$d.complianceGracePeriodExpirationDateTime } else { '' }
                        Reason      = ''
                        ReasonCode  = ''
                        CurrentValue = ''
                    })
                }
                $coverage.Add([pscustomobject]@{
                    Source = "deviceCompliancePolicySettingStateSummaries/{id}/deviceComplianceSettingStates ('$drillSetting')"
                    Count = $states.Count; Complete = $states.Complete; Failure = $states.Failure
                })
            }
            catch {
                $warnings.Add("Could not read the device list for '$drillSetting' - $($_.Exception.Message)")
            }
        }
    }

    # --- Tier 3: the actual failure reason, opt-in, one call per device -------
    # deviceComplianceSettingState (tier 2) carries no error reason at all -
    # that field lives only on the unrelated deviceCompliancePolicySettingState
    # entity, reachable per device via its own policy compliance states. A
    # device failing more than one policy may need more than one call here.
    if ($includeReasons -and $deviceRows.Count -gt 0) {
        $warnings.Add("Fetching failure reasons for $($deviceRows.Count) device(s) - one or more Graph calls per device.")
        $doneCount = 0
        foreach ($row in $deviceRows) {
            $doneCount++
            # Every device, not every tenth - each one can involve more than
            # one Graph round trip, and a batch of fewer than ten devices
            # would otherwise leave the bar sitting still for the whole phase,
            # which reads as a hang rather than as slow, working progress.
            & $ReportProgress (40 + [int](($doneCount / $deviceRows.Count) * 55)) `
                "Reading failure reason for $($row.DeviceName) ($doneCount of $($deviceRows.Count))"

            if (-not $row.DeviceId) { continue }

            try {
                $policyStates = Get-SightlineGraphCollection `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($row.DeviceId)/deviceCompliancePolicyStates"
                # Non-compliant means the policy evaluated and the device failed
                # it. Error means Intune could not evaluate the policy at all -
                # a different problem, but one the admin still wants a reason
                # for, so both are walked here rather than only the former.
                $relevantPolicies = @($policyStates.Items | Where-Object {
                    $_.PSObject.Properties.Name -contains 'state' -and [string]$_.state -in @('nonCompliant', 'error')
                })

                foreach ($policy in $relevantPolicies) {
                    $pn = $policy.PSObject.Properties.Name
                    if (-not ($pn -contains 'id')) { continue }

                    $settingStates = Get-SightlineGraphCollection `
                        -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($row.DeviceId)/deviceCompliancePolicyStates/$($policy.id)/settingStates"
                    $hit = @($settingStates.Items | Where-Object {
                        $sn = $_.PSObject.Properties.Name
                        ($sn -contains 'settingName') -and ([string]$_.settingName) -eq $drillSetting
                    })
                    if ($hit.Count -gt 0) {
                        $hn = $hit[0].PSObject.Properties.Name
                        $row.Reason = if ($hn -contains 'errorDescription') { [string]$hit[0].errorDescription } else { '' }
                        $row.ReasonCode = if ($hn -contains 'errorCode') { [string]$hit[0].errorCode } else { '' }
                        $row.CurrentValue = if ($hn -contains 'currentValue') { [string]$hit[0].currentValue } else { '' }
                        if (-not $row.Reason -and [string]$policy.state -eq 'error') {
                            $row.Reason = 'Not evaluated - Intune reported an error assessing this policy on this device.'
                        }
                        break
                    }
                }
            }
            catch { continue }
        }

        $withReason = @($deviceRows | Where-Object { $_.Reason }).Count
        $coverage.Add([pscustomobject]@{
            Source = 'managedDevices/{id}/deviceCompliancePolicyStates/{id}/settingStates (per device)'
            Count = $deviceRows.Count; Complete = $true; Failure = $null
        })
        if ($withReason -lt $deviceRows.Count) {
            $warnings.Add("A reason could not be resolved for $($deviceRows.Count - $withReason) of $($deviceRows.Count) device(s). The setting may be reported under a different contributing policy on those devices.")
        }
    }

    # --- Write output -----------------------------------------------------------
    & $ReportProgress 92 'Writing output'

    $sheets = @(@{ Name = 'Overview'; Rows = @($overviewRows) })
    if ($deviceRows.Count -gt 0) {
        $sheets += @{ Name = 'Devices'; Rows = @($deviceRows) }
    }

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    $written = Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName 'compliance-failure-breakdown' -Sheets $sheets

    if ($writeHtml) {
        $htmlBody = New-ComplianceBreakdownHtmlReport -Platform $platform -Overview $overviewRows `
            -DrilledInto $drilledInto -DeviceRows @($deviceRows) -IncludeReasons $includeReasons `
            -Provenance $provenance -Theme $reportTheme
        $htmlPath = Join-Path $folder 'compliance-failure-breakdown.html'
        Write-SightlineTextFile -Path $htmlPath -Content $htmlBody
    }

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $message = "$($overviewRows.Count) failing setting(s) for $platform."
    if ($drilledInto) { $message += " Drilled into '$drillSetting': $($deviceRows.Count) device(s) affected." }
    if ($incomplete.Count -gt 0) { $message += ' Some sources were incomplete.' }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $overviewRows.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}

function New-ComplianceBreakdownHtmlReport {
    param(
        [Parameter(Mandatory)] [string]   $Platform,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Overview,
        [AllowNull()]          $DrilledInto,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DeviceRows,
        [Parameter(Mandatory)] [bool]     $IncludeReasons,
        [Parameter(Mandatory)] $Provenance,
        [ValidateSet('light', 'dark')] [string] $Theme = 'light'
    )

    $e = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }

    $h = [System.Text.StringBuilder]::new()
    [void]$h.Append('<!DOCTYPE html><html lang="en" data-theme="' + $Theme + '"><head><meta charset="utf-8">')
    [void]$h.Append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.Append('<title>Compliance failure breakdown - ' + (& $e $Platform) + '</title>')
    $css = @'
:root{
  color-scheme:light dark;
  /* Portal Light - matches the app. */
  --ground:#f3f2f1; --surface:#fff; --surface-alt:#faf9f8;
  --ink:#201f1e; --muted:#605e5c; --line:#edebe9; --strong:#d2d0ce;
  --run:#0078d4; --ok:#107c10; --warn:#797028; --bad:#a4262c; --excl:#a4262c;
  --warn-bg:#fff4ce; --bad-bg:#fdf3f4;
  --lift:0 1.6px 3.6px rgba(0,0,0,.13),0 .3px .9px rgba(0,0,0,.11);
  --mono:ui-monospace,"Cascadia Mono","SF Mono",Consolas,monospace
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --ground:#1b1a19; --surface:#292827; --surface-alt:#252423;
  --ink:#faf9f8; --muted:#a19f9d; --line:#323130; --strong:#484644;
  --run:#4cc2ff; --ok:#6ccb5f; --warn:#fce100; --bad:#f1707b; --excl:#f1707b;
  --warn-bg:#3b3223; --bad-bg:#3b2325; --lift:none
}}
:root[data-theme="dark"]{
  --ground:#1b1a19; --surface:#292827; --surface-alt:#252423;
  --ink:#faf9f8; --muted:#a19f9d; --line:#323130; --strong:#484644;
  --run:#4cc2ff; --ok:#6ccb5f; --warn:#fce100; --bad:#f1707b; --excl:#f1707b;
  --warn-bg:#3b3223; --bad-bg:#3b2325; --lift:none
}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
font:14px/1.5 "Segoe UI",ui-sans-serif,system-ui,sans-serif}
main{max-width:1020px;margin:0 auto;padding:24px}
h1{font-size:19px;font-weight:600;margin:0 0 2px;letter-spacing:-.01em}
.sub{color:var(--muted);font-size:13px;margin:0 0 14px}
.topbar{display:flex;align-items:baseline;gap:14px;margin:0 0 10px}
.topbar button{background:none;border:none;color:var(--run);font:inherit;font-size:11.5px;cursor:pointer;padding:2px 6px}
section{background:var(--surface);border-radius:2px;padding:16px 18px;margin-bottom:16px;box-shadow:var(--lift)}
:root[data-theme="dark"] section{border:1px solid var(--line)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) section{border:1px solid var(--line)}}
h2{font-size:15px;font-weight:600;margin:0 0 3px}
.hint{color:var(--muted);font-size:12.5px;margin:0 0 12px;max-width:76ch}
.tagline{font-size:12.5px;margin:0 0 14px;padding:9px 12px;border-left:3px solid var(--strong);background:var(--surface-alt)}
.tagline code{font-family:var(--mono);font-size:11.5px}
.excl{border-left:4px solid var(--excl);border-radius:2px;padding:11px 14px;margin:0 0 16px;background:var(--bad-bg);font-size:12.5px}
.excl-h{font-weight:600;margin-bottom:5px;color:var(--bad)}
.excl .via{color:var(--muted);font-size:11.5px}
.excl-n{margin:7px 0 0;font-size:11.5px;color:var(--muted)}
.identity{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 14px}
.fact{display:inline-flex;align-items:baseline;gap:6px;background:var(--surface);
border-radius:2px;padding:4px 10px;font-size:12px;box-shadow:var(--lift)}
:root[data-theme="dark"] .fact{border:1px solid var(--line)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .fact{border:1px solid var(--line)}}
.fact .k{color:var(--muted);font-size:11px}
.fact .v{font-weight:600}
ul.forest,ul.forest ul{list-style:none;margin:0;padding:0}
ul.forest>li.root{border-top:1px solid var(--line);padding:9px 0}
ul.forest>li.root:first-child{border-top:none}
ul.forest ul{margin-left:14px;border-left:1px solid var(--strong);padding-left:13px;margin-top:5px}
ul.forest ul li{padding:3px 0}
ul.forest ul ul ul ul{margin-left:0;border-left:none;padding-left:0}
ul.forest ul ul ul ul>li::before{content:"\21B3";color:var(--muted);margin-right:5px;font-size:11px}
li.zero>.node .gname{color:var(--muted);font-weight:400}
li.repeat{padding:3px 0}
li.repeat .gname{color:var(--muted);font-weight:400}
.node{display:flex;align-items:baseline;gap:9px;flex-wrap:wrap}
.gname{font-weight:600}
.pfx{color:var(--muted);font-weight:400}
.how{font-size:11.5px;color:var(--muted)}
.count{font-size:11.5px;color:var(--muted)}
.inherited-count{color:var(--warn);font-weight:600}
details.rule{margin:4px 0 0 2px}
details.rule summary{font-size:11.5px;color:var(--run);cursor:pointer}
details.rule code{display:block;margin-top:5px;font-family:var(--mono);font-size:11.5px;
background:var(--surface-alt);padding:8px 10px;border-radius:2px;word-break:break-all;color:var(--muted)}
details.sect{border:1px solid var(--line);border-radius:2px;margin-bottom:7px}
details.sect summary{padding:9px 12px;cursor:pointer;display:flex;gap:10px;align-items:baseline;font-size:12.5px}
details.sect .sname{font-weight:600}
details.sect .smeta{color:var(--muted);font-size:11.5px;margin-left:auto}
details.sect.empty-sect{opacity:.55}
details.sect.empty-sect summary{cursor:default}
table.applies{width:100%;border-collapse:collapse;font-size:12.5px}
table.applies th{text-align:left;font-weight:600;padding:7px 12px;border-top:1px solid var(--line);
border-bottom:1px solid var(--line);background:var(--surface-alt);cursor:pointer;user-select:none;
white-space:nowrap;position:sticky;top:0;z-index:1}
table.applies td{padding:7px 12px;border-bottom:1px solid var(--line);vertical-align:top}
table.applies tr:last-child td{border-bottom:none}
.i-in{font-size:10.5px;padding:1px 7px;border-radius:2px;border:1px solid var(--strong)}
.i-ex{font-size:10.5px;padding:1px 7px;border-radius:2px;border:1px solid var(--excl);color:var(--excl);font-weight:600}
.i-req{font-size:10.5px;padding:1px 7px;border-radius:2px;border:1px solid var(--ink);font-weight:600}
.dash{color:var(--muted)}
.ok{color:var(--ok)}.bad{color:var(--bad);font-weight:600}
input[type=search]{width:100%;padding:8px 10px;border:1px solid var(--strong);border-radius:2px;
font:inherit;margin-bottom:10px;background:var(--surface);color:var(--ink)}
.meta{font-size:12px;color:var(--muted)}
.meta dt{display:inline;font-weight:400}
.meta dd{display:inline;margin:0 16px 0 4px;color:var(--ink)}
.meta table{width:100%;border-collapse:collapse;font-size:12px}
.meta th,.meta td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);font-weight:400}
.empty{color:var(--muted);font-size:12.5px;margin:0}
button.linky{background:none;border:none;color:var(--run);font:inherit;cursor:pointer;padding:0}
.toolbar{font-size:11.5px;color:var(--muted);margin:0 0 10px}
details.tree>summary{cursor:pointer;list-style:none;display:block}
details.tree>summary::-webkit-details-marker{display:none}
details.tree>summary h2{margin:0}
details.tree>summary::before{content:"\25B8";color:var(--muted);font-size:11px;margin-right:7px}
details.tree[open]>summary::before{content:"\25BE"}
.summary-line{display:block;color:var(--muted);font-size:12.5px;margin:2px 0 0 18px}
details.tree[open] .summary-line{margin-bottom:10px}
/* Printed on white whatever the screen theme, so a PDF is always legible. */
@media print{
  :root,:root[data-theme="dark"]{
    --ground:#fff;--surface:#fff;--surface-alt:#fff;--ink:#000;--muted:#444;
    --line:#ccc;--strong:#999;--lift:none;--bad-bg:#fff;--warn-bg:#fff
  }
  body{background:#fff}
  details>summary{display:none}
  details{display:block}
  details.rule code{border:1px solid #ccc}
  section{break-inside:avoid;box-shadow:none;border:none;padding:0 0 12px}
  .topbar button{display:none}
}
'@

    [void]$h.Append("<style>$css</style></head><body><main>")

    [void]$h.Append('<div class="topbar"><button type="button" id="theme-toggle">Switch theme</button></div>')
    [void]$h.Append('<h1>Compliance failure breakdown</h1><p class="sub">' + (& $e $Platform) + '</p>')

    [void]$h.Append('<details class="meta"><summary style="cursor:pointer;font-size:12px">Provenance &middot; ' +
        (& $e $Provenance.Tenant) + ' &middot; ' + (& $e $Provenance.GeneratedAt) + '</summary>')
    [void]$h.Append('<dl class="meta" style="margin-top:8px"><dt>Collected by</dt><dd>' + (& $e $Provenance.CollectedBy) + '</dd>' +
        '<dt>Tool</dt><dd>compliance-failure-breakdown</dd></dl>')
    [void]$h.Append('<table style="margin-top:8px"><thead><tr><th>Source</th><th>Items</th><th>State</th></tr></thead><tbody>')
    foreach ($c in $Provenance.Coverage) {
        $state = if ($c.Complete) { '<span class="ok">complete</span>' } else { '<span class="bad">incomplete</span>' }
        $reasonText = if (-not $c.Complete -and $c.Failure) { ' : ' + (& $e $c.Failure) } else { '' }
        [void]$h.Append('<tr><td>' + (& $e $c.Source) + '</td><td>' + $c.Count + '</td><td>' + $state + $reasonText + '</td></tr>')
    }
    [void]$h.Append('</tbody></table></details>')

    # --- Overview: the ranked list, always present -----------------------------
    [void]$h.Append('<section><h2>Ranked by devices affected</h2>')
    if ($Overview.Count -eq 0) {
        [void]$h.Append('<p class="empty">No failing settings were found for this platform.</p>')
    }
    else {
        [void]$h.Append('<p class="hint">' + $Overview.Count + ' setting(s) with at least one non-compliant device. Tenant-wide, cheap to read regardless of fleet size - this does not walk devices individually.</p>')
        [void]$h.Append('<input type="search" id="filter" placeholder="Filter settings...">')
        [void]$h.Append('<table class="applies"><thead><tr>')
        foreach ($col in @('Setting', 'Non-compliant', 'Error', 'Conflict', 'Compliant')) {
            [void]$h.Append('<th data-sort>' + $col + '</th>')
        }
        [void]$h.Append('</tr></thead><tbody>')
        foreach ($row in $Overview) {
            $cls = if ($row.NonCompliant -gt 0) { 'i-ex' } else { 'i-in' }
            [void]$h.Append('<tr><td>' + (& $e $row.SettingName) + '</td>' +
                '<td><span class="' + $cls + '">' + $row.NonCompliant + '</span></td>' +
                '<td>' + $row.Error + '</td><td>' + $row.Conflict + '</td><td>' + $row.Compliant + '</td></tr>')
        }
        [void]$h.Append('</tbody></table>')
    }
    [void]$h.Append('</section>')

    # --- Drill-down: which devices, and optionally why -------------------------
    if ($DrilledInto) {
        [void]$h.Append('<section><h2>Devices affected by ' + (& $e $DrilledInto.SettingName) + '</h2>')
        if ($DeviceRows.Count -eq 0) {
            [void]$h.Append('<p class="empty">No device-level detail was returned for this setting.</p>')
        }
        else {
            $reasonNote = if ($IncludeReasons) {
                'Failure reasons were fetched per device - this is the expensive path, one or more Graph calls per device.'
            } else {
                'Showing which devices are affected only. Enable "fetch failure reason" to see why, at the cost of a call per device.'
            }
            [void]$h.Append('<p class="hint">' + $reasonNote + '</p>')
            [void]$h.Append('<table class="applies"><thead><tr>')
            $cols = @('Device', 'User', 'State', 'Grace period expires')
            if ($IncludeReasons) { $cols += @('Reason', 'Current value') }
            foreach ($col in $cols) { [void]$h.Append('<th data-sort>' + $col + '</th>') }
            [void]$h.Append('</tr></thead><tbody>')
            foreach ($row in $DeviceRows) {
                [void]$h.Append('<tr><td>' + (& $e $row.DeviceName) + '</td><td>' + (& $e $row.UserPrincipalName) +
                    '</td><td>' + (& $e $row.State) + '</td><td>' + (& $e $row.GracePeriodExpires) + '</td>')
                if ($IncludeReasons) {
                    $reason = if ($row.Reason) { & $e $row.Reason } else { '<span class="dash">&mdash;</span>' }
                    [void]$h.Append('<td>' + $reason + '</td><td>' + (& $e $row.CurrentValue) + '</td>')
                }
                [void]$h.Append('</tr>')
            }
            [void]$h.Append('</tbody></table>')
        }
        [void]$h.Append('</section>')
    }

    $js = @'
document.addEventListener("DOMContentLoaded", function () {
  var themeBtn = document.getElementById("theme-toggle");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var root = document.documentElement;
      var dark = root.getAttribute("data-theme") === "dark";
      root.setAttribute("data-theme", dark ? "light" : "dark");
    });
  }

  var filter = document.getElementById("filter");
  if (filter) {
    filter.addEventListener("input", function () {
      var q = filter.value.toLowerCase();
      document.querySelectorAll("table.applies tbody tr").forEach(function (tr) {
        tr.style.display = tr.textContent.toLowerCase().indexOf(q) > -1 ? "" : "none";
      });
    });
  }

  document.querySelectorAll("table.applies th[data-sort]").forEach(function (th, i) {
    th.addEventListener("click", function () {
      var table = th.closest("table");
      var tbody = table.querySelector("tbody");
      var rows = Array.prototype.slice.call(tbody.querySelectorAll("tr"));
      var asc = th.getAttribute("data-asc") !== "true";
      table.querySelectorAll("th").forEach(function (h) { h.removeAttribute("data-asc"); });
      th.setAttribute("data-asc", asc);
      rows.sort(function (a, b) {
        var av = a.children[i].textContent.trim();
        var bv = b.children[i].textContent.trim();
        var an = parseFloat(av), bn = parseFloat(bv);
        var cmp = (!isNaN(an) && !isNaN(bn)) ? an - bn : av.localeCompare(bv);
        return asc ? cmp : -cmp;
      });
      rows.forEach(function (r) { tbody.appendChild(r); });
    });
  });
});
'@

    [void]$h.Append('<script>' + $js + '</script></main></body></html>')
    return $h.ToString()
}
