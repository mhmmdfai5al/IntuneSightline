Set-StrictMode -Version Latest

$script:SightlineJobs = [hashtable]::Synchronized(@{})

function Get-SightlineJob {
    param([Parameter(Mandatory)] [string] $JobId)

    if (-not $script:SightlineJobs.ContainsKey($JobId)) { return $null }
    $job = $script:SightlineJobs[$JobId]

    # Harvest a finished runspace exactly once.
    if ($job.Handle -and $job.Handle.IsCompleted -and $job.State.Status -eq 'Running') {
        try {
            $job.Shell.EndInvoke($job.Handle) | Out-Null
            $errors = @($job.Shell.Streams.Error)
            if ($errors.Count -gt 0 -and -not $job.State.Result) {
                $job.State.Status  = 'Failed'
                $job.State.Message = $errors[0].ToString()
            }
        }
        catch {
            $job.State.Status  = 'Failed'
            $job.State.Message = $_.Exception.Message
        }
        finally {
            $job.Shell.Dispose()
            $job.Shell  = $null
            $job.Handle = $null
        }

        if ($job.State.Status -eq 'Running') {
            $job.State.Status = 'Failed'
            $job.State.Message = 'Tool exited without returning a result.'
        }
    }

    return $job.State
}

function Get-SightlineRunningJob {
    foreach ($id in @($script:SightlineJobs.Keys)) {
        $state = Get-SightlineJob -JobId $id
        if ($state -and $state.Status -eq 'Running') { return $state }
    }
    return $null
}

function Start-SightlineJob {
    <#
        One job at a time by design. No Intune admin runs four collections
        simultaneously, and serialising removes a large class of state bugs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tool,
        [hashtable] $Parameters = @{},
        [Parameter(Mandatory)] [string] $CoreRoot
    )

    if (Get-SightlineRunningJob) {
        throw 'Another tool is already running. Wait for it to finish or cancel it.'
    }

    $jobId = [guid]::NewGuid().ToString('n').Substring(0, 12)

    $state = [hashtable]::Synchronized(@{
        JobId     = $jobId
        ToolId    = $Tool.Id
        ToolName  = $Tool.Name
        Status    = 'Running'
        Percent   = 0
        Step      = 'Starting'
        StartedAt = (Get-Date).ToString('u')
        Message   = $null
        Result    = $null
    })

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions  = 'ReuseThread'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace

    $script = {
        param($CoreRoot, $ToolPath, $Parameters, $State, $AuthContext)

        try {
            foreach ($file in @('Platform.ps1', 'Auth.ps1', 'Graph.ps1', 'Batch.ps1', 'Intune.ps1', 'Output.ps1', 'Workbook.ps1')) {
                . (Join-Path $CoreRoot $file)
            }
            Import-SightlineAuthContext -Context $AuthContext

            # Tools report progress through this, never by writing to the host.
            #
            # GetNewClosure binds $State at creation. Without it PowerShell
            # resolves $State dynamically at call time, so a tool with its own
            # variable called $state shadows the job state and the callback
            # writes to the wrong object.
            $report = {
                param([int]$Percent, [string]$Step)
                $State.Percent = $Percent
                $State.Step    = $Step
            }.GetNewClosure()

            . $ToolPath
            $result = Invoke-Tool -Parameters $Parameters -ReportProgress $report

            $State.Result  = $result
            $State.Percent = 100
            $State.Step    = 'Finished'
            $State.Status  = if ($result.Status -eq 'Failed') { 'Failed' } else { 'Complete' }
            $State.Message = $result.Message
        }
        catch {
            # Keep the location. A bare exception message names the symptom but
            # not the line, which turns a one-minute fix into a guessing game.
            $detail = $_.Exception.Message

            if ($_.InvocationInfo) {
                $where = @()
                if ($_.InvocationInfo.ScriptName) {
                    $where += (Split-Path -Leaf $_.InvocationInfo.ScriptName)
                }
                if ($_.InvocationInfo.ScriptLineNumber) {
                    $where += "line $($_.InvocationInfo.ScriptLineNumber)"
                }
                if ($where.Count -gt 0) { $detail += "  [$($where -join ', ')]" }

                if ($_.InvocationInfo.Line) {
                    $detail += "`n" + $_.InvocationInfo.Line.Trim()
                }
            }

            if ($_.ScriptStackTrace) {
                $frames = @($_.ScriptStackTrace -split "`n" | Select-Object -First 4)
                $detail += "`n" + ($frames -join "`n")
            }

            $State.Status  = 'Failed'
            $State.Message = $detail
            $State.Step    = 'Failed'
        }
    }

    $shell.AddScript($script).
        AddArgument($CoreRoot).
        AddArgument($Tool.EntryPointPath).
        AddArgument($Parameters).
        AddArgument($state).
        AddArgument((Export-SightlineAuthContext)) | Out-Null

    $handle = $shell.BeginInvoke()

    $script:SightlineJobs[$jobId] = @{
        State    = $state
        Shell    = $shell
        Handle   = $handle
        Runspace = $runspace
    }

    return $state
}

function Stop-SightlineJob {
    <#
        Stopping is best-effort. The pipeline is interrupted, but a request
        already in flight to Graph runs to completion first, so a stop can take
        a few seconds on a slow call.

        Whatever the tool had already written to disk stays there. That output
        is partial by definition and the message says so - a half-finished
        export that looks complete is the failure this whole project exists to
        avoid.
    #>
    param([Parameter(Mandatory)] [string] $JobId)

    if (-not $script:SightlineJobs.ContainsKey($JobId)) { return $null }
    $job = $script:SightlineJobs[$JobId]

    if ($job.Shell) {
        try { $job.Shell.Stop() } catch { }
        try { $job.Shell.Dispose() } catch { }
        $job.Shell  = $null
        $job.Handle = $null
    }

    # Without this the runspace stays open for the life of the process.
    if ($job.ContainsKey('Runspace') -and $job.Runspace) {
        try { $job.Runspace.Close() }   catch { }
        try { $job.Runspace.Dispose() } catch { }
        $job.Runspace = $null
    }

    if ($job.State.Status -eq 'Running') {
        $job.State.Status  = 'Cancelled'
        $job.State.Step    = 'Stopped'
        $job.State.Message = 'Stopped before it finished. Any file already written is incomplete - treat it as a partial export, not a result.'
    }

    return $job.State
}
