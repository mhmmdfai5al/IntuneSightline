Set-StrictMode -Version Latest

$ToolId      = 'change-history'
$ToolVersion = '1.4.0'

function Get-SightlineAuditActor {
    <#
        The actor shape varies by how the change was made: an admin in the
        portal, an app using application permissions, or a service. Pull
        whichever identity fields are present rather than assuming one.
    #>
    param($Actor)

    if (-not $Actor) {
        return [pscustomobject]@{ Name = '(unknown)'; Id = ''; Type = 'unknown'; App = '' }
    }

    $names = $Actor.PSObject.Properties.Name

    $upn = ''
    foreach ($field in @('userPrincipalName', 'userId', 'remoteTenantId')) {
        if ($names -contains $field -and $Actor.$field) { $upn = [string]$Actor.$field; break }
    }

    $app = ''
    foreach ($field in @('applicationDisplayName', 'applicationId')) {
        if ($names -contains $field -and $Actor.$field) { $app = [string]$Actor.$field; break }
    }

    $type = if ($names -contains 'type' -and $Actor.type) { [string]$Actor.type } else { 'unknown' }

    $display = if ($upn) { $upn } elseif ($app) { "$app (application)" } else { '(unknown)' }

    return [pscustomobject]@{
        Name = $display
        Id   = if ($names -contains 'userId') { [string]$Actor.userId } else { '' }
        Type = $type
        App  = $app
    }
}

function Get-SightlineRoleGroupMap {
    <#
        Maps a security group id to the Intune role names assigned through it.

        Intune role assignments target security GROUPS, not users - the members
        collection is documented as "the list of role member security group
        Entra IDs". Keying this on user ids silently matched nothing.

        The role name comes from the expanded roleDefinition; the assignment's
        own displayName is the assignment ("Houston administrators"), not the
        role ("Help Desk Operator").
    #>
    [CmdletBinding()]
    param()

    $map = @{}

    try {
        $result = Get-SightlineGraphCollection `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleAssignments?$expand=roleDefinition'
    }
    catch {
        return [pscustomobject]@{ Map = $map; Count = 0; Complete = $false; Failure = $_.Exception.Message }
    }

    foreach ($assignment in $result.Items) {
        $names = $assignment.PSObject.Properties.Name

        $roleName = '(unnamed role)'
        if ($names -contains 'roleDefinition' -and $assignment.roleDefinition -and
            ($assignment.roleDefinition.PSObject.Properties.Name -contains 'displayName')) {
            $roleName = [string]$assignment.roleDefinition.displayName
        }
        elseif ($names -contains 'displayName') {
            $roleName = [string]$assignment.displayName
        }

        if ($names -contains 'members') {
            foreach ($groupId in @($assignment.members)) {
                $key = [string]$groupId
                if (-not $map.ContainsKey($key)) { $map[$key] = @() }
                if ($map[$key] -notcontains $roleName) { $map[$key] += $roleName }
            }
        }
    }

    return [pscustomobject]@{
        Map      = $map
        Count    = $map.Count
        Complete = $result.Complete
        Failure  = $result.Failure
    }
}

function Get-SightlineActorRoles {
    <#
        Resolves one actor's roles by walking their group memberships and
        intersecting with the role-group map. One request per actor, so the
        caller caps how many actors are worth resolving.
    #>
    param(
        [Parameter(Mandatory)] [string] $UserId,
        [Parameter(Mandatory)] [hashtable] $RoleGroupMap
    )

    try {
        $groups = Get-SightlineGraphCollection `
            -Uri "https://graph.microsoft.com/v1.0/users/$UserId/transitiveMemberOf/microsoft.graph.group?`$select=id"
    }
    catch {
        return @()
    }

    $roles = @()
    foreach ($group in $groups.Items) {
        $id = [string]$group.id
        if ($RoleGroupMap.ContainsKey($id)) {
            foreach ($role in $RoleGroupMap[$id]) {
                if ($roles -notcontains $role) { $roles += $role }
            }
        }
    }

    return @($roles)
}

function Get-SightlineActivityTypes {
    <#
        The valid activity vocabulary, assembled from the two helper functions
        Intune exposes. Activity types are scoped to a category, so the full
        list is the union across categories.
    #>
    [CmdletBinding()]
    param()

    $base = 'https://graph.microsoft.com/beta/deviceManagement/auditEvents'
    $all  = [System.Collections.Generic.List[string]]::new()

    try {
        $categories = Invoke-SightlineGraphRequest -Uri "$base/getAuditCategories"
    }
    catch {
        return [pscustomobject]@{ Types = @(); Complete = $false; Failure = $_.Exception.Message }
    }

    foreach ($category in @($categories.value)) {
        try {
            $types = Invoke-SightlineGraphRequest -Uri "$base/getAuditActivityTypes(category='$category')"
            foreach ($type in @($types.value)) {
                if ($type -and $all -notcontains $type) { $all.Add([string]$type) }
            }
        }
        catch { continue }
    }

    return [pscustomobject]@{ Types = @($all); Complete = $true; Failure = $null }
}

function Resolve-SightlineUpn {function Resolve-SightlineUpn {
    <#
        Confirms the account exists before scanning audit events.

        Without this, a typo and "this person changed nothing" both return an
        empty sheet and look identical. Cheap to check, and it fails fast
        rather than after a long collection.
    #>
    param([Parameter(Mandatory)] [string] $Upn)

    $escaped = $Upn.Replace("'", "''")
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$escaped'&`$select=id,userPrincipalName,displayName"

    try {
        $result = Invoke-SightlineGraphRequest -Uri $uri
    }
    catch {
        throw "Could not look up '$Upn': $($_.Exception.Message)"
    }

    $found = @($result.value)
    if ($found.Count -eq 0) {
        throw "No account found with the principal name '$Upn'. Check the spelling - audit events record the principal name, not the display name."
    }

    return $found[0]
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }

    $fromInput    = ([string]$Parameters.fromDate).Trim()
    $toInput      = ([string]$Parameters.toDate).Trim()
    $activityType = ([string]$Parameters.activityType).Trim()
    $objectName   = ([string]$Parameters.objectName).Trim()
    $upnFilter    = ([string]$Parameters.userPrincipalName).Trim()
    $resolveRoles = [bool]$Parameters.resolveRoles

    # An ID is exact and survives renames; a name is matched as it was recorded.
    $objectIsId = $objectName -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

    # Blank ends default to the last seven days, which is the common case,
    # but any window inside Graph's two year retention is valid.
    $fromDate = if ($fromInput) { [datetime]::ParseExact($fromInput, 'yyyy-MM-dd', $null) }
                else { (Get-Date).Date.AddDays(-7) }

    $toDate   = if ($toInput) { [datetime]::ParseExact($toInput, 'yyyy-MM-dd', $null).AddDays(1) }
                else { (Get-Date).AddMinutes(5) }

    if ($toDate -le $fromDate) {
        throw "The end of the range must be after the start. Got $($fromDate.ToString('yyyy-MM-dd')) to $($toInput)."
    }

    $spanDays = [math]::Round(($toDate - $fromDate).TotalDays, 1)

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $rows     = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $actorAccount = $null
    if ($upnFilter) {
        & $ReportProgress 2 'Checking the account exists'
        $actorAccount = Resolve-SightlineUpn -Upn $upnFilter
    }

    $since = $fromDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $until = $toDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $actorAccount = $null
    if ($upnFilter) {
        & $ReportProgress 2 'Checking the account exists'
        $actorAccount = Resolve-SightlineUpn -Upn $upnFilter
    }

    # Activity type is validated against the API's own vocabulary, because an
    # exact string is required and a near miss returns nothing rather than an
    # error - which reads as "no changes" and is the worst possible outcome.
    if ($activityType) {
        & $ReportProgress 3 'Checking the activity type'
        $vocab = Get-SightlineActivityTypes

        if ($vocab.Complete -and $vocab.Types.Count -gt 0) {
            $exact = @($vocab.Types | Where-Object { $_ -eq $activityType })
            if ($exact.Count -eq 0) {
                $near = @($vocab.Types | Where-Object { $_ -like "*$activityType*" } | Select-Object -First 12)
                $hint = if ($near.Count -gt 0) { " Did you mean: $($near -join '; ')" }
                        else { " Valid values include: $(@($vocab.Types | Select-Object -First 12) -join '; ')" }
                throw "'$activityType' is not an activity type Intune recognises.$hint"
            }
            $activityType = $exact[0]
        }
        else {
            $warnings.Add('The activity type could not be validated against Intune, so it was used as typed. A wrong value returns nothing rather than an error.')
        }
    }

    & $ReportProgress 5 'Reading audit events'

    # Only activityDateTime, activityType, displayName and id can be filtered
    # server-side. Actor and resource live inside nested objects that Intune's
    # audit API will not filter on, so an account or policy filter has to be
    # applied here after everything in the window has been read.
    #
    # That is why a wide window is slow: the cost is set by how many events
    # happened in the period, not by how many match.
    $base    = 'https://graph.microsoft.com/beta/deviceManagement/auditEvents'
    $clauses = @("activityDateTime ge $since", "activityDateTime le $until")

    $serverFiltered = @('date range')
    if ($activityType) {
        $clauses += "activityType eq '$($activityType.Replace("'", "''"))'"
        $serverFiltered += 'activity type'
    }

    $uri = "$base`?`$filter=$($clauses -join ' and ')&`$orderby=activityDateTime desc"

    $events = Get-SightlineGraphCollection -Uri $uri -MaxPages 500 -OnProgress {
        param($n) & $ReportProgress 25 "Read $n event(s)"
    }

    $coverage.Add([pscustomobject]@{
        Source   = "deviceManagement/auditEvents (filtered by $($serverFiltered -join ' and '))"
        Count    = $events.Count
        Complete = $events.Complete
        Failure  = $events.Failure
    })

    if (-not $events.Complete) {
        $warnings.Add('Audit collection did not finish, so changes are missing from this report. Narrow the date range and run again.')
    }

    $warnings.Add("Window: $($fromDate.ToString('yyyy-MM-dd')) to $($toDate.AddSeconds(-1).ToString('yyyy-MM-dd')) ($spanDays day(s)). Graph holds two years of audit events; anything older is gone, not hidden.")

    # Explain a long run rather than leaving it unaccounted for.
    if ($events.Count -gt 20000) {
        $localFilters = @()
        if ($upnFilter)  { $localFilters += 'account' }
        if ($objectName) { $localFilters += 'policy' }

        if ($localFilters.Count -gt 0) {
            $warnings.Add("$($events.Count) events were read to answer this. Intune's audit API filters on date and activity type only - the $($localFilters -join ' and ') filter had to be applied after collection. A shorter window, or an activity type, is what makes this faster.")
        } else {
            $warnings.Add("$($events.Count) events were read. On a large tenant an unfiltered window is simply this big; narrow the dates or set an activity type to reduce it.")
        }
    }

    $roleGroupMap = @{}
    $actorRoles   = @{}
    $rolesUsable  = $false

    if ($resolveRoles) {
        & $ReportProgress 35 'Reading role assignments'
        $roleResult   = Get-SightlineRoleGroupMap
        $roleGroupMap = $roleResult.Map
        $rolesUsable  = $roleResult.Complete -and $roleGroupMap.Count -gt 0

        $coverage.Add([pscustomobject]@{
            Source   = 'deviceManagement/roleAssignments (role groups)'
            Count    = $roleResult.Count
            Complete = $roleResult.Complete
            Failure  = $roleResult.Failure
        })

        if (-not $roleResult.Complete) {
            $warnings.Add('Role assignments could not be read in full, so the role column is incomplete.')
        }
        elseif ($roleGroupMap.Count -eq 0) {
            $warnings.Add('No Intune role assignments were visible to this account, so no roles could be resolved.')
        }
    }

    & $ReportProgress 55 'Building history'

    $matched = 0
    foreach ($event in $events.Items) {
        $names = $event.PSObject.Properties.Name

        $targets = @(if ($names -contains 'resources') { $event.resources } else { @() })
        if ($targets.Count -eq 0) { $targets = @($null) }

        foreach ($target in $targets) {
            $targetName = ''
            $targetId   = ''
            $targetType = ''

            if ($target) {
                $tn = $target.PSObject.Properties.Name
                if ($tn -contains 'displayName') { $targetName = [string]$target.displayName }
                if ($tn -contains 'resourceId')  { $targetId   = [string]$target.resourceId }
                if ($tn -contains 'type')        { $targetType = [string]$target.type }
            }

            # Exact, case-insensitive. No wildcard: a partial match that quietly
            # picks one of several similar policy names would produce a
            # confident history for the wrong object.
            if ($objectName) {
                $hit = if ($objectIsId) { $targetId -eq $objectName } else { $targetName -eq $objectName }
                if (-not $hit) { continue }
            }

            $actor = Get-SightlineAuditActor -Actor $(if ($names -contains 'actor') { $event.actor } else { $null })

            # Both filters together narrow rather than widen.
            if ($upnFilter -and $actor.Name -ne $upnFilter) { continue }

            $matched++

            $rows.Add([pscustomobject]@{
                When            = if ($names -contains 'activityDateTime') { $event.activityDateTime } else { '' }
                Action          = if ($names -contains 'activityOperationType') { $event.activityOperationType } else { '' }
                Result          = if ($names -contains 'activityResult') { $event.activityResult } else { '' }
                ObjectName      = $targetName
                ObjectType      = $targetType
                ObjectId        = $targetId
                Actor           = $actor.Name
                ActorType       = $actor.Type
                ActorId          = $actor.Id
                ActorCurrentRole = ''
                Category        = if ($names -contains 'category') { $event.category } else { '' }
                Activity        = if ($names -contains 'displayName') { $event.displayName } else { '' }
                ComponentName   = if ($names -contains 'componentName') { $event.componentName } else { '' }
                CorrelationId   = if ($names -contains 'correlationId') { $event.correlationId } else { '' }
            })
        }
    }

    $renames = @()

    if ($objectName -and $matched -eq 0) {
        $what = if ($objectIsId) { 'ID' } else { 'name' }
        $extra = if ($upnFilter) { " made by $upnFilter" } else { '' }
        $warnings.Add("No changes recorded for that $what$extra between $($fromDate.ToString('yyyy-MM-dd')) and $($toDate.AddSeconds(-1).ToString('yyyy-MM-dd')). Matching is exact. Widen the dates if the change was older.")
    }

    if ($objectName -and $matched -gt 0) {
        if ($objectIsId) {
            # An ID appearing under several names is a rename, and that is
            # often the answer to the question being asked.
            $usedNames = @($rows | Select-Object -ExpandProperty ObjectName -Unique | Where-Object { $_ })
            if ($usedNames.Count -gt 1) {
                $renames = @($rows | Group-Object ObjectName | ForEach-Object {
                    [pscustomobject]@{
                        Name        = $_.Name
                        Changes     = $_.Count
                        FirstSeen   = ($_.Group | Sort-Object When | Select-Object -First 1).When
                        LastSeen    = ($_.Group | Sort-Object When | Select-Object -Last 1).When
                    }
                } | Sort-Object LastSeen)
                $warnings.Add("This object has appeared under $($usedNames.Count) different names in the period: $($usedNames -join ', '). It was renamed.")
            }
        }
        else {
            # A name matching several IDs means the history is mixed together
            # and no single answer is safe.
            $ids = @($rows | Select-Object -ExpandProperty ObjectId -Unique | Where-Object { $_ })
            if ($ids.Count -gt 1) {
                $warnings.Add("The name '$objectName' matched $($ids.Count) different objects: $($ids -join ', '). This history mixes them together. Re-run with a specific ID for one object's changes.")
            }
        }
    }

    if ($rolesUsable) {
        $actorIds = @($rows | Where-Object { $_.ActorId } |
            Select-Object -ExpandProperty ActorId -Unique)

        # One request per actor, so cap it. A tenant-wide sweep can contain
        # hundreds of distinct actors and resolving all of them would cost more
        # than the report is worth.
        $cap = 50
        $toResolve = @($actorIds | Select-Object -First $cap)

        $done = 0
        foreach ($actorId in $toResolve) {
            $done++
            & $ReportProgress 80 "Resolving role $done of $($toResolve.Count)"
            $actorRoles[$actorId] = (@(Get-SightlineActorRoles -UserId $actorId -RoleGroupMap $roleGroupMap) -join '; ')
        }

        foreach ($row in $rows) {
            if ($row.ActorId -and $actorRoles.ContainsKey($row.ActorId)) {
                $row.ActorCurrentRole = $actorRoles[$row.ActorId]
            }
        }

        if ($actorIds.Count -gt $cap) {
            $warnings.Add("$($actorIds.Count) distinct actors appear; roles were resolved for the first $cap. Narrow the period or filter by account to resolve all of them.")
        }

        $unresolved = @($actorRoles.Values | Where-Object { -not $_ }).Count
        if ($unresolved -gt 0) {
            $warnings.Add("$unresolved actor(s) hold no Intune role through a group. They may act through Entra directory roles, which are not read here.")
        }
    }

    & $ReportProgress 85 'Summarising'

    $sheets = @(
        @{ Name = 'Changes'; Rows = @($rows) }
    )

    # Deletions are the whole reason to read audit at all - every other tool
    # in this set can only see objects that still exist.
    $deletions = @($rows | Where-Object { $_.Action -match 'Delete|Remove' })
    if ($deletions.Count -gt 0) {
        $sheets += @{ Name = 'Deletions'; Rows = $deletions }
        $warnings.Add("$($deletions.Count) deletion(s) in this period. These objects no longer exist and cannot be seen by any other report here.")
    }

    $byActor = @($rows | Group-Object Actor | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{
            Actor        = $_.Name
            Changes      = $_.Count
            CurrentRole  = (@($_.Group | Select-Object -ExpandProperty ActorCurrentRole -Unique | Where-Object { $_ }) -join '; ')
            FirstSeen    = ($_.Group | Sort-Object When | Select-Object -First 1).When
            LastSeen     = ($_.Group | Sort-Object When | Select-Object -Last 1).When
        }
    })
    if ($byActor.Count -gt 0) {
        $sheets += @{ Name = 'By actor'; Rows = $byActor }
    }

    $byObject = @($rows | Where-Object { $_.ObjectName } | Group-Object ObjectName |
        Sort-Object Count -Descending | Select-Object -First 500 | ForEach-Object {
            [pscustomobject]@{
                ObjectName  = $_.Name
                ObjectType  = ($_.Group | Select-Object -First 1).ObjectType
                Changes     = $_.Count
                Actors      = (@($_.Group | Select-Object -ExpandProperty Actor -Unique) -join '; ')
                LastChanged = ($_.Group | Sort-Object When | Select-Object -Last 1).When
            }
        })
    if ($byObject.Count -gt 0) {
        $sheets += @{ Name = 'By object'; Rows = $byObject }
    }

    if ($renames.Count -gt 0) {
        $sheets += @{ Name = 'Names used'; Rows = $renames }
    }

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName 'change-history' -Sheets $sheets | Out-Null

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $scope = @()
    if ($objectName) { $scope += "'$objectName'" }
    if ($upnFilter)  { $scope += "by $upnFilter" }

    $window = "$($fromDate.ToString('yyyy-MM-dd')) to $($toDate.AddSeconds(-1).ToString('yyyy-MM-dd'))"
    $message = if ($scope.Count -gt 0) {
        "$($rows.Count) change(s) to $($scope -join ' '), $window."
    } else {
        "$($rows.Count) change(s) across $($byObject.Count) object(s), $window."
    }
    if ($renames.Count -gt 0) { $message += " Renamed $($renames.Count - 1) time(s) in this period." }
    if ($deletions.Count -gt 0) { $message += " $($deletions.Count) were deletions." }
    if ($incomplete.Count -gt 0) { $message += ' Collection was incomplete.' }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $rows.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}
