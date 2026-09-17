Set-StrictMode -Version Latest

$ToolId      = 'assignment-inventory'
$ToolVersion = '1.0.0'

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }
    $includeApps = [bool]$Parameters.includeApps
    $resolveNames = [bool]$Parameters.resolveGroupNames

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $rows     = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $groups  = @{}
    $filters = @{}

    if ($resolveNames) {
        & $ReportProgress 3 'Listing groups'
        $groupResult = Get-SightlineGroupLookup
        $groups = $groupResult.Lookup
        $coverage.Add([pscustomobject]@{
            Source = 'groups'; Count = $groupResult.Count
            Complete = $groupResult.Complete; Failure = $groupResult.Failure
        })
        if (-not $groupResult.Complete) {
            $warnings.Add('Group listing did not finish. Some targets will show as unresolved.')
        }
    } else {
        $warnings.Add('Group name resolution was turned off. Targets show IDs only.')
    }

    & $ReportProgress 8 'Listing assignment filters'
    $filterResult = Get-SightlineFilterLookup
    $filters = $filterResult.Lookup
    $coverage.Add([pscustomobject]@{
        Source = 'deviceManagement/assignmentFilters'; Count = $filterResult.Count
        Complete = $filterResult.Complete; Failure = $filterResult.Failure
    })

    $surfaces  = @(Get-SightlinePolicySurfaces -IncludeApps:$includeApps)
    $index     = 0
    $unassigned = [System.Collections.Generic.List[object]]::new()

    foreach ($surface in $surfaces) {
        $index++
        $percent = 10 + [int](($index - 1) / $surfaces.Count * 85)
        & $ReportProgress $percent "Reading $($surface.Kind)"

        $listed = Get-SightlineGraphCollection -Uri $surface.Uri

        $coverage.Add([pscustomobject]@{
            Source   = $surface.Label
            Count    = $listed.Count
            Complete = $listed.Complete
            Failure  = $listed.Failure
        })

        if (-not $listed.Complete) {
            $optional = ($surface.ContainsKey('Optional') -and $surface.Optional)
            if (-not $optional) {
                $warnings.Add("$($surface.Kind) did not collect fully. Assignments from it are missing.")
            }
            continue
        }

        # Assignments are a navigation property, absent from the list response.
        # Fetched for the whole surface in batches rather than one call per
        # policy - the same requests, a twentieth of the round trips.
        $assignmentsBySurface = Get-SightlinePolicyAssignments -Surface $surface -Policies @($listed.Items) -OnProgress {
            param($done, $all) & $ReportProgress $percent "$($surface.Kind) assignments $done of $all"
        }

        if (-not $assignmentsBySurface.Complete) {
            $warnings.Add("Some $($surface.Kind) assignments could not be read. Policies affected are reported as unassigned when they may not be.")
        }

        foreach ($policy in $listed.Items) {
            $name = Get-SightlinePolicyName -Policy $policy -NameField $surface.NameField
            $policyId = [string]$policy.id

            if (-not $assignmentsBySurface.ByPolicy.ContainsKey($policyId)) {
                $warnings.Add("No assignment response came back for '$name'.")
                continue
            }

            $assignments = $assignmentsBySurface.ByPolicy[$policyId]

            if ($assignments.Failure) {
                $warnings.Add("Could not read assignments for '$name': $($assignments.Failure)")
                continue
            }

            if ($assignments.Count -eq 0) {
                $unassigned.Add([pscustomobject]@{
                    PolicyName = $name
                    PolicyKind = $surface.Kind
                    PolicyId   = $policy.id
                    Reason     = 'No assignments'
                })
                continue
            }

            foreach ($assignment in $assignments.Items) {
                $rows.Add((ConvertTo-SightlineAssignmentRow -Assignment $assignment `
                    -PolicyName $name -PolicyId $policy.id -PolicyKind $surface.Kind `
                    -Groups $groups -Filters $filters))
            }
        }
    }

    & $ReportProgress 96 'Writing inventory'

    $sheets = @(
        @{ Name = 'Assignments'; Rows = @($rows) }
    )

    if ($unassigned.Count -gt 0) {
        $sheets += @{ Name = 'Unassigned'; Rows = @($unassigned) }
        $warnings.Add("$($unassigned.Count) item(s) have no assignment at all.")
    }

    $broad = @($rows | Where-Object { $_.TargetType -in @('All devices', 'All users') -and $_.Intent -eq 'Include' })
    if ($broad.Count -gt 0) {
        $sheets += @{ Name = 'Tenant-wide'; Rows = $broad }
        $warnings.Add("$($broad.Count) assignment(s) target every device or every user.")
    }

    $byGroup = @($rows | Where-Object { $_.TargetType -eq 'Group' } |
        Group-Object TargetName | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{
                GroupName       = $_.Name
                AssignmentCount = $_.Count
                Kinds           = (($_.Group | Select-Object -ExpandProperty PolicyKind -Unique) -join ', ')
            }
        })
    if ($byGroup.Count -gt 0) {
        $sheets += @{ Name = 'By group'; Rows = $byGroup }
    }

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName 'assignment-inventory' -Sheets $sheets | Out-Null

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $message = "$($rows.Count) assignment(s) across $($surfaces.Count) policy surface(s)."
    if ($incomplete.Count -gt 0) {
        $message += " $($incomplete.Count) source(s) incomplete - this is not the full picture."
    }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $rows.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}
