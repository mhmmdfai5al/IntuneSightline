Set-StrictMode -Version Latest

function Test-SightlinePrerequisites {
    <#
        Runs before sign-in. Returns one row per check so the caller can
        print them and decide whether to continue.

        Deliberately does not require the Microsoft.Graph SDK. Authentication
        here is plain device code flow against the token endpoint, so there is
        nothing to install. If the SDK happens to be present that is noted for
        information only and changes nothing.
    #>
    [CmdletBinding()]
    param(
        [string] $ToolsRoot
    )

    $checks = [System.Collections.Generic.List[object]]::new()

    $add = {
        param($Name, $State, $Detail)
        $checks.Add([pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail })
    }

    # PowerShell version
    $psv = $PSVersionTable.PSVersion
    & $add 'PowerShell 7 or later' `
        $(if ($psv.Major -ge 7) { 'Pass' } else { 'Fail' }) `
        "Found $psv"

    # Platform
    & $add 'Supported platform' 'Pass' (Get-SightlinePlatform)

    # Output folder is writable
    try {
        $root  = Get-SightlineOutputRoot
        $probe = Join-Path $root ".write-test-$([guid]::NewGuid().ToString('n').Substring(0,6))"
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force
        & $add 'Output folder writable' 'Pass' $root
    }
    catch {
        & $add 'Output folder writable' 'Fail' $_.Exception.Message
    }

    # Can reach the identity and Graph endpoints
    foreach ($endpoint in @(
        @{ Name = 'Reach login.microsoftonline.com'; Uri = 'https://login.microsoftonline.com/common/discovery/instance?api-version=1.1&authorization_endpoint=https://login.microsoftonline.com/common/oauth2/v2.0/authorize' },
        @{ Name = 'Reach graph.microsoft.com';       Uri = 'https://graph.microsoft.com/v1.0/$metadata#users' }
    )) {
        try {
            Invoke-WebRequest -Uri $endpoint.Uri -Method Head -TimeoutSec 10 -SkipHttpErrorCheck | Out-Null
            & $add $endpoint.Name 'Pass' 'Reachable'
        }
        catch {
            & $add $endpoint.Name 'Fail' 'Not reachable. Check network or proxy.'
        }
    }

    # Tools present
    if ($ToolsRoot) {
        $tools = @(Get-SightlineTools -ToolsRoot $ToolsRoot)
        & $add 'Tools discovered' `
            $(if ($tools.Count -gt 0) { 'Pass' } else { 'Warn' }) `
            "$($tools.Count) tool(s)"
    }

    # SDK presence is informational only
    & $add 'Authentication method' 'Info' 'Browser sign-in, device code fallback. No modules required.'
    & $add 'Access level' 'Info' 'Read only. Write permissions are discarded at sign-in.'

    return @($checks)
}

function Write-SightlinePreflight {
    param([Parameter(Mandatory)] [object[]] $Checks)

    Write-Host ''
    Write-Host 'Prerequisites' -ForegroundColor White

    foreach ($check in $Checks) {
        $colour = switch ($check.State) {
            'Pass' { 'Green' }
            'Warn' { 'Yellow' }
            'Fail' { 'Red' }
            default { 'DarkGray' }
        }
        $mark = switch ($check.State) {
            'Pass' { 'ok  ' }
            'Warn' { 'warn' }
            'Fail' { 'FAIL' }
            default { '--  ' }
        }
        Write-Host ("  {0}  {1,-38} {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $colour
    }
    Write-Host ''

    return @($Checks | Where-Object { $_.State -eq 'Fail' }).Count -eq 0
}
