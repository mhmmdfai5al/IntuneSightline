Set-StrictMode -Version Latest

$script:SightlineFieldTypes = @('text', 'boolean', 'path', 'select', 'multiselect', 'number')
$script:SightlineWarnedTools = @{}

function Write-SightlineToolWarning {
    param([string] $Key, [string] $Message)

    if ($script:SightlineWarnedTools.ContainsKey($Key)) { return }
    $script:SightlineWarnedTools[$Key] = $true
    Write-Warning $Message
}

function Get-SightlineTools {
    <#
        Scans the tools folder and returns one descriptor per valid manifest.

        The shell learns everything it knows about a tool from here. If the
        shell ever needs a special case for a specific tool id, the contract
        has failed and the manifest needs a new field instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolsRoot)

    $tools = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in Get-ChildItem -LiteralPath $ToolsRoot -Directory | Sort-Object Name) {
        $manifestPath = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        } catch {
            Write-SightlineToolWarning -Key "$($dir.Name):json" -Message "Skipping $($dir.Name): manifest is not valid JSON."
            continue
        }

        $problems = @(Test-SightlineManifest -Manifest $manifest)
        if ($problems.Count -gt 0) {
            Write-SightlineToolWarning -Key "$($dir.Name):manifest" `
                -Message "Skipping $($dir.Name): $(@($problems) -join '; ')"
            continue
        }

        $entryPath = Join-Path $dir.FullName $manifest.entryPoint
        if (-not (Test-Path -LiteralPath $entryPath)) {
            Write-SightlineToolWarning -Key "$($dir.Name):entry" -Message "Skipping $($dir.Name): entry point '$($manifest.entryPoint)' not found."
            continue
        }

        $fields = @()
        if ($manifest.PSObject.Properties.Name -contains 'fields') {
            $fields = @($manifest.fields)
        }

        # Appended by core so the choice is identical everywhere and no tool
        # has to declare it. Tools read $Parameters.outputFormat.
        $fields += [pscustomobject]@{
            id      = 'outputFormat'
            type    = 'select'
            label   = 'Output format'
            options = @('Workbook (.xlsx)', 'Separate CSV files')
            default = 'Workbook (.xlsx)'
        }

        $note = ''
        if ($manifest.PSObject.Properties.Name -contains 'note') { $note = [string]$manifest.note }

        if ($manifest.PSObject.Properties.Name -contains 'hidden' -and $manifest.hidden) {
            continue
        }

        $shortDescription = ''
        if ($manifest.PSObject.Properties.Name -contains 'shortDescription') {
            $shortDescription = [string]$manifest.shortDescription
        }

        $order = 999
        if ($manifest.PSObject.Properties.Name -contains 'order') { $order = [int]$manifest.order }

        $tools.Add([pscustomobject]@{
            Order          = $order
            ShortDescription = $shortDescription
            Note           = $note
            Id             = $manifest.id
            Name           = $manifest.name
            Description    = $manifest.description
            Category       = $manifest.category
            Version        = $manifest.version
            RequiredScopes = @($manifest.requiredScopes)
            Fields         = $fields
            EntryPointPath = $entryPath
            Folder         = $dir.FullName
        })
    }

    return @($tools)
}

function Test-SightlineManifest {
    param([Parameter(Mandatory)] $Manifest)

    $problems = [System.Collections.Generic.List[string]]::new()
    $names    = $Manifest.PSObject.Properties.Name

    foreach ($required in @('id', 'name', 'description', 'version', 'entryPoint', 'requiredScopes')) {
        if ($names -notcontains $required) { $problems.Add("missing '$required'") }
    }

    # A tool may only ever ask for read permissions. Enforced here so a
    # contributed tool cannot quietly widen what the app requests.
    if ($names -contains 'requiredScopes') {
        foreach ($scope in @($Manifest.requiredScopes)) {
            $readOnly = @(Select-SightlineReadOnlyScope -Scopes @($scope))
            if ($readOnly.Count -eq 0) {
                $problems.Add("'$scope' is not a read permission and cannot be requested")
            }
        }
    }

    if ($names -contains 'fields') {
        foreach ($field in @($Manifest.fields)) {
            $fieldNames = $field.PSObject.Properties.Name

            foreach ($required in @('id', 'type', 'label')) {
                if ($fieldNames -notcontains $required) {
                    $problems.Add("field missing '$required'")
                }
            }

            if ($fieldNames -contains 'type' -and $field.type -notin $script:SightlineFieldTypes) {
                $problems.Add("unsupported field type '$($field.type)'")
            }

            if ($fieldNames -contains 'type' -and $field.type -in @('select', 'multiselect')) {
                if ($fieldNames -notcontains 'options') {
                    $problems.Add("field '$($field.id)' needs options")
                }
            }

            # A bad pattern would silently reject everything the admin types,
            # so it is compiled here rather than discovered at run time.
            if ($fieldNames -contains 'pattern' -and $field.pattern) {
                try   { [void][regex]::new([string]$field.pattern) }
                catch { $problems.Add("field '$($field.id)' has an invalid pattern") }
            }
        }
    }

    return @($problems)
}

function Get-SightlineToolAvailability {
    <#
        A tool is available only if every scope its manifest declares was
        actually granted. Checked before the run rather than discovered
        halfway through as a Graph 403.
    #>
    param([Parameter(Mandatory)] $Tool)

    $check = Test-SightlineScope -Required @($Tool.RequiredScopes)

    $reason = if ($check.Satisfied) {
        $null
    } elseif (@(Get-SightlineGrantedScopes).Count -eq 0) {
        'Not signed in, or the token carries no permissions.'
    } else {
        $client = Get-SightlineClientId
        $suffix = if ($client) { " for application $client" } else { '' }
        "Needs $($check.Missing -join ', ') — not consented$suffix."
    }

    [pscustomobject]@{
        Available = $check.Satisfied
        Missing   = @($check.Missing)
        Reason    = $reason
    }
}

function Resolve-SightlineToolParameters {
    <#
        Applies manifest defaults and rejects unknown keys. Tools receive a
        predictable hashtable rather than whatever the browser happened to post.

        Two values come from the shell rather than from any manifest: the output
        format, and the theme the page was showing when the run started. Both
        apply to every tool, so no tool declares them - and both have to be let
        through here explicitly, or the same rejection that keeps tools
        predictable would silently drop them.
    #>
    param(
        [Parameter(Mandatory)] $Tool,
        [hashtable] $Submitted = @{}
    )

    $resolved = @{}

    foreach ($field in @($Tool.Fields)) {
        $names = $field.PSObject.Properties.Name

        if ($Submitted.ContainsKey($field.id) -and $null -ne $Submitted[$field.id]) {
            $value = $Submitted[$field.id]
        }
        elseif ($names -contains 'default') {
            $value = $field.default
        }
        else {
            $value = switch ($field.type) {
                'boolean'     { $false }
                'multiselect' { @() }
                'number'      { 0 }
                default       { '' }
            }
        }

        if ($field.type -eq 'boolean')     { $value = [bool]$value }
        if ($field.type -eq 'number')      { $value = [int]$value }
        if ($field.type -eq 'multiselect') { $value = @($value) }

        if ($names -contains 'pattern' -and $field.pattern -and
            $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            if ($value -notmatch [string]$field.pattern) {
                $hint = if ($names -contains 'patternMessage' -and $field.patternMessage) {
                    [string]$field.patternMessage
                } else {
                    "'$($field.label)' is not in the expected format."
                }
                throw $hint
            }
        }

        $isRequired = ($names -contains 'required') -and $field.required
        if ($isRequired) {
            $empty = ($null -eq $value) -or
                     ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or
                     ($value -is [array]  -and $value.Count -eq 0)
            if ($empty) { throw "'$($field.label)' is required." }
        }

        $resolved[$field.id] = $value
    }

    # Supplied by the shell for every tool. Constrained to known values rather
    # than passed through, so a posted string cannot reach a tool unchecked.
    if ($Submitted.ContainsKey('theme') -and [string]$Submitted['theme'] -eq 'dark') {
        $resolved['theme'] = 'dark'
    } else {
        $resolved['theme'] = 'light'
    }

    return $resolved
}

function Get-SightlineRequiredScopes {
    <#
        The union of every scope the installed tools declare.

        Requesting the minimum and hoping Entra volunteers the rest does not
        work: that behaviour was observed on one shared client and does not
        generalise. A registration returns what you ask for. So ask for what
        the tools need - already-consented scopes are granted silently, and
        anything genuinely missing surfaces as a consent prompt rather than as
        tools that are mysteriously unavailable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolsRoot)

    $scopes = [System.Collections.Generic.List[string]]::new()

    foreach ($tool in @(Get-SightlineTools -ToolsRoot $ToolsRoot)) {
        foreach ($scope in @($tool.RequiredScopes)) {
            if ($scope -and $scopes -notcontains $scope) { $scopes.Add($scope) }
        }
    }

    # Only ever request what a tool declares. Adding anything else - even a
    # read-only convenience scope - risks including something the tenant has
    # not consented, and sign-in is all-or-nothing: one un-consented scope
    # walls the whole request.
    #
    # Manifests are already validated as read-only, but filter again here so
    # the request itself can never widen beyond reads.
    return @(Select-SightlineReadOnlyScope -Scopes @($scopes))
}
