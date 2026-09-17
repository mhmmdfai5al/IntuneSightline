Set-StrictMode -Version Latest

$script:SightlineGraphBeta = 'https://graph.microsoft.com/beta'

function Get-SightlinePolicySurfaces {
    <#
        The catalogue of endpoints that hold assignable configuration.

        Kept as data rather than logic scattered through tools, because
        Microsoft moves these. Security baselines live on two surfaces at once:
        older ones under deviceManagement/intents, newer ones under
        configurationPolicies filtered by templateFamily. Query one and the
        other class silently disappears, producing a clean report that is
        simply missing half the tenant.
    #>
    param([switch] $IncludeApps)

    $base = $script:SightlineGraphBeta

    $surfaces = @(
        @{ Kind = 'Settings catalog'; Label = 'deviceManagement/configurationPolicies'
           Uri = "$base/deviceManagement/configurationPolicies"
           NameField = 'name'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Device configuration'; Label = 'deviceManagement/deviceConfigurations'
           Uri = "$base/deviceManagement/deviceConfigurations"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'ADMX template'; Label = 'deviceManagement/groupPolicyConfigurations'
           Uri = "$base/deviceManagement/groupPolicyConfigurations"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Compliance policy'; Label = 'deviceManagement/deviceCompliancePolicies'
           Uri = "$base/deviceManagement/deviceCompliancePolicies"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Security baseline (intent)'; Label = 'deviceManagement/intents'
           Uri = "$base/deviceManagement/intents"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Remediation script'; Label = 'deviceManagement/deviceHealthScripts'
           Uri = "$base/deviceManagement/deviceHealthScripts"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Platform script'; Label = 'deviceManagement/deviceManagementScripts'
           Uri = "$base/deviceManagement/deviceManagementScripts"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'macOS shell script'; Label = 'deviceManagement/deviceShellScripts'
           Uri = "$base/deviceManagement/deviceShellScripts"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All' },

        @{ Kind = 'Windows update ring'; Label = 'deviceManagement/windowsUpdateForBusinessConfigurations'
           Uri = "$base/deviceManagement/deviceConfigurations?`$filter=isof('microsoft.graph.windowsUpdateForBusinessConfiguration')"
           NameField = 'displayName'; Scope = 'DeviceManagementConfiguration.Read.All'; Optional = $true }
    )

    if ($IncludeApps) {
        $surfaces += @{ Kind = 'Application'; Label = 'deviceAppManagement/mobileApps'
                        Uri = "$base/deviceAppManagement/mobileApps"
                        NameField = 'displayName'; Scope = 'DeviceManagementApps.Read.All' }
    }

    return @($surfaces)
}

function Get-SightlineGroupLookup {
    <#
        id -> display name, so reports name the target instead of showing a GUID.
        A report an admin has to paste into another tool to understand is not
        a report.
    #>
    [CmdletBinding()]
    param([scriptblock] $OnProgress)

    $lookup = @{}
    $result = Get-SightlineGraphCollection -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName&$top=999' -OnProgress $OnProgress

    foreach ($group in $result.Items) {
        $lookup[$group.id] = $group.displayName
    }

    return [pscustomobject]@{
        Lookup   = $lookup
        Count    = $result.Count
        Complete = $result.Complete
        Failure  = $result.Failure
    }
}

function Get-SightlineFilterLookup {
    [CmdletBinding()]
    param()

    $lookup = @{}
    try {
        $result = Get-SightlineGraphCollection -Uri "$script:SightlineGraphBeta/deviceManagement/assignmentFilters"
        foreach ($filter in $result.Items) { $lookup[$filter.id] = $filter.displayName }
        return [pscustomobject]@{ Lookup = $lookup; Count = $result.Count; Complete = $result.Complete; Failure = $result.Failure }
    }
    catch {
        return [pscustomobject]@{ Lookup = $lookup; Count = 0; Complete = $false; Failure = $_.Exception.Message }
    }
}

function ConvertTo-SightlineAssignmentRow {
    <#
        Flattens one Graph assignment object into a row.

        Assignment targets are polymorphic: group, all devices, all users, plus
        exclusion variants, with an optional filter attached. Reports need one
        shape, so the odata type is resolved here rather than in every tool.
    #>
    param(
        [Parameter(Mandatory)] $Assignment,
        [Parameter(Mandatory)] [string] $PolicyName,
        [Parameter(Mandatory)] [string] $PolicyId,
        [Parameter(Mandatory)] [string] $PolicyKind,
        [hashtable] $Groups  = @{},
        [hashtable] $Filters = @{}
    )

    $target = $Assignment.target
    $type   = if ($target.PSObject.Properties.Name -contains '@odata.type') { $target.'@odata.type' } else { '' }

    $targetType = switch -Wildcard ($type) {
        '*allDevicesAssignmentTarget*'      { 'All devices' }
        '*allLicensedUsersAssignmentTarget*'{ 'All users' }
        '*exclusionGroupAssignmentTarget*'  { 'Group' }
        '*groupAssignmentTarget*'           { 'Group' }
        default                             { 'Unknown' }
    }

    $intent = if ($type -like '*exclusionGroupAssignmentTarget*') { 'Exclude' } else { 'Include' }

    $targetName = ''
    $targetId   = ''
    if ($targetType -eq 'Group' -and ($target.PSObject.Properties.Name -contains 'groupId')) {
        $targetId   = $target.groupId
        $targetName = if ($Groups.ContainsKey($targetId)) { $Groups[$targetId] } else { '(name not resolved)' }
    }

    $filterId   = ''
    $filterName = ''
    $filterMode = ''
    if ($target.PSObject.Properties.Name -contains 'deviceAndAppManagementAssignmentFilterId' -and
        $target.deviceAndAppManagementAssignmentFilterId) {
        $filterId   = $target.deviceAndAppManagementAssignmentFilterId
        $filterName = if ($Filters.ContainsKey($filterId)) { $Filters[$filterId] } else { '(name not resolved)' }
        if ($target.PSObject.Properties.Name -contains 'deviceAndAppManagementAssignmentFilterType') {
            $filterMode = $target.deviceAndAppManagementAssignmentFilterType
        }
    }

    [pscustomobject]@{
        PolicyName = $PolicyName
        PolicyKind = $PolicyKind
        PolicyId   = $PolicyId
        Intent     = $intent
        TargetType = $targetType
        TargetName = $targetName
        TargetId   = $targetId
        FilterName = $filterName
        FilterMode = $filterMode
        FilterId   = $filterId
    }
}

function Get-SightlinePolicyName {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $NameField
    )

    $names = $Policy.PSObject.Properties.Name
    if ($names -contains $NameField -and $Policy.$NameField) { return [string]$Policy.$NameField }
    if ($names -contains 'displayName' -and $Policy.displayName) { return [string]$Policy.displayName }
    if ($names -contains 'name' -and $Policy.name) { return [string]$Policy.name }
    return '(unnamed)'
}

function Get-SightlineDeviceStates {
    <#
        Intune's own per-policy verdict for a device.

        Deliberately not computed locally. Intune evaluates conflicts
        server-side across every policy targeting the device, including
        policies the signed-in admin cannot see. A local comparison runs only
        on what this account could read, so under scope tags it would report
        "no conflicts" on a device that genuinely has one - a false clean
        result, which is the worst outcome this tool can produce.

        The trade-off is that these states only exist after the device has
        checked in and reported, so the verdict is as of its last sync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ManagedDeviceId)

    $base   = "$script:SightlineGraphBeta/deviceManagement/managedDevices/$ManagedDeviceId"
    $states = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()

    $sources = @(
        @{ Kind = 'Device configuration'; Path = 'deviceConfigurationStates' },
        @{ Kind = 'Compliance policy';    Path = 'deviceCompliancePolicyStates' }
    )

    foreach ($source in $sources) {
        $result = Get-SightlineGraphCollection -Uri "$base/$($source.Path)"

        foreach ($state in $result.Items) {
            $names = $state.PSObject.Properties.Name
            $states.Add([pscustomobject]@{
                PolicyId    = if ($names -contains 'id') { $state.id } else { '' }
                DisplayName = if ($names -contains 'displayName') { $state.displayName } else { '(unnamed)' }
                Kind        = $source.Kind
                State       = if ($names -contains 'state') { $state.state } else { 'unknown' }
                Source      = $source.Path
                Version     = if ($names -contains 'version') { $state.version } else { '' }
            })
        }

        $coverage.Add([pscustomobject]@{
            Source   = "managedDevices/{id}/$($source.Path)"
            Count    = $result.Count
            Complete = $result.Complete
            Failure  = $result.Failure
        })
    }

    return [pscustomobject]@{
        States   = @($states)
        Coverage = @($coverage)
    }
}

function Get-SightlineConflictedSettings {
    <#
        Per-setting detail for one policy already reported as conflicted.

        Called only for policies in a conflict or error state, so the extra
        request per policy stays proportional to the problem rather than to
        the size of the tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManagedDeviceId,
        [Parameter(Mandatory)] [string] $PolicyStateId,
        [string] $Path = 'deviceConfigurationStates'
    )

    $uri = "$script:SightlineGraphBeta/deviceManagement/managedDevices/$ManagedDeviceId/$Path/$PolicyStateId/settingStates"

    try {
        $result = Get-SightlineGraphCollection -Uri $uri
    }
    catch {
        return [pscustomobject]@{ Settings = @(); Complete = $false; Failure = $_.Exception.Message }
    }

    $settings = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $result.Items) {
        $names = $item.PSObject.Properties.Name
        $state = if ($names -contains 'state') { $item.state } else { 'unknown' }

        # Only the settings actually in trouble; the rest are noise here.
        if ($state -notin @('conflict', 'error', 'notApplicable')) { continue }

        $sources = ''
        if ($names -contains 'sources' -and $item.sources) {
            $sources = (@($item.sources | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'displayName') { $_.displayName } else { $_.id }
            }) -join '; ')
        }

        $settings.Add([pscustomobject]@{
            Setting      = if ($names -contains 'settingName') { $item.settingName }
                           elseif ($names -contains 'setting') { $item.setting } else { '(unnamed)' }
            State        = $state
            CurrentValue = if ($names -contains 'currentValue') { $item.currentValue } else { '' }
            ErrorCode    = if ($names -contains 'errorCode') { $item.errorCode } else { '' }
            ContributingPolicies = $sources
        })
    }

    return [pscustomobject]@{
        Settings = @($settings)
        Complete = $result.Complete
        Failure  = $result.Failure
    }
}

function Get-SightlineDeviceIndex {
    <#
        One pass over managed devices, matched in memory afterwards.

        Resolving N devices with N filtered queries costs N round trips and
        breaks when a name contains a quote. One collection and a local index
        is cheaper for anything above a single device, and lets an ambiguous
        name be reported rather than silently resolved.
    #>
    [CmdletBinding()]
    param([scriptblock] $OnProgress)

    $select = 'id,deviceName,serialNumber,azureADDeviceId,operatingSystem,osVersion,' +
              'userPrincipalName,userDisplayName,managedDeviceOwnerType,complianceState,' +
              'lastSyncDateTime,enrolledDateTime,model,manufacturer,isEncrypted,joinType'

    $result = Get-SightlineGraphCollection `
        -Uri "$script:SightlineGraphBeta/deviceManagement/managedDevices?`$select=$select&`$top=999" `
        -OnProgress $OnProgress

    $byName   = @{}
    $bySerial = @{}
    $byId     = @{}

    foreach ($device in $result.Items) {
        $byId[[string]$device.id] = $device

        if ($device.PSObject.Properties.Name -contains 'azureADDeviceId' -and $device.azureADDeviceId) {
            $byId[[string]$device.azureADDeviceId] = $device
        }

        if ($device.deviceName) {
            $key = ([string]$device.deviceName).ToLowerInvariant()
            if (-not $byName.ContainsKey($key)) { $byName[$key] = @() }
            $byName[$key] += $device
        }

        if ($device.PSObject.Properties.Name -contains 'serialNumber' -and $device.serialNumber) {
            $key = ([string]$device.serialNumber).ToLowerInvariant()
            if (-not $bySerial.ContainsKey($key)) { $bySerial[$key] = @() }
            $bySerial[$key] += $device
        }
    }

    return [pscustomobject]@{
        ByName   = $byName
        BySerial = $bySerial
        ById     = $byId
        Count    = $result.Count
        Complete = $result.Complete
        Failure  = $result.Failure
    }
}

function Resolve-SightlineDeviceQuery {
    <#
        Matches one input against the index. Device name, serial number,
        Intune id or Entra device id, in that order.

        Returns the match plus a problem string rather than throwing, so one
        bad entry in a comma separated list does not abandon the others.
    #>
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] $Index
    )

    $needle = $Query.Trim()
    if (-not $needle) { return $null }

    $key = $needle.ToLowerInvariant()

    if ($Index.ById.ContainsKey($needle)) {
        return [pscustomobject]@{ Query = $needle; Device = $Index.ById[$needle]; Problem = $null; MatchedOn = 'ID' }
    }

    foreach ($pair in @(
        @{ Table = $Index.ByName;   On = 'device name' },
        @{ Table = $Index.BySerial; On = 'serial number' }
    )) {
        if ($pair.Table.ContainsKey($key)) {
            $hits = @($pair.Table[$key])
            if ($hits.Count -eq 1) {
                return [pscustomobject]@{ Query = $needle; Device = $hits[0]; Problem = $null; MatchedOn = $pair.On }
            }
            $list = (@($hits | ForEach-Object { "$($_.deviceName) [$($_.id)]" }) -join '; ')
            return [pscustomobject]@{
                Query = $needle; Device = $null; MatchedOn = $pair.On
                Problem = "matched $($hits.Count) devices - use the Intune ID instead: $list"
            }
        }
    }

    return [pscustomobject]@{
        Query = $needle; Device = $null; MatchedOn = $null
        Problem = 'no device matched. Names and serials must match exactly, though case does not matter.'
    }
}

function Get-SightlineDeviceApps {
    # Detected apps are beta only and single-device, so this is one call per
    # device and the caller decides whether it is worth it.
    param([Parameter(Mandatory)] [string] $ManagedDeviceId)

    try {
        $result = Get-SightlineGraphCollection `
            -Uri "$script:SightlineGraphBeta/deviceManagement/managedDevices/$ManagedDeviceId/detectedApps?`$select=id,displayName,version,publisher,sizeInByte"
        return [pscustomobject]@{ Apps = @($result.Items); Complete = $result.Complete; Failure = $result.Failure }
    }
    catch {
        return [pscustomobject]@{ Apps = @(); Complete = $false; Failure = $_.Exception.Message }
    }
}

function Get-SightlineEncryptionStates {
    # Fleet-wide encryption posture in one collection rather than per device.
    [CmdletBinding()]
    param()

    try {
        $result = Get-SightlineGraphCollection `
            -Uri "$script:SightlineGraphBeta/deviceManagement/managedDeviceEncryptionStates"
        $byId = @{}
        foreach ($state in $result.Items) { $byId[[string]$state.id] = $state }
        return [pscustomobject]@{ ById = $byId; Count = $result.Count; Complete = $result.Complete; Failure = $result.Failure }
    }
    catch {
        return [pscustomobject]@{ ById = @{}; Count = 0; Complete = $false; Failure = $_.Exception.Message }
    }
}

function Get-SightlinePolicyAssignments {
    <#
        Assignments for a whole surface in batched calls rather than one per
        policy.

        Assignments are a navigation property, absent from the list response,
        so every tool that walks a policy surface has been issuing one request
        per policy. On a tenant with a thousand policies that is a thousand
        sequential round trips per surface; batched at twenty it is fifty.

        Returns a hashtable of policy id -> the same shape
        Get-SightlineGraphCollection returns, so callers keep their existing
        Items / Count / Complete handling unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Surface,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
        [scriptblock] $OnProgress
    )

    $results = @{}
    if ($Policies.Count -eq 0) {
        return [pscustomobject]@{ ByPolicy = $results; Complete = $true; Failure = $null; Batches = 0 }
    }

    # Batch urls are relative to the version root, so the absolute surface uri
    # has to be reduced to its path. Query strings are dropped: the filter that
    # selected the policies does not belong on their assignments.
    $path = ([uri]($Surface.Uri.Split('?')[0])).AbsolutePath
    $version = if ($path -like '/beta/*') { 'beta' } else { 'v1.0' }
    $path = $path -replace '^/(beta|v1\.0)', ''

    $requests = @($Policies | ForEach-Object {
        @{ Id = [string]$_.id; Url = "$path/$($_.id)/assignments" }
    })

    $batch = Get-SightlineBatchCollection -Requests $requests -Version $version -OnProgress $OnProgress

    foreach ($id in $batch.Results.Keys) {
        $entry = $batch.Results[$id]
        $results[$id] = [pscustomobject]@{
            Items    = @($entry.Items)
            Count    = @($entry.Items).Count
            Complete = $entry.Complete
            Failure  = $entry.Failure
        }
    }

    return [pscustomobject]@{
        ByPolicy = $results
        Complete = $batch.Complete
        Failure  = $batch.Failure
        Batches  = $batch.Batches
    }
}
