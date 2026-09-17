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

function Invoke-SightlineScopeDiscovery {
    # Signature note: -UseDeviceCode forces the fallback flow.
    <#
        Signs in with user-consentable scopes only, then reads back everything
        the tenant has already consented for this client.

        This is the whole trick. Entra puts every consented scope for the
        resource in the token, so asking for the minimum reveals the maximum
        without ever triggering an approval prompt.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId = 'organizations',
        [string] $ClientId,
        [switch] $UseDeviceCode
    )

    $args = @{ TenantId = $TenantId; UseDeviceCode = $UseDeviceCode }
    if ($ClientId) { $args.ClientId = $ClientId }

    Connect-SightlineGraphAuto @args | Out-Null

    # Drop every write permission before anything else happens. The token is
    # exchanged for a narrower one, so this is a real restriction rather than
    # a filtered view of a token that could still write.
    $restricted = Restrict-SightlineTokenToReadOnly

    $noise     = @('openid', 'profile', 'email', 'offline_access')
    $granted   = @(Get-SightlineGrantedScopes   | Where-Object { $_ -notin $noise } | Sort-Object)
    $discarded = @(Get-SightlineDiscardedScopes | Where-Object { $_ -notin $noise } | Sort-Object)

    return [pscustomobject]@{
        Account    = (Get-SightlineAuthState).Account
        Tenant     = (Get-SightlineAuthState).TenantName
        Scopes     = $granted
        Discarded  = $discarded
        Restricted = $restricted
        Reason     = (Get-SightlineRestrictionReason)
    }
}

function Write-SightlineScopeReport {
    param(
        [Parameter(Mandatory)] $Discovery,
        [Parameter(Mandatory)] [object[]] $Tools
    )

    if (@($Discovery.Discarded).Count -gt 0) {
        Write-Host 'Write permissions discarded' -ForegroundColor White
        foreach ($scope in $Discovery.Discarded) {
            Write-Host "  $scope" -ForegroundColor DarkGray
        }
        if ($Discovery.Restricted) {
            Write-Host '  Token exchanged for a read-only grant. These are not in it.' -ForegroundColor Green
        } else {
            Write-Host '  Removed from the working set, but still present in the token.' -ForegroundColor Yellow
            Write-Host '  IntuneSightline will not use them. No tool can request or see them.' -ForegroundColor Yellow
            if ($Discovery.Reason) {
                Write-Host "  Narrowing failed: $($Discovery.Reason)" -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }

    Write-Host 'Read permissions available to this session' -ForegroundColor White
    if (@($Discovery.Scopes).Count -eq 0) {
        Write-Host '  (none beyond basic sign-in)' -ForegroundColor Red
    } else {
        foreach ($scope in $Discovery.Scopes) {
            Write-Host "  $scope" -ForegroundColor DarkGray
        }
    }
    Write-Host ''

    $available = [System.Collections.Generic.List[string]]::new()
    $blocked   = [System.Collections.Generic.List[object]]::new()

    foreach ($tool in $Tools) {
        $availability = Get-SightlineToolAvailability -Tool $tool
        if ($availability.Available) {
            $available.Add($tool.Name)
        } else {
            $blocked.Add([pscustomobject]@{ Name = $tool.Name; Missing = @($availability.Missing) })
        }
    }

    Write-Host "Tools  ·  $($available.Count) available, $($blocked.Count) blocked" -ForegroundColor White
    foreach ($name in $available) { Write-Host "  ok    $name" -ForegroundColor Green }
    foreach ($item in $blocked) {
        Write-Host ("  --    {0}  (needs {1})" -f $item.Name, ($item.Missing -join ', ')) -ForegroundColor Yellow
    }

    $needed = @($blocked | ForEach-Object { $_.Missing } | Sort-Object -Unique)

    if ($needed.Count -gt 0) {
        Write-Host ''
        Write-Host "These permissions are not consented for application $(Get-SightlineClientId):" -ForegroundColor Yellow
        foreach ($scope in $needed) { Write-Host "  $scope" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host 'Consent belongs to an application, not to you. If another app registration' -ForegroundColor DarkGray
        Write-Host 'in your tenant already has these, point IntuneSightline at it with -ClientId.'   -ForegroundColor DarkGray
        Write-Host 'To raise the request yourself:  ./Start-IntuneSightline.ps1 -RequestConsent' -ForegroundColor DarkGray
    }

    return $needed
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
