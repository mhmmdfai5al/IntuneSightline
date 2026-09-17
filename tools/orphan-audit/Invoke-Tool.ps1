Set-StrictMode -Version Latest

$ToolId      = 'orphan-audit'
$ToolVersion = '1.0.0'

function Get-SightlineGroupMemberCount {
    param([Parameter(Mandatory)] [string] $GroupId)

    try {
        $headers = @{
            Authorization    = "Bearer $(Get-SightlineAccessToken)"
            ConsistencyLevel = 'eventual'
        }
        return [int](Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$count" -Headers $headers)
    }
    catch {
        return -1
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }
    $checkEmpty   = [bool]$Parameters.checkEmptyGroups
    $includeApps  = [bool]$Parameters.includeApps

    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $findings = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    & $ReportProgress 3 'Listing groups'
    $groupResult = Get-SightlineGroupLookup
    $groups = $groupResult.Lookup
    $coverage.Add([pscustomobject]@{
        Source = 'groups'; Count = $groupResult.Count
        Complete = $groupResult.Complete; Failure = $groupResult.Failure
    })

    & $ReportProgress 6 'Listing assignment filters'
    $filterResult = Get-SightlineFilterLookup
    $usedFilters  = @{}
    $coverage.Add([pscustomobject]@{
        Source = 'deviceManagement/assignmentFilters'; Count = $filterResult.Count
        Complete = $filterResult.Complete; Failure = $filterResult.Failure
    })

    $surfaces      = @(Get-SightlinePolicySurfaces -IncludeApps:$includeApps)
    $targetedGroups = @{}
    $index = 0

    foreach ($surface in $surfaces) {
        $index++
        $percent = 10 + [int](($index - 1) / $surfaces.Count * 70)
        & $ReportProgress $percent "Checking $($surface.Kind)"

        $listed = Get-SightlineGraphCollection -Uri $surface.Uri
        $coverage.Add([pscustomobject]@{
            Source = $surface.Label; Count = $listed.Count
            Complete = $listed.Complete; Failure = $listed.Failure
        })

        if (-not $listed.Complete) {
            $optional = ($surface.ContainsKey('Optional') -and $surface.Optional)
            if (-not $optional) {
                $warnings.Add("$($surface.Kind) did not collect fully. Orphans in it were not checked.")
            }
            continue
        }

        foreach ($policy in $listed.Items) {
            $name = Get-SightlinePolicyName -Policy $policy -NameField $surface.NameField

            try {
                $assignments = Get-SightlineGraphCollection -Uri "$($surface.Uri.Split('?')[0])/$($policy.id)/assignments"
            }
            catch {
                $warnings.Add("Could not read assignments for '$name'.")
                continue
            }

            if ($assignments.Count -eq 0) {
                $findings.Add([pscustomobject]@{
                    Finding    = 'Unassigned'
                    ItemName   = $name
                    ItemKind   = $surface.Kind
                    ItemId     = $policy.id
                    Detail     = 'Nothing is assigned. This policy applies to no one.'
                })
                continue
            }

            foreach ($assignment in $assignments.Items) {
                $target = $assignment.target
                $names  = $target.PSObject.Properties.Name

                if ($names -contains 'groupId' -and $target.groupId) {
                    $targetedGroups[$target.groupId] = $name
                }

                if ($names -contains 'deviceAndAppManagementAssignmentFilterId' -and
                    $target.deviceAndAppManagementAssignmentFilterId) {
                    $usedFilters[$target.deviceAndAppManagementAssignmentFilterId] = $true
                }

                # A group that was deleted leaves the assignment behind, pointing nowhere.
                if ($names -contains 'groupId' -and $target.groupId -and
                    -not $groups.ContainsKey($target.groupId)) {
                    $findings.Add([pscustomobject]@{
                        Finding  = 'Missing group'
                        ItemName = $name
                        ItemKind = $surface.Kind
                        ItemId   = $policy.id
                        Detail   = "Assigned to group $($target.groupId), which was not found."
                    })
                }
            }
        }
    }

    if ($checkEmpty -and $targetedGroups.Count -gt 0) {
        $keys  = @($targetedGroups.Keys)
        $done  = 0
        foreach ($groupId in $keys) {
            $done++
            if ($done % 5 -eq 0) {
                & $ReportProgress 82 "Counting members $done of $($keys.Count)"
            }

            $count = Get-SightlineGroupMemberCount -GroupId $groupId
            if ($count -eq 0) {
                $findings.Add([pscustomobject]@{
                    Finding  = 'Empty group targeted'
                    ItemName = $targetedGroups[$groupId]
                    ItemKind = 'Assignment target'
                    ItemId   = $groupId
                    Detail   = "Group '$(if ($groups.ContainsKey($groupId)) { $groups[$groupId] } else { $groupId })' has no members."
                })
            }
            elseif ($count -lt 0) {
                $warnings.Add("Could not count members of group $groupId.")
            }
        }
    }

    & $ReportProgress 92 'Checking unused filters'
    foreach ($filterId in $filterResult.Lookup.Keys) {
        if (-not $usedFilters.ContainsKey($filterId)) {
            $findings.Add([pscustomobject]@{
                Finding  = 'Unused filter'
                ItemName = $filterResult.Lookup[$filterId]
                ItemKind = 'Assignment filter'
                ItemId   = $filterId
                Detail   = 'Defined but not used by any assignment.'
            })
        }
    }

    & $ReportProgress 96 'Writing findings'

    $sheets = @(
        @{ Name = 'All findings'; Rows = @($findings) }
    )

    # One sheet per finding type: an admin usually wants one category at a time.
    foreach ($group in ($findings | Group-Object Finding | Sort-Object Count -Descending)) {
        $sheets += @{ Name = $group.Name; Rows = @($group.Group) }
        $warnings.Add("$($group.Count) x $($group.Name)")
    }

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName 'orphan-audit' -Sheets $sheets | Out-Null

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $message = "$($findings.Count) finding(s)."
    if ($findings.Count -eq 0) { $message = 'No orphans found.' }
    if ($incomplete.Count -gt 0) {
        $message += " $($incomplete.Count) source(s) incomplete - absence of findings does not mean absence of orphans."
    }

    return New-SightlineToolResult -Status $status -OutputPath $folder `
        -RowCount $findings.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
}
