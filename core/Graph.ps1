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
        $failure  = $_.Exception.Message

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
