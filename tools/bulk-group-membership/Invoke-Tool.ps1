Set-StrictMode -Version Latest

$ToolId      = 'bulk-group-membership'
$ToolVersion = '1.0.0'

# Resolves a list of device names or serial numbers to the Entra Object IDs
# needed for Entra's own "Bulk operations > Import members" feature on a
# group's Members page. That feature wants a specific column header and a
# device's directory Object ID - a different GUID from Intune's own managed
# device ID and from the device's separate deviceId property. Confirmed
# against a real template exported from Entra, not assumed.
#
# Resolution follows the same name-then-serial order every other tool in
# this app already uses for a single device, just batched: name first for
# every row, serial as a second pass for whatever didn't match, then a third
# pass resolving each match's azureADDeviceId to its Entra device object -
# the same chain the journey tools' own device-origin lookup already uses
# for their identity strip, narrowed to the one field this needs.

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )

    $uploadedPath = [string]$Parameters.deviceList
    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not $uploadedPath -or -not (Test-Path $uploadedPath)) {
            return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
                -Message 'No device list was uploaded, or the uploaded file could not be found.'
        }

        # --- Read the input --------------------------------------------------------
        & $ReportProgress 5 'Reading the device list'

        $rows = @(Import-Csv -LiteralPath $uploadedPath)
        if ($rows.Count -eq 0) {
            return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
                -Message 'The uploaded file has no data rows. Expected one device name or serial number per row, one column.'
        }

        $firstColumn = $rows[0].PSObject.Properties.Name | Select-Object -First 1
        $inputs = @($rows | ForEach-Object { [string]$_.$firstColumn } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })

        if ($inputs.Count -eq 0) {
            return New-SightlineToolResult -Status 'Failed' -OutputPath $folder `
                -Message 'Every row in the uploaded file was blank.'
        }

        # --- Pass A: batch-resolve by device name -----------------------------------
        # Requests are correlated by index, not by the device name/serial itself -
        # a duplicate row in the input (the same serial pasted twice, say) would
        # otherwise collide as a batch id and one of the two silently vanish.
        & $ReportProgress 15 "Resolving $($inputs.Count) device(s) by name"

        $select = 'id,deviceName,serialNumber,azureADDeviceId'
        $byNameRequests = @(for ($i = 0; $i -lt $inputs.Count; $i++) {
            $escaped = $inputs[$i].Replace("'", "''")
            @{ Id = "r$i"; Url = "/deviceManagement/managedDevices?`$filter=deviceName eq '$escaped'&`$select=$select" }
        })
        $byNameBatch = Invoke-SightlineGraphBatch -Requests $byNameRequests -Version 'beta'
        $coverage.Add([pscustomobject]@{
            Source = 'managedDevices (batched, by name)'; Count = $inputs.Count
            Complete = $byNameBatch.Complete; Failure = $byNameBatch.Failure
        })

        $resolved    = @{}   # row index -> managedDevice object
        $ambiguous   = [System.Collections.Generic.List[int]]::new()
        $stillNeeded = [System.Collections.Generic.List[int]]::new()

        for ($i = 0; $i -lt $inputs.Count; $i++) {
            $response = $byNameBatch.Responses["r$i"]
            $hits = @()
            if ($response -and -not $response.Failure -and $response.Body -and ($response.Body.PSObject.Properties.Name -contains 'value')) {
                $hits = @($response.Body.value)
            }
            if ($hits.Count -eq 1) { $resolved[$i] = $hits[0] }
            elseif ($hits.Count -gt 1) { $ambiguous.Add($i) }
            else { $stillNeeded.Add($i) }
        }

        # --- Pass B: batch-resolve whatever didn't match a name, by serial ----------
        if ($stillNeeded.Count -gt 0) {
            & $ReportProgress 35 "Resolving $($stillNeeded.Count) device(s) by serial number"

            $bySerialRequests = @($stillNeeded | ForEach-Object {
                $escaped = $inputs[$_].Replace("'", "''")
                @{ Id = "r$_"; Url = "/deviceManagement/managedDevices?`$filter=serialNumber eq '$escaped'&`$select=$select" }
            })
            $bySerialBatch = Invoke-SightlineGraphBatch -Requests $bySerialRequests -Version 'beta'
            $coverage.Add([pscustomobject]@{
                Source = 'managedDevices (batched, by serial)'; Count = $stillNeeded.Count
                Complete = $bySerialBatch.Complete; Failure = $bySerialBatch.Failure
            })

            foreach ($i in $stillNeeded) {
                $response = $bySerialBatch.Responses["r$i"]
                $hits = @()
                if ($response -and -not $response.Failure -and $response.Body -and ($response.Body.PSObject.Properties.Name -contains 'value')) {
                    $hits = @($response.Body.value)
                }
                if ($hits.Count -eq 1) { $resolved[$i] = $hits[0] }
                elseif ($hits.Count -gt 1) { $ambiguous.Add($i) }
            }
        }

        # --- Pass C: batch-resolve each match's Entra directory Object ID -----------
        $withAzureId = @($resolved.Keys | Where-Object {
            $d = $resolved[$_]
            $d.PSObject.Properties.Name -contains 'azureADDeviceId' -and $d.azureADDeviceId
        })

        $objectIdOf = @{}
        if ($withAzureId.Count -gt 0) {
            & $ReportProgress 55 "Resolving $($withAzureId.Count) device(s) to an Entra Object ID"

            $entraRequests = @($withAzureId | ForEach-Object {
                $azureId = [string]$resolved[$_].azureADDeviceId
                @{ Id = "r$_"; Url = "/devices(deviceId='$azureId')?`$select=id" }
            })
            $entraBatch = Invoke-SightlineGraphBatch -Requests $entraRequests -Version 'v1.0'
            $coverage.Add([pscustomobject]@{
                Source = 'devices (batched, Entra Object ID)'; Count = $withAzureId.Count
                Complete = $entraBatch.Complete; Failure = $entraBatch.Failure
            })

            foreach ($i in $withAzureId) {
                $response = $entraBatch.Responses["r$i"]
                if ($response -and -not $response.Failure -and $response.Body -and ($response.Body.PSObject.Properties.Name -contains 'id')) {
                    $objectIdOf[$i] = [string]$response.Body.id
                }
            }
        }

        # --- Build the two output sets ------------------------------------------------
        & $ReportProgress 85 'Writing output'

        $readyRows  = [System.Collections.Generic.List[object]]::new()
        $unresolved = [System.Collections.Generic.List[object]]::new()

        for ($i = 0; $i -lt $inputs.Count; $i++) {
            $value = $inputs[$i]
            if ($objectIdOf.ContainsKey($i)) {
                $readyRows.Add([pscustomobject]@{ Input = $value; ObjectId = $objectIdOf[$i]; DeviceName = $resolved[$i].deviceName })
            }
            elseif ($ambiguous -contains $i) {
                $unresolved.Add([pscustomobject]@{ Input = $value; Reason = 'Matched more than one device. A more specific identifier is needed.' })
            }
            elseif ($resolved.ContainsKey($i)) {
                $unresolved.Add([pscustomobject]@{ Input = $value; Reason = 'Device found, but has no linked Entra device object to resolve an Object ID from.' })
            }
            else {
                $unresolved.Add([pscustomobject]@{ Input = $value; Reason = 'No enrolled device matched this name or serial number, by either.' })
            }
        }

        # The Entra-ready file: exact format of Entra's own downloaded template -
        # UTF-8 with a BOM, CRLF line endings, the header preserved byte-for-byte,
        # since Entra's own guidance is to keep it "exactly as downloaded" and a
        # generic CSV writer gives no guarantee of matching either convention.
        $entraHeader = 'Member object ID or user principal name [memberObjectIdOrUpn] Required'
        $entraLines = [System.Text.StringBuilder]::new()
        [void]$entraLines.Append($entraHeader).Append("`r`n")
        foreach ($row in $readyRows) { [void]$entraLines.Append($row.ObjectId).Append("`r`n") }

        $readyPath = Join-Path $folder 'ready-to-upload.csv'
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        [System.IO.File]::WriteAllText($readyPath, $entraLines.ToString(), $utf8Bom)

        # The audit-friendly report: what matched, what didn't, and why - normal
        # workbook output, following the project's usual provenance convention.
        $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
            -Coverage @($coverage) -Warnings @($warnings)

        Save-SightlineDataset -Folder $folder -Provenance $provenance -Format 'Workbook' `
            -BaseName 'bulk-group-membership-report' -Sheets @(
                @{ Name = 'Ready to upload'; Rows = @($readyRows) }
                @{ Name = 'Unresolved'; Rows = @($unresolved) }
            )

        $message = "$($readyRows.Count) of $($inputs.Count) device(s) resolved to an Entra Object ID."
        if ($unresolved.Count -gt 0) { $message += " $($unresolved.Count) could not be resolved - see the report." }

        $status = if ($readyRows.Count -eq 0) { 'Failed' } elseif ($unresolved.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

        return New-SightlineToolResult -Status $status -OutputPath $folder `
            -RowCount $readyRows.Count -Warnings @($warnings) -Coverage @($coverage) -Message $message
    }
    finally {
        # Working data, not a report - and it may carry device or user
        # information, so it does not linger on disk once the run is over,
        # success or failure.
        if ($uploadedPath -and (Test-Path $uploadedPath)) {
            Remove-Item -LiteralPath $uploadedPath -Force -ErrorAction SilentlyContinue
        }
    }
}
