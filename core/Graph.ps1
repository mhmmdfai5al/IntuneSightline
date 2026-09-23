Set-StrictMode -Version Latest

function Invoke-SightlineGraphRequest {
    <#
        Single Graph call with throttle handling.

        Intune endpoints frequently omit Retry-After on a 429, so we fall
        back to exponential backoff rather than assuming the header is there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method     = 'GET',
        [int]    $MaxRetries = 5
    )

    $attempt = 0

    while ($true) {
        try {
            $headers = @{
                Authorization = "Bearer $(Get-SightlineAccessToken)"
                Accept        = 'application/json'
            }
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -ErrorAction Stop
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            $retryable = $status -in @(429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -ge $MaxRetries) { throw }

            $wait = $null
            $hasResponse = $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response
            if ($hasResponse -and ($_.Exception.Response.PSObject.Properties.Name -contains 'Headers')) {
                $header = $_.Exception.Response.Headers | Where-Object { $_.Key -eq 'Retry-After' }
                if ($header) { $wait = [int](@($header.Value)[0]) }
            }
            if (-not $wait) { $wait = [math]::Pow(2, $attempt) * 2 }

            Start-Sleep -Seconds $wait
            $attempt++
        }
    }
}

function Get-SightlineGraphCollection {
    <#
        Pages a Graph collection to completion.

        Returns both the items and a coverage record. A caller must be able
        to tell "there were none" apart from "collection stopped early",
        or a clean report is indistinguishable from an incomplete one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [scriptblock] $OnProgress,
        [int] $MaxPages = 200
    )

    $items     = [System.Collections.Generic.List[object]]::new()
    $next      = $Uri
    $pages     = 0
    $complete  = $true
    $failure   = $null
    $rejected  = $false

    try {
        while ($next -and $pages -lt $MaxPages) {
            $response = Invoke-SightlineGraphRequest -Uri $next
            $pages++

            if ($response.PSObject.Properties.Name -contains 'value') {
                foreach ($item in $response.value) { $items.Add($item) }
            } else {
                $items.Add($response)
            }

            if ($OnProgress) { & $OnProgress $items.Count }

            $next = if ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
                $response.'@odata.nextLink'
            } else { $null }
        }

        if ($next) {
            $complete = $false
            $failure  = "Stopped after $MaxPages pages; more data remains."
        }
    }
    catch {
        $complete = $false

        # Intune admins reading this know what a 403 means; they don't need
        # a paragraph. The .NET HTTP exception always has the shape "...: 403
        # (Forbidden)." - pull just the code and reason out of it. Anything
        # that doesn't match this exact shape falls back to the message as
        # given, so a genuinely different error is never hidden.
        $raw = $_.Exception.Message
        $short = [regex]::Match($raw, ': (\d{3}) \(([^)]+)\)')
        $failure = if ($short.Success) { "$($short.Groups[1].Value) ($($short.Groups[2].Value))." } else { $raw }

        # A 400 means the query itself was rejected - usually an unsupported
        # $filter. Callers that offer a simpler fallback need to tell that
        # apart from a collection that merely stopped early.
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            if ($code -eq 400) { $rejected = $true }
        }
    }

    [pscustomobject]@{
        Items    = $items
        Count    = $items.Count
        Complete = $complete
        Endpoint = $Uri
        Failure  = $failure
        Rejected = $rejected
    }
}

function ConvertFrom-SightlineBase64Script {
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Base64
    )

    if ([string]::IsNullOrWhiteSpace($Base64)) { return $null }

    try {
        $bytes = [System.Convert]::FromBase64String($Base64)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
}

function Get-SightlineAuditActor {
    <#
        The actor shape varies by how the change was made: an admin in the
        portal, an app using application permissions, or a service. Pull
        whichever identity fields are present rather than assuming one.
    #>
    param($Actor)

    if (-not $Actor) {
        return [pscustomobject]@{ Name = '(unknown)'; Id = ''; Type = 'unknown'; App = '' }
    }

    $names = $Actor.PSObject.Properties.Name

    $upn = ''
    foreach ($field in @('userPrincipalName', 'userId', 'remoteTenantId')) {
        if ($names -contains $field -and $Actor.$field) { $upn = [string]$Actor.$field; break }
    }

    $app = ''
    foreach ($field in @('applicationDisplayName', 'applicationId')) {
        if ($names -contains $field -and $Actor.$field) { $app = [string]$Actor.$field; break }
    }

    $type = if ($names -contains 'type' -and $Actor.type) { [string]$Actor.type } else { 'unknown' }

    $display = if ($upn) { $upn } elseif ($app) { "$app (application)" } else { '(unknown)' }

    return [pscustomobject]@{
        Name = $display
        Id   = if ($names -contains 'userId') { [string]$Actor.userId } else { '' }
        Type = $type
        App  = $app
    }
}

function Get-SightlineAuditContext {
    <#
        Resolves who changed an object and when, from a single fixed-width
        audit query - no retry, no widening.

        Intune's audit API filters server-side only on activityDateTime,
        activityType and displayName; the object touched lives inside each
        event's nested Resources collection, which cannot be filtered on the
        server. So this queries a ±1 hour window around the object's own
        LastModified timestamp, then matches ResourceId client-side against
        whatever that window returns.

        The window is fixed deliberately. Microsoft publishes no latency SLA
        for this endpoint, so ±1 hour is a stated safety margin against an
        unknown rather than a tuned value - widening it automatically would
        trade a small, predictable cost for an unbounded one on a busy
        tenant, and every caller would inherit that trade-off silently.

        Returns $null when the window contains no matching event, rather
        than expanding the search - "not found" is itself useful information
        and should reach the caller as such, not be hidden behind a retry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $ResourceId,
        [Parameter(Mandatory)] [datetime] $Around
    )

    $windowStart = $Around.AddHours(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $windowEnd   = $Around.AddHours(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $base   = 'https://graph.microsoft.com/beta/deviceManagement/auditEvents'
    $filter = "activityDateTime ge $windowStart and activityDateTime le $windowEnd"
    $uri    = "$base`?`$filter=$filter&`$orderby=activityDateTime desc"

    $events = Get-SightlineGraphCollection -Uri $uri -MaxPages 50

    if (-not $events.Complete) {
        return [pscustomobject]@{
            Found = $false; Actor = $null; EventTime = $null
            Note  = "Audit lookup for this window did not finish - $($events.Failure)"
        }
    }

    foreach ($event in $events.Items) {
        $names     = $event.PSObject.Properties.Name
        $resources = @(if ($names -contains 'resources') { $event.resources } else { @() })

        $hit = @($resources | Where-Object {
            $_.PSObject.Properties.Name -contains 'resourceId' -and
            ([string]$_.resourceId) -eq $ResourceId
        })
        if ($hit.Count -eq 0) { continue }

        $en    = $event.PSObject.Properties.Name
        $actor = Get-SightlineAuditActor -Actor $(if ($en -contains 'actor') { $event.actor } else { $null })

        return [pscustomobject]@{
            Found     = $true
            Actor     = $actor.Name
            EventTime = if ($en -contains 'activityDateTime') { [string]$event.activityDateTime } else { $null }
            Note      = $null
        }
    }

    return [pscustomobject]@{
        Found = $false; Actor = $null; EventTime = $null
        Note  = "No audit event matched this object within an hour of $($Around.ToString('yyyy-MM-dd HH:mm')) UTC. The change may be older than the audit retention period, or outside the fixed window this lookup uses."
    }
}
