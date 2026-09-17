Set-StrictMode -Version Latest

$ToolId      = 'device-360'
$ToolVersion = '2.1.0'

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }

    $queries          = @(([string]$Parameters.devices -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $includeConflicts = [bool]$Parameters.includeConflicts
    $includeEncrypt   = [bool]$Parameters.includeEncryption
    $includeInstalled = [bool]$Parameters.includeInstalledApps
    $includeApps      = [bool]$Parameters.includeApps

    if ($queries.Count -eq 0) {
        return New-SightlineToolResult -Status 'Failed' -Message 'No devices given.'
    }

    $maxDevices = 5
    if ($queries.Count -gt $maxDevices) {
        return New-SightlineToolResult -Status 'Failed' `
            -Message "$($queries.Count) devices given; this tool takes at most $maxDevices. Beyond a handful the output stops being readable - use assignment inventory or the orphan audit for fleet-wide questions."
    }

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $summary     = [System.Collections.Generic.List[object]]::new()
    $applies     = [System.Collections.Generic.List[object]]::new()
    $groupRows   = [System.Collections.Generic.List[object]]::new()
    $conflicts   = [System.Collections.Generic.List[object]]::new()
    $settingRows = [System.Collections.Generic.List[object]]::new()
    $appRows     = [System.Collections.Generic.List[object]]::new()
    $encryptRows = [System.Collections.Generic.List[object]]::new()
    $unresolved  = [System.Collections.Generic.List[object]]::new()

    # --- Resolve every requested device from one index -----------------------
    & $ReportProgress 4 'Listing managed devices'
    $index = Get-SightlineDeviceIndex

    $coverage.Add([pscustomobject]@{
        Source = 'deviceManagement/managedDevices'; Count = $index.Count
        Complete = $index.Complete; Failure = $index.Failure
    })

    if (-not $index.Complete) {
        $warnings.Add('The device list did not collect fully, so a device may be reported as not found when it exists.')
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($query in $queries) {
        $match = Resolve-SightlineDeviceQuery -Query $query -Index $index
        if ($match.Device) {
            $devices.Add($match.Device)
        } else {
            $unresolved.Add([pscustomobject]@{ Entry = $match.Query; Problem = $match.Problem })
            $warnings.Add("'$($match.Query)' $($match.Problem)")
        }
    }

    if ($devices.Count -eq 0) {
        Write-SightlineCsv -Path (Join-Path $folder 'not-found.csv') -Rows @($unresolved)
        return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
            -Warnings @($warnings) -Coverage @($coverage) `
            -Message 'None of the devices given could be resolved.'
    }

    # --- Shared reference data, fetched once for all devices -----------------
    & $ReportProgress 12 'Listing assignment filters'
    $filterResult = Get-SightlineFilterLookup
    $filters      = $filterResult.Lookup

    $surfaces = @(Get-SightlinePolicySurfaces -IncludeApps:$includeApps)
    $policies = [System.Collections.Generic.List[object]]::new()

    $surfaceNo = 0
    foreach ($surface in $surfaces) {
        $surfaceNo++
        & $ReportProgress (15 + [int](($surfaceNo / $surfaces.Count) * 35)) "Reading $($surface.Kind)"

        $listed = Get-SightlineGraphCollection -Uri $surface.Uri
        $coverage.Add([pscustomobject]@{
            Source = $surface.Label; Count = $listed.Count
            Complete = $listed.Complete; Failure = $listed.Failure
        })

        if (-not $listed.Complete) {
            $optional = ($surface.ContainsKey('Optional') -and $surface.Optional)
            if (-not $optional) {
                $warnings.Add("$($surface.Kind) did not collect fully. It may target these devices without appearing here.")
            }
            continue
        }

        foreach ($policy in $listed.Items) {
            try {
                $assignments = Get-SightlineGraphCollection -Uri "$($surface.Uri.Split('?')[0])/$($policy.id)/assignments"
            }
            catch { continue }

            if ($assignments.Count -eq 0) { continue }

            $policies.Add([pscustomobject]@{
                Name        = Get-SightlinePolicyName -Policy $policy -NameField $surface.NameField
                Kind        = $surface.Kind
                Id          = $policy.id
                Assignments = @($assignments.Items)
            })
        }
    }

    $encryption = $null
    if ($includeEncrypt) {
        & $ReportProgress 52 'Reading encryption states'
        $encryption = Get-SightlineEncryptionStates
        $coverage.Add([pscustomobject]@{
            Source = 'deviceManagement/managedDeviceEncryptionStates'; Count = $encryption.Count
            Complete = $encryption.Complete; Failure = $encryption.Failure
        })
    }

    # --- Per device ----------------------------------------------------------
    $deviceNo = 0
    foreach ($device in $devices) {
        $deviceNo++
        $base = 55 + [int](($deviceNo - 1) / $devices.Count * 40)
        & $ReportProgress $base "$($device.deviceName) ($deviceNo of $($devices.Count))"

        # Group membership hangs off the Entra device object, not the Intune one.
        $memberOf = @{}
        try {
            $dirDevice = Invoke-SightlineGraphRequest -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$($device.azureADDeviceId)')?`$select=id"
            $groups    = Get-SightlineGraphCollection -Uri "https://graph.microsoft.com/v1.0/devices/$($dirDevice.id)/transitiveMemberOf?`$select=id,displayName"
            foreach ($group in $groups.Items) {
                if ($group.PSObject.Properties.Name -contains 'displayName') { $memberOf[$group.id] = $group.displayName }
            }
            if (-not $groups.Complete) {
                $warnings.Add("$($device.deviceName): group membership is incomplete, so group-targeted policies may be missing.")
            }
        }
        catch {
            $warnings.Add("$($device.deviceName): could not read group membership - $($_.Exception.Message)")
        }

        foreach ($group in $memberOf.GetEnumerator()) {
            $groupRows.Add([pscustomobject]@{
                DeviceName = $device.deviceName
                GroupName  = $group.Value
                GroupId    = $group.Key
            })
        }

        # What targets this device
        $stateLookup   = @{}
        $deviceApplies = [System.Collections.Generic.List[object]]::new()

        foreach ($policy in $policies) {
            foreach ($assignment in $policy.Assignments) {
                $target = $assignment.target
                $names  = $target.PSObject.Properties.Name
                $type   = if ($names -contains '@odata.type') { $target.'@odata.type' } else { '' }

                $via = ''
                if ($type -like '*allDevicesAssignmentTarget*') { $via = 'All devices' }
                elseif (($type -like '*groupAssignmentTarget*' -or $type -like '*exclusionGroupAssignmentTarget*') -and
                        $names -contains 'groupId' -and $memberOf.ContainsKey($target.groupId)) {
                    $via = $memberOf[$target.groupId]
                }
                if (-not $via) { continue }

                $filterName = ''
                if ($names -contains 'deviceAndAppManagementAssignmentFilterId' -and
                    $target.deviceAndAppManagementAssignmentFilterId) {
                    $fid = $target.deviceAndAppManagementAssignmentFilterId
                    $filterName = if ($filters.ContainsKey($fid)) { $filters[$fid] } else { $fid }
                }

                $deviceApplies.Add([pscustomobject]@{
                    DeviceName    = $device.deviceName
                    PolicyName    = $policy.Name
                    PolicyKind    = $policy.Kind
                    PolicyId      = $policy.Id
                    Intent        = if ($type -like '*exclusion*') { 'Exclude' } else { 'Include' }
                    AppliesVia    = $via
                    FilterName    = $filterName
                    ReportedState = ''
                    Note          = if ($filterName) { 'A filter may still prevent this from applying.' } else { '' }
                })
            }
        }

        # Intune's own conflict verdict
        if ($includeConflicts) {
            & $ReportProgress ($base + 2) "$($device.deviceName): reported state"
            $deviceStates = Get-SightlineDeviceStates -ManagedDeviceId $device.id

            foreach ($reported in $deviceStates.States) {
                if ($reported.DisplayName) { $stateLookup[$reported.DisplayName] = $reported.State }
            }

            $flagged = @($deviceStates.States | Where-Object { $_.State -in @('conflict', 'error') })
            foreach ($reported in $flagged) {
                $conflicts.Add([pscustomobject]@{
                    DeviceName = $device.deviceName
                    PolicyName = $reported.DisplayName
                    Kind       = $reported.Kind
                    State      = $reported.State
                })

                $detail = Get-SightlineConflictedSettings -ManagedDeviceId $device.id `
                    -PolicyStateId $reported.PolicyId -Path $reported.Source

                foreach ($setting in $detail.Settings) {
                    $settingRows.Add([pscustomobject]@{
                        DeviceName           = $device.deviceName
                        PolicyName           = $reported.DisplayName
                        Setting              = $setting.Setting
                        State                = $setting.State
                        CurrentValue         = $setting.CurrentValue
                        ContributingPolicies = $setting.ContributingPolicies
                        ErrorCode            = $setting.ErrorCode
                    })
                }
            }

            if ($deviceStates.States.Count -eq 0) {
                $warnings.Add("$($device.deviceName) reported no policy state at all. Conflict verdicts only exist after a device checks in, so this is not the same as no conflicts.")
            }
        }

        foreach ($row in $deviceApplies) {
            if ($stateLookup.ContainsKey($row.PolicyName)) { $row.ReportedState = $stateLookup[$row.PolicyName] }
            $applies.Add($row)
        }

        # Installed apps
        if ($includeInstalled) {
            & $ReportProgress ($base + 3) "$($device.deviceName): installed apps"
            $detected = Get-SightlineDeviceApps -ManagedDeviceId $device.id
            foreach ($app in $detected.Apps) {
                $appRows.Add([pscustomobject]@{
                    DeviceName = $device.deviceName
                    AppName    = $app.displayName
                    Version    = if ($app.PSObject.Properties.Name -contains 'version') { $app.version } else { '' }
                    Publisher  = if ($app.PSObject.Properties.Name -contains 'publisher') { $app.publisher } else { '' }
                })
            }
            if (-not $detected.Complete -and $detected.Failure) {
                $warnings.Add("$($device.deviceName): installed apps could not be read - $($detected.Failure)")
            }
        }

        # Encryption
        if ($includeEncrypt -and $encryption -and $encryption.ById.ContainsKey([string]$device.id)) {
            $encState = $encryption.ById[[string]$device.id]
            $names    = $encState.PSObject.Properties.Name
            $encryptRows.Add([pscustomobject]@{
                DeviceName          = $device.deviceName
                EncryptionState     = if ($names -contains 'encryptionState') { $encState.encryptionState } else { '' }
                EncryptionReadiness = if ($names -contains 'encryptionReadinessState') { $encState.encryptionReadinessState } else { '' }
                PolicyDetails       = if ($names -contains 'policyDetails') { (@($encState.policyDetails | ForEach-Object { $_.policyName }) -join '; ') } else { '' }
            })
        }

        $deviceConflicts = @($conflicts | Where-Object { $_.DeviceName -eq $device.deviceName })

        $summary.Add([pscustomobject]@{
            DeviceName    = $device.deviceName
            SerialNumber  = if ($device.PSObject.Properties.Name -contains 'serialNumber') { $device.serialNumber } else { '' }
            IntuneId      = $device.id
            EntraDeviceId = $device.azureADDeviceId
            OS            = "$($device.operatingSystem) $($device.osVersion)"
            Model         = if ($device.PSObject.Properties.Name -contains 'model') { $device.model } else { '' }
            Manufacturer  = if ($device.PSObject.Properties.Name -contains 'manufacturer') { $device.manufacturer } else { '' }
            Owner         = $device.managedDeviceOwnerType
            JoinType      = if ($device.PSObject.Properties.Name -contains 'joinType') { $device.joinType } else { '' }
            PrimaryUser   = $device.userPrincipalName
            UserName      = if ($device.PSObject.Properties.Name -contains 'userDisplayName') { $device.userDisplayName } else { '' }
            Compliance    = $device.complianceState
            Encrypted     = if ($device.PSObject.Properties.Name -contains 'isEncrypted') { $device.isEncrypted } else { '' }
            Enrolled      = if ($device.PSObject.Properties.Name -contains 'enrolledDateTime') { $device.enrolledDateTime } else { '' }
            LastSync      = $device.lastSyncDateTime
            GroupCount    = $memberOf.Count
            PolicyCount   = $deviceApplies.Count
            ConflictCount = $deviceConflicts.Count
        })
    }

    # --- What the devices disagree about --------------------------------------
    $differences = [System.Collections.Generic.List[object]]::new()

    if ($devices.Count -gt 1) {
        & $ReportProgress 94 'Comparing devices'
        $allNames = @($devices | ForEach-Object { $_.deviceName })

        # A policy that reaches some of these devices but not others is almost
        # always the answer to "why does this one behave differently".
        foreach ($group in ($applies | Where-Object { $_.Intent -eq 'Include' } | Group-Object PolicyName)) {
            $has = @($group.Group | Select-Object -ExpandProperty DeviceName -Unique)
            $missing = @($allNames | Where-Object { $_ -notin $has })
            if ($missing.Count -eq 0) { continue }

            $differences.Add([pscustomobject]@{
                Difference = 'Policy reaches some devices only'
                Item       = $group.Name
                Kind       = ($group.Group | Select-Object -First 1).PolicyKind
                Applies    = ($has -join '; ')
                DoesNot    = ($missing -join '; ')
                Detail     = 'Reaches via: ' + ((@($group.Group | Select-Object -ExpandProperty AppliesVia -Unique)) -join '; ')
            })
        }

        foreach ($group in ($conflicts | Group-Object PolicyName)) {
            $affected = @($group.Group | Select-Object -ExpandProperty DeviceName -Unique)
            $clear    = @($allNames | Where-Object { $_ -notin $affected })
            if ($clear.Count -eq 0) { continue }

            $differences.Add([pscustomobject]@{
                Difference = 'Conflict on some devices only'
                Item       = $group.Name
                Kind       = ($group.Group | Select-Object -First 1).Kind
                Applies    = ($affected -join '; ')
                DoesNot    = ($clear -join '; ')
                Detail     = 'Reported state differs between these devices.'
            })
        }

        foreach ($field in @('Compliance', 'OS', 'Owner', 'JoinType')) {
            $values = @($summary | Select-Object -ExpandProperty $field -Unique)
            if ($values.Count -le 1) { continue }
            $differences.Add([pscustomobject]@{
                Difference = "Devices differ on $field"
                Item       = $field
                Kind       = 'Device property'
                Applies    = ''
                DoesNot    = ''
                Detail     = ($summary | ForEach-Object { "$($_.DeviceName)=$($_.$field)" }) -join '; '
            })
        }
    }

    # --- Output ---------------------------------------------------------------
    & $ReportProgress 96 'Writing report'

    $sheets = @()

    if ($conflicts.Count -gt 0)   { $sheets += @{ Name = 'Conflicts';   Rows = @($conflicts) } }
    if ($differences.Count -gt 0) { $sheets += @{ Name = 'Differences'; Rows = @($differences) } }
    if ($unresolved.Count -gt 0)  { $sheets += @{ Name = 'Not found';   Rows = @($unresolved) } }

    $sheets += @{ Name = 'Devices'; Rows = @($summary) }
    $sheets += @{ Name = 'Applies'; Rows = @($applies) }
    $sheets += @{ Name = 'Groups';  Rows = @($groupRows) }

    if ($settingRows.Count -gt 0) { $sheets += @{ Name = 'Conflicting settings'; Rows = @($settingRows) } }
    if ($encryptRows.Count -gt 0) { $sheets += @{ Name = 'Encryption';           Rows = @($encryptRows) } }

    # Installed apps last and always: it dwarfs every other sheet and is
    # rarely why the report was run.
    if ($appRows.Count -gt 0) {
        $sheets += @{ Name = 'Installed apps'; Rows = @($appRows) }
        if ($appRows.Count -gt 2000) {
            $warnings.Add("Installed apps is $($appRows.Count) rows and sits at the end of the workbook. Turn it off if you are not using it.")
        }
    }

    $excludes = @($applies | Where-Object { $_.Intent -eq 'Exclude' })
    if ($excludes.Count -gt 0) {
        $warnings.Add("$($excludes.Count) exclusion(s) match these devices. An exclusion overrides an inclusion.")
    }

    $filtered = @($applies | Where-Object { $_.FilterName })
    if ($filtered.Count -gt 0) {
        $warnings.Add("$($filtered.Count) assignment(s) carry a filter. Filters are evaluated on the device and are not resolved here.")
    }

    if ($includeInstalled) {
        $warnings.Add('Installed apps come from Intune app discovery, which on Windows covers MSI and Store apps only. It is not a complete software inventory.')
    }

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    $baseName = if ($devices.Count -eq 1) {
        "device-$(($devices[0].deviceName -replace '[^A-Za-z0-9\-]', '-'))"
    } else {
        "device-360-$($devices.Count)-devices"
    }

    Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName $baseName -Sheets $sheets | Out-Null

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($unresolved.Count -gt 0 -or $incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $message = "$($devices.Count) device(s), $($applies.Count) targeting item(s)."
    if ($conflicts.Count -gt 0)   { $message += " $($conflicts.Count) conflict(s) reported." }
    if ($differences.Count -gt 0) { $message += " $($differences.Count) difference(s) between them." }
    if ($unresolved.Count -gt 0) { $message += " $($unresolved.Count) entry(ies) could not be resolved." }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $applies.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}
