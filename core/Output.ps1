Set-StrictMode -Version Latest

function New-SightlineProvenance {
    <#
        Every export carries this. It travels with the file into the change
        ticket or audit folder, where someone reads it three weeks later and
        needs to know what the data covers and who could see it.
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolId,
        [Parameter(Mandatory)] [string] $ToolVersion,
        [object[]] $Coverage = @(),
        [string[]] $Warnings = @()
    )

    $auth = Get-SightlineAuthState

    [pscustomobject]@{
        Tool          = $ToolId
        ToolVersion   = $ToolVersion
        GeneratedAt   = (Get-Date).ToString('u')
        Tenant        = $auth.TenantName
        TenantId      = $auth.TenantId
        CollectedBy   = $auth.Account
        ScopesGranted = ($auth.Scopes -join '; ')
        Platform      = Get-SightlinePlatform
        Coverage      = $Coverage
        Warnings      = $Warnings
    }
}

function Write-SightlineProvenanceFile {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] $Provenance
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('IntuneSightline export')
    $lines.Add('')
    $lines.Add("Tool            : $($Provenance.Tool) v$($Provenance.ToolVersion)")
    $lines.Add("Generated       : $($Provenance.GeneratedAt)")
    $lines.Add("Tenant          : $($Provenance.Tenant) [$($Provenance.TenantId)]")
    $lines.Add("Collected by    : $($Provenance.CollectedBy)")
    $lines.Add("Scopes granted  : $($Provenance.ScopesGranted)")
    $lines.Add("Host platform   : $($Provenance.Platform)")
    $lines.Add('')
    $lines.Add('Coverage')

    if (@($Provenance.Coverage).Count -eq 0) {
        $lines.Add('  (none recorded)')
    } else {
        foreach ($entry in $Provenance.Coverage) {
            $state = if ($entry.Complete) { 'complete' } else { 'INCOMPLETE' }
            $line  = "  {0,-34} {1,6} item(s)  {2}" -f $entry.Source, $entry.Count, $state
            $lines.Add($line)
            if (-not $entry.Complete -and $entry.Failure) {
                $lines.Add("      reason: $($entry.Failure)")
            }
        }
    }

    $lines.Add('')
    $lines.Add('Warnings')
    if (@($Provenance.Warnings).Count -eq 0) {
        $lines.Add('  (none)')
    } else {
        foreach ($w in $Provenance.Warnings) { $lines.Add("  - $w") }
    }

    $lines.Add('')
    $lines.Add('An export with any INCOMPLETE source is not a full picture of the tenant.')
    $lines.Add('Results absent from this export may exist but were not collected.')

    Write-SightlineTextFile -Path (Join-Path $Folder '_provenance.txt') -Content ($lines -join "`n")
}

function Write-SightlineCsv {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows
    )

    if ($Rows.Count -eq 0) {
        Write-SightlineTextFile -Path $Path -Content ''
        return
    }

    $csv = $Rows | ConvertTo-Csv -NoTypeInformation
    Write-SightlineTextFile -Path $Path -Content ($csv -join "`n")
}

function New-SightlineToolResult {
    param(
        [ValidateSet('Success', 'PartialSuccess', 'Failed')]
        [string] $Status = 'Success',

        [string]   $OutputPath,
        [int]      $RowCount = 0,
        [string[]] $Warnings = @(),
        [object[]] $Coverage = @(),
        [string]   $Message
    )

    [pscustomobject]@{
        Status     = $Status
        OutputPath = $OutputPath
        RowCount   = $RowCount
        Warnings   = @($Warnings)
        Coverage   = @($Coverage)
        Message    = $Message
    }
}
