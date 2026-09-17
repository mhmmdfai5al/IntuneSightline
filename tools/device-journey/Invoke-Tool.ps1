Set-StrictMode -Version Latest

$ToolId      = 'device-journey'
$ToolVersion = '1.0.0'

function Find-SightlineDeviceRecord {
    <#
        Resolves a device from its Intune record, by name or serial.

        The device comes first and Autopilot second. Starting from an Autopilot
        registration excluded every co-managed, hybrid joined and manually
        enrolled device, which is most of a typical estate.
    #>
    param([Parameter(Mandatory)] [string] $Query)

    $base    = 'https://graph.microsoft.com/beta/deviceManagement'
    $escaped = $Query.Replace("'", "''")
    $select  = 'id,deviceName,serialNumber,azureADDeviceId,operatingSystem,osVersion,' +
               'userPrincipalName,userDisplayName,managedDeviceOwnerType,joinType,' +
               'deviceEnrollmentType,managementAgent,enrolledDateTime,lastSyncDateTime,' +
               'model,manufacturer,complianceState'

    foreach ($field in @('deviceName', 'serialNumber')) {
        try {
            $result = Invoke-SightlineGraphRequest `
                -Uri "$base/managedDevices?`$filter=$field eq '$escaped'&`$select=$select"
            $hits = @($result.value)

            if ($hits.Count -gt 1) {
                $list = (@($hits | ForEach-Object { "$($_.deviceName) [$($_.serialNumber)]" }) -join '; ')
                return [pscustomobject]@{
                    Device = $null
                    Problem = "'$Query' matched $($hits.Count) devices: $list. Use a serial number."
                }
            }
            if ($hits.Count -eq 1) {
                return [pscustomobject]@{ Device = $hits[0]; Problem = $null }
            }
        }
        catch { continue }
    }

    return [pscustomobject]@{
        Device  = $null
        Problem = "no enrolled device matched '$Query', by name or serial number. Both are matched exactly."
    }
}

function Get-SightlineDeviceOrigin {
    <#
        How the device came to exist in the directory, and who put it there.

        trustType is the definitive join answer - AzureAd, ServerAd or Workplace
        - and registeredOwners names the account that performed the join. An
        admin needs both at a glance to know what they are looking at.
    #>
    param([Parameter(Mandatory)] [string] $EntraDeviceId)

    $origin = [pscustomobject]@{
        DirectoryId  = ''
        DisplayName  = ''
        JoinType     = ''
        TrustType    = ''
        ProfileType  = ''
        RegisteredOn = ''
        JoinedBy     = ''
        Problem      = $null
    }

    try {
        $device = Invoke-SightlineGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$EntraDeviceId')?`$select=id,displayName,trustType,profileType,registrationDateTime,accountEnabled,approximateLastSignInDateTime"
    }
    catch {
        $origin.Problem = $_.Exception.Message
        return $origin
    }

    $names = $device.PSObject.Properties.Name
    $origin.DirectoryId = [string]$device.id
    $origin.DisplayName = if ($names -contains 'displayName') { [string]$device.displayName } else { '' }
    $origin.TrustType   = if ($names -contains 'trustType') { [string]$device.trustType } else { '' }
    $origin.ProfileType = if ($names -contains 'profileType') { [string]$device.profileType } else { '' }
    $origin.RegisteredOn = if ($names -contains 'registrationDateTime') { [string]$device.registrationDateTime } else { '' }

    # Entra's own vocabulary is not what an admin reads in the portal.
    $origin.JoinType = switch ($origin.TrustType) {
        'AzureAd'   { 'Microsoft Entra joined' }
        'ServerAd'  { 'Microsoft Entra hybrid joined' }
        'Workplace' { 'Microsoft Entra registered' }
        default     { if ($origin.TrustType) { $origin.TrustType } else { 'unknown' } }
    }

    try {
        $owners = Get-SightlineGraphCollection `
            -Uri "https://graph.microsoft.com/v1.0/devices/$($origin.DirectoryId)/registeredOwners?`$select=id,userPrincipalName,displayName"
        $first = @($owners.Items | Select-Object -First 1)
        if ($first.Count -gt 0) {
            $o = $first[0]
            $on = $o.PSObject.Properties.Name
            $origin.JoinedBy = if ($on -contains 'userPrincipalName' -and $o.userPrincipalName) { [string]$o.userPrincipalName }
                               elseif ($on -contains 'displayName') { [string]$o.displayName } else { '' }
        }
    }
    catch { }

    return $origin
}

function Get-SightlineEnrolmentSummary {
    # One sentence an admin can read at a glance to know what this device is.
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] $Origin,
        [AllowNull()] $Autopilot
    )

    $names = $Device.PSObject.Properties.Name
    $parts = @($Origin.JoinType)

    $enrolment = if ($names -contains 'deviceEnrollmentType') { [string]$Device.deviceEnrollmentType } else { '' }
    $readable = switch ($enrolment) {
        'windowsAutoEnrollment'      { 'automatic enrolment' }
        'windowsBulkAzureDomainJoin' { 'bulk enrolment' }
        'windowsCoManagement'        { 'co-management' }
        'windowsAzureADJoin'         { 'Entra join' }
        'windowsAzureADJoinUsingDeviceAuth' { 'Entra join using device authentication' }
        'userEnrollment'             { 'user enrolment' }
        'deviceEnrollmentManager'    { 'a device enrolment manager' }
        default                      { if ($enrolment) { $enrolment } else { '' } }
    }
    if ($readable) { $parts += "enrolled by $readable" }

    if ($Autopilot) { $parts += 'registered in Autopilot' }
    else            { $parts += 'not registered in Autopilot' }

    if ($names -contains 'managementAgent' -and $Device.managementAgent -eq 'configurationManagerClientMdm') {
        $parts += 'co-managed with Configuration Manager'
    }

    return (($parts -join ', ') + '.')
}

function ConvertTo-JourneyHtmlText {
    # Everything from the tenant is untrusted text: a policy or group named
    # with a tag would otherwise become markup in the report.
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-JourneyNamePrefix {
    <#
        The longest prefix every group name shares, trimmed back to a
        separator so it breaks on a boundary rather than mid-word.

        Group names in a managed tenant are often heavily prefixed with the same
        organisational scheme, which puts the distinguishing part at the end of
        every line and defeats scanning. Dimming the common part fixes that
        without hiding anything.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Names)

    $usable = @($Names | Where-Object { $_ })
    if ($usable.Count -lt 2) { return '' }

    $prefix = [string]$usable[0]
    foreach ($name in $usable) {
        while ($prefix -and -not ([string]$name).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $prefix.Substring(0, $prefix.Length - 1)
        }
        if (-not $prefix) { return '' }
    }

    # Break on a separator: a prefix ending mid-word reads as a typo.
    $cut = -1
    for ($i = $prefix.Length - 1; $i -ge 0; $i--) {
        if ($prefix[$i] -in @('.', '-', '_')) { $cut = $i; break }
    }
    if ($cut -lt 2) { return '' }

    return $prefix.Substring(0, $cut + 1)
}

function New-JourneyTreeHtml {
    <#
        One tree per root, with inheritance nested beneath the root that caused
        it. Roots are the groups the device is genuinely a member of; anything
        indented was reached through nesting and never targeted.

        A group reached by several paths is drawn in full the first time and
        referenced thereafter. Drawing it fully every time is honest but
        unreadable: on a real tenant one group appeared fifteen times, and the
        four groups that actually carried policy were lost among them.

        $Seen is shared across both trees so the reference is accurate no
        matter which tree reaches the group first.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Roots,
        [Parameter(Mandatory)] [hashtable] $NestedIn,
        [Parameter(Mandatory)] [hashtable] $GroupsById,
        [Parameter(Mandatory)] [hashtable] $PolicyCount,
        [Parameter(Mandatory)] [hashtable] $PathCount,
        [Parameter(Mandatory)] [hashtable] $Seen,
        [string] $CommonPrefix = '',
        [string] $EmptyText = 'None.'
    )

    if ($Roots.Count -eq 0) { return '<p class="empty">' + $EmptyText + '</p>' }

    $sb = [System.Text.StringBuilder]::new()

    $nameHtml = {
        param([string] $Name)
        if ($CommonPrefix -and $Name.StartsWith($CommonPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            '<span class="pfx">' + (ConvertTo-JourneyHtmlText $Name.Substring(0, $CommonPrefix.Length)) +
            '</span>' + (ConvertTo-JourneyHtmlText $Name.Substring($CommonPrefix.Length))
        } else {
            ConvertTo-JourneyHtmlText $Name
        }
    }

    # A node is only worth hiding when nothing beneath it carries policy either.
    # Hiding on the node's own count alone removes whole branches: both dynamic
    # roots here hold no policy themselves but lead to groups holding 43.
    $subtree = @{}
    $totalOf = {
        param($Id, [string[]] $Ancestors)
        if ($subtree.ContainsKey($Id)) { return [int]$subtree[$Id] }
        if ($Ancestors -contains $Id) { return 0 }

        $sum = if ($PolicyCount.ContainsKey($Id)) { [int]$PolicyCount[$Id] } else { 0 }
        if ($NestedIn.ContainsKey($Id)) {
            foreach ($child in @($NestedIn[$Id])) {
                $sum += (& $totalOf $child ($Ancestors + $Id))
            }
        }
        $subtree[$Id] = $sum
        return $sum
    }
    foreach ($r in $Roots) { [void](& $totalOf $r @()) }

    $render = {
        param($Id, [string[]] $Ancestors, [bool] $IsRoot)

        if ($Ancestors -contains $Id) { return }   # nesting loop

        $group = $GroupsById[$Id]
        $names = $group.PSObject.Properties.Name
        $rule  = if ($names -contains 'membershipRule' -and $group.membershipRule) { [string]$group.membershipRule } else { '' }
        $count = if ($PolicyCount.ContainsKey($Id)) { [int]$PolicyCount[$Id] } else { 0 }
        $paths = if ($PathCount.ContainsKey($Id)) { [int]$PathCount[$Id] } else { 1 }

        # Second and later appearances collapse to a single reference line.
        if (-not $IsRoot -and $Seen.ContainsKey($Id)) {
            [void]$sb.Append('<li class="repeat"><span class="gname">' +
                (& $nameHtml ([string]$group.displayName)) +
                '</span> <span class="how">already shown above</span></li>')
            return
        }
        $Seen[$Id] = $true

        $branchTotal = if ($subtree.ContainsKey($Id)) { [int]$subtree[$Id] } else { $count }
        $zero = if ($branchTotal -eq 0) { ' zero' } else { '' }
        [void]$sb.Append('<li class="' + $(if ($IsRoot) { 'root' } else { 'child' }) + $zero + '">')
        [void]$sb.Append('<div class="node">')
        [void]$sb.Append('<span class="gname">' + (& $nameHtml ([string]$group.displayName)) + '</span>')

        if (-not $IsRoot -and $paths -gt 1) {
            [void]$sb.Append('<span class="how">reached ' + $paths + ' ways</span>')
        }

        $cls = if ($count -gt 0 -and -not $IsRoot) { 'count inherited-count' } else { 'count' }
        $label = if ($count -eq 0 -and $branchTotal -gt 0) {
            $branchTotal.ToString() + ' below'
        } else {
            $count.ToString() + ' ' + $(if ($count -eq 1) { 'policy' } else { 'policies' })
        }
        [void]$sb.Append('<span class="' + $cls + '">' + $label + '</span></div>')

        if ($rule) {
            [void]$sb.Append('<details class="rule"><summary>rule</summary><code>' +
                (ConvertTo-JourneyHtmlText $rule) + '</code></details>')
        }

        $parents = @()
        if ($NestedIn.ContainsKey($Id)) { $parents = @($NestedIn[$Id]) }

        if ($parents.Count -gt 0) {
            [void]$sb.Append('<ul>')
            # Groups carrying policy first: they are why anyone opened the tree.
            foreach ($parent in @($parents | Sort-Object `
                @{ Expression = { if ($PolicyCount.ContainsKey($_)) { -[int]$PolicyCount[$_] } else { 0 } } }, `
                @{ Expression = { [string]$GroupsById[$_].displayName } })) {
                & $render $parent ($Ancestors + $Id) $false
            }
            [void]$sb.Append('</ul>')
        }

        [void]$sb.Append('</li>')
    }

    [void]$sb.Append('<ul class="forest">')
    foreach ($root in @($Roots | Sort-Object `
        @{ Expression = { if ($PolicyCount.ContainsKey($_)) { -[int]$PolicyCount[$_] } else { 0 } } }, `
        @{ Expression = { [string]$GroupsById[$_].displayName } })) {
        & $render $root @() $true
    }
    [void]$sb.Append('</ul>')

    return $sb.ToString()
}

function Get-JourneySectionName {
    # Groups the policy surfaces into the categories an admin thinks in.
    param([string] $Kind)

    switch -Wildcard ($Kind) {
        'Settings catalog'      { 'Configuration policies' }
        'Device configuration'  { 'Configuration policies' }
        'ADMX template'         { 'Configuration policies' }
        'Windows update ring'   { 'Configuration policies' }
        'Compliance policy'     { 'Compliance policies' }
        'Security baseline*'    { 'Security baselines' }
        'Application'           { 'Applications' }
        '*script*'              { 'Scripts and remediations' }
        default                 { 'Other' }
    }
}

function New-JourneyHtmlReport {
    <#
        One self-contained file: inline styles and script, no external
        references, so it opens from a mail attachment on a machine with no
        network.
    #>
    param(
        [Parameter(Mandatory)] [string]    $Serial,
        [AllowEmptyString()]   [string]    $Tag = '',
        [Parameter(Mandatory)] [hashtable] $DirectOf,
        [Parameter(Mandatory)] [hashtable] $NestedIn,
        [Parameter(Mandatory)] [hashtable] $GroupsById,
        [Parameter(Mandatory)] [hashtable] $PolicyCount,
        [Parameter(Mandatory)] [hashtable] $PathCount,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DeviceRows,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ApplyRows,
        [Parameter(Mandatory)] $Provenance,
        [ValidateSet('light', 'dark')] [string] $Theme = 'light'
    )

    $e = { param($v) ConvertTo-JourneyHtmlText $v }

    # Roots split by how the device got in. Two trees rather than one: a rule
    # matching is a different kind of event from someone adding the device.
    $rootIds = @()
    if ($DirectOf.ContainsKey($Serial)) {
        $rootIds = @($DirectOf[$Serial] | Where-Object { $GroupsById.ContainsKey($_) })
    }

    $dynamicRoots = @($rootIds | Where-Object {
        $g = $GroupsById[$_]
        ($g.PSObject.Properties.Name -contains 'membershipRule') -and $g.membershipRule
    })
    $assignedRoots = @($rootIds | Where-Object { $_ -notin $dynamicRoots })

    # Shared across both trees so "already shown above" is accurate whichever
    # tree reaches a group first.
    $commonPrefix = Get-JourneyNamePrefix -Names @($GroupsById.Keys | ForEach-Object { [string]$GroupsById[$_].displayName })

    $seen = @{}
    $dynamicTree = New-JourneyTreeHtml -Roots $dynamicRoots -NestedIn $NestedIn -GroupsById $GroupsById `
        -PolicyCount $PolicyCount -PathCount $PathCount -Seen $seen -CommonPrefix $commonPrefix `
        -EmptyText 'No dynamic group rule matched this device.'
    $assignedTree = New-JourneyTreeHtml -Roots $assignedRoots -NestedIn $NestedIn -GroupsById $GroupsById `
        -PolicyCount $PolicyCount -PathCount $PathCount -Seen $seen -CommonPrefix $commonPrefix `
        -EmptyText 'The device was not added to any group directly.'

    # Exclusions lead: an exclusion overriding an inclusion is the thing people
    # miss, and it was previously buried among dozens of rows.
    $excluded = @($ApplyRows | Where-Object { $_.Intent -eq 'Exclude' })
    $exclHtml = ''
    if ($excluded.Count -gt 0) {
        $lines = [System.Text.StringBuilder]::new()
        foreach ($group in ($excluded | Group-Object PolicyName)) {
            $vias = (@($group.Group | Select-Object -ExpandProperty ReachesVia -Unique) -join ', ')
            [void]$lines.Append('<div>' + (& $e $group.Name) +
                ' <span class="via">via ' + (& $e $vias) + '</span></div>')
        }
        $exclHtml = '<div class="excl"><div class="excl-h">' + $excluded.Count +
            ' exclusion' + $(if ($excluded.Count -eq 1) { '' } else { 's' }) +
            ' apply to this device</div>' + $lines.ToString() +
            '<p class="excl-n">An exclusion overrides an inclusion for the same policy.</p></div>'
    }

    # Sections by type. Empty ones stay visible but dimmed: nothing of a type
    # reaching the device is a finding, and hiding the section hides it.
    $order = @('Configuration policies', 'Compliance policies', 'Security baselines',
               'Scripts and remediations', 'App configuration policies', 'Applications', 'Other')
    $bySection = @{}
    foreach ($row in $ApplyRows) {
        $name = Get-JourneySectionName -Kind ([string]$row.PolicyKind)
        if (-not $bySection.ContainsKey($name)) { $bySection[$name] = [System.Collections.Generic.List[object]]::new() }
        $bySection[$name].Add($row)
    }

    $sections = [System.Text.StringBuilder]::new()
    $sectionNo = 0
    foreach ($name in $order) {
        # @() wraps the whole if: the block's output goes through the pipeline,
        # which unrolls a one-element array to a scalar, and a scalar has no .Count.
        $rows = @(if ($bySection.ContainsKey($name)) { $bySection[$name] } else { @() })
        if ($rows.Count -eq 0 -and $name -eq 'Other') { continue }

        $sectionNo++
        $excl = @($rows | Where-Object { $_.Intent -eq 'Exclude' }).Count
        $meta = if ($rows.Count -eq 0) { 'none reach this device' }
                else { "$($rows.Count)" + $(if ($excl -gt 0) { " &middot; $excl excluded" } else { '' }) }

        [void]$sections.Append('<details class="sect' + $(if ($rows.Count -eq 0) { ' empty-sect' } else { '' }) + '"' +
            $(if ($sectionNo -eq 1 -and $rows.Count -gt 0) { ' open' } else { '' }) + '>')
        [void]$sections.Append('<summary><span class="sname">' + (& $e $name) +
            '</span><span class="smeta">' + $meta + '</span></summary>')

        if ($rows.Count -gt 0) {
            [void]$sections.Append('<table class="applies"><thead><tr>')
            foreach ($h in @('Name', 'Assignment', 'Reaches via', 'Filter')) {
                [void]$sections.Append('<th data-sort>' + $h + '</th>')
            }
            [void]$sections.Append('</tr></thead><tbody>')

            foreach ($row in ($rows | Sort-Object `
                @{ Expression = { switch ([string]$_.Assignment) {
                    'Excluded' { 0 } 'Uninstall' { 1 } 'Required' { 2 } default { 3 } } } }, `
                PolicyName)) {
                $shown = if ($row.PSObject.Properties.Name -contains 'Assignment' -and $row.Assignment) {
                    [string]$row.Assignment
                } elseif ($row.Intent -eq 'Exclude') { 'Excluded' } else { 'Included' }

                $badgeCls = switch ($shown) {
                    'Excluded'  { 'i-ex' }
                    'Uninstall' { 'i-ex' }
                    'Required'  { 'i-req' }
                    default     { 'i-in' }
                }
                $badge = '<span class="' + $badgeCls + '">' + (& $e $shown) + '</span>'
                $filter = if ($row.FilterName) { (& $e $row.FilterName) } else { '<span class="dash">&mdash;</span>' }

                [void]$sections.Append('<tr><td>' + (& $e $row.PolicyName) + '</td><td>' + $badge +
                    '</td><td>' + (& $e $row.ReachesVia) + '</td><td>' + $filter + '</td></tr>')
            }
            [void]$sections.Append('</tbody></table>')
        }
        [void]$sections.Append('</details>')
    }

    $coverage = [System.Text.StringBuilder]::new()
    foreach ($entry in @($Provenance.Coverage)) {
        $state = if ($entry.Complete) { 'complete' } else { 'INCOMPLETE' }
        [void]$coverage.Append('<tr><td>' + (& $e $entry.Source) + '</td><td>' + (& $e $entry.Count) +
            '</td><td class="' + $(if ($entry.Complete) { 'ok' } else { 'bad' }) + '">' + $state + '</td></tr>')
    }
    $warn = [System.Text.StringBuilder]::new()
    foreach ($w in @($Provenance.Warnings)) { [void]$warn.Append('<li>' + (& $e $w) + '</li>') }

    $device = if ($DeviceRows.Count -gt 0) { $DeviceRows[0] } else { $null }
    $dynamicCount = @($GroupsById.Keys | Where-Object {
        $g = $GroupsById[$_]
        ($g.PSObject.Properties.Name -contains 'membershipRule') -and $g.membershipRule
    }).Count

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

    $js = @'
document.querySelectorAll("th[data-sort]").forEach(function(th){
  th.addEventListener("click",function(){
    var table=th.closest("table"),body=table.tBodies[0],i=[].indexOf.call(th.parentNode.children,th);
    var asc=th.dataset.dir!=="asc";
    [].slice.call(body.rows).sort(function(a,b){
      var x=a.cells[i].innerText.trim(),y=b.cells[i].innerText.trim();
      return asc?x.localeCompare(y):y.localeCompare(x);
    }).forEach(function(r){body.appendChild(r)});
    table.querySelectorAll("th").forEach(function(o){o.dataset.dir=""});
    th.dataset.dir=asc?"asc":"desc";
  });
});
var box=document.getElementById("filter");
if(box){box.addEventListener("input",function(){
  var q=box.value.toLowerCase();
  document.querySelectorAll("details.sect").forEach(function(sec){
    var shown=0;
    sec.querySelectorAll("tbody tr").forEach(function(r){
      var hit=r.innerText.toLowerCase().indexOf(q)>-1;
      r.style.display=hit?"":"none"; if(hit)shown++;
    });
    if(q){sec.open=shown>0;sec.style.display=shown?"":"none";}
    else{sec.style.display="";}
  });
});}
var themeBtn=document.getElementById("theme-toggle");
if(themeBtn){themeBtn.addEventListener("click",function(){
  var root=document.documentElement;
  var dark=root.getAttribute("data-theme")==="dark";
  root.setAttribute("data-theme",dark?"light":"dark");
});}
var all=document.getElementById("expandall");
if(all){all.addEventListener("click",function(){
  var open=all.dataset.state!=="open";
  document.querySelectorAll("details.rule,details.tree,details.sect").forEach(function(d){
    if(!d.classList.contains("empty-sect"))d.open=open;
  });
  all.dataset.state=open?"open":"closed";
  all.textContent=open?"collapse everything":"expand everything";
});}
var zeros=document.getElementById("showzero");
if(zeros){zeros.addEventListener("click",function(){
  var on=zeros.dataset.state==="on";
  document.querySelectorAll("li.zero").forEach(function(l){l.style.display=on?"none":""});
  zeros.dataset.state=on?"off":"on";
  zeros.textContent=on?"show groups with no policy":"hide groups with no policy";
});}
document.querySelectorAll("li.zero").forEach(function(l){l.style.display="none"});
'@

    $h = [System.Text.StringBuilder]::new()
    [void]$h.Append('<!DOCTYPE html><html lang="en" data-theme="' + $Theme + '"><head><meta charset="utf-8">')
    [void]$h.Append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.Append('<title>Autopilot journey - ' + (& $e $Serial) + '</title>')
    [void]$h.Append('<style>' + $css + '</style></head><body><main>')

    [void]$h.Append('<div class="topbar"><button type="button" id="theme-toggle">Switch theme</button></div>')
    [void]$h.Append('<h1>Device journey</h1><p class="sub">' + (& $e $Serial))
    if ($device -and $device.DeviceName) { [void]$h.Append(' &middot; ' + (& $e $device.DeviceName)) }
    [void]$h.Append('</p>')

    # What kind of device this is, and who put it there. An admin needs both
    # before reading anything else - a hybrid joined machine and an Autopilot
    # one have different explanations for the same symptom.
    if ($device) {
        [void]$h.Append('<div class="identity">')

        $facts = @()
        if ($device.JoinType)    { $facts += @{ k = 'Join type';   v = $device.JoinType } }
        if ($device.JoinedBy)    { $facts += @{ k = 'Joined by';   v = $device.JoinedBy } }
        if ($device.Enrolment)   { $facts += @{ k = 'Enrolled by'; v = $device.Enrolment } }
        $facts += @{ k = 'In Autopilot'; v = $device.InAutopilot }
        if ($device.PrimaryUser) { $facts += @{ k = 'Primary user'; v = $device.PrimaryUser } }
        if ($device.Owner)       { $facts += @{ k = 'Ownership';   v = $device.Owner } }
        if ($device.OS)          { $facts += @{ k = 'OS';          v = $device.OS } }

        foreach ($fact in $facts) {
            [void]$h.Append('<span class="fact"><span class="k">' + (& $e $fact.k) +
                '</span><span class="v">' + (& $e $fact.v) + '</span></span>')
        }
        [void]$h.Append('</div>')
    }

    [void]$h.Append('<details class="meta"><summary style="cursor:pointer;font-size:12px">Provenance &middot; ' +
        (& $e $Provenance.Tenant) + ' &middot; ' + (& $e $Provenance.GeneratedAt) + '</summary>')
    [void]$h.Append('<dl class="meta" style="margin-top:8px"><dt>Collected by</dt><dd>' +
        (& $e $Provenance.CollectedBy) + '</dd><dt>Tool</dt><dd>' + (& $e $Provenance.Tool) +
        ' v' + (& $e $Provenance.ToolVersion) + '</dd></dl>')
    [void]$h.Append('<table style="margin-top:8px"><thead><tr><th>Source</th><th>Items</th><th>State</th></tr></thead><tbody>' +
        $coverage.ToString() + '</tbody></table>')
    if ($warn.Length -gt 0) {
        [void]$h.Append('<ul style="font-size:12px;color:#5a646e;margin-top:10px">' + $warn.ToString() + '</ul>')
    }
    [void]$h.Append('</details>')

    [void]$h.Append($exclHtml)

    $directTotal    = $dynamicRoots.Count + $assignedRoots.Count
    $inheritedTotal = [math]::Max(0, $GroupsById.Count - $directTotal)

    $plural = { param($n, $one, $many) if ($n -eq 1) { $one } else { $many } }

    $summaryLine = if ($directTotal -eq 0) {
        'Not a member of any group. Nothing targeted at groups can reach it.'
    } else {
        # A single membership does not need a count repeating back at it, and
        # neither does a set that is entirely one kind.
        $line = 'Member of ' + $directTotal + ' ' + (& $plural $directTotal 'group' 'groups')

        if ($directTotal -eq 1) {
            $line += if ($dynamicRoots.Count -eq 1) { ', matched by rule' } else { ', added directly' }
        }
        elseif ($assignedRoots.Count -eq 0) { $line += ', all matched by rule' }
        elseif ($dynamicRoots.Count -eq 0)  { $line += ', all added directly' }
        else {
            $line += ', ' + $dynamicRoots.Count + ' by rule and ' + $assignedRoots.Count + ' added directly'
        }

        if ($inheritedTotal -gt 0) {
            $line += ', inheriting ' + $inheritedTotal + ' more through nesting.'
        } else {
            $line += '. Nothing further is inherited through nesting.'
        }
        $line
    }

    [void]$h.Append('<section><details class="tree">')
    [void]$h.Append('<summary><h2 style="display:inline">How this device reached its groups</h2>')
    [void]$h.Append('<span class="summary-line">' + (& $e $summaryLine) + '</span></summary>')
    if ($Tag) {
        [void]$h.Append('<p class="tagline">Group tag <code>' + (& $e $Tag) +
            '</code>, written by Intune as <code>OrderID</code> on the device object. Dynamic rules testing <code>devicePhysicalIds</code> read that value.</p>')
    }
    elseif ($device -and $device.InAutopilot -eq 'No') {
        [void]$h.Append('<p class="tagline">Not registered in Autopilot, so no rule can match on a group tag. Its memberships come from other rules or from being added directly.</p>')
    }
    else {
        [void]$h.Append('<p class="tagline">Registered in Autopilot but carrying no group tag, so no rule can match on one.</p>')
    }

    [void]$h.Append('<p class="toolbar">' + $GroupsById.Count + ' groups reached &middot; ' +
        $dynamicRoots.Count + ' by rule &middot; ' + $assignedRoots.Count + ' added directly &middot; ')
    if ($dynamicCount -gt 0) {
        [void]$h.Append('<button class="linky" id="expandall">expand everything</button> &middot; ')
    }
    [void]$h.Append('<button class="linky" id="showzero" data-state="off">show groups with no policy</button></p>')

    [void]$h.Append('<h3 style="font-size:12.5px;font-weight:600;margin:14px 0 3px">Matched by rule</h3>')
    [void]$h.Append('<p class="hint">Dynamic groups whose membership rule this device satisfies. Everything nested beneath was inherited, not targeted.</p>')
    [void]$h.Append($dynamicTree)

    [void]$h.Append('<h3 style="font-size:12.5px;font-weight:600;margin:18px 0 3px">Added directly</h3>')
    [void]$h.Append('<p class="hint">Assigned groups the device is a member of because someone put it there.</p>')
    [void]$h.Append($assignedTree)

    [void]$h.Append('<p class="hint" style="margin:14px 0 0;border-top:1px solid #ced5db;padding-top:10px">Entra does not record when a device joined a dynamic group, so this shows how membership arises, not when it began.</p></details></section>')

    $appliesTotal = $ApplyRows.Count
    $exclTotal    = @($ApplyRows | Where-Object { $_.Intent -eq 'Exclude' }).Count
    $appliesSummary = if ($appliesTotal -eq 0) {
        'Nothing targets this device through any of its groups.'
    } else {
        # Clauses that are zero are dropped: a clean device should read clean.
        $line = "$appliesTotal item" + $(if ($appliesTotal -eq 1) { '' } else { 's' }) + ' reach' +
                $(if ($appliesTotal -eq 1) { 'es' } else { '' }) + ' this device'
        $tail = @()
        if ($exclTotal -gt 0) { $tail += "$exclTotal excluded" }
        $line + $(if ($tail.Count -gt 0) { ', ' + ($tail -join ', ') }) + '.'
    }

    [void]$h.Append('<section><details class="tree">')
    [void]$h.Append('<summary><h2 style="display:inline">What reaches this device</h2>')
    [void]$h.Append('<span class="summary-line">' + (& $e $appliesSummary) + '</span></summary>')
    [void]$h.Append('<p class="hint">Grouped by type. Anything targeting one of the groups above appears here.</p>')
    [void]$h.Append('<input type="search" id="filter" placeholder="Filter across all sections...">')
    [void]$h.Append($sections.ToString())
    [void]$h.Append('</details></section>')

    [void]$h.Append('<script>' + $js + '</script></main></body></html>')
    return $h.ToString()
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }

    $serials     = @(([string]$Parameters.serialNumbers -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $includeApps = [bool]$Parameters.includeApps
    $writeHtml   = [bool]$Parameters.writeHtml

    # Sent by the page so an exported report opens in the theme the admin was
    # already using. A file:// report cannot read the app's saved choice.
    $reportTheme = if ($Parameters.ContainsKey('theme') -and $Parameters.theme -eq 'dark') { 'dark' } else { 'light' }

    if ($serials.Count -eq 0) {
        return New-SightlineToolResult -Status 'Failed' -Message 'No serial number given.'
    }
    if ($serials.Count -gt 2) {
        return New-SightlineToolResult -Status 'Failed' `
            -Message "$($serials.Count) serials given; this tool takes one or two. One traces a device, two compare them."
    }

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $deviceRows = [System.Collections.Generic.List[object]]::new()
    $intentRows = [System.Collections.Generic.List[object]]::new()

    # Held with the set of serials each one reaches, so the same collection can
    # be rendered as one comparison or as separate journeys.
    #
    # Named explicitly: a plain $assignments would collide with the per-policy
    # Graph result inside the loop below, which is exactly how this broke once.
    $reachingAssignments = [System.Collections.Generic.List[object]]::new()

    # --- Resolve each device ---------------------------------------------------
    $found    = [System.Collections.Generic.List[object]]::new()
    $originOf = @{}   # serial -> how the device came to exist
    $apOf     = @{}   # serial -> Autopilot registration, where there is one
    $deviceNo = 0

    foreach ($query in $serials) {
        $deviceNo++
        & $ReportProgress (5 + $deviceNo * 5) "Finding $query"

        $lookup = Find-SightlineDeviceRecord -Query $query
        if (-not $lookup.Device) {
            return New-SightlineToolResult -Status 'Failed' -OutputPath $folder -Message $lookup.Problem
        }

        $device = $lookup.Device
        $names  = $device.PSObject.Properties.Name
        $serial = if ($names -contains 'serialNumber' -and $device.serialNumber) {
            [string]$device.serialNumber
        } else {
            [string]$device.deviceName
        }

        if (-not ($names -contains 'azureADDeviceId') -or -not $device.azureADDeviceId) {
            return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
                -Message "$serial has an Intune record but no directory object, so it has no group membership to report."
        }

        $originOf[$serial] = Get-SightlineDeviceOrigin -EntraDeviceId ([string]$device.azureADDeviceId)
        if ($originOf[$serial].Problem) {
            $warnings.Add("$serial : the directory object could not be read, so the join type and owner are unknown.")
        }

        # Autopilot is enrichment now, not a prerequisite. Most estates are a
        # mix, and a co-managed or hybrid joined device has a journey too.
        $apOf[$serial] = $null
        try {
            $escaped = $serial.Replace("'", "''")
            $ap = Get-SightlineGraphCollection `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$escaped')"
            $exact = @($ap.Items | Where-Object { ([string]$_.serialNumber) -eq $serial })
            if ($exact.Count -gt 0) { $apOf[$serial] = $exact[0] }
        }
        catch { }

        $found.Add($device)
    }

    # Identify devices by the serial their record carries, not by whatever was
    # typed. A device name resolves to a record whose serial differs from the
    # search term, and every lookup below is keyed on the serial.
    $serials = @($found | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'serialNumber' -and $_.serialNumber) {
            [string]$_.serialNumber
        } else { [string]$_.deviceName }
    })

    $coverage.Add([pscustomobject]@{
        Source = 'deviceManagement/managedDevices (by name or serial)'; Count = $found.Count
        Complete = $true; Failure = $null
    })

    $withAutopilot = @($serials | Where-Object { $apOf[$_] }).Count
    $coverage.Add([pscustomobject]@{
        Source = 'windowsAutopilotDeviceIdentities (enrichment)'; Count = $withAutopilot
        Complete = $true; Failure = $null
    })

    $tags = @($serials | ForEach-Object {
        if ($apOf[$_] -and $apOf[$_].PSObject.Properties.Name -contains 'groupTag') {
            [string]$apOf[$_].groupTag
        } else { '' }
    } | Select-Object -Unique)

    if ($found.Count -eq 2) {
        $realTags = @($tags | Where-Object { $_ })
        if ($realTags.Count -gt 1) {
            $warnings.Add("The two devices carry different group tags: $($realTags -join ' and '). That alone explains most differences below.")
        }

        $joins = @($serials | ForEach-Object { $originOf[$_].JoinType } | Select-Object -Unique)
        if ($joins.Count -gt 1) {
            $warnings.Add("The two devices are joined differently: $($joins -join ' and '). That affects which dynamic rules can match them.")
        }
    }

    # --- Real membership, from the directory ---------------------------------
    & $ReportProgress 25 'Resolving group membership'

    $memberOf    = @{}   # serial -> every group id, direct and inherited
    $directOf    = @{}   # serial -> group ids the device is genuinely a member of
    $nestedIn    = @{}   # group id -> group ids it is nested inside
    $groupsById  = @{}
    $tagBySerial = @{}

    foreach ($device in $found) {
        $dn      = $device.PSObject.Properties.Name
        $serial  = if ($dn -contains 'serialNumber' -and $device.serialNumber) { [string]$device.serialNumber } else { [string]$device.deviceName }
        $entraId = [string]$device.azureADDeviceId

        try {
            $dirDevice = Invoke-SightlineGraphRequest `
                -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraId')?`$select=id,displayName,accountEnabled,approximateLastSignInDateTime"
        }
        catch {
            $warnings.Add("$serial : no readable directory object - $($_.Exception.Message)")
            $memberOf[$serial] = @()
            continue
        }

        $groups = Get-SightlineGraphCollection `
            -Uri "https://graph.microsoft.com/v1.0/devices/$($dirDevice.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,membershipRule"

        if (-not $groups.Complete) {
            $warnings.Add("$serial : group membership is incomplete, so some policies may be missing from this report.")
        }

        $ids = @()
        foreach ($group in $groups.Items) {
            $gid = [string]$group.id
            $ids += $gid
            $groupsById[$gid] = $group
        }
        $memberOf[$serial] = $ids

        # transitiveMemberOf flattens direct and inherited together. The forest
        # needs them apart: direct memberships are its roots, everything else
        # is reached by nesting and was never targeted at this device.
        try {
            $direct = Get-SightlineGraphCollection `
                -Uri "https://graph.microsoft.com/v1.0/devices/$($dirDevice.id)/memberOf/microsoft.graph.group?`$select=id"
            $directOf[$serial] = @($direct.Items | ForEach-Object { [string]$_.id })
        }
        catch {
            $directOf[$serial] = @()
            $warnings.Add("$serial : direct group membership could not be read, so the group tree may show inherited groups as direct.")
        }

        $autopilot = $apOf[$serial]
        $apNames   = if ($autopilot) { $autopilot.PSObject.Properties.Name } else { @() }
        $tagBySerial[$serial] = if ($autopilot -and $apNames -contains 'groupTag') { [string]$autopilot.groupTag } else { '' }

        $origin = $originOf[$serial]

        $deviceRows.Add([pscustomobject]@{
            SerialNumber    = $serial
            DeviceName      = if ($dn -contains 'deviceName') { $device.deviceName } else { '' }
            JoinType        = $origin.JoinType
            JoinedBy        = $origin.JoinedBy
            RegisteredOn    = $origin.RegisteredOn
            Enrolment       = if ($dn -contains 'deviceEnrollmentType') { $device.deviceEnrollmentType } else { '' }
            ManagedBy       = if ($dn -contains 'managementAgent') { $device.managementAgent } else { '' }
            InAutopilot     = if ($autopilot) { 'Yes' } else { 'No' }
            GroupTag        = $tagBySerial[$serial]
            DisplayName     = $origin.DisplayName
            OS              = if ($dn -contains 'operatingSystem') { "$($device.operatingSystem) $($device.osVersion)" } else { '' }
            Model           = if ($dn -contains 'model') { $device.model } else { '' }
            Manufacturer    = if ($dn -contains 'manufacturer') { $device.manufacturer } else { '' }
            Owner           = if ($dn -contains 'managedDeviceOwnerType') { $device.managedDeviceOwnerType } else { '' }
            PrimaryUser     = if ($dn -contains 'userPrincipalName') { $device.userPrincipalName } else { '' }
            Compliance      = if ($dn -contains 'complianceState') { $device.complianceState } else { '' }
            Enrolled        = if ($dn -contains 'enrolledDateTime') { $device.enrolledDateTime } else { '' }
            LastSync        = if ($dn -contains 'lastSyncDateTime') { $device.lastSyncDateTime } else { '' }
            GroupCount      = $ids.Count
            EntraDeviceId   = $entraId
        })
    }

    $coverage.Add([pscustomobject]@{
        Source = 'devices/{id}/transitiveMemberOf'; Count = $groupsById.Count
        Complete = $true; Failure = $null
    })

    # Which of these groups sits inside which. Bounded by the groups this device
    # is in - a handful - so one batched call covers it.
    & $ReportProgress 40 'Reading how those groups nest'

    if ($groupsById.Count -gt 0) {
        $edgeRequests = @($groupsById.Keys | ForEach-Object {
            @{ Id = [string]$_; Url = "/groups/$_/memberOf/microsoft.graph.group?`$select=id" }
        })

        $edges = Get-SightlineBatchCollection -Requests $edgeRequests -Version 'v1.0'

        foreach ($gid in $edges.Results.Keys) {
            $entry = $edges.Results[$gid]
            if ($entry.Failure) { $nestedIn[$gid] = @(); continue }

            # Only parents this device actually reaches are part of its story.
            $nestedIn[$gid] = @($entry.Items |
                ForEach-Object { [string]$_.id } |
                Where-Object { $groupsById.ContainsKey($_) })
        }

        $coverage.Add([pscustomobject]@{
            Source = 'groups/{id}/memberOf (nesting edges, batched)'; Count = $edgeRequests.Count
            Complete = $edges.Complete; Failure = $edges.Failure
        })

        if (-not $edges.Complete) {
            $warnings.Add('Some nesting relationships could not be read, so the group tree may be missing branches.')
        }
    }

    # --- What reaches those groups -------------------------------------------
    & $ReportProgress 55 'Reading assignments'

    $filters   = (Get-SightlineFilterLookup).Lookup
    $surfaces  = @(Get-SightlinePolicySurfaces -IncludeApps:$includeApps)
    $surfaceNo = 0

    foreach ($surface in $surfaces) {
        $surfaceNo++
        & $ReportProgress (58 + [int](($surfaceNo / $surfaces.Count) * 32)) "Reading $($surface.Kind)"

        $listed = Get-SightlineGraphCollection -Uri $surface.Uri
        $coverage.Add([pscustomobject]@{
            Source = $surface.Label; Count = $listed.Count
            Complete = $listed.Complete; Failure = $listed.Failure
        })

        if (-not $listed.Complete) {
            $optional = ($surface.ContainsKey('Optional') -and $surface.Optional)
            if (-not $optional) {
                $warnings.Add("$($surface.Kind) did not collect fully. It may reach these devices without appearing here.")
            }
            continue
        }

        foreach ($policy in $listed.Items) {
            try {
                $policyAssignments = Get-SightlineGraphCollection -Uri "$($surface.Uri.Split('?')[0])/$($policy.id)/assignments"
            }
            catch { continue }

            foreach ($assignment in $policyAssignments.Items) {
                $target = $assignment.target
                $tn     = $target.PSObject.Properties.Name
                $type   = if ($tn -contains '@odata.type') { $target.'@odata.type' } else { '' }

                $reaches = @()
                $via     = ''

                if ($type -like '*allDevicesAssignmentTarget*') {
                    $reaches = @($memberOf.Keys)
                    $via     = 'All devices'
                }
                elseif ($tn -contains 'groupId' -and $target.groupId) {
                    $gid = [string]$target.groupId
                    if ($groupsById.ContainsKey($gid)) {
                        $reaches = @($memberOf.Keys | Where-Object { $memberOf[$_] -contains $gid })
                        $via     = [string]$groupsById[$gid].displayName
                    }
                }

                if ($reaches.Count -eq 0) { continue }

                $filterName = ''
                if ($tn -contains 'deviceAndAppManagementAssignmentFilterId' -and
                    $target.deviceAndAppManagementAssignmentFilterId) {
                    $fid = $target.deviceAndAppManagementAssignmentFilterId
                    $filterName = if ($filters.ContainsKey($fid)) { $filters[$fid] } else { $fid }
                }

                $isExclusion = ($type -like '*exclusion*')

                # Policies are simply included or excluded. Apps carry an
                # install intent as well - required, available, uninstall -
                # which the target type does not express, so a required app and
                # an available one were previously indistinguishable.
                $display = if ($isExclusion) {
                    'Excluded'
                }
                elseif ($assignment.PSObject.Properties.Name -contains 'intent' -and $assignment.intent) {
                    switch ([string]$assignment.intent) {
                        'required'                   { 'Required' }
                        'available'                  { 'Available' }
                        'uninstall'                  { 'Uninstall' }
                        'availableWithoutEnrollment' { 'Available (no enrolment)' }
                        default                      { [string]$assignment.intent }
                    }
                }
                else { 'Included' }

                $reachingAssignments.Add([pscustomobject]@{
                    PolicyName = Get-SightlinePolicyName -Policy $policy -NameField $surface.NameField
                    PolicyKind = $surface.Kind
                    Intent     = if ($isExclusion) { 'Exclude' } else { 'Include' }
                    Assignment = $display
                    ReachesVia = $via
                    FilterName = $filterName
                    PolicyId   = $policy.id
                    Reaches    = @($reaches)
                })
            }
        }
    }

    # How many assignments arrive through each group. This is what makes the
    # tree say something: five policies from a group two levels up is the point.
    $policyCountByGroup = @{}
    foreach ($assignment in $reachingAssignments) {
        foreach ($gid in $groupsById.Keys) {
            if ([string]$groupsById[$gid].displayName -eq [string]$assignment.ReachesVia) {
                if (-not $policyCountByGroup.ContainsKey($gid)) { $policyCountByGroup[$gid] = 0 }
                $policyCountByGroup[$gid]++
            }
        }
    }

    # How many distinct paths reach each group. A group reached fifteen ways is
    # drawn once and says so, rather than fifteen times.
    $pathCountByGroup = @{}
    $rootsForGroup = @{}
    foreach ($serial in $directOf.Keys) {
        foreach ($root in @($directOf[$serial])) {
            if (-not $groupsById.ContainsKey($root)) { continue }
            $stack = [System.Collections.Generic.Stack[string]]::new()
            $stack.Push($root)
            $seen = @{}
            while ($stack.Count -gt 0) {
                $current = $stack.Pop()
                if ($seen.ContainsKey($current)) { continue }
                $seen[$current] = $true
                if ($current -ne $root) {
                    if (-not $rootsForGroup.ContainsKey($current)) { $rootsForGroup[$current] = @() }
                    if ($rootsForGroup[$current] -notcontains $root) { $rootsForGroup[$current] += $root }
                }
                if (-not $pathCountByGroup.ContainsKey($current)) { $pathCountByGroup[$current] = 0 }
                $pathCountByGroup[$current]++
                if ($nestedIn.ContainsKey($current)) {
                    foreach ($parent in @($nestedIn[$current])) { $stack.Push($parent) }
                }
            }
        }
    }

    # --- Row builders ---------------------------------------------------------
    # A single journey needs no AppliesTo column - every row applies to that one
    # device. The comparison view needs it, and a column saying whether both
    # share the row. Building both from the same data keeps them consistent.

    function New-JourneyGroupRows {
        param([string[]] $Serials, [switch] $Compare)

        $rows = [System.Collections.Generic.List[object]]::new()

        foreach ($gid in $groupsById.Keys) {
            $inThis = @($Serials | Where-Object { $memberOf[$_] -contains $gid })
            if ($inThis.Count -eq 0) { continue }

            $group = $groupsById[$gid]
            $names = $group.PSObject.Properties.Name
            $rule  = if ($names -contains 'membershipRule' -and $group.membershipRule) { [string]$group.membershipRule } else { '' }

            $mentions = ''
            if ($rule) {
                $mentions = 'No'
                foreach ($serial in $inThis) {
                    $tag = $tagBySerial[$serial]
                    if ($tag -and $rule -like "*$tag*") { $mentions = 'Yes'; break }
                }
            }

            $row = [ordered]@{ GroupName = [string]$group.displayName }
            if ($Compare) {
                $row.AppliesTo    = ($inThis -join '; ')
                $row.SharedByBoth = if ($inThis.Count -eq $Serials.Count) { 'Yes' } else { 'No' }
            }
            $row.Membership      = if ($rule) { 'Dynamic' } else { 'Assigned' }
            $row.RuleMentionsTag = $mentions
            $row.MembershipRule  = $rule
            $row.GroupId         = $gid

            $rows.Add([pscustomobject]$row)
        }

        return @($rows)
    }

    function New-JourneyApplyRows {
        param([string[]] $Serials, [switch] $Compare)

        $rows = [System.Collections.Generic.List[object]]::new()

        foreach ($assignment in $reachingAssignments) {
            $inThis = @($Serials | Where-Object { $assignment.Reaches -contains $_ })
            if ($inThis.Count -eq 0) { continue }

            $row = [ordered]@{
                PolicyName = $assignment.PolicyName
                PolicyKind = $assignment.PolicyKind
                Intent     = $assignment.Intent
                Assignment = $assignment.Assignment
                ReachesVia = $assignment.ReachesVia
            }
            if ($Compare) {
                $row.AppliesTo    = ($inThis -join '; ')
                $row.SharedByBoth = if ($inThis.Count -eq $Serials.Count) { 'Yes' } else { 'No' }
            }
            $row.FilterName = $assignment.FilterName
            $row.Note       = if ($assignment.FilterName) { 'A filter may still prevent this from applying.' } else { '' }
            $row.PolicyId   = $assignment.PolicyId

            $rows.Add([pscustomobject]$row)
        }

        return @($rows)
    }

    # --- Where the two devices differ ----------------------------------------
    $differences = [System.Collections.Generic.List[object]]::new()

    $tagsDiffer = $false
    if ($found.Count -eq 2) {
        $t1 = $tagBySerial[$serials[0]]
        $t2 = $tagBySerial[$serials[1]]
        $tagsDiffer = ($t1 -ne $t2)
    }

    if ($found.Count -eq 2 -and -not $tagsDiffer) {
        & $ReportProgress 92 'Comparing the two devices'
        $a = $serials[0]
        $b = $serials[1]

        $compareGroups = @(New-JourneyGroupRows -Serials $serials -Compare)
        $compareApplies = @(New-JourneyApplyRows -Serials $serials -Compare)

        foreach ($row in $compareGroups) {
            if ($row.SharedByBoth -eq 'Yes') { continue }
            $differences.Add([pscustomobject]@{
                Difference = 'Group membership'
                Item       = $row.GroupName
                Kind       = $row.Membership
                AppliesTo  = $row.AppliesTo
                Missing    = (@($a, $b | Where-Object { $row.AppliesTo -notlike "*$_*" }) -join '; ')
                Detail     = if ($row.MembershipRule) { $row.MembershipRule } else { 'Assigned membership - the device was added manually.' }
            })
        }

        foreach ($row in $compareApplies) {
            if ($row.SharedByBoth -eq 'Yes') { continue }
            $differences.Add([pscustomobject]@{
                Difference = 'Policy reach'
                Item       = $row.PolicyName
                Kind       = $row.PolicyKind
                AppliesTo  = $row.AppliesTo
                Missing    = (@($a, $b | Where-Object { $row.AppliesTo -notlike "*$_*" }) -join '; ')
                Detail     = "Reaches via $($row.ReachesVia)"
            })
        }

        foreach ($field in @('JoinType', 'JoinedBy', 'InAutopilot', 'GroupTag', 'Enrolment', 'ManagedBy', 'Model', 'Owner')) {
            $values = @($deviceRows | ForEach-Object { [string]$_.$field } | Select-Object -Unique)
            if ($values.Count -le 1) { continue }
            $differences.Add([pscustomobject]@{
                Difference = "Devices differ on $field"
                Item       = $field
                Kind       = 'Device property'
                AppliesTo  = ''
                Missing    = ''
                Detail     = (@($deviceRows | ForEach-Object { "$($_.SerialNumber)=$($_.$field)" }) -join '; ')
            })
        }

        if ($differences.Count -eq 0) {
            $warnings.Add('The two devices are in identical groups and receive identical assignments. Any behavioural difference lies outside what Intune targets - a filter, local state, or something reported at check-in.')
        }
    }

    # --- Rules mentioning the tag, checked against reality --------------------
    & $ReportProgress 95 'Comparing rules against reality'

    $realTags = @($tags | Where-Object { $_ })
    if ($realTags.Count -gt 0) {
        $ruleGroups = Get-SightlineGraphCollection `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=securityEnabled eq true&`$select=id,displayName,membershipRule&`$top=999"

        if ($ruleGroups.Complete) {
            foreach ($group in $ruleGroups.Items) {
                $names = $group.PSObject.Properties.Name
                if ($names -notcontains 'membershipRule' -or -not $group.membershipRule) { continue }

                $rule = [string]$group.membershipRule
                $hit  = $false
                foreach ($tag in $realTags) { if ($rule -like "*$tag*") { $hit = $true; break } }
                if (-not $hit) { continue }

                $gid    = [string]$group.id
                $inThis = @($memberOf.Keys | Where-Object { $memberOf[$_] -contains $gid })

                $intentRows.Add([pscustomobject]@{
                    GroupName      = [string]$group.displayName
                    DevicesActuallyIn = ($inThis -join '; ')
                    Agrees         = if ($inThis.Count -gt 0) { 'Yes' }
                                     else { 'NO - the rule references this tag but neither device is in the group' }
                    MembershipRule = $rule
                    GroupId        = $gid
                })
            }
        }
        else {
            $warnings.Add('The dynamic rule list could not be read, so no comparison against intent was possible.')
        }

        $coverage.Add([pscustomobject]@{
            Source = 'groups with dynamic rules (intent comparison)'; Count = $ruleGroups.Count
            Complete = $ruleGroups.Complete; Failure = $ruleGroups.Failure
        })
    }

    $disagree = @($intentRows | Where-Object { $_.Agrees -ne 'Yes' })
    if ($disagree.Count -gt 0) {
        $warnings.Add("$($disagree.Count) group rule(s) reference this tag but contain neither device. Either the rule does not match as intended, or membership has not finished processing.")
    }

    $warnings.Add('Groups here come from actual directory membership, not from reading rules. Rule text is shown only as explanation.')

    # --- Output ----------------------------------------------------------------
    & $ReportProgress 97 'Writing report'

    $written = [System.Collections.Generic.List[string]]::new()

    function Write-Journey {
        param(
            [Parameter(Mandatory)] [string[]] $Serials,
            [Parameter(Mandatory)] [string]   $BaseName,
            [switch] $Compare,
            [object[]] $ExtraSheets = @()
        )

        $sheets = @()
        foreach ($extra in @($ExtraSheets)) { $sheets += $extra }

        $sheets += @{ Name = 'Devices'; Rows = @($deviceRows | Where-Object { $Serials -contains $_.SerialNumber }) }
        $sheets += @{ Name = 'Groups';  Rows = @(New-JourneyGroupRows -Serials $Serials -Compare:$Compare) }
        $sheets += @{ Name = 'Applies'; Rows = @(New-JourneyApplyRows -Serials $Serials -Compare:$Compare) }

        $tagsHere = @($Serials | ForEach-Object { $tagBySerial[$_] } | Where-Object { $_ } | Select-Object -Unique)
        $relevant = @($intentRows | Where-Object {
            $rule = [string]$_.MembershipRule
            $hit = $false
            foreach ($tag in $tagsHere) { if ($rule -like "*$tag*") { $hit = $true; break } }
            $hit
        })
        if ($relevant.Count -gt 0) { $sheets += @{ Name = 'Rules mentioning tag'; Rows = $relevant } }

        $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
            -Coverage @($coverage) -Warnings @($warnings)

        $path = Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
            -BaseName $BaseName -Sheets $sheets
        $written.Add([string]$path)

        # One HTML file per device: the forest describes a single device's
        # membership, so a combined page would have to draw two forests and
        # the comparison already lives in the workbook.
        if ($writeHtml) {
            foreach ($serial in $Serials) {
                $htmlBody = New-JourneyHtmlReport `
                    -Serial      $serial `
                    -Tag         ([string]$tagBySerial[$serial]) `
                    -DirectOf    $directOf `
                    -NestedIn    $nestedIn `
                    -GroupsById  $groupsById `
                    -PolicyCount $policyCountByGroup `
                    -PathCount   $pathCountByGroup `
                    -DeviceRows  @($deviceRows | Where-Object { $_.SerialNumber -eq $serial }) `
                    -ApplyRows   @(New-JourneyApplyRows -Serials @($serial)) `
                    -Provenance  $provenance `
                    -Theme       $reportTheme

                $htmlName = 'journey-' + ($serial -replace '[^A-Za-z0-9\-]', '-') + '.html'
                $htmlPath = Join-Path $folder $htmlName
                Write-SightlineTextFile -Path $htmlPath -Content $htmlBody
                $written.Add([string]$htmlPath)
            }
        }
    }

    if ($tagsDiffer) {
        # Two devices on different tags are two separate journeys, not a
        # comparison. Merging them would invite conclusions from rows that
        # were never comparable in the first place.
        $warnings.Add("The two devices carry different group tags ($($tagBySerial[$serials[0]]) and $($tagBySerial[$serials[1]])). They have been written as two separate reports, because their journeys start from different places and are not comparable.")

        foreach ($serial in $serials) {
            $safe = ($serial -replace '[^A-Za-z0-9\-]', '-')
            $tag  = $tagBySerial[$serial]
            $tagPart = if ($tag) { '-' + ($tag -replace '[^A-Za-z0-9\-]', '-') } else { '' }
            Write-Journey -Serials @($serial) -BaseName "journey-$safe$tagPart"
        }
    }
    else {
        $extra = @()
        if ($differences.Count -gt 0) { $extra += @{ Name = 'Differences';        Rows = @($differences) } }
        if ($disagree.Count -gt 0)    { $extra += @{ Name = 'Rules not matching'; Rows = @($disagree) } }

        $safe = (($serials -join '-') -replace '[^A-Za-z0-9\-]', '-')
        Write-Journey -Serials $serials -BaseName "journey-$safe" -Compare:($found.Count -eq 2) -ExtraSheets $extra
    }

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $htmlCount = @($written | Where-Object { $_ -like '*.html' }).Count

    $message = if ($tagsDiffer) {
        "Two separate journeys written - the devices carry different group tags, so there is nothing to compare."
    } else {
        "$($deviceRows.Count) device(s), $($groupsById.Count) group(s), $($reachingAssignments.Count) assignment(s)."
    }
    if ($htmlCount -gt 0) { $message += " $htmlCount interactive HTML report(s) written alongside." }
    if ($differences.Count -gt 0) { $message += " $($differences.Count) difference(s) between them." }
    if ($disagree.Count -gt 0)    { $message += " $($disagree.Count) rule(s) disagree with membership." }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $reachingAssignments.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}
