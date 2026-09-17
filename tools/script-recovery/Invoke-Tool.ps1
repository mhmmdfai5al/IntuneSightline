Set-StrictMode -Version Latest

$ToolId      = 'script-recovery'
$ToolVersion = '1.0.0'

function Get-SafeName {
    param([string] $Name, [string] $Fallback = 'unnamed')

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Fallback }
    $clean = $Name -replace '[\\/:*?"<>|]', '-'
    $clean = $clean.Trim().TrimEnd('.')
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80) }
    if ([string]::IsNullOrWhiteSpace($clean)) { return $Fallback }
    return $clean
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]    $Parameters,
        [Parameter(Mandatory)] [scriptblock]  $ReportProgress
    )

    $format = if ($Parameters.ContainsKey('outputFormat') -and $Parameters.outputFormat -like 'Separate*') { 'CSV' } else { 'Workbook' }
    $types    = @($Parameters.scriptTypes)
    $maxApps  = [int]$Parameters.maxWin32Apps
    $folder   = New-SightlineRunFolder -ToolId $ToolId
    $rows     = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $base = 'https://graph.microsoft.com/beta'

    # Each entry: the collection endpoint, the folder to write into, and the
    # properties on the per-item response that hold base64 script bodies.
    $sources = @(
        @{
            Type     = 'Remediation'
            Label    = 'deviceManagement/deviceHealthScripts'
            Uri      = "$base/deviceManagement/deviceHealthScripts"
            Folder   = 'remediations'
            Bodies   = @{ 'detectionScriptContent' = 'detect.ps1'; 'remediationScriptContent' = 'remediate.ps1' }
            PerItem  = $true
        },
        @{
            Type     = 'PlatformScript'
            Label    = 'deviceManagement/deviceManagementScripts'
            Uri      = "$base/deviceManagement/deviceManagementScripts"
            Folder   = 'platform-scripts'
            Bodies   = @{ 'scriptContent' = 'script.ps1' }
            PerItem  = $true
        },
        @{
            Type     = 'MacOsShell'
            Label    = 'deviceManagement/deviceShellScripts'
            Uri      = "$base/deviceManagement/deviceShellScripts"
            Folder   = 'macos-shell'
            Bodies   = @{ 'scriptContent' = 'script.sh' }
            PerItem  = $true
        },
        @{
            Type     = 'MacOsCustomAttribute'
            Label    = 'deviceManagement/deviceCustomAttributeShellScripts'
            Uri      = "$base/deviceManagement/deviceCustomAttributeShellScripts"
            Folder   = 'macos-custom-attributes'
            Bodies   = @{ 'scriptContent' = 'script.sh' }
            PerItem  = $true
        }
    )

    $selected = @($sources | Where-Object { $types -contains $_.Type })
    $wantWin32 = ($types -contains 'Win32Detection') -or ($types -contains 'Win32Requirement')

    $totalSteps = $selected.Count + $(if ($wantWin32) { 1 } else { 0 })
    if ($totalSteps -eq 0) {
        return New-SightlineToolResult -Status 'Failed' -Message 'No script types selected.'
    }

    $stepIndex = 0

    foreach ($source in $selected) {
        $stepIndex++
        $percent = [int](($stepIndex - 1) / $totalSteps * 100)
        & $ReportProgress $percent "Listing $($source.Type)"

        $listed = Get-SightlineGraphCollection -Uri $source.Uri
        $written = 0

        if ($listed.Complete -and $listed.Count -gt 0) {
            $index = 0
            foreach ($item in $listed.Items) {
                $index++
                & $ReportProgress $percent "$($source.Type) $index of $($listed.Count)"

                # Bodies are absent from list responses; each item needs its own call.
                try {
                    $full = Invoke-SightlineGraphRequest -Uri "$($source.Uri)/$($item.id)"
                } catch {
                    $warnings.Add("Could not read $($source.Type) '$($item.displayName)': $($_.Exception.Message)")
                    continue
                }

                $safe    = Get-SafeName -Name $full.displayName -Fallback $full.id
                $target  = Join-Path $folder (Join-Path $source.Folder $safe)
                $hasBody = $false

                foreach ($property in $source.Bodies.Keys) {
                    if ($full.PSObject.Properties.Name -notcontains $property) { continue }
                    $decoded = ConvertFrom-SightlineBase64Script -Base64 $full.$property
                    if (-not $decoded) { continue }

                    if (-not (Test-Path -LiteralPath $target)) {
                        New-Item -ItemType Directory -Path $target -Force | Out-Null
                    }

                    $fileName = $source.Bodies[$property]
                    Write-SightlineTextFile -Path (Join-Path $target $fileName) -Content $decoded
                    $hasBody = $true

                    $rows.Add([pscustomobject]@{
                        ScriptType   = $source.Type
                        DisplayName  = $full.displayName
                        Id           = $full.id
                        Publisher    = if ($full.PSObject.Properties.Name -contains 'publisher') { $full.publisher } else { '' }
                        RunAsAccount = if ($full.PSObject.Properties.Name -contains 'runAsAccount') { $full.runAsAccount } else { '' }
                        FileName     = $fileName
                        RelativePath = Join-Path $source.Folder (Join-Path $safe $fileName)
                        Characters   = $decoded.Length
                        LastModified = if ($full.PSObject.Properties.Name -contains 'lastModifiedDateTime') { $full.lastModifiedDateTime } else { '' }
                    })
                    $written++
                }

                if (-not $hasBody) {
                    $warnings.Add("$($source.Type) '$($full.displayName)' returned no script body.")
                }
            }
        }

        $coverage.Add([pscustomobject]@{
            Source   = $source.Label
            Count    = $listed.Count
            Complete = $listed.Complete
            Failure  = $listed.Failure
        })

        if (-not $listed.Complete) {
            $warnings.Add("$($source.Type) collection did not finish. Files written for this type are incomplete.")
        }
    }

    if ($wantWin32) {
        $stepIndex++
        $percent = [int](($stepIndex - 1) / $totalSteps * 100)
        & $ReportProgress $percent 'Listing Win32 apps'

        $appsUri = "$base/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
        $apps    = Get-SightlineGraphCollection -Uri $appsUri

        $inspected = 0
        foreach ($app in $apps.Items) {
            if ($inspected -ge $maxApps) {
                $warnings.Add("Stopped after inspecting $maxApps Win32 apps. Raise the limit to cover the rest.")
                break
            }
            $inspected++
            & $ReportProgress $percent "Win32 app $inspected of $([math]::Min($apps.Count, $maxApps))"

            try {
                $full = Invoke-SightlineGraphRequest -Uri "$base/deviceAppManagement/mobileApps/$($app.id)"
            } catch {
                $warnings.Add("Could not read Win32 app '$($app.displayName)': $($_.Exception.Message)")
                continue
            }

            if ($full.PSObject.Properties.Name -notcontains 'rules') { continue }

            $safe   = Get-SafeName -Name $full.displayName -Fallback $full.id
            $target = Join-Path $folder (Join-Path 'win32-apps' $safe)
            $ruleNo = 0

            foreach ($rule in @($full.rules)) {
                $ruleNames = $rule.PSObject.Properties.Name
                if ($ruleNames -notcontains 'scriptContent') { continue }

                $isDetection = $rule.'@odata.type' -like '*ScriptRule*' -or
                               ($ruleNames -contains 'ruleType' -and $rule.ruleType -eq 'detection')
                $kind = if ($isDetection) { 'Win32Detection' } else { 'Win32Requirement' }
                if ($types -notcontains $kind) { continue }

                $decoded = ConvertFrom-SightlineBase64Script -Base64 $rule.scriptContent
                if (-not $decoded) { continue }

                $ruleNo++
                if (-not (Test-Path -LiteralPath $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }

                $fileName = if ($isDetection) { 'detection.ps1' } else { "requirement-$ruleNo.ps1" }
                Write-SightlineTextFile -Path (Join-Path $target $fileName) -Content $decoded

                $rows.Add([pscustomobject]@{
                    ScriptType   = $kind
                    DisplayName  = $full.displayName
                    Id           = $full.id
                    Publisher    = if ($full.PSObject.Properties.Name -contains 'publisher') { $full.publisher } else { '' }
                    RunAsAccount = ''
                    FileName     = $fileName
                    RelativePath = Join-Path 'win32-apps' (Join-Path $safe $fileName)
                    Characters   = $decoded.Length
                    LastModified = if ($full.PSObject.Properties.Name -contains 'lastModifiedDateTime') { $full.lastModifiedDateTime } else { '' }
                })
            }
        }

        $coverage.Add([pscustomobject]@{
            Source   = 'deviceAppManagement/mobileApps (win32)'
            Count    = $apps.Count
            Complete = $apps.Complete -and ($apps.Count -le $maxApps)
            Failure  = if ($apps.Count -gt $maxApps) { "Inspected $maxApps of $($apps.Count)." } else { $apps.Failure }
        })
    }

    & $ReportProgress 95 'Writing index'

    $provenance = New-SightlineProvenance -ToolId $ToolId -ToolVersion $ToolVersion `
        -Coverage @($coverage) -Warnings @($warnings)

    Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
        -BaseName 'recovered-scripts' -Sheets @(
            @{ Name = 'Scripts'; Rows = @($rows) }
        ) | Out-Null

    $incomplete = @($coverage | Where-Object { -not $_.Complete })
    $status = if ($incomplete.Count -gt 0) { 'PartialSuccess' } else { 'Success' }

    $message = "Recovered $($rows.Count) script file(s)."
    if ($incomplete.Count -gt 0) {
        $message += " $($incomplete.Count) source(s) did not collect fully — this export is not a complete picture."
    }

    return New-SightlineToolResult -Status $status `
        -OutputPath $folder `
        -RowCount   $rows.Count `
        -Warnings   @($warnings) `
        -Coverage   @($coverage) `
        -Message    $message
}
