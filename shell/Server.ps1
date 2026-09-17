Set-StrictMode -Version Latest

function Start-SightlineServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string] $Version = '',
        [int]    $Port = 8787,
        [switch] $NoBrowserLaunch
    )

    $webRoot   = Join-Path $Root 'shell/web'
    $coreRoot  = Join-Path $Root 'core'
    $toolsRoot = Join-Path $Root 'tools'

    # Loopback only. This is a single-admin local tool, not a service, and a
    # stray open port would broadcast tenant data across the network.
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Prefixes.Add("http://localhost:$Port/")
    $prefix = "http://localhost:$Port/"
    $script:SightlinePort    = $Port
    $script:SightlineVersion = $Version
    $script:SightlineUpdate  = @{ Checked = $false; Latest = $null; Url = $null }

    # One background call at startup, never on the request thread. A slow or
    # unreachable GitHub must not delay the page or any tool run - the check
    # fails silently and the banner simply never appears.
    Start-SightlineUpdateCheck -CurrentVersion $Version

    try {
        $listener.Start()
    }
    catch {
        throw "Could not bind to $prefix. Another process may be using port $Port. Try -Port with a different value."
    }

    Write-Host ''
    Write-Host "IntuneSightline is running at http://127.0.0.1:$Port" -ForegroundColor Green
    Write-Host 'Press Ctrl+C in this window to stop.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not $NoBrowserLaunch) {
        Start-SightlineBrowser -Url "http://127.0.0.1:$Port/"
    }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            try {
                Invoke-SightlineRoute -Context $context -WebRoot $webRoot -CoreRoot $coreRoot -ToolsRoot $toolsRoot
            }
            catch {
                Write-SightlineResponse -Context $context -StatusCode 500 -Object @{ error = $_.Exception.Message }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Invoke-SightlineRoute {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $WebRoot,
        [Parameter(Mandatory)] [string] $CoreRoot,
        [Parameter(Mandatory)] [string] $ToolsRoot
    )

    $path   = $Context.Request.Url.AbsolutePath.TrimEnd('/')
    $method = $Context.Request.HttpMethod

    if ([string]::IsNullOrEmpty($path)) { $path = '/' }

    switch -Regex ("$method $path") {

        '^GET /$' {
            $query = $Context.Request.QueryString

            if ($query['code'] -or $query['error']) {
                if ($query['error']) {
                    $detail = [string]$query['error_description']
                    if ($query['error'] -match 'consent_required|interaction_required|invalid_grant' -or
                        $detail -match 'AADSTS65001|admin') {
                        $detail = "No permissions have been consented for this application yet. An " +
                                  "administrator needs to grant its configured API permissions in Entra " +
                                  "(App registrations, API permissions, Grant admin consent). Once that is " +
                                  "done, sign-in here will succeed without prompting."
                    }
                    Write-SightlineAuthLanding -Context $Context -Message $detail -Failed
                    return
                }

                try {
                    Complete-SightlineAuthRequest -Code $query['code'] -State $query['state'] | Out-Null
                    Write-SightlineAuthLanding -Context $Context -Message 'Signed in.'
                }
                catch {
                    Write-SightlineAuthLanding -Context $Context -Message $_.Exception.Message -Failed
                }
                return
            }

            Write-SightlineStaticFile -Context $Context -Path (Join-Path $WebRoot 'index.html')
            return
        }

        '^POST /api/connect$' {
            $body     = Read-SightlineRequestBody -Context $Context
            $tenantId = if ($body.PSObject.Properties.Name -contains 'tenantId') { [string]$body.tenantId } else { '' }
            $clientId = if ($body.PSObject.Properties.Name -contains 'clientId') { [string]$body.clientId } else { '' }

            if (-not (Test-SightlineTenantId -Value $tenantId)) {
                Write-SightlineResponse -Context $Context -StatusCode 400 -Object @{ error = 'Tenant ID must be a GUID or a domain such as contoso.onmicrosoft.com.' }
                return
            }
            if (-not (Test-SightlineClientId -Value $clientId)) {
                Write-SightlineResponse -Context $Context -StatusCode 400 -Object @{ error = 'Client ID must be a GUID.' }
                return
            }

            try {
                $url = New-SightlineAuthRequest -TenantId $tenantId.Trim() -ClientId $clientId.Trim() `
                    -Port $script:SightlinePort
                Write-SightlineResponse -Context $Context -Object @{ authUrl = $url }
            }
            catch {
                Write-SightlineResponse -Context $Context -StatusCode 400 -Object @{ error = $_.Exception.Message }
            }
            return
        }

        '^POST /api/disconnect$' {
            Disconnect-SightlineGraph
            Write-SightlineResponse -Context $Context -Object @{ connected = $false }
            return
        }

        '^GET /(app\.js|styles\.css)$' {
            $file = Join-Path $WebRoot ($path.TrimStart('/'))
            Write-SightlineStaticFile -Context $Context -Path $file
            return
        }

        '^GET /api/state$' {
            $auth   = Get-SightlineAuthState
            $saved  = Get-SightlineConfig
            $update = Get-SightlineUpdateState
            Write-SightlineResponse -Context $Context -Object @{
                connected  = $auth.Connected
                version    = $script:SightlineVersion
                updateAvailable = $update.Available
                latestVersion   = $update.Latest
                updateUrl       = $update.Url
                account    = $auth.Account
                tenant     = $auth.TenantName
                tenantId   = $auth.TenantId
                scopes     = $auth.Scopes
                granted    = $auth.Granted
                expiresAt  = $auth.ExpiresAt
                clientId   = (Get-SightlineClientId)
                clientName = (Get-SightlineClientName)
                noRefresh  = $auth.NoRefresh
                discarded  = $auth.Discarded
                savedTenantId = if ($saved -and $saved.PSObject.Properties.Name -contains 'TenantId') { $saved.TenantId } else { '' }
                savedClientId = if ($saved -and $saved.PSObject.Properties.Name -contains 'ClientId') { $saved.ClientId } else { '' }
                platform   = (Get-SightlinePlatform)
                outputRoot = (Get-SightlineOutputRoot)
                running    = (Get-SightlineRunningJob)
            }
            return
        }

        '^GET /api/tools$' {
            $tools = @(Get-SightlineTools -ToolsRoot $ToolsRoot) | ForEach-Object {
                $availability = Get-SightlineToolAvailability -Tool $_
                @{
                    available      = $availability.Available
                    missingScopes  = $availability.Missing
                    unavailableWhy = $availability.Reason
                    id             = $_.Id
                    name           = $_.Name
                    description    = $_.Description
                    shortDescription = $_.ShortDescription
                    note           = $_.Note
                    category       = $_.Category
                    order          = $_.Order
                    version        = $_.Version
                    requiredScopes = $_.RequiredScopes
                    fields         = $_.Fields
                }
            }
            Write-SightlineResponse -Context $Context -Object @{ tools = @($tools) }
            return
        }

        '^POST /api/run$' {
            $body = Read-SightlineRequestBody -Context $Context

            $tools = @(Get-SightlineTools -ToolsRoot $ToolsRoot)
            $tool  = $tools | Where-Object { $_.Id -eq $body.toolId } | Select-Object -First 1
            if (-not $tool) {
                Write-SightlineResponse -Context $Context -StatusCode 404 -Object @{ error = "Unknown tool '$($body.toolId)'." }
                return
            }

            $submitted = @{}
            if ($body.PSObject.Properties.Name -contains 'parameters' -and $body.parameters) {
                foreach ($prop in $body.parameters.PSObject.Properties) {
                    $submitted[$prop.Name] = $prop.Value
                }
            }

            $availability = Get-SightlineToolAvailability -Tool $tool
            if (-not $availability.Available) {
                Write-SightlineResponse -Context $Context -StatusCode 403 -Object @{ error = $availability.Reason }
                return
            }

            try {
                $parameters = Resolve-SightlineToolParameters -Tool $tool -Submitted $submitted
                $state      = Start-SightlineJob -Tool $tool -Parameters $parameters -CoreRoot $CoreRoot
                Write-SightlineResponse -Context $Context -Object $state
            }
            catch {
                Write-SightlineResponse -Context $Context -StatusCode 400 -Object @{ error = $_.Exception.Message }
            }
            return
        }

        '^GET /api/job/[a-f0-9]+$' {
            $jobId = $path.Split('/')[-1]
            $state = Get-SightlineJob -JobId $jobId
            if (-not $state) {
                Write-SightlineResponse -Context $Context -StatusCode 404 -Object @{ error = 'Job not found.' }
                return
            }
            Write-SightlineResponse -Context $Context -Object $state
            return
        }

        '^POST /api/job/[a-f0-9]+/cancel$' {
            $jobId = $path.Split('/')[-2]
            $state = Stop-SightlineJob -JobId $jobId
            Write-SightlineResponse -Context $Context -Object $state
            return
        }

        '^POST /api/open$' {
            $body = Read-SightlineRequestBody -Context $Context
            try {
                $target = $body.path
                # Only ever reveal things inside our own output root.
                $root = (Resolve-Path -LiteralPath (Get-SightlineOutputRoot)).Path
                $full = (Resolve-Path -LiteralPath $target).Path
                if (-not $full.StartsWith($root)) { throw 'Refusing to open a path outside the IntuneSightline output folder.' }

                Open-SightlinePath -Path $full
                Write-SightlineResponse -Context $Context -Object @{ opened = $full }
            }
            catch {
                Write-SightlineResponse -Context $Context -StatusCode 400 -Object @{ error = $_.Exception.Message }
            }
            return
        }

        default {
            Write-SightlineResponse -Context $Context -StatusCode 404 -Object @{ error = 'Not found.' }
        }
    }
}

function Read-SightlineRequestBody {
    param([Parameter(Mandatory)] $Context)

    $reader = [System.IO.StreamReader]::new($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try   { $raw = $reader.ReadToEnd() }
    finally { $reader.Dispose() }

    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    return $raw | ConvertFrom-Json
}

function Write-SightlineResponse {
    param(
        [Parameter(Mandatory)] $Context,
        [int] $StatusCode = 200,
        $Object
    )

    $json  = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Context.Response.StatusCode  = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Write-SightlineAuthLanding {
    # The page Entra redirects back to. Bounces to the app so the admin never
    # has to think about the callback.
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Message,
        [switch] $Failed
    )

    $colour = if ($Failed) { '#a32020' } else { '#1f6b4a' }
    $meta   = if ($Failed) { '' } else { '<meta http-equiv="refresh" content="1;url=/">' }

    $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>IntuneSightline</title>$meta</head>
<body style="font-family:ui-sans-serif,system-ui;padding:3rem;color:#12161a;background:#eef0f2">
<h2 style="font-weight:600;font-size:16px;color:$colour;margin:0 0 8px">$(if ($Failed) { 'Sign-in failed' } else { 'Signed in' })</h2>
<p style="font-size:14px;margin:0 0 16px">$([System.Net.WebUtility]::HtmlEncode($Message))</p>
<p style="font-size:13px"><a href="/">Return to IntuneSightline</a></p>
</body></html>
"@

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Write-SightlineStaticFile {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-SightlineResponse -Context $Context -StatusCode 404 -Object @{ error = 'Not found.' }
        return
    }

    $type = switch ([System.IO.Path]::GetExtension($Path)) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        default { 'application/octet-stream' }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = $type
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Start-SightlineUpdateCheck {
    <#
        Checks GitHub's latest-release endpoint once, in the background, and
        never touches disk or installs anything - Phase 1 is notice only.

        Runs in its own runspace so a slow or absent network cannot delay the
        page. Comparison is by tag string equality: version numbers here are
        plain x.y.z, so a straight mismatch is enough without a semver parser.
    #>
    param([Parameter(Mandatory)] [string] $CurrentVersion)

    if (-not $CurrentVersion) { return }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($Current)

        try {
            $headers = @{ 'User-Agent' = 'IntuneSightline'; Accept = 'application/vnd.github+json' }
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/mhmmdfai5al/IntuneSightline/releases/latest' `
                -Headers $headers -TimeoutSec 5

            $tag = ([string]$release.tag_name).TrimStart('v')
            if ($tag -and $tag -ne $Current) {
                return @{ Available = $true; Latest = $tag; Url = [string]$release.html_url }
            }
            return @{ Available = $false }
        }
        catch {
            # No releases yet, no network, rate-limited - all the same to the
            # reader: nothing to show. Never surfaced as an error.
            return @{ Available = $false }
        }
    }).AddArgument($CurrentVersion)

    $handle = $ps.BeginInvoke()

    # Polled from a timer rather than blocking here. 15s covers the 5s request
    # timeout plus scheduling slack without leaving the check to run forever.
    $script:SightlineUpdate.Handle = $handle
    $script:SightlineUpdate.Shell  = $ps
    $script:SightlineUpdate.Runspace = $runspace
    $script:SightlineUpdate.StartedAt = Get-Date
}

function Get-SightlineUpdateState {
    <#
        Non-blocking poll, called on every /api/state request.

        $Checked means "the background call finished", not "nothing to
        report" - a version once found stays reported on every later poll
        until the session ends. The first draft conflated the two and the
        banner would flash for a single poll cycle then vanish, which is a
        strange thing for a person to notice and a worse thing to explain.
    #>
    $state = $script:SightlineUpdate
    if (-not $state) {
        return [pscustomobject]@{ Available = $false; Latest = $null; Url = $null }
    }

    if ($state.Checked) {
        if ($state.Latest) {
            return [pscustomobject]@{ Available = $true; Latest = $state.Latest; Url = $state.Url }
        }
        return [pscustomobject]@{ Available = $false; Latest = $null; Url = $null }
    }

    if (-not $state.Handle -or -not $state.Handle.IsCompleted) {
        # Give up waiting past 15s so a hung call cannot keep polling forever.
        if ($state.StartedAt -and ((Get-Date) - $state.StartedAt).TotalSeconds -gt 15) {
            $state.Checked = $true
            try { $state.Shell.Stop(); $state.Shell.Dispose(); $state.Runspace.Close() } catch { }
        }
        return [pscustomobject]@{ Available = $false; Latest = $null; Url = $null }
    }

    $result = $null
    try { $result = $state.Shell.EndInvoke($state.Handle) } catch { }
    try { $state.Shell.Dispose(); $state.Runspace.Close() } catch { }

    $state.Checked = $true

    if ($result -and $result.Available) {
        $state.Latest = $result.Latest
        $state.Url    = $result.Url
        return [pscustomobject]@{ Available = $true; Latest = $result.Latest; Url = $result.Url }
    }
    return [pscustomobject]@{ Available = $false; Latest = $null; Url = $null }
}
