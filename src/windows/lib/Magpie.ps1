# magpie bridge, Windows implementation.
# Implements src/common/SPEC.md section 13: export the provider this machine's
# Claude Code already uses into the format magpie can import.
#
# The token never leaves %USERPROFILE%\.claude\settings.json: the import link
# is built without it and magpie asks for it once, in its own prompt.

$script:MagpiePath = ''
$script:MagpieVersion = ''
$script:MagpieName = ''
$script:MagpieRoot = ''
$script:MagpieModels = ''
$script:MagpieLink = ''

# Find-Magpie -> sets $script:MagpiePath when an executable is found.
function Find-Magpie {
    $script:MagpiePath = ''
    $script:MagpieVersion = ''

    $candidates = New-Object System.Collections.ArrayList
    $cmd = Get-Command magpie -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\magpie\magpie.exe')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'magpie\magpie.exe')) }
    [void]$candidates.Add((Join-Path $env:USERPROFILE 'magpie\magpie.exe'))

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $script:MagpiePath = $c; break }
    }
    if ($script:MagpiePath) {
        try {
            $out = & $script:MagpiePath --version 2>$null
            if ($out) { $script:MagpieVersion = ([string]($out | Select-Object -First 1)).Trim() }
        } catch { }
    }
}

# Get-MagpieDefaultName <host> -> a short, ASCII provider name.
# console.eu.example.com -> example; api.anthropic.com -> anthropic.
function Get-MagpieDefaultName {
    param([string]$HostName)

    $h = $HostName
    if ($h -match ':') { $h = $h.Split(':')[0] }
    if (-not $h -or $h -eq 'localhost' -or $h -eq '127.0.0.1') { return 'local' }
    if ($h.Contains('.')) {
        $labels = $h.Split('.')
        if ($labels.Count -ge 2) { return $labels[$labels.Count - 2] }
        return $labels[0]
    }
    return $h
}

# Get-MagpieAnthropicRoot <base-url>
# SPEC 13.2: strip a trailing /v1/messages, then a trailing /v1, then any
# trailing slash. magpie appends /v1/messages itself.
function Get-MagpieAnthropicRoot {
    param([string]$Url)

    $u = $Url
    while ($u.EndsWith('/')) { $u = $u.Substring(0, $u.Length - 1) }
    if ($u.EndsWith('/v1/messages')) { $u = $u.Substring(0, $u.Length - '/v1/messages'.Length) }
    elseif ($u.EndsWith('/v1')) { $u = $u.Substring(0, $u.Length - '/v1'.Length) }
    return $u
}

function Get-MagpieModelsCsv {
    $names = New-Object System.Collections.ArrayList
    foreach ($m in $script:Core.Models) {
        if ($m.name -and -not $names.Contains($m.name)) { [void]$names.Add($m.name) }
    }
    return ($names -join ',')
}

# magpie refuses a tier until the agent itself has a model, so the default
# pick always comes first.
function Get-MagpieSelectCommand {
    if ($script:Core.Models.Count -eq 0) { return '' }
    $default = $script:Core.Models[0].name
    if (-not $default) { return '' }
    return "magpie claude $($script:MagpieName)/$default"
}

# One `magpie claude <tier> <name>/<id>` per tier the CLI config bound.
function Get-MagpieTierCommands {
    $cmds = New-Object System.Collections.ArrayList
    foreach ($tier in @('sonnet', 'opus', 'haiku', 'fable')) {
        if (-not $script:MagpieTierModels) { continue }
        $id = $script:MagpieTierModels[$tier]
        if (-not $id) { continue }
        [void]$cmds.Add("magpie claude $tier $($script:MagpieName)/$id")
    }
    return $cmds
}

# RFC 3986 unreserved bytes left alone, everything else percent-encoded.
function ConvertTo-MagpieEscape {
    param([string]$Text)
    return [System.Uri]::EscapeDataString($Text)
}

# Build the export. SPEC 13.3: name, anthropic and models, never the key.
function Build-MagpieExport {
    $name = $script:MagpieProviderName
    if (-not $name) { $name = Get-MagpieDefaultName $script:Core.BaseHost }

    if ($name -notmatch '^[A-Za-z0-9._-]+$') {
        Stop-WithError 2 'usage' "--provider-name must be ASCII letters, digits, dot, dash or underscore: $name"
    }

    $script:MagpieName = $name
    $script:MagpieRoot = Get-MagpieAnthropicRoot $script:Core.BaseUrl
    $script:MagpieModels = Get-MagpieModelsCsv

    $script:MagpieLink = 'magpie://import?name=' + (ConvertTo-MagpieEscape $script:MagpieName) +
        '&anthropic=' + (ConvertTo-MagpieEscape $script:MagpieRoot)
    if ($script:MagpieModels) {
        $script:MagpieLink += '&models=' + (ConvertTo-MagpieEscape $script:MagpieModels)
    }

    if ($script:MagpieRoot -notlike 'https://*' -and
        $script:MagpieRoot -notlike 'http://localhost*' -and
        $script:MagpieRoot -notlike 'http://127.0.0.1*') {
        Stop-WithError 3 'unusable-config' "magpie only accepts https for a remote base URL: $($script:MagpieRoot)"
    }
}

function Get-MagpiePlanObject {
    $tiers = @()
    foreach ($c in (Get-MagpieTierCommands)) { $tiers += $c }
    $models = @()
    foreach ($m in $script:Core.Models) { if ($m.name) { $models += $m.name } }

    return [ordered]@{
        ok             = $true
        mode           = 'magpie'
        baseUrl        = $script:Core.BaseUrl
        baseUrlHost    = $script:Core.BaseHost
        authScheme     = $script:Core.AuthScheme
        tokenSource    = $script:Core.TokenSource
        tokenLength    = ([string]$script:Core.Token).Length
        providerName   = $script:MagpieName
        anthropicRoot  = $script:MagpieRoot
        models         = $models
        importLink     = $script:MagpieLink
        magpieInstalled = [bool]$script:MagpiePath
        magpiePath     = $script:MagpiePath
        magpieVersion  = $script:MagpieVersion
        selectCommand  = (Get-MagpieSelectCommand)
        tierCommands   = $tiers
        warnings       = @($script:State.Warnings)
        errors         = @()
    }
}

function Write-MagpieInstallHint {
    Write-Note 'install magpie, then run this again:'
    Write-Note '  download the signed build from https://usemagpie.ai'
    Write-Note '  (there is no official one-line installer for Windows)'
}

# The command line cannot take the key: `magpie import` reads it from the link
# and has no prompt, so a keyless link always fails there. The app does ask, so
# the link goes to the app and the key goes into its own field, never into
# argv, a URL we write, or shell history (SPEC 13.6).
function Open-MagpieImportLink {
    if (-not $script:MagpiePath) {
        Write-MagpieInstallHint
        Stop-WithError 5 'magpie-missing' 'magpie is not installed'
    }
    Write-Note 'opening the link in magpie; it will ask for the API key'
    try {
        Start-Process -FilePath $script:MagpieLink | Out-Null
    } catch {
        Write-Note 'could not open it; paste this into magpie by hand:'
        [Console]::Out.WriteLine($script:MagpieLink)
        Stop-WithError 6 'magpie-open' 'the app did not accept the link'
    }
    Write-Note 'paste the token from settings.json into magpie, then press Add'
}

# The default pick, then each tier. No secret involved.
function Invoke-MagpieBindTiers {
    if (-not $script:MagpiePath) {
        Write-MagpieInstallHint
        Stop-WithError 5 'magpie-missing' 'magpie is not installed'
    }
    $default = $script:Core.Models[0].name
    if (-not $default) { Stop-WithError 3 'no-model-config' 'no model to bind' }

    Write-Note "running: $($script:MagpiePath) claude $($script:MagpieName)/$default"
    & $script:MagpiePath claude "$($script:MagpieName)/$default"
    if ($LASTEXITCODE -ne 0) { Stop-WithError 6 'magpie-select' 'picking the main model failed' }

    foreach ($tier in @('sonnet', 'opus', 'haiku', 'fable')) {
        $id = $script:MagpieTierModels[$tier]
        if (-not $id) { continue }
        Write-Note "running: $($script:MagpiePath) claude $tier $($script:MagpieName)/$id"
        & $script:MagpiePath claude $tier "$($script:MagpieName)/$id"
        if ($LASTEXITCODE -ne 0) { Stop-WithError 6 'magpie-tier' "tier binding failed for $tier" }
    }
    Write-Note "tiers bound. Claude Code now goes through magpie's gateway, so magpie must stay running:"
    Write-Note "  $($script:MagpiePath) daemon install   # or keep the magpie app open"
}

function Invoke-MagpieCommand {
    # Desktop's filter (SPEC 5.3b) does not exist on this path, and applying it
    # would empty the model list we are here to export.
    $script:MagpieNoFilter = $true
    Invoke-Core $script:AuthOverride

    Find-Magpie
    Build-MagpieExport

    if ($script:State.PlanMode) {
        $plan = Get-MagpiePlanObject
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $plan -Depth 10 -Compress))
        return
    }

    Write-Info "provider name   $($script:MagpieName)"
    Write-Info "anthropic root  $($script:MagpieRoot)"
    Write-Info ("models          " + $(if ($script:MagpieModels) { $script:MagpieModels } else { '<none>' }))
    Write-Info "auth            $($script:Core.AuthScheme) (magpie sends both headers by default)"
    if ($script:MagpiePath) { Write-Info "magpie          $($script:MagpiePath) $($script:MagpieVersion)" }
    else { Write-Note 'magpie          not found' }

    if ($script:MagpieApplyMode) {
        Open-MagpieImportLink
    } else {
        [Console]::Out.WriteLine($script:MagpieLink)
        Write-Note 'nothing was changed. --apply opens this link in magpie to add the provider.'
    }
    if ($script:MagpieSetTiers) {
        Invoke-MagpieBindTiers
    } elseif ($script:MagpieApplyMode) {
        Write-Note 'tier bindings were not applied. Add --set-tiers to bind them:'
        foreach ($c in (Get-MagpieTierCommands)) { Write-Note "  $c" }
    }
}
