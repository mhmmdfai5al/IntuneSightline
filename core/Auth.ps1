Set-StrictMode -Version Latest

# Microsoft Graph PowerShell public client. Users can substitute their own
# app registration with -ClientId if their tenant blocks this one.
$script:SightlineDefaultClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Ask for the resource, not for individual permissions.
#
# Microsoft's documentation is explicit: .default triggers a consent prompt
# only when no delegated permission has been granted between this client and
# Graph at all. Where consent exists, the token comes back carrying every
# scope the tenant has delegated to the app - which is exactly what
# Connect-MgGraph does, and why its permission list looks the way it does.
#
# Naming individual scopes was the wrong model. Sign-in is all-or-nothing, so
# one scope the tenant had not consented walled the entire request; and every
# tool added later risked introducing another. With .default an administrator
# grants a permission in Entra and it simply appears - no code change here.
#
# offline_access is an OIDC scope rather than a Graph resource scope, so it
# sits alongside .default and yields the refresh token that long collections
# need. If a tenant rejects the combination, Connect-SightlineGraph falls back
# to .default alone.
$script:SightlineGraphResource = 'https://graph.microsoft.com/.default'
$script:SightlineDiscoveryScopes = @($script:SightlineGraphResource, 'offline_access')
$script:SightlineFallbackScopes  = @($script:SightlineGraphResource)


$script:SightlineAuth = @{
    ClientId     = $null
    TenantId     = $null
    AccessToken  = $null
    RefreshToken = $null
    ExpiresAt    = [datetime]::MinValue
    Scopes       = @()
    Account      = $null
    TenantName   = $null
    GrantedScopes = @()
    DiscardedScopes = @()
    RestrictionReason = $null
    ClientName        = $null
}

# Set when a tenant refuses .default alongside offline_access, so the session
# has no refresh token and will expire rather than renew.
$script:SightlineNoRefresh = $false

function Get-SightlineAuthState {
    <#
        Read-only view for the shell. Never returns the token itself —
        the browser has no business holding a Graph credential.
    #>
    [pscustomobject]@{
        Connected  = [bool]$script:SightlineAuth.AccessToken
        Account    = $script:SightlineAuth.Account
        TenantId   = $script:SightlineAuth.TenantId
        TenantName = $script:SightlineAuth.TenantName
        Scopes     = @($script:SightlineAuth.Scopes)
        Granted    = @($script:SightlineAuth.GrantedScopes)
        Discarded  = @($script:SightlineAuth.DiscardedScopes)
        RestrictionReason = $script:SightlineAuth.RestrictionReason
        ClientName = $script:SightlineAuth.ClientName
        NoRefresh  = $script:SightlineNoRefresh
        ExpiresAt  = if ($script:SightlineAuth.AccessToken) { $script:SightlineAuth.ExpiresAt.ToString('u') } else { $null }
    }
}

function Connect-SightlineGraph {
    <#
        Device code flow. Works identically on Windows, macOS and Linux,
        and needs no browser on the host running PowerShell.
    #>
    [CmdletBinding()]
    param(
        [string]   $TenantId = 'organizations',
        [string]   $ClientId = $script:SightlineDefaultClientId,
        [string[]] $Scopes = $script:SightlineDiscoveryScopes
    )

    $scopeString = ($Scopes -join ' ')

    try {
        $deviceCode = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
            -Body @{ client_id = $ClientId; scope = $scopeString }
    }
    catch {
        $hint = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message -match 'unauthorized_client|AADSTS7000218|AADSTS700016') {
            $hint = "`n`nThis app registration does not allow device code sign-in. " +
                    "In Entra, open the app, go to Authentication, and set " +
                    "'Allow public client flows' to Yes."
        }
        throw "Could not start sign-in for client $ClientId.$hint"
    }

    Write-Host ''
    Write-Host $deviceCode.message -ForegroundColor Cyan
    Write-Host ''

    $deadline = (Get-Date).AddSeconds($deviceCode.expires_in)
    $interval = [int]$deviceCode.interval
    $token    = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $token = Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $ClientId
                    device_code = $deviceCode.device_code
                }
            break
        }
        catch {
            $detail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            $code   = if ($detail) { $detail.error } else { 'unknown_error' }

            switch ($code) {
                'authorization_pending' { continue }
                'slow_down'             { $interval += 5; continue }
                'authorization_declined' { throw 'Sign-in was declined in the browser.' }
                'expired_token'          { throw 'The sign-in code expired. Run the command again.' }
                'bad_verification_code'  { throw 'Sign-in code was not recognised.' }
                default                  { throw "Sign-in failed: $code" }
            }
        }
    }

    if (-not $token) { throw 'Sign-in timed out.' }

    Set-SightlineToken -Token $token -ClientId $ClientId -TenantId $TenantId -Scopes $Scopes
    Resolve-SightlineTenantIdentity

    Write-Host "Connected as $($script:SightlineAuth.Account)" -ForegroundColor Green
    return Get-SightlineAuthState
}

function Set-SightlineToken {
    param(
        [Parameter(Mandatory)] $Token,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string[]] $Scopes
    )

    $script:SightlineAuth.ClientId    = $ClientId
    $script:SightlineAuth.TenantId    = $TenantId
    $script:SightlineAuth.AccessToken = $Token.access_token
    $script:SightlineAuth.ExpiresAt   = (Get-Date).AddSeconds([int]$Token.expires_in - 120)
    $script:SightlineAuth.Scopes      = $Scopes

    if ($Token.PSObject.Properties.Name -contains 'refresh_token') {
        $script:SightlineAuth.RefreshToken = $Token.refresh_token
    }

    Update-SightlineGrantedScopes
}

function Resolve-SightlineAppIdentity {
    <#
        Resolves the client id to the registration's display name.

        A raw GUID in the status bar is precise and unhelpful - and a mismatched
        client cost us two rounds of debugging earlier, which a readable name
        would have made obvious at a glance.

        Attempted with whatever scopes the token already carries - never a
        reason to request more. If the tenant has consented Directory.Read.All
        or Application.Read.All for a tool, this succeeds; otherwise it fails
        quietly and the status bar shows the id.

        The scope is deliberately not added to the sign-in request: it is not
        consented in every tenant, and sign-in is all-or-nothing, so one
        cosmetic permission would wall the whole thing.
    #>
    $clientId = $script:SightlineAuth.ClientId
    if (-not $clientId) { return }

    try {
        $result = Invoke-SightlineGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$clientId'&`$select=displayName"

        $found = @($result.value)
        if ($found.Count -gt 0 -and $found[0].displayName) {
            $script:SightlineAuth.ClientName = [string]$found[0].displayName
            return
        }

        # Not registered in this tenant as an owned app - try the service
        # principal, which exists for any consented multi-tenant client.
        $sp = Invoke-SightlineGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$clientId'&`$select=displayName"
        $spFound = @($sp.value)
        if ($spFound.Count -gt 0 -and $spFound[0].displayName) {
            $script:SightlineAuth.ClientName = [string]$spFound[0].displayName
        }
    }
    catch {
        $script:SightlineAuth.ClientName = $null
    }
}

function Get-SightlineClientName {
    return $script:SightlineAuth.ClientName
}

function Resolve-SightlineTenantIdentity {
    <#
        Records who collected the data. Without this, two admins with
        different scope tags produce different files and nobody can tell why.
    #>
    try {
        $me = Invoke-SightlineGraphRequest -Uri 'https://graph.microsoft.com/v1.0/me?$select=userPrincipalName'
        $script:SightlineAuth.Account = $me.userPrincipalName
    } catch {
        $script:SightlineAuth.Account = '(unknown)'
    }

    try {
        $org = Invoke-SightlineGraphRequest -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName'
        if ($org.value.Count -gt 0) {
            $script:SightlineAuth.TenantName = $org.value[0].displayName
            $script:SightlineAuth.TenantId   = $org.value[0].id
        }
    } catch {
        $script:SightlineAuth.TenantName = '(unknown)'
    }
}

function Get-SightlineAccessToken {
    if (-not $script:SightlineAuth.AccessToken) {
        throw 'Not connected. Run Connect-SightlineGraph first.'
    }

    if ((Get-Date) -ge $script:SightlineAuth.ExpiresAt -and $script:SightlineAuth.RefreshToken) {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$($script:SightlineAuth.TenantId)/oauth2/v2.0/token" `
            -Body @{
                grant_type    = 'refresh_token'
                client_id     = $script:SightlineAuth.ClientId
                refresh_token = $script:SightlineAuth.RefreshToken
                scope         = ($script:SightlineAuth.Scopes -join ' ')
            }

        Set-SightlineToken -Token $token `
            -ClientId $script:SightlineAuth.ClientId `
            -TenantId $script:SightlineAuth.TenantId `
            -Scopes   $script:SightlineAuth.Scopes
    }

    return $script:SightlineAuth.AccessToken
}

function Export-SightlineAuthContext {
    # Serialisable copy for handing to a background runspace.
    return @{
        ClientId     = $script:SightlineAuth.ClientId
        TenantId     = $script:SightlineAuth.TenantId
        AccessToken  = $script:SightlineAuth.AccessToken
        RefreshToken = $script:SightlineAuth.RefreshToken
        ExpiresAt    = $script:SightlineAuth.ExpiresAt
        Scopes       = @($script:SightlineAuth.Scopes)
        Account       = $script:SightlineAuth.Account
        TenantName    = $script:SightlineAuth.TenantName
        GrantedScopes   = @($script:SightlineAuth.GrantedScopes)
        DiscardedScopes = @($script:SightlineAuth.DiscardedScopes)
    }
}

function Import-SightlineAuthContext {
    param([Parameter(Mandatory)] [hashtable] $Context)

    foreach ($key in $Context.Keys) {
        $script:SightlineAuth[$key] = $Context[$key]
    }
}

function ConvertFrom-SightlineJwtPayload {
    <#
        Reads the claims out of an access token locally. No network call and
        no SDK needed — and it reports what the tenant actually granted rather
        than what we asked for, which is the number that matters.
    #>
    param([Parameter(Mandatory)] [string] $Token)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-SightlineClientId {
    return $script:SightlineAuth.ClientId
}

function Get-SightlineGrantedScopes {
    # Authoritative list of what this token can actually do.
    return @($script:SightlineAuth.GrantedScopes)
}

function Update-SightlineGrantedScopes {
    $claims = ConvertFrom-SightlineJwtPayload -Token $script:SightlineAuth.AccessToken
    if (-not $claims) {
        $script:SightlineAuth.GrantedScopes = @()
        return
    }

    $names = $claims.PSObject.Properties.Name
    $granted = @()

    if ($names -contains 'scp' -and $claims.scp) {
        $granted = @($claims.scp -split ' ' | Where-Object { $_ })
    }
    elseif ($names -contains 'roles' -and $claims.roles) {
        $granted = @($claims.roles)
    }

    $script:SightlineAuth.GrantedScopes = $granted

    if ($names -contains 'upn' -and $claims.upn) { $script:SightlineAuth.Account = $claims.upn }
    elseif ($names -contains 'unique_name' -and $claims.unique_name) { $script:SightlineAuth.Account = $claims.unique_name }
}

function Test-SightlineScope {
    param([Parameter(Mandatory)] [string[]] $Required)

    $granted = @(Get-SightlineGrantedScopes)
    $missing = @($Required | Where-Object { $_ -notin $granted })

    [pscustomobject]@{
        Satisfied = ($missing.Count -eq 0)
        Missing   = $missing
    }
}

function New-SightlinePkcePair {
    # RFC 7636. The verifier never leaves the process; only its hash goes to Entra.
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')

    $sha       = [System.Security.Cryptography.SHA256]::Create()
    $hash      = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $sha.Dispose()
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+','-').Replace('/','_')

    return [pscustomobject]@{ Verifier = $verifier; Challenge = $challenge }
}

function Get-SightlineFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Connect-SightlineGraphInteractive {
    <#
        Authorisation code flow with PKCE over a loopback redirect - the same
        flow Connect-MgGraph uses.

        This matters because device code flow carries no redirect URI, so Entra
        cannot infer that the client is public and falls back to the
        allowPublicClient flag. Registrations that are public by redirect URI
        but not by flag issue a device code and then reject the exchange with
        invalid_client. Loopback avoids that entirely, and Entra ignores the
        port for http://localhost, so nothing extra needs registering.
    #>
    [CmdletBinding()]
    param(
        [string]   $TenantId = 'organizations',
        [string]   $ClientId = $script:SightlineDefaultClientId,
        [string[]] $Scopes   = $script:SightlineDiscoveryScopes,
        [int]      $TimeoutSeconds = 180
    )

    $pkce     = New-SightlinePkcePair
    $port     = Get-SightlineFreePort
    $redirect = "http://localhost:$port/"
    $state    = [guid]::NewGuid().ToString('n')

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($redirect)

    try   { $listener.Start() }
    catch { throw "Could not open a local port for sign-in: $($_.Exception.Message)" }

    $query = @(
        "client_id=$([uri]::EscapeDataString($ClientId))"
        "response_type=code"
        "redirect_uri=$([uri]::EscapeDataString($redirect))"
        "response_mode=query"
        "scope=$([uri]::EscapeDataString($Scopes -join ' '))"
        "state=$state"
        "code_challenge=$($pkce.Challenge)"
        "code_challenge_method=S256"
        "prompt=select_account"
    ) -join '&'

    $authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?$query"

    Write-Host ''
    Write-Host 'Opening your browser to sign in.' -ForegroundColor Cyan
    Write-Host 'If it does not open, paste this address:' -ForegroundColor DarkGray
    Write-Host "  $authUrl" -ForegroundColor DarkGray
    Write-Host ''

    Start-SightlineBrowser -Url $authUrl

    try {
        $task = $listener.GetContextAsync()
        if (-not $task.Wait([timespan]::FromSeconds($TimeoutSeconds))) {
            throw "Sign-in was not completed within $TimeoutSeconds seconds."
        }

        $context  = $task.Result
        $received = $context.Request.QueryString

        $body = @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>IntuneSightline</title></head>
<body style="font-family:system-ui;padding:3rem;color:#12161a">
<h2 style="font-weight:500">Signed in</h2>
<p>You can close this tab and return to the terminal.</p>
</body></html>
'@
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()

        if ($received['error']) {
            throw "Sign-in failed: $($received['error']) - $($received['error_description'])"
        }
        if ($received['state'] -ne $state) {
            throw 'Sign-in response did not match the request. Try again.'
        }
        if (-not $received['code']) {
            throw 'No authorisation code was returned.'
        }

        $code = $received['code']
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }

    $token = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            client_id     = $ClientId
            grant_type    = 'authorization_code'
            code          = $code
            redirect_uri  = $redirect
            code_verifier = $pkce.Verifier
            scope         = ($Scopes -join ' ')
        }

    Set-SightlineToken -Token $token -ClientId $ClientId -TenantId $TenantId -Scopes $Scopes
    Resolve-SightlineTenantIdentity

    Write-Host "Connected as $($script:SightlineAuth.Account)" -ForegroundColor Green
    return Get-SightlineAuthState
}

function Connect-SightlineGraphAuto {
    <#
        Browser sign-in first, device code as fallback.

        Neither flow works everywhere: loopback needs a registered redirect URI,
        device code needs allowPublicClient. Between them almost every
        registration is covered, and the user does not need to know which is
        which.
    #>
    [CmdletBinding()]
    param(
        [string]   $TenantId = 'organizations',
        [string]   $ClientId,
        [string[]] $Scopes   = $script:SightlineDiscoveryScopes,
        [switch]   $UseDeviceCode
    )

    $args = @{ TenantId = $TenantId; Scopes = $Scopes }
    if ($ClientId) { $args.ClientId = $ClientId }

    if ($UseDeviceCode) { return Connect-SightlineGraph @args }

    try {
        return Connect-SightlineGraphInteractive @args
    }
    catch {
        Write-Host ''
        Write-Warning "Browser sign-in did not complete: $($_.Exception.Message)"
        Write-Host 'Falling back to device code.' -ForegroundColor Yellow
        return Connect-SightlineGraph @args
    }
}

$script:SightlinePendingAuth = $null

function New-SightlineAuthRequest {
    <#
        Builds the sign-in URL and stashes the PKCE verifier until the browser
        comes back.

        The redirect lands on "/" rather than a dedicated callback path because
        Entra matches the path of a registered loopback redirect URI exactly.
        Registrations almost always have "http://localhost" with an empty path,
        so anything deeper would be rejected. The port is ignored for loopback,
        which is why no extra registration is needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [int]    $Port,
        [string[]] $Scopes = $script:SightlineDiscoveryScopes
    )

    # Individual scopes are deliberately not named here. .default cannot be
    # combined with dynamic scopes in one request, and does not need to be.

    $pkce     = New-SightlinePkcePair
    $state    = [guid]::NewGuid().ToString('n')
    $redirect = "http://localhost:$Port/"

    $script:SightlinePendingAuth = @{
        Verifier = $pkce.Verifier
        State    = $state
        TenantId = $TenantId
        ClientId = $ClientId
        Redirect = $redirect
        Scopes   = @($Scopes)
        Started  = Get-Date
    }

    $query = @(
        "client_id=$([uri]::EscapeDataString($ClientId))"
        'response_type=code'
        "redirect_uri=$([uri]::EscapeDataString($redirect))"
        'response_mode=query'
        "scope=$([uri]::EscapeDataString($Scopes -join ' '))"
        "state=$state"
        "code_challenge=$($pkce.Challenge)"
        'code_challenge_method=S256'
        'prompt=select_account'
    ) -join '&'

    return "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?$query"
}

function Complete-SightlineAuthRequest {
    <#
        Exchanges the authorisation code for a token, then immediately drops
        every write scope from the working set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $State
    )

    $pending = $script:SightlinePendingAuth
    if (-not $pending) { throw 'No sign-in was in progress.' }
    if ($pending.State -ne $State) { throw 'Sign-in response did not match the request.' }

    $script:SightlinePendingAuth = $null

    try {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$($pending.TenantId)/oauth2/v2.0/token" `
            -Body @{
                client_id     = $pending.ClientId
                grant_type    = 'authorization_code'
                code          = $Code
                redirect_uri  = $pending.Redirect
                code_verifier = $pending.Verifier
                scope         = ($pending.Scopes -join ' ')
            }
    }
    catch {
        $message = $_.Exception.Message
        $code    = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed) {
                if ($parsed.PSObject.Properties.Name -contains 'error_description') {
                    $message = ($parsed.error_description -split "`n")[0]
                }
                if ($parsed.PSObject.Properties.Name -contains 'error') {
                    $code = [string]$parsed.error
                }
            }
        }

        # Microsoft states that static (.default) and dynamic consent cannot be
        # combined in one request. offline_access is an OIDC scope rather than a
        # Graph resource scope so it should sit alongside .default, but if this
        # tenant disagrees, retry without it and accept the shorter session.
        $rejectedCombination = ($code -eq 'invalid_scope') -or ($message -match 'invalid_scope|AADSTS70011|combine')

        if ($rejectedCombination -and $pending.Scopes -contains 'offline_access') {
            Write-Warning 'This tenant rejected .default combined with offline_access. Retrying without it - the session will not refresh and will expire in about an hour.'

            $script:SightlineNoRefresh = $true

            try {
                $token = Invoke-RestMethod -Method Post `
                    -Uri "https://login.microsoftonline.com/$($pending.TenantId)/oauth2/v2.0/token" `
                    -Body @{
                        client_id     = $pending.ClientId
                        grant_type    = 'authorization_code'
                        code          = $Code
                        redirect_uri  = $pending.Redirect
                        code_verifier = $pending.Verifier
                        scope         = ($script:SightlineFallbackScopes -join ' ')
                    }
            }
            catch {
                throw "Could not complete sign-in, with or without offline_access: $message"
            }
        }
        else {
            throw "Could not complete sign-in: $message"
        }
    }

    Set-SightlineToken -Token $token -ClientId $pending.ClientId `
        -TenantId $pending.TenantId -Scopes $pending.Scopes
    Resolve-SightlineTenantIdentity
    Resolve-SightlineAppIdentity
    Restrict-SightlineTokenToReadOnly | Out-Null

    Save-SightlineConfig -TenantId $pending.TenantId -ClientId $pending.ClientId

    return Get-SightlineAuthState
}

function Test-SightlineTenantId {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()

    # A GUID, or a verified domain such as contoso.onmicrosoft.com.
    if ($v -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return $true }
    if ($v -match '^[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?)+$') { return $true }
    return $false
}

function Test-SightlineClientId {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim() -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
}

function Request-SightlineConsent {
    <#
        Deliberately asks for scopes that are not yet consented. This is the
        only path that can raise the admin approval screen, and it is opt-in:
        the user has to ask for it, knowing that is what will happen.

        Normal startup never calls this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Scopes,
        [string] $TenantId = 'organizations',
        [string] $ClientId = $script:SightlineDefaultClientId
    )

    $Scopes = @(Select-SightlineReadOnlyScope -Scopes $Scopes | Where-Object { $_ -notin @('openid','profile','email','offline_access') })
    if ($Scopes.Count -eq 0) { throw 'No read permissions to request.' }

    Write-Host ''
    Write-Host 'Requesting additional read permissions:' -ForegroundColor White
    foreach ($scope in $Scopes) { Write-Host "  $scope" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host 'Intune permissions require admin consent. If you are not an administrator,' -ForegroundColor Yellow
    Write-Host 'you will see an approval screen and the request goes to your admin.'         -ForegroundColor Yellow
    Write-Host ''

    return Connect-SightlineGraphAuto -TenantId $TenantId -ClientId $ClientId `
        -Scopes (@($Scopes) + $script:SightlineDiscoveryScopes | Sort-Object -Unique)
}

function Select-SightlineReadOnlyScope {
    <#
        Keeps only scopes whose action segment is a read.

        Graph scopes are Resource.Action.Scope, so the decision is made on the
        action segment alone. Substring matching would be wrong: every Intune
        scope contains the word "Management", and DeviceManagementManagedDevices
        .Read.All is a read despite containing "Managed".

        Accepted:  Group.Read.All, User.ReadBasic.All, DeviceManagementApps.Read.All
        Rejected:  Domain.ReadWrite.All, Directory.AccessAsUser.All,
                   DeviceManagementManagedDevices.PrivilegedOperations.All
    #>
    param([string[]] $Scopes)

    $keep = [System.Collections.Generic.List[string]]::new()

    foreach ($scope in @($Scopes)) {
        if ([string]::IsNullOrWhiteSpace($scope)) { continue }

        # Sign-in scopes carry no resource access.
        if ($scope -in @('openid', 'profile', 'email', 'offline_access')) {
            $keep.Add($scope)
            continue
        }

        $parts = $scope.Split('.')
        if ($parts.Count -lt 2) { continue }

        $action = $parts[1]

        # Must start with Read, and must not be ReadWrite.
        if ($action -match '^Read' -and $action -notmatch 'Write') {
            $keep.Add($scope)
        }
    }

    return @($keep)
}

function Get-SightlineDiscardedScopes {
    return @($script:SightlineAuth.DiscardedScopes)
}

function Get-SightlineRestrictionReason {
    return $script:SightlineAuth.RestrictionReason
}

function Restrict-SightlineTokenToReadOnly {
    <#
        Exchanges the current token for one carrying read scopes only.

        Filtering our own view of the scope list would be cosmetic — the bearer
        token would still hold write permissions and anything holding that token
        could use them. Trading the refresh token for a narrower grant makes the
        restriction real: the new access token cannot write, because the scopes
        are not in it.

        If the exchange fails the broad token stays in place, so this is
        best-effort and reported honestly rather than assumed.
    #>
    [CmdletBinding()]
    param()

    $all       = @(Get-SightlineGrantedScopes)
    $readOnly  = @(Select-SightlineReadOnlyScope -Scopes $all)
    $discarded = @($all | Where-Object { $_ -notin $readOnly })

    $script:SightlineAuth.DiscardedScopes = $discarded

    if ($discarded.Count -eq 0) {
        $script:SightlineAuth.RestrictionReason = $null
        return $true
    }

    $exchanged = $false

    if ($script:SightlineAuth.RefreshToken) {
        try {
            $token = Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$($script:SightlineAuth.TenantId)/oauth2/v2.0/token" `
                -Body @{
                    grant_type    = 'refresh_token'
                    client_id     = $script:SightlineAuth.ClientId
                    refresh_token = $script:SightlineAuth.RefreshToken
                    scope         = ($readOnly -join ' ')
                }

            Set-SightlineToken -Token $token `
                -ClientId $script:SightlineAuth.ClientId `
                -TenantId $script:SightlineAuth.TenantId `
                -Scopes   $readOnly

            # Confirm from the new token rather than trusting the request.
            $remaining = @(Get-SightlineGrantedScopes | Where-Object { $_ -in $discarded })
            if ($remaining.Count -eq 0) {
                $exchanged = $true
            } else {
                $script:SightlineAuth.RestrictionReason =
                    "Entra reissued the token with the same scopes: $($remaining -join ', ')."
            }
        }
        catch {
            $detail = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'error_description')) {
                    $detail = ($parsed.error_description -split "\r?\n")[0]
                }
            }
            $script:SightlineAuth.RestrictionReason = if ($detail) { $detail } else { $_.Exception.Message }
        }
    }
    else {
        $script:SightlineAuth.RestrictionReason = 'No refresh token was issued, so the grant cannot be narrowed.'
    }

    # Whether or not the exchange worked, the write scopes are removed from the
    # working set. Nothing downstream can see them, gate on them, or use them.
    # The token itself may still carry them, which is why the caller reports
    # the difference rather than claiming success.
    $script:SightlineAuth.GrantedScopes = $readOnly

    return $exchanged
}

function Disconnect-SightlineGraph {
    param([switch] $KeepIdentifiers)

    $script:SightlineAuth.AccessToken       = $null
    $script:SightlineAuth.RefreshToken      = $null
    $script:SightlineAuth.Account           = $null
    $script:SightlineAuth.TenantName        = $null
    $script:SightlineAuth.ClientId          = $null
    $script:SightlineAuth.TenantId          = $null
    $script:SightlineAuth.GrantedScopes     = @()
    $script:SightlineAuth.DiscardedScopes   = @()
    $script:SightlineAuth.RestrictionReason = $null
    $script:SightlineAuth.ExpiresAt         = [datetime]::MinValue
    $script:SightlinePendingAuth            = $null

    if (-not $KeepIdentifiers) { Remove-SightlineConfig }
}
