#Requires -Version 7.0
<#
    Static checks that need no tenant.

    Each one exists because something shipped broken: duplicated function
    definitions that silently overrode edits, collections unrolling to scalars
    under StrictMode, .Add on an object that was not a list, and manifests
    declaring scopes or fields the tool never reads.
#>
[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure { param([string] $Message) $failures.Add($Message) }

$psFiles = @(Get-ChildItem -Path $Root -Recurse -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' })

# --- 1. A function defined twice silently overrides the first -----------------
foreach ($file in $psFiles) {
    $names = [regex]::Matches((Get-Content -Raw $file.FullName), '(?m)^\s*function ([A-Za-z]+-[A-Za-z]+)') |
        ForEach-Object { $_.Groups[1].Value }
    $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count -gt 0) { Add-Failure "$($file.Name): duplicate function definition - $($dupes -join ', ')" }
}

# --- 2. @() must wrap the whole if, not sit inside it --------------------------
foreach ($file in $psFiles) {
    $text = Get-Content -Raw $file.FullName
    foreach ($match in [regex]::Matches($text, '=\s*if\s*\(')) {
        $i = $match.Index + $match.Length; $depth = 1
        while ($i -lt $text.Length -and $depth -gt 0) {
            if ($text[$i] -eq '(') { $depth++ } elseif ($text[$i] -eq ')') { $depth-- }
            $i++
        }
        while ($i -lt $text.Length -and $text[$i] -match '\s') { $i++ }
        if ($i -ge $text.Length -or $text[$i] -ne '{') { continue }

        # Balance the braces: a body containing a nested scriptblock would
        # otherwise be cut at the inner closing brace, hiding the -join or
        # .Count that makes the expression a scalar rather than a collection.
        $start = $i + 1; $i++; $braces = 1
        while ($i -lt $text.Length -and $braces -gt 0) {
            if ($text[$i] -eq '{') { $braces++ } elseif ($text[$i] -eq '}') { $braces-- }
            $i++
        }
        if ($braces -ne 0) { continue }
        $body = $text.Substring($start, $i - $start - 1)
        if ($body -match '@\(' -and $body -notmatch '\)\s*\.\w+|\)\s*-join') {
            $line = ($text.Substring(0, $match.Index) -split "`n").Count
            Add-Failure "$($file.Name):$line - @() inside an if; a single item unrolls to a scalar"
        }
    }
}

# --- 3. .Add only belongs on a list -------------------------------------------
foreach ($file in $psFiles) {
    $text  = Get-Content -Raw $file.FullName
    $lists = [regex]::Matches($text, '\$(\w+)\s*=\s*\[System\.Collections\.Generic\.(?:List|Stack)') |
        ForEach-Object { $_.Groups[1].Value }
    foreach ($use in [regex]::Matches($text, '\$(\w+)\.Add\(')) {
        if ($lists -notcontains $use.Groups[1].Value) {
            Add-Failure "$($file.Name): .Add on `$$($use.Groups[1].Value), which is never declared as a list"
        }
    }
}

# --- 4. Automatic variables are not yours to assign ---------------------------
$auto = @('pid', 'host', 'error', 'input', 'matches', 'this', 'true', 'false', 'null')
foreach ($file in $psFiles) {
    foreach ($set in [regex]::Matches((Get-Content -Raw $file.FullName), '\$(\w+)\s*=\s*[^=]')) {
        if ($auto -contains $set.Groups[1].Value.ToLower()) {
            Add-Failure "$($file.Name): assigns to `$$($set.Groups[1].Value), an automatic variable"
        }
    }
}

# --- 5. Manifests describe what the tool actually is --------------------------
# Sections mirror the Intune admin centre's own navigation. A tool with a
# category outside this set would be rendered under "Other".
$clusters = @('Devices', 'Assignments', 'Scripts', 'Audit')
$types    = @('text', 'boolean', 'path', 'select', 'multiselect', 'number')

foreach ($dir in Get-ChildItem -Path (Join-Path $Root 'tools') -Directory) {
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path $manifestPath)) { continue }

    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    $entry    = Join-Path $dir.FullName $manifest.entryPoint
    if (-not (Test-Path $entry)) { Add-Failure "$($manifest.id): entry point missing"; continue }

    $code = Get-Content -Raw $entry

    foreach ($scope in @($manifest.requiredScopes)) {
        $parts = $scope -split '\.'
        if ($parts.Count -lt 2 -or -not $parts[1].StartsWith('Read') -or $parts[1] -match 'Write') {
            Add-Failure "$($manifest.id): '$scope' is not a read permission"
        }
    }

    if ($manifest.category -notin $clusters) {
        Add-Failure "$($manifest.id): category '$($manifest.category)' is not one of $($clusters -join ', ')"
    }

    # outputFormat and theme are supplied by the shell for every tool, so no
    # manifest declares them.
    $declared = @(@($manifest.fields | ForEach-Object { $_.id }) + 'outputFormat' + 'theme')
    foreach ($use in [regex]::Matches($code, '\$Parameters\.(\w+)')) {
        $name = $use.Groups[1].Value
        $after = $code.Substring($use.Index + $use.Length).TrimStart()
        if ($after.StartsWith('(')) { continue }          # a method call, not a field
        if ($declared -notcontains $name) {
            Add-Failure "$($manifest.id): reads `$Parameters.$name, which the manifest does not declare"
        }
    }

    foreach ($field in @($manifest.fields)) {
        if ($field.type -notin $types) { Add-Failure "$($manifest.id): field '$($field.id)' has type '$($field.type)'" }
        if ($field.type -in @('select', 'multiselect') -and -not $field.options) {
            Add-Failure "$($manifest.id): field '$($field.id)' needs options"
        }
        if ($field.pattern) {
            try { [void][regex]::new([string]$field.pattern) }
            catch { Add-Failure "$($manifest.id): field '$($field.id)' has an invalid pattern" }
        }
    }

    $version = [regex]::Match($code, "\`$ToolVersion\s*=\s*'([\d.]+)'")
    if ($version.Success -and $version.Groups[1].Value -ne $manifest.version) {
        Add-Failure "$($manifest.id): tool says v$($version.Groups[1].Value), manifest says v$($manifest.version)"
    }

    foreach ($required in @('function Invoke-Tool', 'Save-SightlineDataset', 'New-SightlineProvenance')) {
        if ($code -notmatch [regex]::Escape($required)) {
            Add-Failure "$($manifest.id): does not use $required"
        }
    }
}

# --- 6. The shell stays ignorant of individual tools --------------------------
$shell = (Get-Content -Raw (Join-Path $Root 'shell/Server.ps1')) +
         (Get-Content -Raw (Join-Path $Root 'shell/web/app.js'))
foreach ($dir in Get-ChildItem -Path (Join-Path $Root 'tools') -Directory) {
    if ($shell -match [regex]::Escape($dir.Name)) {
        Add-Failure "shell references the tool '$($dir.Name)'; it must not know about individual tools"
    }
}

# --- 7. Each tool resolves on its own ----------------------------------------
# Tools are loaded independently, so a function defined in one tool is invisible
# to another. Pooling every file hid exactly that: a tool built by reusing
# another's code passed the check and failed at runtime.
$coreFunctions = @()
foreach ($file in Get-ChildItem -Path (Join-Path $Root 'core') -Filter '*.ps1') {
    $coreFunctions += [regex]::Matches((Get-Content -Raw $file.FullName), 'function ([A-Za-z]+-[A-Za-z]+)') |
        ForEach-Object { $_.Groups[1].Value }
}

foreach ($dir in Get-ChildItem -Path (Join-Path $Root 'tools') -Directory) {
    $entry = Join-Path $dir.FullName 'Invoke-Tool.ps1'
    if (-not (Test-Path $entry)) { continue }

    $code  = Get-Content -Raw $entry
    $local = @([regex]::Matches($code, 'function ([A-Za-z]+-[A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value })

    foreach ($call in [regex]::Matches($code, '(?<![-\w])([A-Za-z]+-(?:Sightline|Journey)[A-Za-z]*)')) {
        $name = $call.Groups[1].Value
        if ($local -contains $name) { continue }
        if ($coreFunctions -contains $name) { continue }
        Add-Failure "$($dir.Name): calls $name, which is neither defined in the tool nor provided by core"
    }
}

# --- 8. No real tenant identifiers anywhere in the repo -----------------------
# A placeholder copied from a live tenant is easy to write and easy to publish.
$textFiles = @(Get-ChildItem -Path $Root -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1','.js','.html','.css','.json','.md','.yml') -and
                   $_.FullName -notmatch '[\\/]\.git[\\/]' })

foreach ($file in $textFiles) {
    $text = Get-Content -Raw $file.FullName
    foreach ($guid in [regex]::Matches($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
        $value = $guid.Value
        # The Microsoft Graph PowerShell client and an all-zero placeholder are fine.
        if ($value -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { continue }
        if ($value -eq '00000000-0000-0000-0000-000000000000') { continue }
        Add-Failure "$($file.Name): contains a GUID ($value). Tenant and client identifiers must not be committed."
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($failure in $failures) { Write-Host "  FAIL  $failure" -ForegroundColor Red }
    Write-Host ''
    Write-Host "$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "All checks passed across $($psFiles.Count) file(s)." -ForegroundColor Green
exit 0
