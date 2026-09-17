Set-StrictMode -Version Latest

function Get-SightlinePlatform {
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS)   { return 'macOS' }
    if ($IsLinux)   { return 'Linux' }
    return 'Unknown'
}

function Get-SightlineOutputRoot {
    <#
        Single owner of "where do files go". Tools must never decide this
        for themselves or the output folder becomes unnavigable.
    #>
    $root = switch (Get-SightlinePlatform) {
        'Windows' { Join-Path $env:USERPROFILE 'Documents' }
        default   { $HOME }
    }

    $path = Join-Path $root 'IntuneSightline'
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function New-SightlineRunFolder {
    param(
        [Parameter(Mandatory)] [string] $ToolId
    )

    $stamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $folder = Join-Path (Get-SightlineOutputRoot) "$ToolId-$stamp"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return $folder
}

function Open-SightlinePath {
    <#
        Invoke-Item is not consistent across platforms, so every
        "reveal this in the file manager" call routes through here.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    switch (Get-SightlinePlatform) {
        'Windows' { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Path`"" }
        'macOS'   { Start-Process -FilePath 'open'         -ArgumentList $Path }
        'Linux'   { Start-Process -FilePath 'xdg-open'     -ArgumentList $Path }
        default   { throw 'Unsupported platform.' }
    }
}

function Start-SightlineBrowser {
    param(
        [Parameter(Mandatory)] [string] $Url
    )

    switch (Get-SightlinePlatform) {
        'Windows' { Start-Process $Url }
        'macOS'   { Start-Process -FilePath 'open'     -ArgumentList $Url }
        'Linux'   { Start-Process -FilePath 'xdg-open' -ArgumentList $Url }
        default   { Write-Host "Open $Url in a browser." }
    }
}

function Write-SightlineTextFile {
    <#
        UTF-8 without BOM, LF endings. Fixed here so files written on one
        OS do not look wrong when opened on another.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )

    $normalised = $Content -replace "`r`n", "`n"
    $encoding   = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalised, $encoding)
}

function Get-SightlineConfigPath {
    return Join-Path (Get-SightlineOutputRoot) 'config.json'
}

function Get-SightlineConfig {
    <#
        Remembers the tenant and client the last successful sign-in used.

        Tenants that publish their own app registration would otherwise have
        every admin pasting two GUIDs on every launch, which is the kind of
        friction that quietly kills adoption.
    #>
    $path = Get-SightlineConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Remove-SightlineConfig {
    # Disconnect forgets the tenant entirely, so an admin moving between
    # tenants is not silently reconnected to the previous one.
    $path = Get-SightlineConfigPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Save-SightlineConfig {
    param(
        [string] $TenantId,
        [string] $ClientId
    )

    # Identifiers only. No tokens, no secrets - this file is safe to share.
    $config = [pscustomobject]@{
        TenantId = $TenantId
        ClientId = $ClientId
        SavedAt  = (Get-Date).ToString('u')
    }

    Write-SightlineTextFile -Path (Get-SightlineConfigPath) -Content ($config | ConvertTo-Json)
}
