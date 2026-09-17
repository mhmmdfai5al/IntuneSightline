Set-StrictMode -Version Latest

<#
    Microsoft Graph JSON batching.

    Combines up to 20 requests into one HTTP call, which is the difference
    between a few hundred round trips and several thousand when something has
    to be asked per object.

    Three things about $batch differ from ordinary requests and are easy to get
    wrong:

      * The batch returns 200 even when individual requests inside it failed.
        Every sub-response carries its own status and has to be checked.
      * Responses can come back in a different order than they were sent, so
        they are correlated by id rather than position.
      * A throttled sub-request is not retried for you. Failed ones must be
        collected and resent, after waiting the longest retry-after in the set.
#>

$script:SightlineBatchSize = 20

function Invoke-SightlineGraphBatch {
    <#
        Sends a set of GET requests as batches and returns them keyed by id.

        Each request is a hashtable: @{ Id = 'g1'; Url = '/groups/x/members' }
        Url must be relative to the Graph version root, not absolute.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Requests,
        [ValidateSet('v1.0', 'beta')] [string] $Version = 'v1.0',
        [int] $MaxRetries = 4,
        [scriptblock] $OnProgress
    )

    $results  = @{}
    $failures = [System.Collections.Generic.List[string]]::new()

    if ($Requests.Count -eq 0) {
        return [pscustomobject]@{ Responses = $results; Complete = $true; Failure = $null; Batches = 0 }
    }

    $endpoint  = "https://graph.microsoft.com/$Version/`$batch"
    $pending   = [System.Collections.Generic.List[object]]::new()
    foreach ($request in $Requests) { $pending.Add($request) }

    $completed = 0
    $batches   = 0
    $attempt   = 0

    while ($pending.Count -gt 0 -and $attempt -le $MaxRetries) {
        $retryQueue = [System.Collections.Generic.List[object]]::new()
        $waitFor    = 0

        for ($offset = 0; $offset -lt $pending.Count; $offset += $script:SightlineBatchSize) {
            $slice = @($pending[$offset..([math]::Min($offset + $script:SightlineBatchSize - 1, $pending.Count - 1))])
            $batches++

            $payload = @{
                requests = @($slice | ForEach-Object {
                    $entry = @{
                        id     = [string]$_.Id
                        method = 'GET'
                        url    = [string]$_.Url
                    }
                    if ($_.ContainsKey('Headers') -and $_.Headers) { $entry.headers = $_.Headers }
                    $entry
                })
            }

            try {
                $headers = @{
                    Authorization  = "Bearer $(Get-SightlineAccessToken)"
                    'Content-Type' = 'application/json'
                    Accept         = 'application/json'
                }

                $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers `
                    -Body ($payload | ConvertTo-Json -Depth 6 -Compress) -ErrorAction Stop
            }
            catch {
                # The whole batch failed, so every request in it is unresolved.
                foreach ($item in $slice) { $retryQueue.Add($item) }
                $failures.Add("Batch call failed: $($_.Exception.Message)")
                continue
            }

            foreach ($sub in @($response.responses)) {
                $names  = $sub.PSObject.Properties.Name
                $id     = [string]$sub.id
                $status = if ($names -contains 'status') { [int]$sub.status } else { 0 }

                if ($status -ge 200 -and $status -lt 300) {
                    $body = if ($names -contains 'body') { $sub.body } else { $null }

                    $next = $null
                    if ($body -and ($body.PSObject.Properties.Name -contains '@odata.nextLink')) {
                        $next = [string]$body.'@odata.nextLink'
                    }

                    $results[$id] = [pscustomobject]@{
                        Status   = $status
                        Body     = $body
                        NextLink = $next
                        Failure  = $null
                    }
                    $completed++
                    continue
                }

                # 429 and 5xx are worth another attempt; 403 and 404 are answers.
                if ($status -in @(429, 500, 502, 503, 504)) {
                    $original = @($slice | Where-Object { [string]$_.Id -eq $id })
                    if ($original.Count -gt 0) { $retryQueue.Add($original[0]) }

                    if ($sub.PSObject.Properties.Name -contains 'headers' -and $sub.headers) {
                        $hn = $sub.headers.PSObject.Properties.Name
                        foreach ($key in @('Retry-After', 'retry-after')) {
                            if ($hn -contains $key -and $sub.headers.$key) {
                                $value = [int]$sub.headers.$key
                                if ($value -gt $waitFor) { $waitFor = $value }
                            }
                        }
                    }
                    continue
                }

                $detail = ''
                if ($names -contains 'body' -and $sub.body -and
                    ($sub.body.PSObject.Properties.Name -contains 'error')) {
                    $detail = [string]$sub.body.error.message
                }

                $results[$id] = [pscustomobject]@{
                    Status   = $status
                    Body     = $null
                    NextLink = $null
                    Failure  = if ($detail) { "$status - $detail" } else { "HTTP $status" }
                }
                $completed++
            }

            if ($OnProgress) { & $OnProgress $completed $Requests.Count }
        }

        $pending = $retryQueue
        if ($pending.Count -eq 0) { break }

        $attempt++
        if ($attempt -le $MaxRetries) {
            # Wait the longest retry-after the service asked for, or back off.
            $sleep = if ($waitFor -gt 0) { $waitFor } else { [math]::Pow(2, $attempt) * 2 }
            Start-Sleep -Seconds $sleep
        }
    }

    # Anything still pending exhausted its retries.
    foreach ($item in $pending) {
        $results[[string]$item.Id] = [pscustomobject]@{
            Status   = 429
            Body     = $null
            NextLink = $null
            Failure  = 'Throttled and not resolved after retries'
        }
        $failures.Add("Request '$($item.Id)' was throttled and did not complete.")
    }

    return [pscustomobject]@{
        Responses = $results
        Complete  = ($pending.Count -eq 0)
        Failure   = if ($failures.Count -gt 0) { ($failures | Select-Object -First 3) -join '; ' } else { $null }
        Batches   = $batches
    }
}

function Get-SightlineBatchCollection {
    <#
        Batches a set of collection requests and follows any paging that the
        batched responses report.

        Paging cannot be batched - a nextLink is an absolute URL for a specific
        request - so those few are followed one at a time afterwards. In
        practice most groups fit in a single page, so this is rare.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Requests,
        [ValidateSet('v1.0', 'beta')] [string] $Version = 'v1.0',
        [scriptblock] $OnProgress
    )

    $batch = Invoke-SightlineGraphBatch -Requests $Requests -Version $Version -OnProgress $OnProgress

    $items    = @{}
    $partial  = [System.Collections.Generic.List[string]]::new()

    foreach ($id in $batch.Responses.Keys) {
        $response = $batch.Responses[$id]

        if ($response.Failure) {
            $items[$id] = [pscustomobject]@{ Items = @(); Complete = $false; Failure = $response.Failure }
            continue
        }

        $collected = [System.Collections.Generic.List[object]]::new()
        if ($response.Body -and ($response.Body.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $response.Body.value) { $collected.Add($item) }
        }

        $next     = $response.NextLink
        $complete = $true
        $pages    = 0

        while ($next -and $pages -lt 50) {
            try {
                $page = Invoke-SightlineGraphRequest -Uri $next
                $pages++
                if ($page.PSObject.Properties.Name -contains 'value') {
                    foreach ($item in $page.value) { $collected.Add($item) }
                }
                $next = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
            }
            catch {
                $complete = $false
                $partial.Add($id)
                break
            }
        }

        if ($next) { $complete = $false; $partial.Add($id) }

        $items[$id] = [pscustomobject]@{ Items = @($collected); Complete = $complete; Failure = $null }
    }

    return [pscustomobject]@{
        Results  = $items
        Complete = $batch.Complete -and $partial.Count -eq 0
        Failure  = $batch.Failure
        Batches  = $batch.Batches
    }
}
